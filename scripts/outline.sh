#!/usr/bin/env bash
# Symbol outline of source files: line number + declaration, so you can
# `sed -n START,ENDp FILE` the part you need instead of reading the file whole.
#
# Usage: wf outline FILE...
#
# Regex based (rg), language agnostic: classes, functions, methods, types,
# interfaces, enums, structs, traits, impls, routes in common languages.
# Markdown files get their heading tree (wf doc).
set -euo pipefail

[ $# -gt 0 ] || {
    echo "usage: wf outline FILE..." >&2
    exit 2
}
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pattern='^\s*(export\s+)?(default\s+)?(public|private|protected|static|abstract|final|async|pub(\([a-z]+\))?|readonly|override|\s)*\s*(class|interface|trait|enum|struct|impl|type|function|func|fn|def|module|namespace|const\s+\w+\s*=\s*(async\s*)?\(|[A-Za-z_][\w<>,\s]*\s+\w+\s*\([^;]*\)\s*\{?\s*$)'
for f in "$@"; do
    [ $# -gt 1 ] && echo "=== $f ($(wc -l <"$f") lines)"
    case "$f" in
    *.md | *.markdown) "$here/doc.sh" "$f" ;;
    *)
        if command -v rg >/dev/null; then
            rg -n --no-heading -e "$pattern" "$f" | cut -c1-160 || true
        else
            grep -nE "$(printf '%s' "$pattern" | sed 's/\\s/[[:space:]]/g; s/\\w/[[:alnum:]_]/g')" "$f" | cut -c1-160 || true
        fi
        ;;
    esac
done
