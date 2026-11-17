#!/bin/sh
set -eu

usage() {
  echo "Usage: $0 <tavashtr-changelog> <debian-trixie-changelog> <output-path> <debian-binaries.tsv>" >&2
  exit 2
}

fail() {
  echo "resolve-tavashtr-changelog: error: $*" >&2
  exit 1
}

[ "$#" -eq 4 ] || usage

tavashtr_changelog=$1
debian_changelog=$2
output_path=$3
binary_versions=$4
suffix="+0tavashtr1"

for input in "$tavashtr_changelog" "$debian_changelog" "$binary_versions"; do
  [ -f "$input" ] || fail "input file does not exist: $input"
done
[ -s "$binary_versions" ] || fail "binary version list is empty: $binary_versions"

command -v dpkg-parsechangelog >/dev/null 2>&1 ||
  fail "dpkg-parsechangelog is required; install devscripts"

get_field() {
  dpkg-parsechangelog --file "$1" --show-field "$2"
}

first_entry_body() {
  awk '
    NR == 1 { next }
    /^ -- / { exit }
    {
      lines[NR] = $0
      if ($0 !~ /^[[:space:]]*$/) {
        last = NR
      }
    }
    END {
      first = 2
      while (first <= last && lines[first] ~ /^[[:space:]]*$/) {
        first++
      }
      for (i = first; i <= last; i++) {
        print lines[i]
      }
    }
  ' "$1"
}

# Print the changelog after its first entry's signature.
entries_after_first() {
  awk '
    /^ -- / && !first_signature_seen {
      first_signature_seen = 1
      next
    }
    first_signature_seen {
      print
    }
  ' "$1"
}

package=$(get_field "$debian_changelog" Source)
tavashtr_package=$(get_field "$tavashtr_changelog" Source)
[ "$package" = "$tavashtr_package" ] ||
  fail "package mismatch: Debian has '$package', Tavashtr has '$tavashtr_package'"

debian_version=$(get_field "$debian_changelog" Version)
case "$debian_version" in *"$suffix")
    fail "Debian version already ends in '$suffix': $debian_version"
    ;;
esac
binary_base=$debian_version
tab=$(printf '\t')
while IFS="$tab" read -r _binary _arch version _suite; do
  case "$version" in
    "$debian_version"+b*)
      rebuild=${version#"$debian_version"+b}
      case "$rebuild" in
        ''|*[!0-9]*) continue ;;
      esac

      if dpkg --compare-versions "$version" gt "$binary_base"; then
        binary_base=$version
      fi
      ;;
  esac
done < "$binary_versions"

tavashtr_distribution=$(get_field "$tavashtr_changelog" Distribution)
previous_version=$(get_field "$tavashtr_changelog" Version)
if [ "$tavashtr_distribution" = "UNRELEASED" ]; then
  previous_version=$(dpkg-parsechangelog --file "$tavashtr_changelog" \
    --offset 1 --count 1 --show-field Version)
fi

new_version="${binary_base}${suffix}"

# Handle Debian revisions like -1deb13u1 when they would lower the version.
if [ -n "$previous_version" ] &&
   ! dpkg --compare-versions "$new_version" gt "$previous_version"; then
  corrected_base=$(printf '%s\n' "$debian_version" |
    sed -E 's/(-[0-9]+)(deb13u[0-9]+)$/\1+\2/')
  if [ "$corrected_base" != "$debian_version" ]; then
    rebuild_suffix=${binary_base#"$debian_version"}
    new_version="${corrected_base}${rebuild_suffix}${suffix}"
  fi
fi

dpkg --compare-versions "$new_version" gt "$binary_base" ||
  fail "generated version $new_version must be higher than Debian version $binary_base"

if [ -n "$previous_version" ]; then
  dpkg --compare-versions "$new_version" gt "$previous_version" ||
    fail "generated version $new_version must be higher than previous version $previous_version"
fi

urgency=$(get_field "$debian_changelog" Urgency)
maintainer=$(get_field "$tavashtr_changelog" Maintainer)

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/resolve-tavashtr-changelog.XXXXXX")
output_tmp=""
cleanup() {
  if [ -n "$output_tmp" ] && [ -f "$output_tmp" ]; then
    rm -f "$output_tmp"
  fi
  if [ -n "${tmpdir:-}" ] && [ -d "$tmpdir" ]; then
    rm -rf "$tmpdir"
  fi
}
trap cleanup 0

first_entry_body "$debian_changelog" > "$tmpdir/debian.body"
first_entry_body "$tavashtr_changelog" > "$tmpdir/tavashtr.body"

[ -s "$tmpdir/debian.body" ] ||
  fail "Debian Trixie's latest entry has no change text"

if [ "$tavashtr_distribution" = "UNRELEASED" ]; then
  [ -s "$tmpdir/tavashtr.body" ] ||
    fail "Tavashtr's UNRELEASED entry has no change text"
else
  : > "$tmpdir/tavashtr.body"
fi

output_dir=$(dirname "$output_path")
mkdir -p "$output_dir"
output_tmp=$(mktemp "$output_dir/.$(basename "$output_path").XXXXXX")

{
  printf '%s (%s) tavashtr; urgency=%s\n\n' \
    "$package" "$new_version" "$urgency"

  if [ -s "$tmpdir/tavashtr.body" ]; then
    if grep -Eq '^[[:space:]]+\[.*\][[:space:]]*$' "$tmpdir/tavashtr.body"; then
      cat "$tmpdir/tavashtr.body"
    else
      printf '  [ From Tavashtr ]\n'
      cat "$tmpdir/tavashtr.body"
    fi
    printf '\n'
  fi

  printf '  [ From Debian ]\n'
  cat "$tmpdir/debian.body"
  printf '\n'

  printf '\n -- %s  %s\n\n' "$maintainer" "$(date -R)"

  if [ "$tavashtr_distribution" = "UNRELEASED" ]; then
    entries_after_first "$tavashtr_changelog"
  else
    cat "$tavashtr_changelog"
  fi
} > "$output_tmp"

parsed_version=$(get_field "$output_tmp" Version)
[ "$parsed_version" = "$new_version" ] ||
  fail "generated version mismatch: expected '$new_version', got '$parsed_version'"

mv "$output_tmp" "$output_path"
output_tmp=""

echo "Wrote $new_version changelog entry to $output_path"
