#!/usr/bin/env bash
set -euo pipefail

# Run from the Tavashtr package root after fetching origin/debian-trixie.
changelog=debian/changelog
debian_ref=origin/debian-trixie
script_dir=$(dirname "$0")

# shellcheck source=.github/scripts/tavashtr-version.sh
. "$script_dir/tavashtr-version.sh"

fail() {
  printf 'release-tavashtr-changelog: %s\n' "$*" >&2
  exit 1
}

[[ $(git symbolic-ref --quiet --short HEAD) == tavashtr ]] ||
  fail 'expected a checkout of the tavashtr branch'
[[ $(dpkg-parsechangelog --file "$changelog" --show-field Distribution) == UNRELEASED ]] ||
  fail 'the top changelog entry must be UNRELEASED'

source_package=$(dpkg-parsechangelog --file "$changelog" --show-field Source)
previous_version=$(dpkg-parsechangelog --file "$changelog" --offset 1 --count 1 --show-field Version)

entry_commit=HEAD
if [[ -n "$previous_version" ]]; then
  entry_commit=$(git log -1 --first-parent --format=%H \
    -S "$source_package ($previous_version) " -- "$changelog")
  [[ -n "$entry_commit" ]] || fail "cannot find the commit for $previous_version"
fi

# The common Debian commit is the original merge head, also through a PR merge
# or a subsequent Tavashtr-only release. With just the initial import it is on
# Tavashtr's first-parent history, so use the Debian branch directly.
debian_commit=$(git merge-base "$entry_commit" "$debian_ref")
if git rev-list --first-parent "$entry_commit" | grep -Fx "$debian_commit" >/dev/null; then
  debian_commit=$debian_ref
fi

tmpdir=$(mktemp -d debian/.release-tavashtr.XXXXXX)
trap 'rm -rf -- "$tmpdir"' EXIT

git show "$debian_commit:$changelog" > "$tmpdir/debian-changelog"
debian_package=$(dpkg-parsechangelog --file "$tmpdir/debian-changelog" --show-field Source)
[[ "$debian_package" == "$source_package" ]] ||
  fail "package mismatch: Debian has '$debian_package', Tavashtr has '$source_package'"
debian_version=$(dpkg-parsechangelog --file "$tmpdir/debian-changelog" --show-field Version)
[[ ! "$debian_version" =~ \+0tavashtr[0-9]+$ ]] ||
  fail "Debian version already has a Tavashtr suffix: $debian_version"

bash "$script_dir/lookup-debian-binaries.sh" "$source_package" "$debian_version" amd64 \
  --allow-empty > "$tmpdir/debian-binaries.tsv"
binary_base=$(latest_debian_binary_version "$debian_version" "$tmpdir/debian-binaries.tsv")

suffix=+0tavashtr1
previous_base=
if [[ "$previous_version" =~ ^(.+)\+0tavashtr([0-9]+)$ ]]; then
  previous_base=${BASH_REMATCH[1]}
  suffix=+0tavashtr$((10#${BASH_REMATCH[2]} + 1))
fi

release_base() {
  local source_version=$1
  local candidate="$source_version${binary_base#"$debian_version"}"

  # Keep a previous rebuild for this source if it has rotated out of the archive.
  if [[ "$previous_base" == "$source_version"+b* &&
        "${previous_base#"$source_version"+b}" =~ ^[0-9]+$ ]] &&
     dpkg --compare-versions "$previous_base" gt "$candidate"; then
    candidate=$previous_base
  fi
  printf '%s\n' "$candidate"
}

new_version="$(release_base "$debian_version")$suffix"
if [[ -n "$previous_version" ]] &&
   ! dpkg --compare-versions "$new_version" gt "$previous_version"; then
  corrected_base=$(normalize_debian_security_version "$debian_version")
  new_version="$(release_base "$corrected_base")$suffix"
fi

dpkg --compare-versions "$new_version" gt "$binary_base" ||
  fail "generated version $new_version must be higher than Debian version $binary_base"
if [[ -n "$previous_version" ]]; then
  dpkg --compare-versions "$new_version" gt "$previous_version" ||
    fail "generated version $new_version must be higher than previous version $previous_version"
fi

edited="$tmpdir/tavashtr-changelog"
perl - "$new_version" "$changelog" > "$edited" <<'PERL'
my $version = shift;
my $header = <>;
$header =~ s/\([^()]*\)([ \t]+)UNRELEASED(?=;)/($version)${1}tavashtr/
    or die "Cannot update the UNRELEASED changelog header\n";
print $header;

my $body = <>;
while (defined $body && $body =~ /^\s*$/) {
    print $body;
    $body = <>;
}
die "The UNRELEASED entry has no change text\n" if !defined $body || $body =~ /^ -- /;
print "  [ From Tavashtr ]\n" unless $body =~ /^\s+\[ From Tavashtr \]\s*$/;
print $body;
print while <>;
PERL

[[ $(dpkg-parsechangelog --file "$edited" --show-field Version) == "$new_version" &&
   $(dpkg-parsechangelog --file "$edited" --show-field Distribution) == tavashtr ]] ||
  fail 'the edited changelog did not parse as the expected release'
chmod --reference="$changelog" "$edited"
mv -- "$edited" "$changelog"
printf 'Prepared Tavashtr release %s from Debian source %s.\n' "$new_version" "$debian_version"
