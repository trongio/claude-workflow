## Stack rules: Django + htmx (uv)

### Python strictness
- Python version pinned in `pyproject.toml` (`requires-python`) and `.python-version` from the STACK.md version table; dependencies locked with `uv.lock`. [review]
- `mypy --strict` with `django-stubs` (plugin enabled, `strict_settings = true`); no `# type: ignore` without an error code and a reason. [ci: mypy]
- Ruff with `select = ["ALL"]` minus a short, commented ignore list (`D` docstrings, `COM812`, `ISC001`); `ruff format` is the formatter. The ignore list only shrinks. [ci: ruff]
- `manage.py check --fail-level WARNING` runs on every change. [ci: django-check] `check --deploy` with production settings runs before each deploy. [not yet: a release gate that runs `check --deploy` against production settings]

### Models and queries
- Migrations are generated, committed and checked: `makemigrations --check --dry-run` fails on drift. Reviewed as their own change; data migrations separate from schema migrations. [ci: migrations]
- Business logic in `services.py` (writes) and `selectors.py` (reads); views stay at parse, authorize, call, render. No logic in `save()` overrides or signals that a reader would not find. [review]
- Every list view uses `select_related`/`prefetch_related` and pagination; a test with `django_assert_num_queries` (pytest-django) at 1 and 20 rows proves the count is constant. [guard-test]
- A read that gates a write runs in `transaction.atomic()` with `select_for_update()` or relies on a unique constraint. [review]
- `USE_TZ = True`; every datetime is aware; user-facing zones are explicit (`zoneinfo.ZoneInfo`). [review]
<!-- tune: multi-tenant: tenant FK on every owned model, a manager that requires a tenant, Postgres RLS with FORCE set per request transaction, guard test -->
{{#if multiTenant}}
- Tenancy: every tenant-owned model has a `tenant` FK and a default manager that refuses queries without a bound tenant; Postgres RLS with `FORCE ROW LEVEL SECURITY` backs it; middleware sets `app.tenant_id` with `set_config(..., true)` inside `ATOMIC_REQUESTS`. A guard test fails when a model with a `tenant` field uses a plain manager. [guard-test]
{{/if}}
<!-- /tune -->

### Views and htmx
- Every view that changes state is POST (or PUT/PATCH/DELETE via htmx), requires login and a permission check (`PermissionRequiredMixin` or an explicit `has_perm`), and has a test that a user without the permission gets 403, including nested resources. [guard-test: a URL-pattern test fails when a non-GET view has no permission check]
- CSRF stays on; htmx sends the token via `hx-headers` set once in the base template. [review]
- htmx partials are templates under `templates/<app>/partials/`; a partial and its full page render the same include, never two copies. [review]
- A refused form re-renders with the user's input and the field error, with status 422. htmx 2 does not swap 4xx responses by default, so the base template sets `htmx.config.responseHandling` (or an `htmx:beforeSwap` handler) to swap 422 into the form. [review] [ux]
- Errors shown to users are message keys (`gettext_lazy`); logs never include request bodies, SQL params or PII. [review]

### Tests
- pytest-django against Postgres (the production engine), `pytest-xdist` with a database per worker, factory_boy factories with named unsafe traits. [ci: pytest-full]
- `time-machine` or `freezegun` for date-dependent tests. [review]
- Inner loop: `wf test-affected` maps `apps/**/foo.py` to `tests/**/test_foo.py`; the full suite runs in `wf gates --release`. [ci]

### i18n
- `gettext` catalogs in `locale/`; every template string through `{% translate %}` / `{% blocktranslate count %}` (plural forms per locale, never string concatenation); `makemessages` + `compilemessages` run in the build and a test fails on fuzzy or missing entries. [guard-test]
