## Stack rules: Rust API (axum + tokio + sqlx)

### Strictness
- Toolchain pinned in `rust-toolchain.toml` from the STACK.md version table; edition latest stable. [review]
- Workspace lints in `Cargo.toml`: `[workspace.lints.rust] unsafe_code = "forbid"`, `missing_debug_implementations = "warn"`; `[workspace.lints.clippy] pedantic = { level = "warn", priority = -1 }`, `unwrap_used = "deny"`, `expect_used = "warn"`, `panic = "deny"`, `todo = "deny"`, `dbg_macro = "deny"`. Clippy runs with `-D warnings`, so pedantic warnings fail the gate. [ci: clippy]
- `#[allow(...)]` needs a `reason = "..."` (`#[expect(..., reason)]` preferred); the count only shrinks. [review]
- `cargo deny check` (licenses, advisories, duplicate versions, banned crates) in the release gate. [ci: cargo-deny]

### Code shape
- Make illegal states unrepresentable: newtypes for ids and money (`TenantId(Uuid)`, `Cents(i64)`), enums over booleans, constructors that validate. [review]
- Errors: one `thiserror` enum per layer; `IntoResponse` maps it to `{ "error": { "key", "params" } }` and a status. Internal messages and sqlx errors never reach the response body. [guard-test]
- Handlers: extractors (`State`, an `AuthUser` extractor, `Json<T>` with `serde(deny_unknown_fields)`), then one service call. Every state-changing route takes `AuthUser` and checks the ability; a test per route proves 403. [guard-test]
- No blocking calls on the async runtime (`spawn_blocking` for CPU or sync I/O). [review]
- Time via an injected clock; `chrono-tz`/`jiff` zones explicit. [review]
- OpenAPI with `utoipa` derived from the handler types; a test fails when the committed spec is stale. [guard-test]

### Data
- `sqlx::query!`/`query_as!` macros only (compile-time checked); `.sqlx/` offline data committed and `cargo sqlx prepare --check` in the release gate. [ci: sqlx-prepare]
- Migrations in `migrations/`, reversible, reviewed as their own change. [review]
- Lists bounded with `LIMIT` and a maximum page size; a read that gates a write uses `FOR UPDATE` in the transaction or a unique constraint. [review]
<!-- tune: multi-tenant: RLS FORCE + set_config per transaction in the tx helper + guard test -->
{{#if multiTenant}}
- Tenancy: RLS with `FORCE ROW LEVEL SECURITY` on every tenant-owned table; the transaction helper sets `app.tenant_id` with `set_config(..., true)`; a guard test fails when a table with `tenant_id` has RLS off. [guard-test]
{{/if}}
<!-- /tune -->

### Tests
- `#[sqlx::test]` integration tests against real Postgres; unit tests next to the code. [ci: cargo-test-full]
- The inner loop runs lib and bin tests; integration tests and all targets run in `wf gates --release`. [ci]
