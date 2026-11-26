## Stack rules: Node + Hono API (TypeScript)

### TypeScript strictness
- `tsconfig`: `strict`, `noUncheckedIndexedAccess`, `exactOptionalPropertyTypes`, `noImplicitOverride`, `noFallthroughCasesInSwitch`, `verbatimModuleSyntax`, `module: nodenext`. [ci: typecheck]
- ESLint flat config with `typescript-eslint` `strictTypeChecked` (type-aware, `projectService: true`); `no-explicit-any`, `no-floating-promises`, `no-misused-promises`, `switch-exhaustiveness-check` as errors; `--max-warnings 0`. [ci: eslint]
- `knip` stays at zero unused files, exports and dependencies. [ci: knip]
- No `as` casts on boundary data; every request body, query, header and env value is parsed by zod. [review]
- Env parsed once by a zod schema in `src/env.ts`; nothing else reads `process.env`. [guard-test]

### Contract
- Routes are declared with `@hono/zod-openapi` (`createRoute`): the request and response schemas ARE the validation and the documentation. The generated `openapi.json` is committed; a test fails when it differs from a fresh build. [guard-test]
- Removing a path, a response field or an enum value, or tightening a request constraint, is a breaking change: it needs a version bump or an explicit entry in a breaking-changes list reviewed by the owner. [review] [not yet: an automated OpenAPI diff gate]
- Errors are `{ error: { key, params } }` with a stable machine key and the right status; never an exception message, stack or SQL. One `app.onError` maps known errors and logs the rest with a request id. [guard-test]

### Authorization and data
- Auth middleware sets a typed `c.var.user`; every state-changing route calls `authorize(user, action, resource)` before the use case, and has a test that an unauthorized caller gets 403, nested resources included. [guard-test: a route-table test fails when a non-GET route has no authorize marker]
- Use cases in `src/services/` are the only DB callers; route handlers stay at parse, authorize, call, respond. [review]
- Lists are paginated (cursor preferred) with a hard maximum page size; a test asserts the query count does not grow with rows. [guard-test]
- A read that gates a write holds the row lock (`.for('update')` in a transaction) or relies on a unique constraint; idempotency keys on any endpoint a client may retry that moves money or sends messages. [review]
<!-- tune: multi-tenant projects: tenant_id + Postgres RLS with FORCE, set_config per transaction, guard test per table -->
{{#if multiTenant}}
- Tenancy: tenant-owned tables carry `tenant_id` with Postgres row-level security (`FORCE ROW LEVEL SECURITY`); every request transaction does `set_config('app.tenant_id', $1, true)`; the app role does not own tables. A guard test fails when a table with `tenant_id` has RLS off. [guard-test]
{{/if}}
<!-- /tune -->

### Tests and runtime
- Vitest against a real Postgres per worker; `app.request()` for HTTP tests (no network). Fake timers for dates. [ci: vitest-full]
- Structured logs with pino: one line per request with id, route, status, duration; never bodies, tokens or PII. [review]
- Graceful shutdown: stop accepting, drain in-flight requests, close the pool. [review]
