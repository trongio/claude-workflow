#!/usr/bin/env bash
# Navigate a markdown file by headings instead of reading it in slices.
#
# Usage: wf doc FILE                 heading tree: line, size, heading
#        wf doc FILE SECTION-REGEX   print only the matching sections
#        wf doc FILE --depth N       tree down to heading level N
#
# The tree shows each heading's line number and its section size in lines
# (heading through the next heading of the same or higher level). Over 80
# headings it shows levels 1-2 only unless --depth is given. With a regex
# (extended, case-insensitive, matched against the heading text) it prints
# each matching section whole, nested subsections included; read a section
# with `sed -n START,ENDp FILE` when you need just part of it. Headings inside
# ``` fences are ignored.
set -euo pipefail

file="${1:?usage: wf doc FILE [SECTION-REGEX | --depth N]}"
shift
regex=""
depth=0
while [ $# -gt 0 ]; do
    case "$1" in
    --depth)
        depth="${2:?--depth needs N}"
        shift
        ;;
    --depth=*) depth="${1#--depth=}" ;;
    *) regex="$1" ;;
    esac
    shift
done
[ -f "$file" ] || {
    echo "doc: no such file: $file" >&2
    exit 2
}

# Pass 1: heading index "line level end text" (end = last line of section).
index="$(awk '
    /^(```|~~~)/ { fence = !fence; next }
    fence { next }
    /^#{1,6} / {
        match($0, /^#+/); n++
        line[n] = NR; lvl[n] = RLENGTH; text[n] = substr($0, RLENGTH + 2)
    }
    END {
        for (i = 1; i <= n; i++) {
            end = NR
            for (j = i + 1; j <= n; j++) if (lvl[j] <= lvl[i]) { end = line[j] - 1; break }
            print line[i] "\t" lvl[i] "\t" end "\t" text[i]
        }
    }
' "$file")"

if [ -z "$index" ]; then
    echo "doc: no headings in $file ($(wc -l <"$file") lines)"
    exit 0
fi

if [ -z "$regex" ]; then
    count="$(printf '%s\n' "$index" | wc -l)"
    if [ "$depth" = 0 ] && [ "$count" -gt 80 ]; then
        depth=2
        echo "($count headings; levels 1-2 shown, use --depth 3 or a SECTION-REGEX)"
    fi
    printf '%s\n' "$index" | awk -F'\t' -v d="$depth" '
        BEGIN { print "  line   size  heading" }
        d == 0 || $2 <= d {
            pad = ""; for (k = 1; k < $2; k++) pad = pad "  "
            printf "%6d %6d  %s%s %s\n", $1, $3 - $1 + 1, pad, substr("######", 1, $2), $4
        }'
    exit 0
fi

# Matching sections; a match nested inside an already printed one is skipped.
mapfile -t ranges < <(printf '%s\n' "$index" | awk -F'\t' -v re="$regex" '
    BEGIN { re = tolower(re) }
    tolower($4) ~ re && $1 > last { print $1 "," $3; last = $3 }
')
if [ "${#ranges[@]}" -eq 0 ]; then
    echo "doc: no heading matches /$regex/ (run without a regex for the tree)" >&2
    exit 1
fi
for r in "${ranges[@]}"; do
    echo "--- $file:${r%,*}-${r#*,}"
    sed -n "${r}p" "$file"
done
