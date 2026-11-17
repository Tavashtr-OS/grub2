#!/bin/sh
set -eu

# Run from the Debian source package root, outside debian folder
# Run this to add the latest commit's message directly to debian/changelog

subject=$(git log -1 --format=%s)
if [ -z "$subject" ]; then
  printf '%s\n' 'dch-last: the latest commit has an empty subject' >&2
  exit 1
fi

changelog=debian/changelog
distribution=$(dpkg-parsechangelog --file "$changelog" --show-field Distribution)

if [ "$distribution" = UNRELEASED ]; then
  exec dch --changelog "$changelog" --append -- "$subject"
fi

exec dch --changelog "$changelog" --local +tavashtr --distribution UNRELEASED -- "$subject"
