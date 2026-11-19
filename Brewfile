# make tools  ==  brew bundle --file=Brewfile
# Container runtime: Colima + the docker CLI. Start it once with
#   colima start --cpu 4 --memory 8   (kind + kube-prometheus-stack need ~4 CPU / 6-8 GB)
# Docker Desktop also works instead (no cask here, it would conflict with an existing
# install). `make doctor` checks that `docker info` works.
brew "colima"
brew "docker"
brew "docker-compose"
tap "hashicorp/tap"
brew "hashicorp/tap/terraform"   # homebrew-core terraform is frozen at 1.5.7 (BSL)
brew "awscli"
brew "kubernetes-cli"
brew "helm"
brew "kind"
brew "kustomize"
brew "hadolint"
brew "actionlint"
brew "kubeconform"
brew "shellcheck"
brew "jq"
brew "gh"
# tflint: Homebrew has no tflint formula any more and there is no official tap.
# `make lint` runs the pinned multi-arch image TFLINT_IMAGE (tool-versions.env) with
# Docker, and CI uses terraform-linters/setup-tflint. Nothing to install here.
