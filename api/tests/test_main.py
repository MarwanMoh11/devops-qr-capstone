import re

import boto3
import pytest
from fastapi.testclient import TestClient
from moto import mock_aws

import main

BUCKET = "test-bucket"
ID_RE = re.compile(r"^[0-9a-f]{64}$")


@pytest.fixture
def s3(monkeypatch):
    monkeypatch.setenv("S3_BUCKET", BUCKET)
    monkeypatch.setenv("AWS_REGION", "us-east-1")
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "testing")
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "testing")
    monkeypatch.delenv("S3_ENDPOINT_URL", raising=False)
    monkeypatch.delenv("S3_KEY_PREFIX", raising=False)
    main.get_settings.cache_clear()
    main.get_s3.cache_clear()
    main.reset_ready_cache()
    with mock_aws():
        client = boto3.client("s3", region_name="us-east-1")
        client.create_bucket(Bucket=BUCKET)
        yield client
    main.get_settings.cache_clear()
    main.get_s3.cache_clear()
    main.reset_ready_cache()


@pytest.fixture
def api(s3):
    with TestClient(main.app) as client:
        yield client


def test_create_returns_201_and_is_idempotent(api, s3):
    first = api.post("/v1/qr", json={"url": "https://example.com"})
    assert first.status_code == 201
    body = first.json()
    assert ID_RE.match(body["id"])
    assert body["key"] == f"qr_codes/{body['id']}.png"
    s3.head_object(Bucket=BUCKET, Key=body["key"])

    second = api.post("/v1/qr", json={"url": "  https://example.com  "})
    assert second.status_code == 201
    assert second.json()["id"] == body["id"]


@pytest.mark.parametrize(
    "url",
    ["ftp://x", "not-a-url", "https://example.com/" + "a" * 2029, "http://", ""],
)
def test_invalid_urls_return_422(api, url):
    assert api.post("/v1/qr", json={"url": url}).status_code == 422


def test_overlong_url_is_exactly_2049_chars():
    assert len("https://example.com/" + "a" * 2029) == 2049


def test_get_returns_png(api):
    qr_id = api.post("/v1/qr", json={"url": "https://example.com"}).json()["id"]
    response = api.get(f"/v1/qr/{qr_id}")
    assert response.status_code == 200
    assert response.headers["content-type"] == "image/png"
    assert response.headers["cache-control"] == "public, max-age=31536000, immutable"
    assert response.content.startswith(b"\x89PNG")


def test_get_unknown_id_returns_404(api):
    assert api.get(f"/v1/qr/{'0' * 64}").status_code == 404


@pytest.mark.parametrize("bad_id", ["abc", "G" * 64, "A" * 64, "0" * 65])
def test_get_bad_id_returns_422(api, bad_id):
    assert api.get(f"/v1/qr/{bad_id}").status_code == 422


def test_healthz(api):
    response = api.get("/healthz")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_readyz_ready_when_bucket_exists(api):
    response = api.get("/readyz")
    assert response.status_code == 200
    assert response.json() == {"status": "ready"}


def test_readyz_unavailable_when_bucket_missing(api, s3):
    s3.delete_bucket(Bucket=BUCKET)
    assert api.get("/readyz").status_code == 503


def test_metrics_exposes_contract_names_with_route_templates(api):
    qr_id = api.post("/v1/qr", json={"url": "https://example.com/metrics"}).json()["id"]
    api.get(f"/v1/qr/{qr_id}")
    api.get("/healthz")
    text = api.get("/metrics").text
    assert "qr_codes_generated_total" in text
    assert "qr_http_request_duration_seconds_bucket" in text
    assert 'qr_storage_errors_total{operation="put"}' in text
    assert 'qr_http_requests_total{method="POST",route="/v1/qr",status="201"}' in text
    assert 'route="/v1/qr/{id}"' in text
    assert qr_id not in text
    assert 'route="/healthz"' not in text


def test_storage_failure_returns_502_without_leaking_error(api, s3):
    s3.delete_bucket(Bucket=BUCKET)
    response = api.post("/v1/qr", json={"url": "https://example.com"})
    assert response.status_code == 502
    assert response.json() == {"detail": "storage unavailable"}
    assert api.get(f"/v1/qr/{'0' * 64}").status_code == 502
