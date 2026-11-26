## Stack rules: Laravel + Inertia + Vue

### PHP strictness
- `declare(strict_types=1);` in every PHP file, added by Pint (`"rules": {"declare_strict_types": true}` in `pint.json`). [ci: pint]
- Larastan at level `max` with `phpstan/phpstan-strict-rules` and `bleedingEdge.neon` included; `tmpDir` set to one absolute path shared by every worktree (for example `%env.HOME%/.cache/phpstan/<project>` or an absolute path written by `wf wt-init`), so worktrees reuse the cache; a relative `tmpDir` gives each worktree a cold cache. [ci: phpstan]
- The phpstan baseline only shrinks: a new `ignoreErrors` entry or a regenerated baseline that grows is a review blocker. Pay debt down with `--generate-baseline` only when the count falls. [review] [not yet: a baseline-size guard test]
- Typed config reads: `Config::string()`, `Config::integer()`, `Config::boolean()`, never `config()` cast by hand. [ci: phpstan]
- No `mixed` leaking out of a service: request input goes through a FormRequest, then a typed DTO (`spatie/laravel-data`), before it reaches an Action. [review]
- Generated TypeScript types: DTOs and enums are exported to `resources/js/types/generated.d.ts` with `spatie/laravel-typescript-transformer`; a test fails when the committed file is stale. Never hand-write a TS type for a PHP DTO. [guard-test]

### Eloquent and queries
- `Model::shouldBeStrict(! app()->isProduction())` in `AppServiceProvider::boot()`: lazy loading, silently discarded attributes and missing attributes throw outside production. [guard-test: a test asserts strict mode is on]
- Every list endpoint has a query-count test: `$this->expectsDatabaseQueryCount(N)` (or `DB::enableQueryLog()` with a bound) with 1 and with 20 rows; the count must not grow with rows. [guard-test]
- Lists are paginated (`->paginate()`/`->cursorPaginate()`) or explicitly bounded (`->limit()`); `->get()` on an unbounded user-controlled set is a finding. Chunk (`->lazyById()`) anything a job walks. [review]
- A read that decides a write runs inside `DB::transaction()` with `->lockForUpdate()` (or a unique index that makes the second write fail). [review] [guard-test for money and quotas]
- Migrations are reviewed as their own change: reversible `down()`, no data rewrite inside a schema migration, indexes for every foreign key and filter column. [review]
<!-- tune: multi-tenant projects add the tenancy rule here (global scope + Postgres RLS + a test per model that a foreign tenant row is invisible) -->
{{#if multiTenant}}
- Tenancy: every tenant-owned model uses the `BelongsToTenant` trait (global scope + `tenant_id` set on create) AND the table has Postgres row-level security with `FORCE ROW LEVEL SECURITY`; the request sets the tenant with `SET LOCAL` inside its transaction. The app DB role is not the table owner. A guard test lists every model with a `tenant_id` column and fails when one lacks the trait. [guard-test]
- Octane/long-lived workers: tenant context is reset per request and re-bound per queued job; no tenant data in singletons or statics. [guard-test: a worker-reuse test]
{{/if}}
<!-- /tune -->

### HTTP layer
- Every state-changing route has a FormRequest whose `authorize()` calls a policy ability, and a Feature test on THAT route (and each child route of a resource) that a user without the ability gets 403. A test on the parent route does not cover the child. [guard-test: a route-list test fails when a POST/PUT/PATCH/DELETE route has no `can:` middleware or FormRequest]
- Controllers are thin: validate (FormRequest), authorize, call one Action, return an Inertia response or redirect. Business rules live in `app/Actions/`. [review]
- Validation errors and flash messages are translation keys; Inertia shares them and the client resolves them. [not yet: i18n check]
- Exceptions rendered to users carry a message key; `report()` logs never include request bodies, SQL bindings or PII. [review]

### Tests
- Pest with the same database engine as production (Postgres, never SQLite) and `RefreshDatabase` or transactions; parallel with `--parallel` and a database per process. [ci: pest-full]
- `Carbon::setTestNow()` / `$this->travelTo()` for every date-dependent test; no `now()` comparisons against wall clock. [review]
- Factories can produce the unsafe shape (a soft-deleted parent, a row of another tenant, an expired subscription) as named states, so tests can prove the guard. [review]
- Inner loop: `wf test-affected` maps `app/**/Foo.php` to `tests/**/FooTest.php`; the full parallel suite runs in `wf gates --release`. [ci]

### Frontend (Vue 3 + TypeScript)
- Single-file components with `<script setup lang="ts">`; props and emits typed with `defineProps<T>()` / `defineEmits<T>()`. [ci: typecheck]
- `tsconfig`: `strict`, `noUncheckedIndexedAccess`, `exactOptionalPropertyTypes`, `noImplicitOverride`; `vue-tsc --noEmit` is the typecheck. [ci: typecheck]
- ESLint with `typescript-eslint` `strictTypeChecked` (type-aware) and `eslint-plugin-vue` `flat/recommended`, `no-explicit-any` as error, `--max-warnings 0`. [ci: eslint]
- `knip` reports unused files, exports and dependencies; it stays at zero. [ci: knip]
- Page props are typed from the generated types; shared props through one typed composable. [review]
- Forms use Inertia `useForm`; a refused submit keeps the user's input and shows the server's reason next to the field. [review] [ux]
- No `v-html` with anything a user or translator can influence. [review]
- Vitest + Vue Testing Library for components with behaviour. Playwright for journeys at 375 px and 1440 px in the widest locale. [ci: vitest, e2e]
