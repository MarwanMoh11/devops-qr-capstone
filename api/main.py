"""QR code API: renders a PNG per URL, stores it in a private S3 bucket and streams it back."""

import hashlib
import json
import logging
import os
import sys
import time
from contextlib import asynccontextmanager
from dataclasses import dataclass
from functools import lru_cache
from io import BytesIO
from typing import Annotated

import boto3
import qrcode
from botocore.config import Config
from botocore.exceptions import BotoCoreError, ClientError
from fastapi import FastAPI, HTTPException, Path
from fastapi.responses import JSONResponse, Response, StreamingResponse
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest
from pydantic import BaseModel, HttpUrl, field_validator

MAX_URL_LENGTH = 2048
READY_CACHE_SECONDS = 5.0
IMMUTABLE_CACHE = "public, max-age=31536000, immutable"
UNINSTRUMENTED_ROUTES = {"/metrics", "/healthz", "/readyz"}


# ---------------------------------------------------------------- configuration


@dataclass(frozen=True)
class Settings:
    s3_bucket: str
    aws_region: str
    s3_endpoint_url: str | None
    s3_key_prefix: str
    log_level: str


@lru_cache
def get_settings() -> Settings:
    bucket = os.environ.get("S3_BUCKET", "").strip()
    if not bucket:
        raise RuntimeError("S3_BUCKET is required")
    return Settings(
        s3_bucket=bucket,
        aws_region=os.environ.get("AWS_REGION", "us-east-1"),
        s3_endpoint_url=os.environ.get("S3_ENDPOINT_URL") or None,
        s3_key_prefix=os.environ.get("S3_KEY_PREFIX", "qr_codes/"),
        log_level=os.environ.get("LOG_LEVEL", "info").upper(),
    )


@lru_cache
def get_s3():
    settings = get_settings()
    config = Config(
        connect_timeout=2,
        read_timeout=5,
        retries={"max_attempts": 2},
        s3={"addressing_style": "path"} if settings.s3_endpoint_url else None,
    )
    # Credentials come from the default chain (env vars locally, Pod Identity on EKS).
    return boto3.client(
        "s3",
        region_name=settings.aws_region,
        endpoint_url=settings.s3_endpoint_url,
        config=config,
    )


# ---------------------------------------------------------------------- logging


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        entry = {
            "ts": self.formatTime(record, "%Y-%m-%dT%H:%M:%S%z"),
            "level": record.levelname.lower(),
            "logger": record.name,
            "msg": record.getMessage(),
        }
        entry.update(getattr(record, "fields", {}))
        if record.exc_info:
            entry["exc"] = self.formatException(record.exc_info)
        return json.dumps(entry)


log = logging.getLogger("qr")


def configure_logging(level: str) -> None:
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter())
    log.handlers[:] = [handler]
    log.setLevel(level)
    log.propagate = False


# ---------------------------------------------------------------------- metrics

HTTP_REQUESTS = Counter(
    "qr_http_requests_total", "HTTP requests by route template", ["route", "method", "status"]
)
HTTP_DURATION = Histogram(
    "qr_http_request_duration_seconds", "HTTP request duration in seconds", ["route", "method"]
)
CODES_GENERATED = Counter("qr_codes_generated_total", "QR codes generated and stored")
STORAGE_ERRORS = Counter("qr_storage_errors_total", "S3 errors by operation", ["operation"])
for _operation in ("put", "get", "head"):
    STORAGE_ERRORS.labels(operation=_operation)


class MetricsMiddleware:
    """Pure ASGI middleware: labels requests by route template, never by raw path."""

    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return
        start = time.perf_counter()
        status = {"code": 500}

        async def send_wrapper(message):
            if message["type"] == "http.response.start":
                status["code"] = message["status"]
            await send(message)

        try:
            await self.app(scope, receive, send_wrapper)
        finally:
            route = scope.get("route")
            template = getattr(route, "path", None) or "unmatched"
            if template not in UNINSTRUMENTED_ROUTES:
                elapsed = time.perf_counter() - start
                method = scope["method"]
                HTTP_REQUESTS.labels(template, method, str(status["code"])).inc()
                HTTP_DURATION.labels(template, method).observe(elapsed)
                log.info(
                    "request",
                    extra={
                        "fields": {
                            "route": template,
                            "method": method,
                            "status": status["code"],
                            "duration_ms": round(elapsed * 1000, 1),
                        }
                    },
                )


# -------------------------------------------------------------------------- app

_ready_cache: dict[str, float | bool] = {}


def reset_ready_cache() -> None:
    _ready_cache.clear()


@asynccontextmanager
async def lifespan(_app: FastAPI):
    settings = get_settings()
    configure_logging(settings.log_level)
    log.info("startup", extra={"fields": {"bucket": settings.s3_bucket}})
    yield


app = FastAPI(title="QR code API", lifespan=lifespan, docs_url=None, redoc_url=None)
app.add_middleware(MetricsMiddleware)


class CreateQr(BaseModel):
    url: str

    @field_validator("url")
    @classmethod
    def validate_url(cls, value: str) -> str:
        value = value.strip()
        if len(value) > MAX_URL_LENGTH:
            raise ValueError(f"url must be at most {MAX_URL_LENGTH} characters")
        parsed = HttpUrl(value)
        if not parsed.host:
            raise ValueError("url must have a host")
        return str(parsed)


def object_key(qr_id: str) -> str:
    return f"{get_settings().s3_key_prefix}{qr_id}.png"


def render_png(url: str) -> bytes:
    qr = qrcode.QRCode(error_correction=qrcode.constants.ERROR_CORRECT_L, box_size=10, border=4)
    qr.add_data(url)
    qr.make(fit=True)
    buffer = BytesIO()
    qr.make_image(fill_color="black", back_color="white").save(buffer, format="PNG")
    return buffer.getvalue()


def storage_unavailable(operation: str, exc: Exception) -> HTTPException:
    STORAGE_ERRORS.labels(operation=operation).inc()
    log.warning(
        "storage error",
        extra={"fields": {"operation": operation, "error": type(exc).__name__}},
    )
    return HTTPException(status_code=502, detail="storage unavailable")


@app.post("/v1/qr", status_code=201)
def create_qr(body: CreateQr) -> dict[str, str]:
    qr_id = hashlib.sha256(body.url.encode()).hexdigest()
    key = object_key(qr_id)
    try:
        get_s3().put_object(
            Bucket=get_settings().s3_bucket,
            Key=key,
            Body=render_png(body.url),
            ContentType="image/png",
            CacheControl=IMMUTABLE_CACHE,
        )
    except (ClientError, BotoCoreError) as exc:
        raise storage_unavailable("put", exc) from None
    CODES_GENERATED.inc()
    return {"id": qr_id, "key": key}


@app.get("/v1/qr/{id}")
def get_qr(
    qr_id: Annotated[str, Path(alias="id", pattern=r"^[0-9a-f]{64}$")],
) -> StreamingResponse:
    try:
        obj = get_s3().get_object(Bucket=get_settings().s3_bucket, Key=object_key(qr_id))
    except ClientError as exc:
        if exc.response.get("Error", {}).get("Code") in ("NoSuchKey", "404"):
            raise HTTPException(status_code=404, detail="not found") from None
        raise storage_unavailable("get", exc) from None
    except BotoCoreError as exc:
        raise storage_unavailable("get", exc) from None
    return StreamingResponse(
        obj["Body"].iter_chunks(),
        media_type="image/png",
        headers={"Cache-Control": IMMUTABLE_CACHE, "Content-Length": str(obj["ContentLength"])},
    )


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/readyz")
def readyz() -> JSONResponse:
    now = time.monotonic()
    checked_at = _ready_cache.get("at")
    if checked_at is None or now - float(checked_at) >= READY_CACHE_SECONDS:
        try:
            get_s3().head_bucket(Bucket=get_settings().s3_bucket)
            ready = True
        except (ClientError, BotoCoreError) as exc:
            STORAGE_ERRORS.labels(operation="head").inc()
            log.warning("readiness check failed", extra={"fields": {"error": type(exc).__name__}})
            ready = False
        _ready_cache.update(at=now, ready=ready)
    if _ready_cache["ready"]:
        return JSONResponse({"status": "ready"})
    return JSONResponse({"status": "unavailable"}, status_code=503)


@app.get("/metrics")
def metrics() -> Response:
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)
