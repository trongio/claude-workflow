## Stack rules: Go API (chi + pgx + sqlc)

### Strictness
- Go version pinned in `go.mod` (`go` and `toolchain` lines) from the STACK.md version table. [review]
- `golangci-lint` v2 with a committed `.golangci.yml`: `default: standard` plus `errorlint`, `wrapcheck` (at package boundaries), `bodyclose`, `noctx`, `sqlclosecheck`, `rowserrcheck`, `contextcheck`, `gosec`, `exhaustive`, `forcetypeassert`, `nilnil`, `gocritic`, `revive`; formatters `gofumpt` and `goimports`. A v1 binary cannot read a v2 config, so the gate is pending, never green, until v2 is installed. [ci: golangci-lint]
- No `//nolint` without a linter name and a reason on the same line; the count only shrinks. [review] [not yet: a nolint-count guard]
- `govulncheck ./...` in the release gate. [ci: govulncheck]

### Code shape
- `context.Context` is the first parameter of every function that does I/O and is passed down, never stored in a struct. [ci: golangci-lint contextcheck]
- Errors wrap with `%w` and are compared with `errors.Is/As`; handlers map domain errors to `{ "error": { "key": ..., "params": ... } }` with the right status. Never `err.Error()` in a response. [review]
- Handlers: decode (with `http.MaxBytesReader` and `DisallowUnknownFields`), authorize, call a service, encode. Services take interfaces they need, defined where they are used. [review]
- No package-level mutable state; config is parsed once in `main` and passed in. [review]
- Every goroutine has an owner that waits for it (`errgroup`) and a way to stop (context). [review]
- Time: `time.Now()` only via an injected clock in domain code; time zones are explicit `*time.Location` values. [review]

### Data
- SQL in `internal/db/queries/*.sql`, compiled by sqlc; `sqlc diff` and `sqlc vet` fail on drift. No string-built SQL. [ci: sqlc]
- Migrations with goose, reversible, reviewed as their own change. [review]
- Every list query has `LIMIT` with a bounded page size; a test asserts list endpoints issue a constant number of queries (count via a pgx tracer in tests). [guard-test]
- A read that gates a write uses `SELECT ... FOR UPDATE` in the same transaction or a unique constraint. [review]
<!-- tune: multi-tenant: tenant_id + RLS FORCE, set_config per transaction via a pgx BeforeAcquire/tx helper, guard test per table -->
{{#if multiTenant}}
- Tenancy: tenant-owned tables have Postgres RLS with `FORCE ROW LEVEL SECURITY`; the tx helper runs `select set_config('app.tenant_id', $1, true)` before any query; a guard test fails when a table with `tenant_id` has RLS off. [guard-test]
{{/if}}
<!-- /tune -->

### Tests
- `go test -race -shuffle=on -count=1 ./...` in the release gate; the inner loop relies on Go's test cache. [ci: go-test-full]
- Integration tests against real Postgres (testcontainers or a per-package database), table-driven, `t.Parallel()` where safe. [ci]
- Authorization: a router test walks `chi.Walk` and fails when a non-GET route lacks the authorize middleware; each state-changing route has a 403 test. [guard-test]
- Device or edge drivers implement one interface and pass a shared contract test suite against a wire-faithful simulator. A green simulator test never replaces a hardware check. [guard-test] [review]
