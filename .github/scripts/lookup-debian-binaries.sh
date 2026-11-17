#!/usr/bin/env bash
set -euo pipefail

source_package=${1:?Pass the Debian source package name}
source_version=${2:?Pass the Debian source package version}
target_arch=${3:?Pass the target architecture, e.g. amd64}
keyring=${DEBIAN_ARCHIVE_KEYRING:-/usr/share/keyrings/debian-archive-keyring.gpg}

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
matches="$tmp/matches.tsv"
: > "$matches"

fetch() {
  curl --fail --silent --show-error --location \
    --connect-timeout 10 --max-time 90 --retry 2 "$@"
}

for suite in trixie trixie-updates trixie-security; do
  mirror=https://deb.debian.org/debian
  if [[ "$suite" == trixie-security ]]; then
    mirror=https://deb.debian.org/debian-security
  fi
  root="$mirror/dists/$suite"
  release="$tmp/$suite.Release"

  fetch "$root/InRelease" -o "$tmp/InRelease"
  gpgv --keyring "$keyring" --output "$release" "$tmp/InRelease"
  if ! grep -Fxq "Codename: $suite" "$release"; then
    printf 'Unexpected Debian codename in the signed release for %s.\n' "$suite" >&2
    exit 1
  fi

  valid_until=$(sed -n 's/^Valid-Until: //p' "$release")
  if [[ -n "$valid_until" ]]; then
    expiry=$(date -u -d "$valid_until" +%s)
    if (( expiry <= $(date -u +%s) )); then
      printf 'Debian metadata expired for %s.\n' "$suite" >&2
      exit 1
    fi
  fi

  for arch in "$target_arch" all; do
    index_path="main/binary-$arch/Packages.xz"
    hash=$(awk -v path="$index_path" '
      /^SHA256:$/ { in_sha256 = 1; next }
      /^[^[:space:]]/ { in_sha256 = 0 }
      in_sha256 && $3 == path { print $1; exit }
    ' "$release")

    if [[ ! "$hash" =~ ^[[:xdigit:]]{64}$ ]]; then
      printf 'No signed checksum for %s/%s.\n' "$suite" "$index_path" >&2
      exit 1
    fi

    fetch "$root/${index_path%/*}/by-hash/SHA256/$hash" -o "$tmp/Packages.xz"
    if ! printf '%s  %s\n' "$hash" "$tmp/Packages.xz" | sha256sum --check --status; then
      printf 'Debian index checksum mismatch for %s/%s.\n' "$suite" "$index_path" >&2
      exit 1
    fi

    xz -dc "$tmp/Packages.xz" |
      awk -v wanted_source="$source_package" -v wanted_version="$source_version" \
          -v target_arch="$target_arch" -v suite="$suite" '
        BEGIN { RS = ""; FS = "\n"; OFS = "\t" }
        {
          package = version = arch = source = ""
          for (i = 1; i <= NF; i++) {
            if ($i ~ /^Package: /)      package = substr($i, 10)
            if ($i ~ /^Version: /)      version = substr($i, 10)
            if ($i ~ /^Architecture: /) arch = substr($i, 15)
            if ($i ~ /^Source: /)       source = substr($i, 9)
          }

          count = split(source, fields, /[[:space:]]+/)
          source_name = source == "" ? package : fields[1]
          source_version = count > 1 ? fields[2] : version
          gsub(/[()]/, "", source_version)

          if (version != "" && source_name == wanted_source &&
              source_version == wanted_version &&
              (arch == target_arch || arch == "all"))
            print package, arch, version, suite
        }
      ' >> "$matches"
  done
done

if [[ ! -s "$matches" ]]; then
  printf 'No Debian binaries found for %s %s (%s).\n' \
    "$source_package" "$source_version" "$target_arch" >&2
  exit 1
fi

LC_ALL=C sort -u "$matches"
