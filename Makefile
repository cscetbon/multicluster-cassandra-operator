# Copyright 2019 Orange
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# 	You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# 	See the License for the specific language governing permissions and
# limitations under the License.

################################################################################


# Name of this service/application
SERVICE_NAME := multi-casskop

DOCKER_REPO_BASE ?= orangeopensource
#we could want to separate registry for branches
DOCKER_REPO_BASE_TEST ?= orangeopensource

# Docker image name for this project
IMAGE_NAME := $(SERVICE_NAME)

BUILD_IMAGE ?= orangeopensource/casskop-build

TELEPRESENCE_REGISTRY ?= datawire
KUBESQUASH_REGISTRY:=

KUBECONFIG ?= ~/.kube/config

MINIKUBE_CONFIG ?= ~/.minikube
MINIKUBE_CONFIG_MOUNT ?= /home/circleci/.minikube

# Repository url for this project
#in gitlab CI_REGISTRY_IMAGE=repo/path/name:tag
ifdef CI_REGISTRY_IMAGE
	REPOSITORY := $(CI_REGISTRY_IMAGE)
else
	REPOSITORY := $(DOCKER_REPO_BASE)/$(IMAGE_NAME)
endif

# Branch is used for the docker image version
ifdef CIRCLE_BRANCH
	#removing / for fork which lead to docker error
	BRANCH := $(subst /,-,$(CIRCLE_BRANCH))
else
  ifdef CIRCLE_TAG
		BRANCH := $(CIRCLE_TAG)
	else
		BRANCH=$(shell git rev-parse --abbrev-ref HEAD)
	endif
endif

#Operator version is managed in go file
#BaseVersion is for dev docker image tag
BASEVERSION := $(shell cat version/version.go | awk -F\" '/Version =/ { print $$2}')
#Version is for binary, docker image and helm

ifdef CIRCLE_TAG
	VERSION := ${BRANCH}
else
	VERSION := $(BASEVERSION)-${BRANCH}
endif

HELM_VERSION := $(shell cat helm/multi-casskop/Chart.yaml| grep version | awk -F"version: " '{print $$2}')

#si branche master, on pousse le tag latest
ifeq ($(CIRCLE_BRANCH),master)
	PUSHLATEST := true
endif

params:
	@echo "CIRCLE_BRANCH = '$(CIRCLE_BRANCH)'"
	@echo "CIRCLE_TAG = '$(CIRCLE_TAG)'"
	@echo "Version = '$(VERSION)'"
	@echo "Image= '$(REPOSITORY):$(VERSION)'"


# Shell to use for running scripts
SHELL := $(shell which bash)

# Get docker path or an empty string
DOCKER := $(shell command -v docker)

# Get the main unix group for the user running make (to be used by docker-compose later)
GID := $(shell id -g)

# Get the unix user id for the user running make (to be used by docker-compose later)
UID := $(shell id -u)

# Commit hash from git
COMMIT=$(shell git rev-parse HEAD)


# CMDs
UNIT_TEST_CMD := KUBERNETES_CONFIG=`pwd`/config/test-kube-config.yaml POD_NAME=test go test --cover --coverprofile=coverage.out `go list ./... | grep -v e2e` > test-report.out
UNIT_TEST_CMD_WITH_VENDOR := KUBERNETES_CONFIG=`pwd`/config/test-kube-config.yaml POD_NAME=test go test -mod=vendor --cover --coverprofile=coverage.out `go list -mod=vendor ./... | grep -v e2e` > test-report.out 
UNIT_TEST_COVERAGE := go tool cover -html=coverage.out -o coverage.html
GO_GENERATE_CMD := go generate `go list ./... | grep -v /vendor/`
GO_LINT_CMD := golint `go list ./... | grep -v /vendor/`
MOCKS_CMD := go generate ./mocks

# environment dirs
DEV_DIR := docker/circleci
APP_DIR := build/Dockerfile

OPERATOR_SDK_VERSION=v0.9.0
# workdir
WORKDIR := /go/cassandra-k8s-operator

UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Linux)
	GOOS = linux
endif
ifeq ($(UNAME_S),Darwin)
	GOOS = darwin
endif

# Some other usefule make file for interracting with kubernetes 
include kube.mk

#
#
################################################################################

# The default action of this Makefile is to build the development docker image
default: build

clean:
	@rm -rf $(OUT_BIN) || true
	@rm -f apis/multicluster/v1alpha1/zz_generated.deepcopy.go || true

helm-package:
	@echo Packaging $(HELM_VERSION)
	helm package helm/multi-casskop
	mv multi-casskop-$(HELM_VERSION).tgz docs/helm
	helm repo index docs/helm/

# Build cassandra-k8s-operator executable file in local go env

export CGO_ENABLED:=0
export PURE:="on"
.PHONY: build
build:
	@echo "Generate zzz-deepcopy objects"
	operator-sdk version
	operator-sdk generate k8s
	@echo "Build Cassandra Operator"
	operator-sdk build $(REPOSITORY):$(VERSION) --image-build-args "--build-arg https_proxy=$$https_proxy --build-arg http_proxy=$$http_proxy"
	#go build -o /Users/seb/gomac/src/github.com/Orange-OpenSource/multicluster-cassandra-operator/build/_output/bin/multicluster-cassandra-operator -gcflags all=-trimpath=/Users/seb/gomac/src/github.com/Orange-OpenSource -asmflags all=-trimpath=/Users/seb/gomac/src/github.com/Orange-OpenSource github.com/Orange-OpenSource/multicluster-cassandra-operator/cmd/manager
ifdef PUSHLATEST
	docker tag $(REPOSITORY):$(VERSION) $(REPOSITORY):latest
endif
#

build-local:
	@echo "Generate zzz-deepcopy objects"
	operator-sdk version
	operator-sdk generate k8s
	@echo "Build Cassandra Operator for $(GOOS)"
	go build -o /Users/seb/gomac/src/github.com/Orange-OpenSource/multicluster-cassandra-operator/build/_output/bin/multicluster-cassandra-operator-$(GOOS) -gcflags all=-trimpath=/Users/seb/gomac/src/github.com/Orange-OpenSource -asmflags all=-trimpath=/Users/seb/gomac/src/github.com/Orange-OpenSource github.com/Orange-OpenSource/multicluster-cassandra-operator/cmd/manager

# Run a shell into the development docker image
.PHONY: docker-build
docker-build: ## Build the Operator and it's Docker Image
	echo "Generate zzz-deepcopy objects"
	docker run --rm -v $(PWD):$(WORKDIR) -v $(GOPATH)/pkg/mod:/go/pkg/mod -v $(shell go env GOCACHE):/root/.cache/go-build --env GO111MODULE=on --env https_proxy=$(https_proxy) --env http_proxy=$(http_proxy) $(BUILD_IMAGE):$(OPERATOR_SDK_VERSION) /bin/bash -c 'operator-sdk generate k8s'
	echo "Build Cassandra Operator. Using cache from "$(shell go env GOCACHE)
	docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v $(PWD):$(WORKDIR) -v $(GOPATH)/pkg/mod:/go/pkg/mod -v $(shell go env GOCACHE):/root/.cache/go-build --env GO111MODULE=on --env https_proxy=$(https_proxy) --env http_proxy=$(http_proxy) $(BUILD_IMAGE):$(OPERATOR_SDK_VERSION) /bin/bash -c 'operator-sdk build $(REPOSITORY):$(VERSION) --image-build-args "--build-arg https_proxy=$$https_proxy --build-arg http_proxy=$$http_proxy"'
ifdef PUSHLATEST
	docker tag $(REPOSITORY):$(VERSION) $(REPOSITORY):latest
endif

circleci-process:
	circleci config process .circleci/config.yml

circleci-validate:
	circleci config validate

debug-telepresence:
	export TELEPRESENCE_REGISTRY=$(TELEPRESENCE_REGISTRY) ; \
	echo "execute : cat multi-casskop.env" ; \
  sudo mkdir -p /var/run/secrets/kubernetes.io ; \
	sudo ln -s /tmp/known/var/run/secrets/kubernetes.io/serviceaccount /var/run/secrets/kubernetes.io/ ; \
	tdep=$(shell kubectl get deployment -l app=multi-casskop -o jsonpath='{.items[0].metadata.name}') ; \
	telepresence --swap-deployment $$tdep --mount=/tmp/known --env-file multi-casskop.env \
	--also-proxy 10.40.0.0/16
#	--also-proxy 172.18.0.0/16


#ifeq (run,$(firstword $(MAKECMDGOALS)))
#ifeq ($(firstword $(MAKECMDGOALS)), $(filter $(firstword $(MAKECMDGOALS)), run run-local run-docker)
ifneq (,$(filter $(firstword $(MAKECMDGOALS)),run run-local run-docker))
  RUN_ARGS := $(wordlist 2,$(words $(MAKECMDGOALS)),$(MAKECMDGOALS))
  $(eval $(RUN_ARGS):;@:)
endif


NAMESPACE ?= cassandra-demo
# Run the development environment (in local go env) in the background using local ~/.kube/config
.PHONY: run
run:
	export POD_NAME=multi-caaskop; \
	export WATCH_NAMESPACE=$(NAMESPACE); \
	export LOG_LEVEL=Debug; \
	operator-sdk up local --namespace cassandra-demo  --operator-flags "$(RUN_ARGS)"

run-local:
	export POD_NAME=multi-caaskop; \
	export WATCH_NAMESPACE=$(NAMESPACE); \
	export LOG_LEVEL=Debug; \
	./build/_output/bin/multicluster-cassandra-operator-$(GOOS) $(RUN_ARGS)


run-docker:
	docker rm multi-casskop || true
	docker run --name multi-casskop -d -e KUBECONFIG=/root/.kube/config -e WATCH_NAMESPACE=$(NAMESPACE) -v $(KUBECONFIG):/root/.kube/config $(REPOSITORY):$(VERSION) $(RUN_ARGS)
	docker logs -f multi-casskop

.PHONY: push
push:
	docker push $(REPOSITORY):$(VERSION)
ifdef PUSHLATEST
	docker push $(REPOSITORY):latest
endif

.PHONY: tag
tag:
	git tag $(VERSION)

.PHONY: publish
publish:
	@COMMIT_VERSION="$$(git rev-list -n 1 $(VERSION))"; \
	docker tag $(REPOSITORY):"$$COMMIT_VERSION" $(REPOSITORY):$(VERSION)
	docker push $(REPOSITORY):$(VERSION)
ifdef PUSHLATEST
	docker push $(REPOSITORY):latest
endif

.PHONY: release
release: tag image publish

# Test stuff in dev
.PHONY: docker-unit-test
docker-unit-test:
	docker run  --env GO111MODULE=on --rm -v $(PWD):$(WORKDIR)  -v $(GOPATH)/pkg/mod:/go/pkg/mod -v $(shell go env GOCACHE):/root/.cache/go-build $(BUILD_IMAGE):$(OPERATOR_SDK_VERSION) /bin/bash -c '$(UNIT_TEST_CMD); cat test-report.out; $(UNIT_TEST_COVERAGE)'
.PHONY: docker-unit-test-with-vendor
docker-unit-test-with-vendor:
	docker run  --env GO111MODULE=on --rm -v $(PWD):$(WORKDIR)  -v $(GOPATH)/pkg/mod:/go/pkg/mod -v $(shell go env GOCACHE):/root/.cache/go-build $(BUILD_IMAGE):$(OPERATOR_SDK_VERSION) /bin/bash -c '$(UNIT_TEST_CMD_WITH_VENDOR); cat test-report.out; $(UNIT_TEST_COVERAGE)'

.PHONY: unit-test
unit-test:
	$(UNIT_TEST_CMD) && echo "success!" || { echo "failure!"; cat test-report.out; exit 1; }
	cat test-report.out 
	$(UNIT_TEST_COVERAGE)

.PHONY: unit-test-with-vendor
unit-test-with-vendor:
	$(UNIT_TEST_CMD_WITH_VENDOR) && echo "success!" || { echo "failure!"; cat test-report.out; exit 1; }
	cat test-report.out 
	$(UNIT_TEST_COVERAGE)


.PHONY: docker-go-lint
docker-go-lint:
	docker run  --env GO111MODULE=on -ti --rm -v $(PWD):$(WORKDIR) -u $(UID):$(GID) --name $(SERVICE_NAME) $(BUILD_IMAGE):$(OPERATOR_SDK_VERSION) /bin/sh -c '$(GO_LINT_CMD)'

# golint is not fully supported by modules yet - https://github.com/golang/lint/issues/409
.PHONY: go-lint
go-lint:
	$(GO_LINT_CMD)


.PHONY: deps-development
# Test if the dependencies we need to run this Makefile are installed
deps-development:
ifndef DOCKER
	@echo "Docker is not available. Please install docker"
	@exit 1
endif




