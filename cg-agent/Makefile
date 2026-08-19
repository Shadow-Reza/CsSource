# cg-agent - build a static Linux/amd64 binary.
# Requires Go >= 1.22 on the build host (https://go.dev/dl/). No CGO, no libc.
#
#   go mod tidy      # once, needs network (fetches github.com/go-sql-driver/mysql)
#   make             # -> bin/cg-agent
#   make test        # unit tests (no DB, no network)

BINARY  := cg-agent
OUT     := bin/$(BINARY)
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || date -u +%Y%m%d%H%M%S)
LDFLAGS := -s -w -X main.version=$(VERSION)

.PHONY: build tidy test vet fmt clean check run-stub

build:
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags '$(LDFLAGS)' -o $(OUT) .

tidy:
	go mod tidy

test:
	CGO_ENABLED=0 go test ./... -count=1

vet:
	go vet ./...

fmt:
	gofmt -l -w .

clean:
	rm -rf bin

# validate the example config with the freshly built binary (needs a Linux host)
check: build
	./$(OUT) -check -config deploy/config.example.toml

# run locally in stub mode with the example config (needs a Linux host)
run-stub: build
	CG_AGENT_MODE=stub ./$(OUT) -config deploy/config.example.toml
