# Build helper binaries used by the e2e test suite.
#
# Helpers live under testdata/cmd/ — the testdata path keeps them
# out of `go build ./...` and `go test ./...`, but they remain
# buildable via explicit paths.  Output binaries go to ./bin.

BIN := bin
HELPERS := sleep-and-bind fork-grandchild slow-binder

.PHONY: all deepstar helpers clean test test-unit test-e2e

all: deepstar helpers

deepstar: $(BIN)/deepstar

$(BIN)/deepstar: $(shell find cmd internal -name '*.go' 2>/dev/null) go.mod
	@mkdir -p $(BIN)
	go build -o $@ ./cmd/deepstar

helpers: $(addprefix $(BIN)/, $(HELPERS))

$(BIN)/%: testdata/cmd/%/main.go
	@mkdir -p $(BIN)
	go build -o $@ ./testdata/cmd/$*

# Run all tests.  Unit tests cover the internal packages; e2e tests
# drive the deepstar binary against synthetic fixtures.
test: test-unit test-e2e

test-unit:
	go test ./internal/...

test-e2e: all
	go test ./e2e/...

clean:
	rm -rf $(BIN)
