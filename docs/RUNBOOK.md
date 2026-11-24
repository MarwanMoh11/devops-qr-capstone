# RUNBOOK

How to run, operate and tear down the DevOps QR capstone. Every step is a `make` target.
Each target runs one script in `scripts/`. Scripts print every external command they run on
a line starting with `+`, so the terminal shows exactly what happened.

> **Honesty note.** The cloud sections (GitHub repo onward) are scripted and statically
> checked (shellcheck, actionlint, `make -n`, dry runs against stub CLIs) but have **not yet
> been run against AWS**. No output below is real terminal output; each step says in one
> line what success looks like.

Constants (`project.env`): region `us-east-1`, cluster `devops-qr-eks`, kind cluster
`qr-kind`, namespaces `qr-app` and `monitoring`, ECR repos `devops-qr/api` and
`devops-qr/web`. Pinned tool versions are in `tool-versions.env`.

Kube contexts: every kubectl/helm call names its context explicitly, `kind-qr-kind` for
kind and `devops-qr-eks` for EKS (created by `aws eks update-kubeconfig --alias`). A
teardown can never touch kind, and a kind deploy can never touch EKS.

## 1. Prerequisites

- macOS with Homebrew, and a running Docker engine with about 4 CPUs and 6–8 GB of RAM:
  `make tools` installs Colima and the docker CLI, then `colima start --cpu 4 --memory 8`
  (Docker Desktop with at least 6 GB under Settings → Resources also works instead).
  `make doctor` fails if `docker info` does not work and prints the start command.
- A **standard AWS account** (credits are fine). AWS Academy / Learner Lab accounts block
  IAM role and OIDC provider creation; the preflight refuses them.
- A GitHub account.
- Human steps, once: `make tools` and `colima start --cpu 4 --memory 8`, then `aws login`
  as an IAM admin user, not root (or `aws sso login`), and `gh auth login`.

## 2. First-time setup sequence

```bash
make tools          # brew bundle --file=Brewfile (CLIs, Colima, docker)
colima start --cpu 4 --memory 8   # skip if Docker is already running
aws login           # IAM admin user, not root (or: aws sso login)
gh auth login
make doctor
make test lint local-up local-smoke local-down        # optional local proof
make kind-up kind-deploy kind-smoke kind-monitoring    # optional cluster proof
make grafana CLUSTER=kind                              # optional; Ctrl-C to stop
make kind-down
git add -A && git commit -m "Initial commit"   # gh-repo pushes commits only and refuses a dirty tree
make gh-repo
make up             # = bootstrap, infra-up, platform-up, release, smoke-test
make url
make grafana
make nuke           # when finished
```

## 3. Targets

### Setup

| Target | Runs | Success looks like |
|---|---|---|
| `help` | `awk` over the Makefile's `## ` comments | Every target listed by group with a one-line description. |
| `tools` | `brew bundle --file=Brewfile` | brew reports the bundle is complete. Terraform comes from `hashicorp/tap` (core is frozen at 1.5.7). tflint is not installed: there is no Homebrew formula, so `make lint` runs the pinned image `TFLINT_IMAGE` with Docker. |
| `doctor` | `scripts/doctor.sh`: `terraform version`, `aws --version`, `kubectl version --client`, `helm version --short`, `kind version`, `kustomize version`, `kubeconform -v`, `hadolint --version`, `actionlint --version`, `shellcheck --version`, `jq`, `gh`, `curl`, `openssl`, `docker --version`; `docker info`; `aws sts get-caller-identity`; `gh auth status` | Every tool line says `ok`, Docker is running, and it ends with `doctor: all required checks passed`. Version drift from `tool-versions.env` and missing logins are `warn` lines; missing tools or Docker down fail it. |

### Quality

| Target | Runs | Success looks like |
|---|---|---|
| `lint` | `scripts/lint.sh all`: `shellcheck scripts/*.sh`; `actionlint`; `hadolint --config .hadolint.yaml api/Dockerfile front-end-nextjs/Dockerfile`; `terraform fmt -check -recursive infra`; per stack `terraform -chdir=infra/<stack> init -backend=false -input=false` + `validate`; `docker run --rm -v "$PWD/infra:/data" -w /data --entrypoint sh $TFLINT_IMAGE -c 'tflint --init --config /data/.tflint.hcl && tflint --recursive --config /data/.tflint.hcl'` (one container so the aws ruleset survives; CI uses the setup-tflint binary with the same two commands); `kustomize build k8s/base`, `k8s/overlays/local` and a temp copy of `k8s/overlays/eks` with placeholder values, each piped to `kubeconform -strict -summary -kubernetes-version 1.36.0 -ignore-missing-schemas`; `helm template kps oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack --version 93.4.0 -n monitoring -f monitoring/kps-values.yaml [-f monitoring/kps-values-kind.yaml] \| kubeconform -summary -ignore-missing-schemas`; `kustomize build monitoring \| kubeconform`; `jq empty monitoring/dashboards/qr-services.json` | Ends with `lint (all): passed`. One part at a time: `scripts/lint.sh shell\|actions\|docker\|terraform\|k8s\|monitoring`. |
| `test` | `scripts/test.sh`: `docker build --target test api`, `docker build --target test front-end-nextjs` | Both builds finish (api runs ruff + pytest, web runs eslint) and it prints `tests passed`. |
| `fmt` | `terraform fmt -recursive infra` | Lists any reformatted files; a second run prints nothing. |

### Local: Docker Compose

| Target | Runs | Success looks like |
|---|---|---|
| `build` | `scripts/build.sh`: `docker build --target runtime -t qr-api:dev api`, `docker build --target runtime -t qr-web:dev front-end-nextjs` | `docker images` lists `qr-api:dev` and `qr-web:dev` (native arch, never pushed). |
| `local-up` | `scripts/local.sh up`: `docker compose --project-directory . -f compose.yaml up -d --build --wait` | Compose reports every service healthy or completed; the app is at `http://localhost:3000`. |
| `local-smoke` | `scripts/smoke-test.sh http://localhost:3000` (see `smoke-test`) | Ends with `smoke test passed: http://localhost:3000`. |
| `local-logs` | `docker compose ... logs --no-color --tail=200` | Recent logs from `qr-s3`, `qr-s3-init`, `qr-api`, `qr-web`. |
| `local-down` | `docker compose ... down -v --remove-orphans` | Containers, network and volumes removed. |

### Local: kind

| Target | Runs | Success looks like |
|---|---|---|
| `kind-up` | `scripts/kind.sh up`: `kind create cluster --name qr-kind --config k8s/kind/cluster.yaml --wait 120s` (skipped if it exists), `kubectl --context kind-qr-kind get nodes` | One node `Ready`. |
| `kind-deploy` | `scripts/kind.sh deploy`: `scripts/build.sh`; `kind load docker-image qr-api:dev qr-web:dev --name qr-kind`; `kubectl --context kind-qr-kind apply -f k8s/namespace.yaml`; `scripts/deploy.sh local dev`, which copies `k8s/` to a temp dir, runs `kustomize edit set image qr-api=qr-api:dev qr-web=qr-web:dev` in the copied `overlays/local`, `kustomize build`, `kubectl -n qr-app delete job --all --ignore-not-found` (the bucket-init Job is immutable and MinIO uses an emptyDir, so it is re-run on every deploy), `kubectl apply -f <rendered>`, `kubectl -n qr-app wait --for=condition=complete job --all --timeout=360s`, `kubectl -n qr-app rollout status deploy/qr-api` and `deploy/qr-web` (`--timeout=300s`) | Both rollouts report `successfully rolled out` and it prints `app: http://localhost:8080`. |
| `kind-smoke` | `scripts/smoke-test.sh http://localhost:8080` | Ends with `smoke test passed: http://localhost:8080`. |
| `kind-monitoring` | `scripts/monitoring-up.sh kind` (see `monitoring-up`), with `-f monitoring/kps-values-kind.yaml` added | Helm reports the `kps` release deployed; `make grafana CLUSTER=kind` then shows the "QR services" dashboard. |
| `kind-down` | `kind delete cluster --name qr-kind` | `kind get clusters` no longer lists `qr-kind`. |

### GitHub

| Target | Runs | Success looks like |
|---|---|---|
| `gh-repo` | `scripts/gh-repo.sh`: stops if `git status --porcelain` is non-empty (commit first); without an `origin` remote, `gh repo create devops-qr-capstone --private --source . --remote origin --push`; with one, `git push -u origin main` | The repo exists, `main` is pushed, and the first CI runs are green with every AWS job shown as skipped. |
| `gh-setup` | `scripts/gh-setup.sh`: reads `terraform -chdir=infra/bootstrap output -json` and `terraform -chdir=infra/main output -json`, then `gh variable set <NAME> --repo <owner/repo> --body <value>` for each §5.4 mapping whose output exists; ends with `gh variable list` | `gh variable list` shows `AWS_ACCOUNT_ID`, `AWS_REGION`, `TF_STATE_BUCKET`, `AWS_PLAN_ROLE_ARN`, `AWS_DEPLOY_ROLE_ARN`, `CLUSTER_ADMIN_ARN` after bootstrap, plus `EKS_CLUSTER_NAME`, `ECR_REGISTRY`, `ECR_REPO_API`, `ECR_REPO_WEB`, `S3_BUCKET` after infra-up. |
| `gh-teardown` | `scripts/gh-teardown.sh $(SCOPE)` (default `main`): `gh variable delete` for the main-stack variables; `gh run list --workflow app.yml --status queued\|in_progress` + `gh run cancel <id>`; with `SCOPE=all` also the bootstrap variables. Missing variables are not errors. | `gh variable list` no longer shows the deleted names. |

| Variable | From Terraform output |
|---|---|
| `AWS_ACCOUNT_ID`, `AWS_REGION`, `TF_STATE_BUCKET` | bootstrap `aws_account_id`, `aws_region`, `tf_state_bucket` |
| `AWS_PLAN_ROLE_ARN`, `AWS_DEPLOY_ROLE_ARN`, `CLUSTER_ADMIN_ARN` | bootstrap `gha_plan_role_arn`, `gha_deploy_role_arn`, `admin_principal_arn` |
| `EKS_CLUSTER_NAME`, `ECR_REGISTRY` | main `cluster_name`, `ecr_registry` |
| `ECR_REPO_API`, `ECR_REPO_WEB`, `S3_BUCKET` | main `ecr_repo_api`, `ecr_repo_web`, `s3_bucket_name` |

### Cloud up (run on AWS, 24 Nov 2026)

`bootstrap`, `infra-plan` and `infra-up` first run the full preflight (the other cloud scripts check only the AWS and/or GitHub login they need): tools present (`terraform kubectl helm kustomize jq curl gh`), `aws sts get-caller-identity` works, the caller is not the account root user (bootstrap rejects root as `admin_principal_arn`), the caller ARN is not an AWS Academy / Learner Lab role and `aws iam list-open-id-connect-providers` is allowed, and `gh auth status` works.

| Target | Runs | Success looks like |
|---|---|---|
| `bootstrap` | `scripts/bootstrap.sh`: preflight; `terraform -chdir=infra/bootstrap init -input=false`; `terraform -chdir=infra/bootstrap apply -input=false -var region=us-east-1 -var github_oidc_sub_prefix=<from gh api repos/<owner/repo>/actions/oidc/customization/sub> -var create_github_oidc_provider=<auto> -auto-approve`; `scripts/gh-setup.sh`. `create_github_oidc_provider` is `false` only when a GitHub OIDC provider already exists in the account and is not in this state (so a re-run never destroys the one it created). | Terraform reports `Apply complete!` and `gh variable list` shows the six bootstrap variables. |
| `infra-plan` | `scripts/infra.sh plan`: preflight; `terraform -chdir=infra/main init -input=false -reconfigure -backend-config=bucket=devops-qr-tfstate-<acct> -backend-config=key=main/terraform.tfstate -backend-config=region=us-east-1 -backend-config=use_lockfile=true`; `terraform -chdir=infra/main plan -input=false -var region=us-east-1 -var kubernetes_version=1.36 -var admin_principal_arn=<bootstrap output>` | A plan summary `Plan: N to add, 0 to change, 0 to destroy` on the first run. |
| `infra-up` | `scripts/infra.sh up`: preflight; `aws eks describe-cluster-versions --region us-east-1 --cluster-versions 1.36` must report `versionStatus` `STANDARD_SUPPORT` (anything else, or an API error, stops the run); the same `init`; `terraform -chdir=infra/main apply ... -auto-approve`; `aws eks update-kubeconfig --region us-east-1 --name devops-qr-eks --alias devops-qr-eks`; `kubectl --context devops-qr-eks get nodes`; `kubectl --context devops-qr-eks apply -f k8s/namespace.yaml` (the CI deploy role cannot create it); `scripts/gh-setup.sh` | `Apply complete!` after about 15–20 minutes, two nodes `Ready`, namespace `qr-app` present, and the five main-stack variables set. |
| `kubeconfig` | `aws eks update-kubeconfig --region us-east-1 --name devops-qr-eks --alias devops-qr-eks` | `kubectl config get-contexts` lists `devops-qr-eks`. |
| `platform-up` | `scripts/cloud.sh platform-up`: kubeconfig; `kubectl --context devops-qr-eks apply -f k8s/namespace.yaml`; `scripts/monitoring-up.sh eks` | Namespace `qr-app` exists and Helm reports `kps` deployed. |
| `monitoring-up` | `scripts/monitoring-up.sh $(CLUSTER)` (default `eks`): `kubectl create namespace monitoring` if absent; creates Secret `grafana-admin` (`admin-user=admin`, `admin-password=$(openssl rand -base64 24)`) if absent; `helm upgrade --install kps oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack --version 93.4.0 --kube-context <ctx> -n monitoring -f monitoring/kps-values.yaml [-f monitoring/kps-values-kind.yaml] --wait --timeout 10m`; `kubectl apply -k monitoring` | Helm prints `STATUS: deployed` and `configmap/qr-dashboards` is applied. |
| `release` | `scripts/release.sh`: checks the `EKS_CLUSTER_NAME` repo variable exists; `gh workflow run app.yml --repo <owner/repo> --ref main`; polls `gh run list --workflow app.yml --branch main --event workflow_dispatch` for the new run id; `gh run watch <id> --exit-status` | The run finishes green: `test`, `manifests`, `publish (api)`, `publish (web)`, `deploy`. |
| `deploy` | `scripts/cloud.sh deploy` (laptop escape hatch): `git fetch origin main`; `aws ecr describe-images --repository-name devops-qr/api` and `devops-qr/web` `--image-ids imageTag=<origin/main sha>` (stops if missing; CI builds the linux/amd64 images); kubeconfig; `scripts/deploy.sh eks <sha>`: temp copy of `k8s/`, then in `overlays/eks`: `kustomize edit set image qr-api=<registry>/devops-qr/api:<sha> qr-web=<registry>/devops-qr/web:<sha>`, `kustomize edit add configmap qr-api-config --behavior=merge --from-literal=S3_BUCKET=devops-qr-qrcodes-<acct> --from-literal=AWS_REGION=us-east-1`, `kustomize build`, `kubectl --context devops-qr-eks get namespace qr-app` (stops with a clear message only on NotFound), `kubectl --context devops-qr-eks apply -f <rendered>`, `rollout status` for both Deployments | Both rollouts report `successfully rolled out`. |
| `url` | `scripts/url.sh`: polls `kubectl --context devops-qr-eks -n qr-app get svc qr-web -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'` for up to 5 minutes | Prints `http://<name>.elb.us-east-1.amazonaws.com`. |
| `smoke-test` | `scripts/smoke-test.sh "$(scripts/url.sh)"`: waits up to 5 minutes for `GET /api/healthz` (new NLB DNS takes 1–3 minutes), `POST /api/qr {"url":"https://example.com"}` must return 201 with `image_url` `/api/qr/<64 hex>`, `GET <image_url>` must return 200 `image/png` starting with the PNG signature | Ends with `smoke test passed: http://<nlb-dns>`. |
| `grafana` | `scripts/grafana.sh $(CLUSTER)` (default `eks`): reads `admin-user`/`admin-password` from Secret `monitoring/grafana-admin`; `kubectl --context <ctx> -n monitoring port-forward svc/kps-grafana 3001:80` | Prints the URL and login, then `Forwarding from 127.0.0.1:3001`. Open `http://localhost:3001` → Dashboards → "QR services". Ctrl-C stops it. |
| `status` | `scripts/cloud.sh status`: `kubectl --context devops-qr-eks get nodes -o wide`; `-n qr-app get deploy,pods,svc`; `-n monitoring get pods`; `-n amazon-cloudwatch get pods`; the URL; `gh run list --limit 5` | All pods `Running`, Deployments `2/2`, and a URL. |
| `up` | `make bootstrap`, `make infra-up`, `make platform-up`, `make release`, `make smoke-test`, in that order | The last line is `smoke test passed: http://<nlb-dns>`. |

### Teardown (not yet run against AWS)

| Target | Runs | Success looks like |
|---|---|---|
| `lb-cleanup` | `scripts/lb-cleanup.sh`: finds the VPC (`terraform output vpc_id`, else `aws ec2 describe-vpcs` with tags `Project=devops-qr`, `Stack=main`); polls `aws elbv2 describe-load-balancers` and `aws elb describe-load-balancers` for load balancers in that VPC for up to 5 minutes, then force-deletes any left (`aws elbv2 delete-load-balancer`, `aws elb delete-load-balancer`); deletes target groups in the VPC; revokes rules in other SGs that reference `k8s-*` SGs and deletes those SGs (retrying while ENIs detach); deletes `available` ENIs in the VPC | Ends with `lb-cleanup done for vpc-…`, or `no project VPC found`. |
| `infra-down` | `scripts/infra-down.sh`, steps 1–5 below | Ends with `infra-down done (bootstrap stack kept ...)`. |
| `nuke` | `scripts/nuke.sh`: `infra-down`, then steps 6–7 below | `verify-clean` prints only `clean` lines and exits 0. |
| `verify-clean` | `scripts/verify-clean.sh` (see section 7) | Every line starts with `clean` and it exits 0. |

Teardown order (§9). Each step can be re-run.

1. `scripts/gh-teardown.sh main`: delete the main-stack variables and cancel queued and in-progress `app.yml` runs, so CI goes back to skipping deploys.
2. If `aws eks describe-cluster --name devops-qr-eks` finds the cluster and the API is reachable: delete every `type: LoadBalancer` Service in any namespace (`kubectl --context devops-qr-eks -n <ns> delete svc <name> --wait=true --timeout=5m`); `kubectl delete namespace qr-app --wait=true --timeout=5m`; `helm uninstall kps --kube-context devops-qr-eks -n monitoring --ignore-not-found --wait --timeout 5m`; `kubectl delete namespace monitoring`. If the cluster is unreachable, this step is skipped and step 3 force-deletes.
3. `scripts/lb-cleanup.sh` (above).
4. `terraform -chdir=infra/main init ...` and `terraform -chdir=infra/main destroy -input=false -var region=us-east-1 -var kubernetes_version=1.36 -var admin_principal_arn=<arn> -auto-approve` (skipped only if `aws s3api head-bucket` returns a definite 404; any other error, such as a 403 or a throttle, stops the teardown). ECR `force_delete` and S3 `force_destroy` empty the repos and bucket.
5. `aws logs describe-log-groups --log-group-name-prefix /aws/containerinsights/devops-qr-eks/`, `/aws/eks/devops-qr-eks/` and `/aws/application-signals/` (account- and region-wide, written by the CloudWatch add-on's Application Signals pipeline), then `aws logs delete-log-group` for each.
6. (nuke) Guard first: stop unless `aws eks describe-cluster` says the cluster is gone and either the state bucket is a definite 404 or `terraform -chdir=infra/main state list` is empty (it stops too if the state cannot be read). The message says to run `make infra-down`, then `make nuke`. Then `terraform -chdir=infra/bootstrap init` and `terraform -chdir=infra/bootstrap destroy -input=false -var region=us-east-1 -var github_oidc_sub_prefix=repo:<owner/repo> -var create_github_oidc_provider=<auto> -auto-approve`. If `infra/bootstrap/terraform.tfstate` is missing: delete every object version and delete marker in `devops-qr-tfstate-<acct>` (`aws s3api list-object-versions` + `aws s3api delete-objects`), `aws s3 rb`, delete roles `devops-qr-gha-deploy` and `devops-qr-gha-plan` (detach managed and delete inline policies first), and delete the GitHub OIDC provider **only if it carries the tag `Project=devops-qr`** (a provider without the tag existed before this project and is kept).
7. (nuke) `scripts/gh-teardown.sh all`, then `scripts/verify-clean.sh`.

## 4. Day 2

- **Deploy a change.** Commit and push to `main` (or merge a PR). `app.yml` tests, builds `linux/amd64`, pushes `:<sha>` to ECR, deploys and smoke-tests. Watch it with `gh run watch`. To re-run the pipeline on the current `main`: `make release`. To deploy from the laptop an image CI already built: `make deploy`.
- **Change infrastructure.** Edit `infra/`, open a PR: `infra.yml` runs fmt/validate/tflint and posts a read-only plan in the job summary. After merging, apply from the laptop with `make infra-plan` then `make infra-up`.
- **Change monitoring.** CI only validates it (`lint.yml`). Apply with `make monitoring-up`; the CI deploy role cannot install CRDs.
- **View Grafana.** `make grafana`, open `http://localhost:3001`, log in with the printed user and password, then Dashboards → "QR services".
- **View Container Insights.** AWS console → CloudWatch → Insights → Container Insights → cluster `devops-qr-eks` (performance monitoring view). Metrics only; container logs are off.
- **Check health.** `make status`.

## 5. Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `terraform destroy` hangs or fails on the VPC, subnets or security groups | An NLB, a `k8s-*` security group or an ENI is still in the VPC (it was created by Kubernetes, outside Terraform). Run `make lb-cleanup`, then `make infra-down` again. Never delete the cluster from the console. |
| Log groups `/aws/containerinsights/devops-qr-eks/*` or `/aws/application-signals/*` remain | The CloudWatch agent recreated them. Step 5 of `make infra-down` sweeps them; re-run it. |
| An EBS volume appears | Something created a PVC. The cluster has no EBS CSI driver, so a PVC should stay Pending; delete the PVC and the volume, then run `make verify-clean`. |
| Destroy fails on a non-empty ECR repo or bucket | Both use `force_delete`/`force_destroy`. If the bootstrap state is lost, `make nuke` uses the aws-cli fallback for the versioned state bucket. |
| `EntityAlreadyExists` for the GitHub OIDC provider | There is one per account. `make bootstrap` detects an existing one and sets `create_github_oidc_provider=false`; re-run it. |
| CI fails with `Not authorized to perform sts:AssumeRoleWithWebIdentity` | The OIDC `sub` must be exactly `<sub prefix>:ref:refs/heads/main`, where the prefix is what GitHub reports for the repo (`repo:<owner>@<id>/devops-qr-capstone@<id>` for repos with immutable subjects) (owner is case-sensitive). Do not use GitHub `environment:` in the workflows; it changes the `sub`. Re-run `make bootstrap` if the repo was renamed. |
| The web or API pod fails probes | The web container needs `HOSTNAME=0.0.0.0`. Any `NEXT_PUBLIC_*` value or `next.config` rewrite is fixed at build time; read env vars only inside route handlers. |
| `exec format error` on EKS | An arm64 image from a Mac reached the x86 nodes. Laptop images are never pushed; only CI pushes `linux/amd64`. |
| kind: `ErrImagePull` / `ImagePullBackOff` | Images must be loaded with `kind load` (done by `make kind-deploy`), and tags must not be `latest`. |
| kind: node-exporter crash-loops | `hostRootFsMount` must be off on Docker Desktop (`monitoring/kps-values-kind.yaml`). Give Docker at least 6 GB of RAM (`colima start --cpu 4 --memory 8`). |
| kind: `kind load docker-image` fails on a third-party image | With Docker's containerd image store, multi-arch images break it; `make kind-deploy` preloads them with `docker save --platform` + `kind load image-archive`. |
| EKS: Container Insights has no node metrics | AWS's Container Insights docs ask for IMDS hop limit 2 for the CloudWatch agent pods; `infra/main/eks.tf` sets `metadata_options.http_put_response_hop_limit = 2` (module default 1). |
| kind: API not ready after a restart | MinIO uses an emptyDir, so the bucket is gone after a MinIO restart. `make kind-deploy` deletes and re-runs the bucket-init Job. |
| ServiceMonitor or CRD errors after a kube-prometheus-stack major bump | Helm does not upgrade CRDs. Apply the new chart's CRDs first (`helm show crds oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack --version <new> \| kubectl --context devops-qr-eks apply --server-side -f -`), then `make monitoring-up`. |
| Pods `Pending` with `Too many pods` | m7i-flex.large allows 29 pods per node (t3a.medium 17). Raise the node group's desired size to 3; a new account's 5-vCPU limit only fits 2, so request an increase first (`node_desired` in `infra/main`), then `make infra-up`. |
| EKS control plane cannot use an AZ | `use1-az3` cannot host the control plane; AZs are chosen by zone ID (`use1-az1`, `use1-az2`) in `infra/main`. |
| Node group fails to create | Without NAT, public subnets need `map_public_ip_on_launch=true`, or nodes cannot reach ECR/EKS. Check `infra/main/vpc.tf`. |
| `svc/qr-web` never gets a hostname | The in-tree LB needs subnets tagged `kubernetes.io/role/elb=1` and exactly one security group tagged `kubernetes.io/cluster/devops-qr-eks` per node. `kubectl --context devops-qr-eks -n qr-app describe svc qr-web` shows the controller's events. If the NLB annotation misbehaves, removing it gives a Classic LB; teardown is the same. |
| `infra-up` refuses the Kubernetes version | 1.36 is no longer in standard support (extended support costs $0.60/h instead of $0.10/h). Change `KUBERNETES_VERSION` in `project.env` and the default in `infra/main/variables.tf`. |
| API returns 403 instead of 404, or `/readyz` fails on EKS | The Pod Identity role needs `s3:ListBucket` on the bucket. Pods must start after the association exists; `kubectl -n qr-app rollout restart deploy/qr-api`. |
| `publish` fails with `tag invalid ... immutable` | The tag already exists. The job checks first and skips; if it still fails, re-run the job. |
| Pushes to `main` try to deploy to a cluster that is gone | The repo variables were not deleted. `make gh-teardown`. |
| The smoke test times out on a new cluster | NLB DNS takes 1–3 minutes to resolve; the test waits 5 minutes. Re-run `make smoke-test`. |
| Bootstrap state lost (`infra/bootstrap/terraform.tfstate`) | Do not delete it. If it is lost, `make nuke` uses the aws-cli fallback (step 6). |
| Preflight says the account is AWS Academy / Learner Lab | Those accounts block IAM roles and OIDC providers. Use a standard account. |
| tflint fails with a GitHub rate limit during `--init` | Export `GITHUB_TOKEN=$(gh auth token)` and re-run `make lint`. |

## 6. Cost

us-east-1, on-demand, while running (§13):

| Item | $/h |
|---|---|
| EKS control plane (standard support) | 0.100 |
| 2 × m7i-flex.large (Free-plan default; 2 × t3a.medium is 0.075) | 0.192 |
| 4 public IPv4 (2 nodes + NLB in 2 AZs) at $0.005 | 0.020 |
| NLB (hour + ~1 NLCU) | 0.029 |
| EBS 2 × 20 GiB gp3 | 0.004 |
| Container Insights (enhanced observability, ~25 containers, logs off) | ~0.02 (estimate; check Cost Explorer after the first day) |
| S3, ECR, Terraform-owned log groups | < 0.005 |
| **Total** | **≈ $0.37/h ≈ $9/day**. Skipping NAT saves ≥ $0.045/h. `make nuke` takes it to $0. |

GitHub Actions: a private repo on the Free plan has 2,000 minutes a month; a full `app.yml`
run is estimated at 6–8 minutes.

## 7. Teardown verification

`make verify-clean` runs `scripts/verify-clean.sh`. It asks each service's own API and
filters by project tag (`Project=devops-qr`), cluster tag
(`kubernetes.io/cluster/devops-qr-eks` or `eks:cluster-name=devops-qr-eks`), VPC or name
prefix, so unrelated resources in the account are not reported:

| Check | AWS CLI call |
|---|---|
| EKS cluster | `aws eks list-clusters` |
| EC2 instances | `aws ec2 describe-instances` (not terminated, with project or cluster tags) |
| ELBv2 / Classic load balancers | `aws elbv2 describe-load-balancers` + `describe-tags`; `aws elb describe-load-balancers` + `describe-tags` |
| EBS volumes | `aws ec2 describe-volumes` filtered by cluster and project tags |
| Elastic IPs | `aws ec2 describe-addresses` |
| NAT gateways | `aws ec2 describe-nat-gateways --filter Name=tag:Project,Values=devops-qr` |
| VPCs and ENIs | `aws ec2 describe-vpcs` (project tag), `aws ec2 describe-network-interfaces` in those VPCs |
| ECR repositories | `aws ecr describe-repositories` (names starting `devops-qr/`) |
| S3 buckets | `aws s3api list-buckets` (names starting `devops-qr-`) |
| Log groups | `aws logs describe-log-groups` for `/aws/containerinsights/devops-qr-eks`, `/aws/eks/devops-qr-eks` and `/aws/application-signals` |
| IAM roles | `aws iam list-roles` (names starting `devops-qr-`, plus EKS cluster/node-group roles tagged `Project=devops-qr`) |
| GitHub OIDC provider | `aws iam list-open-id-connect-providers` + tags (only if tagged `Project=devops-qr`) |

It prints one line per check: `clean  <check>` or `FOUND  <check>  <ids>`. It exits 0 only
when everything is clean. Any AWS error stops it with a non-zero exit; it never reports
`clean` for a check it could not run.

**Success looks like:** every line starts with `clean`, the last line is
`verify-clean: nothing from devops-qr left in us-east-1 (plus global IAM/S3)`, and the exit
code is 0. After that, also check the AWS Billing console the next day.

## 8. Why no Ansible

The brief's configuration-management needs are covered by EKS managed node groups and the
Kubernetes manifests. AWS builds the nodes from the EKS-optimised AL2023 AMI and replaces
them on update; the app's configuration is declarative (Kustomize). There are no long-lived
hosts to configure, so an Ansible playbook would have nothing to manage.
