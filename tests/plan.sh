#!/usr/bin/env bash
# Planning-phase test: wf detect (nested monorepo packages, per-package gates), wf versions
# (registry parsing and --check against a fixture, no network), wf plan (answers, scaffold for every
# stack profile, cards). Needs bun, jq, git.
#
# Usage: tests/plan.sh [SCRATCH_DIR]   (default: a fresh mktemp dir)
# `ok` never fails, so `test && ok || die` is a safe if-then-else here.
# shellcheck disable=SC2015
set -eu

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
wf="$repo/bin/wf"
dir="${1:-$(mktemp -d "${TMPDIR:-/tmp}/wf-plan.XXXXXX")}"
# Scratch is removed on success unless WF_KEEP=1 or a dir was passed; kept on failure for debugging.
own_scratch=$([ -z "${1:-}" ] && echo 1 || true)
wf_scratch_cleanup() {
    local rc="${1:-$?}"
    if [ "$rc" = 0 ] && [ -n "$own_scratch" ] && [ -z "${WF_KEEP:-}" ]; then
        git -C "$dir" worktree prune 2>/dev/null || true
        rm -rf "$dir" "$dir".* "$dir"-*
    fi
    return "$rc"
}
trap wf_scratch_cleanup EXIT
pass=0
# Any accidental network call fails fast instead of reaching a registry.
export https_proxy=http://127.0.0.1:9 http_proxy=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9

ok() {
    pass=$((pass + 1))
    printf 'ok   %s\n' "$1"
}
die() {
    printf 'FAIL %s\n' "$1" >&2
    exit 1
}
newrepo() { # newrepo NAME -> path of a fresh git repo
    local d="$dir/$1"
    rm -rf "$d"
    mkdir -p "$d"
    git -C "$d" init -q -b main
    git -C "$d" -c user.email=t@example.test -c user.name=t commit -q --allow-empty -m init
    printf '%s\n' "$d"
}

for c in bun jq git; do command -v "$c" >/dev/null || die "$c is required"; done

# ---------------------------------------------------------------- versions (fixture, no network)
fx="$dir/fixture.json"
cat >"$fx" <<'EOF'
{
  "https://registry.npmjs.org/react/latest": { "name": "react", "version": "19.1.0" },
  "https://registry.npmjs.org/react": { "time": { "19.0.0": "2026-01-01T00:00:00Z", "19.1.0": "2026-04-01T12:00:00Z" } },
  "https://registry.npmjs.org/@inertiajs%2Freact/latest": { "name": "@inertiajs/react", "version": "2.0.1" },
  "https://repo.packagist.org/p2/laravel/framework.json": { "packages": { "laravel/framework": [
    { "version": "v13.0.0-beta.2", "time": "2026-11-20T10:00:00+00:00" },
    { "version": "v12.9.1", "time": "2026-11-01T10:00:00+00:00" },
    { "version": "v12.9.0", "time": "2026-10-01T10:00:00+00:00" } ] } },
  "https://pypi.org/pypi/django/json": { "info": { "version": "5.2.3" }, "releases": { "5.2.3": [ { "upload_time_iso_8601": "2026-09-02T08:00:00Z" } ] } },
  "https://crates.io/api/v1/crates/axum": { "crate": { "max_stable_version": "0.8.4", "newest_version": "0.9.0-alpha.1" }, "versions": [ { "num": "0.8.4", "created_at": "2026-05-01T00:00:00Z" } ] },
  "https://proxy.golang.org/github.com/!burnt!sushi/toml/@latest": { "Version": "v1.5.0", "Time": "2026-03-03T00:00:00Z" },
  "https://endoflife.date/api/nodejs.json": [
    { "cycle": "27", "latest": "27.1.0", "latestReleaseDate": "2026-11-01", "eol": "2027-06-01", "lts": false },
    { "cycle": "26", "latest": "26.4.0", "latestReleaseDate": "2026-10-20", "eol": "2029-04-30", "lts": "2026-10-28" },
    { "cycle": "20", "latest": "20.19.0", "latestReleaseDate": "2026-01-01", "eol": "2026-04-30", "lts": "2023-10-24" } ]
}
EOF
export WF_VERSIONS_FIXTURE="$fx"
vdir="$(newrepo versions)"
out="$(cd "$vdir" && "$wf" versions --json npm:react npm:@inertiajs/react composer:laravel/framework pypi:django crates:axum go:github.com/BurntSushi/toml eol:nodejs)" || die "versions against the fixture"
v() { jq -r --arg id "$1" '.[] | select(.id == $id) | .version' <<<"$out"; }
[ "$(jq -r '.[] | select(.id == "npm:react") | .released' <<<"$out")" = 2026-04-01 ] && ok "versions: npm release date from the packument time field" || die "versions: npm released"
[ "$(jq -r '.[] | select(.id == "npm:@inertiajs/react") | .version' <<<"$out")" = 2.0.1 ] && ok "versions: npm row stands without a date" || die "versions: npm without time"
for c in versions plan detect; do
    "$wf" "$c" --help 2>&1 | grep -q '^import\|from .\.\./' && die "wf $c --help prints source lines" || true
done
ok "help: versions, plan and detect print only their header comment"
[ "$(v npm:react)" = 19.1.0 ] && [ "$(v npm:@inertiajs/react)" = 2.0.1 ] && ok "versions: npm (scoped names escaped)" || die "versions: npm"
[ "$(v composer:laravel/framework)" = 12.9.1 ] && ok "versions: Packagist skips prereleases" || die "versions: packagist got $(v composer:laravel/framework)"
[ "$(v pypi:django)" = 5.2.3 ] && [ "$(jq -r '.[] | select(.id=="pypi:django") | .released' <<<"$out")" = 2026-09-02 ] && ok "versions: PyPI with release date" || die "versions: pypi"
[ "$(v crates:axum)" = 0.8.4 ] && jq -e '.[] | select(.id=="crates:axum") | .note | test("pre-1.0")' <<<"$out" >/dev/null && ok "versions: crates.io stable, 0.x flagged pre-1.0" || die "versions: crates"
[ "$(v go:github.com/BurntSushi/toml)" = 1.5.0 ] && ok "versions: Go proxy (capitals escaped)" || die "versions: go"
[ "$(v eol:nodejs)" = 26.4.0 ] && ok "versions: endoflife.date prefers the active LTS" || die "versions: eol got $(v eol:nodejs)"
(cd "$vdir" && "$wf" versions npm:not-in-fixture >/dev/null 2>&1) && die "versions: a missing fixture entry must fail" || ok "versions: a fetch failure exits non-zero"
[ ! -e "$vdir/.workflow/plan/versions.json" ] && ok "versions: fixture runs write no cache" || die "versions: fixture wrote a cache"

stackmd="$vdir/STACK.md"
{
    echo '# x'
    (cd "$vdir" && "$wf" versions --table npm:react composer:laravel/framework)
} >"$stackmd"
(cd "$vdir" && "$wf" versions --check "$stackmd") >/dev/null && ok "versions --check: no drift on a fresh table" || die "versions --check fresh"
sed -i.bak 's/| 12.9.1 |/| 11.0.0 |/' "$stackmd"
drift="$(cd "$vdir" && "$wf" versions --check "$stackmd")" && die "versions --check must exit 1 on drift" || true
grep -q 'DRIFT composer:laravel/framework: 11.0.0 -> 12.9.1' <<<"$drift" && [ "$(grep -c '^DRIFT' <<<"$drift")" = 1 ] && ok "versions --check prints only the drifted row" || die "versions --check output: $drift"

# ---------------------------------------------------------------- detect (nested monorepo)
mono="$(newrepo mono)"
mkdir -p "$mono/apps/web/src" "$mono/services/api" "$mono/libs/php/core" "$mono/apps/web/node_modules" "$mono/deep/a/b/c"
echo '{"name":"web","scripts":{"test":"vitest run","build":"vite build","lint":"eslint ."},"devDependencies":{"vitest":"^3.0.0","vite":"^6.0.0","typescript":"^5.0.0","react":"^19.0.0"}}' >"$mono/apps/web/package.json"
echo '{"packages":{"node_modules/vitest":{"version":"3.2.1"}}}' >"$mono/apps/web/package-lock.json"
printf 'module example.com/api\n\ngo 1.24\n\nrequire github.com/go-chi/chi/v5 v5.2.1\n' >"$mono/services/api/go.mod"
echo '{"require":{"laravel/framework":"^12.0"},"require-dev":{"pestphp/pest":"^3.0","laravel/pint":"^1.0"}}' >"$mono/libs/php/core/composer.json"
echo '{"name":"too-deep"}' >"$mono/deep/a/b/c/package.json"
echo 'echo hi' >"$mono/run.sh"
git -C "$mono" add -A
det="$(cd "$mono" && "$wf" detect --json)" || die "detect --json"
dirs="$(jq -r '[.packages[].dir] | sort | join(" ")' <<<"$det")"
[ "$dirs" = "apps/web libs/php/core services/api" ] && ok "detect: packages at depth <= 3, not deeper ($dirs)" || die "detect dirs: $dirs"
[ "$(jq -r '.packages[] | select(.dir=="apps/web") | .frameworks.vitest' <<<"$det")" = 3.2.1 ] && ok "detect: version from the lockfile" || die "detect: lockfile version"
[ "$(jq -r '.greenfield' <<<"$det")" = false ] && ok "detect: not greenfield" || die "detect: greenfield"
summary="$(cd "$mono" && "$wf" init)" || die "wf init (summary)"
[ "$(wc -l <<<"$summary")" -le 20 ] && grep -q '^gate .*cwd .*when .*flags' <<<"$summary" && grep -q 'pending (needs ' <<<"$summary" && ok "init: compact summary with a gate table naming what pending gates need" || die "init summary: $summary"
dt="$(cd "$mono" && "$wf" detect)"
grep -q ' go not installed' <<<"$dt" && die "detect: old 'not installed' wording: $dt" || true
if command -v go >/dev/null; then grep -q '^package services/api: go: ' <<<"$dt"; else grep -q '^package services/api: go (toolchain missing: go)' <<<"$dt"; fi && ok "detect: toolchain wording only when missing" || die "detect text: $dt"
cfg="$(cd "$mono" && "$wf" init --full)" || die "wf init --full"
jq -e '[.gates[] | has("when")] | all' <<<"$cfg" >/dev/null && ok "init: every gate has when" || die "init: a gate without when"
jq -e '.gates[] | select(.cwd=="apps/web" and .name=="test-web" and .release==false and (.cmd | test("--changed")))' <<<"$cfg" >/dev/null && ok "init: nested node package gets cwd and an affected-only inner test gate" || die "init: nested node gates"
jq -e '.gates[] | select(.name=="test-full-web" and .inner==false and .heavy==true)' <<<"$cfg" >/dev/null && ok "init: full suite is release-only and heavy" || die "init: full suite gate"
jq -e '.gates[] | select(.cwd=="libs/php/core" and .pending==true and (.when | index("libs/php/core/*.php")))' <<<"$cfg" >/dev/null && ok "init: uninstalled PHP package gates are pending with prefixed when" || die "init: php gates"
jq -e '[.gates[] | select(.name | test("^pytest"))] | length == 0' <<<"$cfg" >/dev/null && ok "init: no pytest without a Python project" || die "init: pytest added unconditionally"
jq -e '.gates[] | select(.name=="shellcheck" and .when == ["*.sh"])' <<<"$cfg" >/dev/null && ok "init: shellcheck gate scoped to *.sh" || die "init: shellcheck"
if ! command -v shellcheck >/dev/null; then
    jq -e '.gates[] | select(.name=="shellcheck" and .pending==true)' <<<"$cfg" >/dev/null && ok "init: shellcheck pending when not installed" || die "init: shellcheck pending"
fi
git -C "$mono" checkout -q -b feat/x
[ "$(cd "$mono" && "$wf" init --full | jq -r .baseBranch)" = main ] && ok "init: baseBranch is main, not the current feature branch" || die "init: baseBranch fell back to the feature branch"

# ---------------------------------------------------------------- plan answers
p="$(newrepo answers)"
(
    cd "$p"
    "$wf" plan set surfaces '["Web (phone first)", "Native mobile app"]' >/dev/null
    "$wf" plan set data.sensitivity "Personal data (PII),Many customer orgs" >/dev/null
    "$wf" plan set locales "en, ka, ru" >/dev/null
    "$wf" plan set product.kind "B2B SaaS" >/dev/null
    "$wf" plan set product.name "Acme Rooms" >/dev/null
)
set +e
bad="$(cd "$p" && "$wf" plan set scale "Gigantic" 2>&1)"
rc=$?
set -e
[ "$rc" = 2 ] && grep -q 'not an option: Gigantic' <<<"$bad" && grep -q '"Under 1k users"' <<<"$bad" && ! jq -e '.answers.scale' "$p/.workflow/plan/brief.json" >/dev/null &&
    ok "plan set: an invalid label exits 2 with the valid options" || die "plan set invalid: rc=$rc $bad"
(cd "$p" && "$wf" plan set surfaces "Web (phone first),Smoke signals" >/dev/null 2>&1) && die "plan set: an invalid multi-select item was accepted" || ok "plan set: invalid multi-select item refused"

[ "$(jq -c '.answers.surfaces' "$p/.workflow/plan/brief.json")" = '["web-phone","native"]' ] && ok "plan set: JSON list of labels -> values" || die "plan set list"
[ "$(jq -c '.answers["data.sensitivity"]' "$p/.workflow/plan/brief.json")" = '["pii","multi-tenant"]' ] && ok "plan set: comma-separated labels -> values" || die "plan set csv"
[ "$(jq -c '.answers.locales' "$p/.workflow/plan/brief.json")" = '["en","ka","ru"]' ] && ok "plan set: Other text for a list question" || die "plan set locales"
q="$(cd "$p" && "$wf" plan questions --json)"
[ "$(jq '.questions | length' <<<"$q")" -le 4 ] && ! jq -e '.questions[] | select(.key=="surfaces" or .key=="locales")' <<<"$q" >/dev/null && ok "plan questions: <= 4, answered ones skipped" || die "plan questions"
(cd "$p" && "$wf" plan defaults >/dev/null)
jq -e '.source.scale == "assumed" and .source.surfaces == "owner"' "$p/.workflow/plan/brief.json" >/dev/null && ok "plan defaults: assumptions recorded, answers kept" || die "plan defaults"

# ---------------------------------------------------------------- scaffold every stack
n=0
for f in "$repo"/templates/stacks/*.json; do
    id="$(basename "$f" .json)"
    ui="$(jq -r '.uiOptions[0]' "$f")"
    s="$(newrepo "stack-$id")"
    # Alternate brief shapes so both sides of every {{#if}} render somewhere.
    if [ $((n % 2)) = 0 ]; then
        mkdir -p "$s/.workflow/plan"
        cp "$p/.workflow/plan/brief.json" "$s/.workflow/plan/"
    else
        (cd "$s" && "$wf" plan defaults >/dev/null)
    fi
    n=$((n + 1))
    (cd "$s" && "$wf" plan scaffold --stack "$id" --ui "$ui" --no-versions >"$s/scaffold.out") || die "scaffold $id: $(cat "$s/scaffold.out")"
    for doc in docs/STACK.md docs/ENGINEERING-STANDARDS.md CLAUDE.md .claude/workflow.json; do
        [ -s "$s/$doc" ] || die "scaffold $id: missing $doc"
    done
    if [ "$ui" != native ]; then [ -s "$s/docs/UI-UX-STANDARDS.md" ] || die "scaffold $id: missing UI-UX-STANDARDS.md"; fi
    left="$(grep -rn '{{' "$s/docs" "$s/CLAUDE.md" "$s/.claude/workflow.json" || true)"
    [ -z "$left" ] || die "scaffold $id: unrendered placeholders: $left"
    jq -e --arg id "$id" '(.gates | length > 0) and ([.gates[] | has("when") and (has("requires") | not)] | all) and .stack.id == $id and (.docs.standards | length > 0)' "$s/.claude/workflow.json" >/dev/null || die "scaffold $id: workflow.json"
    jq -e '[.gates[] | select(.release == false)] | length >= 1' "$s/.claude/workflow.json" >/dev/null || die "scaffold $id: no affected-only inner test gate"
    grep -q 'versions:start' "$s/docs/STACK.md" || die "scaffold $id: no version table"
    if grep -n $'\xe2\x80\x94' "$s/docs/"*.md "$s/CLAUDE.md"; then die "scaffold $id: em dash in output"; fi
done
ok "scaffold: all $n stacks render with no placeholders, gates all have when, inner + release split"
grep -qx '.workflow/' "$dir/stack-go-api/.gitignore" && ok "scaffold: .workflow/ in .gitignore" || die "scaffold: .gitignore"
[ "$(jq -r .idPrefix "$dir/stack-django-htmx/.claude/workflow.json")" = AR ] && ok "scaffold: idPrefix from the product name" || die "scaffold idPrefix: $(jq -r .idPrefix "$dir/stack-django-htmx/.claude/workflow.json")"
jq -e '.gates[] | select(.name == "build") | .when | index("vite.config.*") == null' "$dir/stack-next-ts/.claude/workflow.json" >/dev/null &&
    jq -e '[.gates[].when[]] | index("vite.config.*") != null' "$dir/stack-laravel-inertia-react/.claude/workflow.json" >/dev/null &&
    ok "scaffold: no vite.config.* on Next's build gate, kept where vite ships" || die "scaffold: framework config globs"

# unpend clears pending only for gates whose tools now exist.
u="$dir/stack-laravel-inertia-react"
mkdir -p "$u/vendor/bin" && touch "$u/vendor/bin/pest"
(cd "$u" && "$wf" plan unpend >/dev/null) || die "plan unpend"
jq -e '(.gates[] | select(.name=="pest") | has("pending") | not) and (.gates[] | select(.name=="phpstan") | .pending == true)' "$u/.claude/workflow.json" >/dev/null && ok "plan unpend: clears installed tools only" || die "plan unpend result"

# unpend in a wf init repo (no stack.id): a gate clears once its command's tools are on PATH.
i="$(newrepo unpend-init)"
mkdir -p "$i/.claude"
echo '{"gates":[{"name":"a","cmd":"git status","when":["*"],"pending":true},{"name":"b","cmd":"no-such-tool-xyz run","when":["*"],"pending":true}]}' >"$i/.claude/workflow.json"
out="$(cd "$i" && "$wf" plan unpend)" || die "plan unpend (init repo)"
jq -e '(.gates[0] | has("pending") | not) and .gates[1].pending == true' "$i/.claude/workflow.json" >/dev/null && grep -q 'b (needs no-such-tool-xyz)' <<<"$out" &&
    ok "plan unpend: init-repo gates clear by their command's tools" || die "plan unpend init: $out"

# Never overwrites without --force.
s="$dir/stack-go-api"
echo "mine" >"$s/CLAUDE.md"
(cd "$s" && "$wf" plan scaffold --stack go-api --ui native --no-versions | grep -q 'kept.*CLAUDE.md') && [ "$(cat "$s/CLAUDE.md")" = mine ] && [ -s "$s/.workflow/plan/rendered/CLAUDE.md" ] && ok "scaffold: keeps existing files, renders a copy aside" || die "scaffold overwrote CLAUDE.md"

# Scaffold with real (fixture) versions: build the fixture from the stack's package list.
s="$(newrepo stack-versions)"
(cd "$s" && "$wf" plan defaults >/dev/null)
bun -e "
import { urlFor } from '$repo/scripts/cmd/versions.ts';
const st = JSON.parse(await Bun.file('$repo/templates/stacks/go-api.json').text());
const fx = {};
for (const id of st.packages) {
  const u = urlFor(id);
  fx[u] = id.startsWith('eol:') ? [{ cycle: '1', latest: '1.2.3', latestReleaseDate: '2026-01-01', eol: false }] : { Version: 'v1.2.3', Time: '2026-01-01T00:00:00Z' };
}
await Bun.write('$dir/go-fixture.json', JSON.stringify(fx));
" || die "build go-api fixture"
(cd "$s" && WF_VERSIONS_FIXTURE="$dir/go-fixture.json" "$wf" plan scaffold --stack go-api --ui native >/dev/null) || die "scaffold go-api with versions"
grep -qF "| \`go:github.com/go-chi/chi/v5\` | 1.2.3 |" "$s/docs/STACK.md" && ! grep -q UNVERIFIED "$s/docs/STACK.md" && ok "scaffold: version table filled from wf versions" || die "scaffold: version table"
(cd "$s" && WF_VERSIONS_FIXTURE="$dir/go-fixture.json" "$wf" versions --check docs/STACK.md >/dev/null) && ok "scaffold: generated STACK.md passes versions --check" || die "scaffold: STACK.md check"

# ---------------------------------------------------------------- cards
c="$dir/stack-laravel-inertia-react"
cat >"$c/cards.json" <<'EOF'
{"milestones":[{"name":"v1","cards":[{"key":"rooms","title":"Rooms: create and archive","size":"M","area":"core","depends":["auth"],"goal":"Admins manage rooms.","acceptance":["An admin creates a room","An archived room cannot be booked"]}]}]}
EOF
(cd "$c" && "$wf" plan cards cards.json >"$c/cards.out") || die "plan cards: $(cat "$c/cards.out")"
[ "$(grep -c '^created' "$c/cards.out")" = 6 ] && ok "plan cards: first cards + planner cards created" || die "plan cards count: $(cat "$c/cards.out")"
rooms="$(find "$c/tasks" -maxdepth 1 -name '*rooms*.md')"
auth_id="$(grep -l 'title: "Auth' "$c"/tasks/*.md | xargs sed -n 's/^id: //p')"
grep -q "^depends: \[$auth_id\]" "$rooms" && grep -q '^- \[ \] An archived room cannot be booked' "$rooms" && ok "plan cards: depends keys resolve to ids, acceptance written" || die "plan cards body/depends"
echo '{"cards":[{"key":"x","title":"Orphan dep","depends":["nope"]}]}' >"$c/bad-cards.json"
(cd "$c" && "$wf" plan cards bad-cards.json --dry-run 2>&1 >/dev/null) | grep -q 'unknown key(s) nope' && ok "plan cards: an unknown dependency key warns" || die "plan cards: unknown key not warned"
(cd "$c" && "$wf" plan cards cards.json | grep -c '^kept' | grep -qx 6) && [ "$(find "$c/tasks" -maxdepth 1 -name '*.md' | wc -l)" -eq 6 ] && ok "plan cards: idempotent" || die "plan cards: not idempotent"
(cd "$c" && "$wf" detect --save >/dev/null && "$wf" plan status | grep -q "^next: research") && ok "plan status: names the next phase" || die "plan status"

if command -v shellcheck >/dev/null; then
    shellcheck "$repo/tests/plan.sh" && ok "shellcheck tests/plan.sh" || die "shellcheck"
fi
printf '\n%d checks passed (scratch: %s)\n' "$pass" "$dir"
