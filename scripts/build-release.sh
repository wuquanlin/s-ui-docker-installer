#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if ! git diff --quiet || ! git diff --cached --quiet; then
  printf 'Working tree must be clean before building a release.\n' >&2
  exit 1
fi

version="${1:-$(git describe --tags --always)}"
name="s-ui-docker-installer-${version}"
mkdir -p dist
git archive --format=tar.gz --prefix="${name}/" \
  -o "dist/${name}.tar.gz" HEAD
git archive --format=zip --prefix="${name}/" \
  -o "dist/${name}.zip" HEAD
(
  cd dist
  sha256sum "${name}.tar.gz" "${name}.zip" >"${name}.sha256"
)
printf 'Built dist/%s.{tar.gz,zip,sha256}\n' "$name"
