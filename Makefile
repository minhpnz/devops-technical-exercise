# Entry points for the local setup.
SHELL   := /bin/bash
CLUSTER := greeter
CONTEXT := kind-$(CLUSTER)
VERSION ?= 0.1.0
IMAGE   := greeter:$(VERSION)

export DOCKER_BUILDKIT := 1

.PHONY: cluster down image load

cluster:
	@if kind get clusters 2>/dev/null | grep -qx $(CLUSTER); then \
	  echo "cluster $(CLUSTER) already exists"; \
	else \
	  kind create cluster --config kind/cluster.yaml --wait 180s; \
	fi
	kubectl --context $(CONTEXT) wait --for=condition=Ready nodes --all --timeout=120s

down:
	kind delete cluster --name $(CLUSTER)

image:
	docker build --build-arg VERSION=$(VERSION) -t $(IMAGE) .

load:
	kind load docker-image $(IMAGE) --name $(CLUSTER)

TF   := terraform
ENVS := dev prod

.PHONY: up deploy deploy-dev deploy-prod smoke plan

up: cluster image load deploy smoke

deploy: $(addprefix deploy-,$(ENVS))

$(addprefix deploy-,$(ENVS)): deploy-%:
	cd infra/$* && $(TF) init -input=false >/dev/null && \
	  $(TF) apply -input=false -auto-approve $(if $(IMAGE_TAG),-var image_tag=$(IMAGE_TAG))

plan:
	@for e in $(ENVS); do echo "== $$e"; (cd infra/$$e && $(TF) init -input=false >/dev/null && \
	  $(TF) plan -input=false -detailed-exitcode -compact-warnings | tail -n 3); done

smoke:
	@scripts/smoke.sh



PLATFORMS := -platform=darwin_amd64 -platform=darwin_arm64 -platform=linux_amd64 -platform=linux_arm64

.PHONY: lint tf-lock

lint:
	hadolint Dockerfile
	shellcheck -x scripts/*.sh
	helm lint charts/greeter --set greetingName=lint
	@helm template x charts/greeter 2>&1 | grep -q "at '/greetingName'" || \
	  { echo "chart must refuse to render without greetingName"; exit 1; }
	helm template greeter charts/greeter --set greetingName=lint --set service.nodePort=30080 \
	  | kubeconform -strict -summary -kubernetes-version 1.37.0 -
	$(TF) fmt -recursive -check infra
	@for e in $(ENVS); do (cd infra/$$e && $(TF) init -backend=false -input=false >/dev/null && $(TF) validate -no-color) || exit 1; done

tf-lock:
	@for e in $(ENVS); do (cd infra/$$e && $(TF) providers lock $(PLATFORMS)); done
