#!/usr/bin/env bash
set -Eeuo pipefail

release_json="$(curl -fsSL --connect-timeout 5 --max-time 15 \
  https://api.github.com/repos/alireza0/s-ui/releases/latest)"
tag="$(printf '%s' "$release_json" | jq -r '.tag_name')"
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  printf 'Invalid upstream release tag: %s\n' "$tag" >&2
  exit 1
}

code="$(curl -fsSL -o /dev/null -w '%{http_code}' \
  "https://hub.docker.com/v2/repositories/alireza7/s-ui/tags/${tag}")"
[[ "$code" == "200" ]] || {
  printf 'Docker Hub tag is unavailable: %s (HTTP %s)\n' "$tag" "$code" >&2
  exit 1
}
printf 'Official S-UI release and Docker tag: %s\n' "$tag"
