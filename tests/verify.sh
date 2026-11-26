#!/usr/bin/env bash
# Verification and search tools: wf check, flow, shots (Playwright, against a
# static fixture served by Bun.serve), wf rgx, wf lang and the locale merge driver.
# Playwright tests run only when Playwright resolves (after trying `wf check --install`);
# otherwise they print SKIP. Needs bun, jq, git, rg.
#
# Usage: tests/verify.sh [SCRATCH_DIR]   (default: a fresh mktemp dir)
# shellcheck disable=SC2015
set -eu

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
wf="$repo/bin/wf"
dir="${1:-$(mktemp -d "${TMPDIR:-/tmp}/wf-verify.XXXXXX")}"
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
pass=0
skip=0
server_pid=""
trap 'rc=$?; [ -n "$server_pid" ] && kill "$server_pid" 2>/dev/null; wf_scratch_cleanup "$rc"' EXIT

ok() {
    pass=$((pass + 1))
    printf 'ok   %s\n' "$1"
}
die() {
    printf 'FAIL %s\n' "$1" >&2
    [ -n "${2:-}" ] && printf '%s\n' "$2" | head -n 30 >&2
    exit 1
}
skipped() {
    skip=$((skip + 1))
    printf 'SKIP %s\n' "$1"
}

# --- fixture project: a git repo with a config and a static site --------------
proj="$dir/proj"
mkdir -p "$proj/site" "$proj/.claude" "$proj/tasks"
git -C "$proj" init -q
cat >"$proj/site/good.html" <<'EOF'
<!doctype html><html lang="ka"><head><meta name="viewport" content="width=device-width"><title>good</title></head>
<body><h1>Good page</h1><p>Hello there.</p></body></html>
EOF
cat >"$proj/site/bad.html" <<'EOF'
<!doctype html><html lang="ka"><head><meta name="viewport" content="width=device-width"><title>bad</title>
<style>.wide{width:2000px;height:10px}.clip{width:80px;overflow:hidden;text-overflow:ellipsis}.nw{white-space:nowrap}
.narrow{width:60px;word-break:break-all}</style></head>
<body><h1>Bad page</h1><div class="wide"></div><div class="clip">Labelthatistoolong</div>
<p class="nw">one two three four five six seven</p><p class="narrow">Supercalifragilistic</p>
<img src="photo.png"><button style="width:20px;height:20px">x</button><script>console.error("boom")</script></body></html>
EOF
cat >"$proj/site/wrong.html" <<'EOF'
<!doctype html><html lang="en"><head><title>wrong</title></head><body><h1>English page</h1></body></html>
EOF
cat >"$proj/site/login.html" <<'EOF'
<!doctype html><html lang="ka"><head><title>login</title></head><body><h1>Sign in</h1>
<form action="/good.html"><label>Email <input name="email"></label><button>Sign in</button></form>
<script>console.log("login page ready")</script></body></html>
EOF
cat >"$dir/serve.ts" <<'EOF'
const root = process.argv[2];
const server = Bun.serve({
    port: 0,
    async fetch(req) {
        const file = Bun.file(root + new URL(req.url).pathname);
        return (await file.exists()) ? new Response(file) : new Response('not found', { status: 404 });
    },
});
await Bun.write(process.argv[3], String(server.port));
EOF
bun "$dir/serve.ts" "$proj/site" "$dir/port" >/dev/null 2>&1 &
server_pid=$!
for _ in $(seq 1 50); do [ -s "$dir/port" ] && break || sleep 0.1; done
[ -s "$dir/port" ] || die "fixture server did not start"
base="http://127.0.0.1:$(cat "$dir/port")"
printf '{"dev":{"url":"%s","viewports":[375,1440]},"ux":{"widestLocale":"ka"}}\n' "$base" >"$proj/.claude/workflow.json"
cd "$proj"

# --- Playwright: wf check / flow / shots ---------------------------------------
"$wf" check --help | grep -q 'wrong-locale' && ok "check --help" || die "check --help"
nourl="$dir/nourl"
mkdir -p "$nourl"
git -C "$nourl" init -q
set +e
out="$(cd "$nourl" && "$wf" check /good.html 2>&1)"
rc=$?
set -e
[ "$rc" = 2 ] && grep -q 'set dev.url in .claude/workflow.json or pass a full URL' <<<"$out" &&
    ok "check refuses a path with no dev.url" || die "check without dev.url (rc $rc)" "$out"
have_pw=1
if ! "$wf" check /good.html --viewports 1440 >/dev/null 2>"$dir/pw.err"; then
    if grep -q 'playwright unavailable' "$dir/pw.err"; then
        "$wf" check --install >/dev/null 2>&1 || true
        "$wf" check /good.html --viewports 1440 >/dev/null 2>"$dir/pw.err" || have_pw=0
    else
        die "check on a clean page" "$(cat "$dir/pw.err")"
    fi
fi

if [ "$have_pw" = 0 ]; then
    skipped "playwright checks: $(head -c 160 "$dir/pw.err")"
else
    out="$("$wf" check /good.html)" && ok "clean page passes at both viewports" || die "clean page" "$out"
    [ "$(grep -c '^ok' <<<"$out")" = 2 ] && ok "one line per url x viewport" || die "line count" "$out"

    set +e
    json="$("$wf" check /bad.html --viewports 375 --json)"
    rc=$?
    set -e
    [ "$rc" = 1 ] && ok "failing page exits 1" || die "bad page exit $rc" "$json"
    for probe in '.overflow.px > 0:overflow' '.clipped.n >= 1:clipped text' '.nowrap.n >= 1:nowrap prose' \
        '.midword.n >= 1:mid-word break' '.img.noAlt == 1:missing alt' '.img.noSize == 1:missing width/height' \
        '.tap.n >= 1:small tap target' '.console.first[0] == "boom":console error' '.failed.n >= 1:failed request' \
        '.lang == "ka":html lang' '(.shot | test("bad-html-375.png$")):screenshot path'; do
        jq -e "${probe%%:*}" <<<"$json" >/dev/null && ok "check reports ${probe#*:}" || die "check ${probe#*:}" "$json"
    done
    [ -f "$(jq -r .shot <<<"$json")" ] && ok "screenshot written" || die "screenshot missing"

    set +e
    human="$("$wf" check /bad.html /wrong.html)"
    set -e
    awk 'length > 120 { exit 1 }' <<<"$human" && ok "summary lines <= 120 chars" || die "long summary" "$human"
    [ "$(grep -c 'wrong.html' <<<"$human")" = 1 ] && grep -q 'wrong-locale' <<<"$human" &&
        ok "wrong <html lang> aborts that url" || die "wrong-locale" "$human"
    "$wf" check /wrong.html --locale en >/dev/null && ok "--locale overrides the widest locale" || die "--locale en"
    "$wf" check /good.html --viewports 1440 --expect 'Not on page' >/dev/null && die "--expect" || ok "--expect fails on missing text"
    "$wf" check /bad.html --viewports 1440 --advisory console,requests,overflow,clipped,nowrap,midword,alt,size >/dev/null &&
        ok "--advisory downgrades checks" || die "--advisory"

    cat >"$proj/steps.flow.json" <<'EOF'
[{"goto": "/login.html"}, {"fill": "Email", "value": "{{env.WF_TEST_EMAIL}}"}]
EOF
    cat >"$proj/pass.flow.json" <<'EOF'
{"steps": [{"include": "steps.flow.json"}, {"click": "Sign in"}, {"expectUrl": "/good.html"},
 {"expectText": "Hello there"}, {"screenshot": "after"}, {"saveState": ".workflow/state.json"}]}
EOF
    cat >"$proj/fail.flow.json" <<'EOF'
{"steps": [{"goto": "/login.html"}, {"expectText": "Not here", "timeout": 800}, {"goto": "/good.html"}]}
EOF
    out="$(WF_TEST_EMAIL=a@b.test "$wf" flow pass.flow.json)" && grep -q 'flow ok: 7 steps' <<<"$out" &&
        ok "flow passes (include, env, click, expect, screenshot)" || die "flow pass" "$out"
    [ -f .workflow/state.json ] && ok "flow saves storage state" || die "saveState"
    set +e
    out="$("$wf" flow fail.flow.json)"
    rc=$?
    set -e
    [ "$rc" = 1 ] && grep -q '^FAIL  2 expectText' <<<"$out" && ! grep -q ' 3 goto' <<<"$out" &&
        ok "flow stops at the first failure" || die "flow fail" "$out"
    grep -q 'fail-step-2.png' <<<"$out" && grep -q 'login page ready' <<<"$out" &&
        ok "failed step prints a screenshot and the console" || die "flow fail detail" "$out"
    "$wf" flow pass.flow.json >/dev/null 2>&1 && die "unset env var" || ok "flow refuses an unset {{env.X}}"

    # shellcheck disable=SC2016 # literal backticks in the card
    printf -- '---\nid: VT-1\ntitle: shots\nstatus: todo\n---\n## Surfaces\n- `/good.html` home\n- /bad.html\n\n## Acceptance\n- [ ] /not-a-surface\n' >tasks/VT-1-shots.md
    set +e
    out="$("$wf" shots VT-1)"
    set -e
    m=.workflow/shots/VT-1/manifest.json
    grep -q 'login: none' <<<"$out" && ok "shots reports the missing login flow" || die "shots login" "$out"
    [ "$(jq '.shots | length' "$m")" = 4 ] && [ "$(jq -r '[.shots[].path] | unique | join(",")' "$m")" = "/bad.html,/good.html" ] &&
        ok "shots: card surfaces x viewports in the manifest" || die "shots manifest" "$(cat "$m")"
    jq -e '.locale == "ka" and ([.shots[] | select(.path == "/bad.html") | .ok] | all | not)' "$m" >/dev/null &&
        [ -f ".workflow/shots/VT-1/$(jq -r '.shots[0].file' "$m")" ] && ok "shots: files and check results" || die "shots results"
    cp steps.flow.json .workflow/steps.flow.json
    cp pass.flow.json .workflow/login.flow.json
    out="$(WF_TEST_EMAIL=a@b.test "$wf" shots VT-1 /good.html)" && jq -e '.login and (.shots | length == 2)' "$m" >/dev/null &&
        ok "shots signs in with the login flow and takes explicit paths" || die "shots login flow" "$out"
fi

# --- wf rgx ----------------------------------------------------------------------
mkdir -p "$dir/rgx/src" "$dir/rgx/dist"
for i in $(seq 1 30); do echo "needle $i" >>"$dir/rgx/src/many.txt"; done
for i in 1 2 3; do echo "needle $i" >>"$dir/rgx/src/few.txt"; done
echo "needle in a lockfile" >"$dir/rgx/package-lock.json"
echo "needle in a build" >"$dir/rgx/dist/app.js"
echo "needle minified" >"$dir/rgx/src/app.min.js"
out="$(cd "$dir/rgx" && "$wf" rgx needle src/few.txt)"
[ "$(wc -l <<<"$out")" = 3 ] && grep -q '^src/few.txt:1:needle 1' <<<"$out" && ok "rgx prints hits with line numbers" || die "rgx hits" "$out"
out="$(cd "$dir/rgx" && "$wf" rgx needle --max 10)"
grep -q '^rgx: 33 hits in 2 files' <<<"$out" && grep -Eq '^ +30  src/many.txt' <<<"$out" &&
    [ "$(grep -c '^src/many.txt:' <<<"$out")" = 3 ] && ok "rgx over --max prints counts and top hits" || die "rgx counts" "$out"
grep -Eq 'lock|dist|min.js' <<<"$out" && die "rgx excludes" "$out" || ok "rgx skips lockfiles, build dirs, minified"
(cd "$dir/rgx" && "$wf" rgx nothing-matches-this) && die "rgx no match" || ok "rgx exits 1 on no match"

# --- wf lang ---------------------------------------------------------------------
tabs="$dir/tabs"
spaces="$dir/spaces"
mkdir -p "$tabs/lang" "$spaces/src/locales/en" "$spaces/src/locales/ka"
git -C "$tabs" init -q
git -C "$spaces" init -q
printf '{\n\t"hello": "Hello",\n\t"nav.home": "Home"\n}\n' >"$tabs/lang/en.json"
printf '{\n\t"hello": "Gamarjoba"\n}\n' >"$tabs/lang/ka.json"
printf '{\n    "nav": {\n        "home": "Home"\n    }\n}\n' >"$spaces/src/locales/en/common.json"
printf '{\n    "nav": {\n        "home": "Mtavari"\n    }\n}\n' >"$spaces/src/locales/ka/common.json"
out="$(cd "$tabs" && "$wf" lang set bye Bye nav.about About)"
[ "$out" = "set 2 keys in en" ] && ok "lang set prints the count and the locale" || die "lang set" "$out"
grep -q $'^\t"bye": "Bye"' "$tabs/lang/en.json" && ! grep -q '^ ' "$tabs/lang/en.json" && ok "lang set keeps tabs" || die "tabs" "$(cat "$tabs/lang/en.json")"
(cd "$spaces" && "$wf" lang set common:nav.about About >/dev/null)
grep -q '^        "about": "About"' "$spaces/src/locales/en/common.json" && ok "lang set keeps 4 spaces, nests in a namespace" ||
    die "spaces" "$(cat "$spaces/src/locales/en/common.json")"
(cd "$tabs" && "$wf" lang set bye Bye --locale fr >/dev/null 2>&1) && die "lang set --locale fr without --create" ||
    ok "lang set refuses a locale with no catalog"
[ ! -e "$tabs/lang/fr.json" ] || die "refused locale still wrote a file"
out="$(cd "$tabs" && "$wf" lang set bye Au-revoir --locale fr --create)"
[ "$out" = "set 1 keys in fr" ] && grep -q '"bye": "Au-revoir"' "$tabs/lang/fr.json" && ok "lang set --create starts a catalog" || die "lang --create" "$out"
rm "$tabs/lang/fr.json"
out="$(cd "$spaces" && "$wf" lang get common.nav.home)"
grep -q $'common.nav.home\tka\tMtavari' <<<"$out" && ok "lang get resolves nested keys per locale" || die "lang get" "$out"
set +e
out="$(cd "$tabs" && "$wf" lang missing)"
rc=$?
set -e
[ "$rc" = 1 ] && grep -q 'ka: 3 missing' <<<"$out" && grep -q '^  nav.home' <<<"$out" && ok "lang missing lists gaps, exits 1" || die "lang missing" "$out"
out="$(cd "$tabs" && "$wf" lang rm bye)"
[ "$out" = "removed 1 keys" ] && ! grep -q bye "$tabs/lang/en.json" && ok "lang rm" || die "lang rm" "$out"

# --- merge driver ----------------------------------------------------------------
mr="$dir/merge"
mkdir -p "$mr/lang"
git -C "$mr" init -q -b main
git -C "$mr" config user.email t@t.test
git -C "$mr" config user.name test
printf '{\n\t"keep": "Keep",\n\t"gone": "Gone",\n\t"back": "Back"\n}\n' >"$mr/lang/en.json"
out="$(cd "$mr" && "$wf" lang install-driver)"
grep -q 'lang/\*.json merge=wf-lang' "$mr/.gitattributes" && git -C "$mr" config merge.wf-lang.driver | grep -q lang-merge-driver.ts &&
    ok "lang install-driver writes .gitattributes and git config" || die "install-driver" "$out"
git -C "$mr" add -A && git -C "$mr" commit -qm base
git -C "$mr" checkout -qb theirs
printf '{\n\t"keep": "Keep",\n\t"gone": "Gone",\n\t"back": "Back again",\n\t"theirs": "T"\n}\n' >"$mr/lang/en.json"
git -C "$mr" commit -qam theirs
git -C "$mr" checkout -q main
printf '{\n\t"keep": "Keep",\n\t"ours": "O"\n}\n' >"$mr/lang/en.json"
git -C "$mr" commit -qam ours
out="$(git -C "$mr" merge --no-edit theirs 2>&1)" && ok "merge driver merges a two-sided key addition" || die "merge" "$out"
jq -e '.ours == "O" and .theirs == "T" and (has("gone") | not) and .back == "Back again"' "$mr/lang/en.json" >/dev/null &&
    ! grep -q '<<<<<<<' "$mr/lang/en.json" && ok "merge keeps both additions and the untouched deletion" || die "merge result" "$(cat "$mr/lang/en.json")"
grep -q 'resurrected back (deleted in ours)' <<<"$out" && ok "merge driver flags a resurrected deletion" || die "resurrected warning" "$out"
grep -q $'^\t"theirs"' "$mr/lang/en.json" && ok "merge keeps the tab indent" || die "merge indent"

echo "verify: $pass passed, $skip skipped"
