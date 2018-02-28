files := $(shell find . -path ./vendor -prune -path ./pb -prune -o -name '*.go' -print)
pkgs := $(shell go list ./... | grep -v /vendor/ )

cwd= $(shell pwd)
build_dir := $(cwd)/build/bin
dist_dir := $(cwd)/dist

# Define cross compiling targets
os := $(shell uname)
ifeq ("$(os)", "Linux")
	target_os = linux
	cross_os = darwin
else ifeq ("$(os)", "Darwin")
	target_os = darwin
	cross_os = linux
endif

.PHONY: all build check check-format check-os clean cross-compile docker format install lint prepare-release-bintray proto release-docker setup test vet

all : check install test
check : check-os check-format vet lint
travis : clean setup check build test cross-compile docker

check-os:
ifndef target_os
	$(error Unsupported platform: ${os})
endif

setup:
	@echo "== setup"
	go get -v github.com/golang/lint/golint
	go get golang.org/x/tools/cmd/goimports
	go get github.com/golang/dep/cmd/dep
	dep ensure

format :
	@echo "== format"
	@goimports -w $(files)
	@sync

clean :
	@echo "== clean"
	rm -rf build
	rm -rf dist

build :
	@echo "== build"
	GOOS=${target_os} GOARCH=amd64 go build -o ${build_dir}/${target_os}_amd64/osprey -v

install :
	@echo "== install"
	@echo "Installing binary for ${target_os}"
	GOOS=${target_os} GOARCH=amd64 go install -v

cross-compile:
	@echo "== cross compile"
	@echo "Cross compiling binary for ${cross_os}"
	GOOS=${cross_os} GOARCH=amd64 go build -o ${build_dir}/${cross_os}_amd64/osprey -v
	@echo "Cross compiling binary for windows"
	GOOS=windows GOARCH=amd64 go build -o ${build_dir}/windows_amd64/osprey -v

unformatted = $(shell goimports -l $(files))

check-format :
	@echo "== check formatting"
ifneq "$(unformatted)" ""
	@echo "needs formatting:"
	@echo "$(unformatted)" | tr ' ' '\n'
	$(error run 'make format')
endif

vet :
	@echo "== vet"
	@go vet $(pkgs)

lint :
	@echo "== lint"
	@for pkg in $(pkgs); do \
		golint -set_exit_status $$pkg || exit 1 ; \
	done;

test :
	@echo "== run tests"
	go test -race $(pkgs)

proto :
	@echo "== compiling proto files"
	@docker run -v `pwd`/pb:/pb -w / grpc/go:1.0 protoc -I /pb /pb/osgsprey.proto --go_out=plugins=grpc:pb

git_rev := $(shell git rev-parse --short HEAD)
git_tag := $(shell git tag --points-at=$(git_rev))
release_date := $(shell date +%d-%m-%Y)
latest_git_tag := $(git for-each-ref --format="%(tag)" --sort=-taggerdate refs/tags | grep osprey | head -1)
latest_git_rev := $(git rev-list -n 1 $(latest_git_tag))

prepare-release-bintray :
ifeq ($(strip $(SKIP_PREPARE_RELEASE_BINTRAY)), )
	@echo "== prepare bintray release"
ifeq ($(strip $(git_tag)),)
	@echo "no tag on $(git_rev), skipping bintray release"
else
	mkdir -p $(dist_dir)
	sed 's/@version/$(git_tag)/g; s/@release_date/$(release_date)/g; s/@publish/$(BINTRAY_PUBLISH)/g' .bintray.template > $(dist_dir)/bintray.json
	@for distribution in `ls $(build_dir)`; do \
		echo "== $$distribution"; \
		release=$(dist_dir)/$(git_tag)/$$distribution; \
		mkdir -p $$release; \
		cd $(build_dir)/$$distribution; \
		artifact=osprey; \
		case $$distribution in \
			windows*) \
				mv osprey osprey.exe \
				artifact=$$artifact.zip; \
				zip -9 $$artifact osprey.exe; \
				;; \
			*) \
				artifact=$$artifact.tar.gz; \
				tar -zcf `pwd`/$$artifact osprey; \
				;; \
		esac ;\
		if [ "$(git_rev)" = "$(latest_git_rev)" ]; then \
			echo "updating latest distribution"; \
			latest=$(dist_dir)/latest/$$distribution; \
			mkdir -p $$latest; \
			cp $$artifact $$latest; \
		fi ; \
		mv $$artifact $$release; \
	done;
	@echo
	@echo artifacts:
	@tree $(dist_dir)
endif
endif

image := skycirrus/osprey

docker : build
	@echo "== docker"
	docker build -t $(image):latest .

release-docker : docker
ifeq ($(strip $(git_tag)),)
	@echo "no tag on $(git_rev), skipping docker release"
else
	@echo "== release docker"
	@echo "releasing $(image):$(git_tag)"
	@echo docker login -u $(DOCKER_USERNAME) -P $(DOCKER_PASSWORD)
	@echo docker tag $(image):latest $(image):$(git_tag)
	@echo docker push $(image):$(git_tag)
endif