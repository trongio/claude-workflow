## Stack rules: SvelteKit + TypeScript + Drizzle

### TypeScript strictness
- `tsconfig`: `strict`, `noUncheckedIndexedAccess`, `exactOptionalPropertyTypes`, `noImplicitOverride`, `noFallthroughCasesInSwitch`, `verbatimModuleSyntax`. [ci: typecheck]
- ESLint flat config with `typescript-eslint` `strictTypeChecked` + `stylisticTypeChecked` (type-aware, `parserOptions.projectService: true`), `eslint-plugin-svelte` `flat/recommended`; `no-explicit-any`, `no-floating-promises`, `no-misused-promises` and `switch-exhaustiveness-check` as errors; `--max-warnings 0`. [ci: eslint]
- `knip` stays at zero unused files, exports and dependencies. [ci: knip]
- No `as` casts on data that crossed a boundary (request body, form data, search params, env, JSON column): parse it with zod and use the inferred type. [review]
- Env is read only through `$env/*` modules and validated once in `src/lib/server/env.ts`. [review]

### Server boundary
- Server code lives under `src/lib/server/`; SvelteKit refuses to bundle it into the client. Secrets come from `$env/static/private` or `$env/dynamic/private` only. [ci: build]
- `svelte-check --fail-on-warnings` is the typecheck; Svelte 5 runes (`$props`, `$state`, `$derived`) with typed props. [ci: typecheck]
- Every form action, `+server.ts` handler and `load` that reads private data: parse input with zod, load the session, authorize (one `can(user, action, resource)` helper), then call a use case in `src/server/`. A test per state-changing action proves an unauthorized caller is refused; nested resources get their own test. [guard-test]
- Form actions return `fail(status, { error: { key, params } })` on refusal and keep the submitted values; they never throw raw errors to the client and never return exception messages. [review]
- Forms work without JavaScript first (`use:enhance` is progressive enhancement, not a requirement). [guard-test: one Playwright journey with JS disabled]
- `invalidate`/`depends` keys are named constants shared by the loader and the mutation. [review]

### Data
- Drizzle schema is the source of truth; migrations are generated (`drizzle-kit generate`), committed, reviewed as their own change and never edited after merge. [ci: migrations] [review]
- Lists are paginated or bounded with `.limit()`; relational queries use `with:` instead of a query per row. A list endpoint test asserts the query count does not grow with rows (count via a Drizzle logger in tests). [guard-test]
- A read that gates a write runs in `db.transaction()` with `.for('update')` or relies on a unique constraint. [review]
<!-- tune: multi-tenant projects add the tenancy rule here (tenant_id on every owned table, Postgres RLS with FORCE, the session sets the tenant per transaction, a test per table) -->
{{#if multiTenant}}
- Tenancy: every tenant-owned table has `tenant_id` and Postgres row-level security with `FORCE ROW LEVEL SECURITY`; each request runs inside a transaction that does `set_config('app.tenant_id', $1, true)`. The app role does not own the tables. A guard test lists every table with `tenant_id` and fails if RLS is off. [guard-test]
{{/if}}
<!-- /tune -->

### Tests
- Vitest for units and server use cases against a real Postgres (testcontainers or a per-worker database), never SQLite or mocks of the ORM. [ci: vitest-full]
- `vi.useFakeTimers()` / `vi.setSystemTime()` for anything date-dependent. [review]
- Inner loop: `vitest run --changed $WF_BASE`; the full suite and Playwright run in `wf gates --release`. [ci]
- Playwright journeys at 375 px and 1440 px with the widest locale active. [ci: e2e]

### i18n
- Paraglide message catalogs in `messages/<locale>.json`, ICU MessageFormat for plurals; a test asserts every key exists in every locale with the same ICU arguments. [guard-test]
