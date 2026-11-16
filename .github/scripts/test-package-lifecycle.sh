#!/bin/bash
set -Eeuo pipefail

packages_dir=${1:?Usage: test-package-lifecycle.sh /absolute/path/to/build-artifacts}
shopt -s nullglob

declare -A files=() versions=()
declare -a packages=() debs=()
read -r -a selected <<< "${LIFECYCLE_PACKAGES:-}"

for deb in "$packages_dir"/*.deb; do
    package=$(dpkg-deb --field "$deb" Package)
    if [[ -n ${files[$package]+present} ]]; then
        printf 'Multiple build artifacts for %s.\n' "$package" >&2
        exit 1
    fi
    files[$package]=$deb
    if (( ${#selected[@]} == 0 )) && [[ "$package" != *-dbgsym ]]; then
        packages+=("$package")
    fi
done

if (( ${#selected[@]} > 0 )); then
    packages=("${selected[@]}")
fi
if (( ${#packages[@]} == 0 )); then
    echo 'No binary packages selected for lifecycle testing.' >&2
    exit 1
fi

for package in "${packages[@]}"; do
    deb=${files[$package]:?Missing build artifact for $package}
    debs+=("$deb")
    versions[$package]=$(dpkg-deb --field "$deb" Version)
done

export DEBIAN_FRONTEND=noninteractive
apt-get update

archive_packages=()
for package in "${packages[@]}"; do
    candidate=$(LC_ALL=C apt-cache policy "$package" | sed -n 's/^[[:space:]]*Candidate: //p')
    if [[ -n "$candidate" && "$candidate" != '(none)' ]]; then
        archive_packages+=("$package")
    fi
done
if (( ${#archive_packages[@]} > 0 )); then
    apt-get install --yes --no-install-recommends "${archive_packages[@]}"
fi

same_version_debs=()
for package in "${packages[@]}"; do
    previous_version=$(dpkg-query --show --showformat='${Version}' "$package" 2>/dev/null || true)
    printf '%s: Trixie %s -> workflow build %s\n' "$package" "${previous_version:-absent}" "${versions[$package]}"
    if [[ "$previous_version" == "${versions[$package]}" ]]; then
        same_version_debs+=("${files[$package]}")
    fi
done

# APT can pick the archive copy when versions match.
if (( ${#same_version_debs[@]} == ${#debs[@]} )); then
    dpkg --install "${debs[@]}"
else
    apt-get install --yes --no-install-recommends --allow-downgrades "${debs[@]}"
    if (( ${#same_version_debs[@]} > 0 )); then
        dpkg --install "${same_version_debs[@]}"
    fi
fi

for package in "${packages[@]}"; do
    installed=$(dpkg-query --show --showformat='${db:Status-Status} ${Version}' "$package")
    test "$installed" = "installed ${versions[$package]}"
done

verification=$(dpkg --verify "${packages[@]}")
if [[ -n "$verification" ]]; then
    printf '%s\n' "$verification" >&2
    exit 1
fi

apt-get remove --yes "${packages[@]}"
for package in "${packages[@]}"; do
    status=$(dpkg-query --show --showformat='${db:Status-Status}' "$package" 2>/dev/null || true)
    case "$status" in
        ''|not-installed|config-files) ;;
        *)
            printf '%s has status %s after removal.\n' "$package" "$status" >&2
            exit 1
            ;;
    esac
done

# New binaries can disappear from APT's view once removed.
dpkg --purge "${packages[@]}"
for package in "${packages[@]}"; do
    status=$(dpkg-query --show --showformat='${db:Status-Status}' "$package" 2>/dev/null || true)
    if [[ -n "$status" && "$status" != not-installed ]]; then
        printf '%s has status %s after purge.\n' "$package" "$status" >&2
        exit 1
    fi
done

echo 'Package lifecycle checks passed.'
