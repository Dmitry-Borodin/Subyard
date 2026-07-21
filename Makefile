GO ?= go
VERSION ?= 0.1.0-dev

.PHONY: build test verify clean

build:
	@PATH="$$(dirname "$$(command -v $(GO))"):$${PATH}" YARD_BUILD_VERSION="$(VERSION)" ./scripts/build-engine.sh

test:
	$(GO) test ./...

verify:
	./tests/run.sh

clean:
	@find .build -maxdepth 1 -type f -name 'yard' -delete 2>/dev/null || true
