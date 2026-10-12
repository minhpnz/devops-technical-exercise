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
