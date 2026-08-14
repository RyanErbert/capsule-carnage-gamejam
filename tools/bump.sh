#!/usr/bin/env bash
# Bump the build number. Run before committing, or let the pre-commit hook do it.
#   tools/bump.sh          -> 0.0.73 becomes 0.0.74
#   tools/bump.sh minor    -> 0.0.73 becomes 0.1.0
#   tools/bump.sh major    -> 0.0.73 becomes 1.0.0
set -e
cd "$(dirname "$0")/.."
maj=$(grep -o '"major": *[0-9]*' version.json | grep -o '[0-9]*')
min=$(grep -o '"minor": *[0-9]*' version.json | grep -o '[0-9]*')
bld=$(grep -o '"build": *[0-9]*' version.json | grep -o '[0-9]*')
case "${1:-build}" in
  major) maj=$((maj + 1)); min=0; bld=0 ;;
  minor) min=$((min + 1)); bld=0 ;;
  *)     bld=$((bld + 1)) ;;
esac
printf '{\n  "major": %d,\n  "minor": %d,\n  "build": %d\n}\n' "$maj" "$min" "$bld" > version.json
echo "v$maj.$min.$bld"
