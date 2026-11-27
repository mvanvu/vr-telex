#!/usr/bin/env bash
# Copies the release public key into the install script: the lines from
# "-----BEGIN PGP PUBLIC KEY BLOCK-----" to "-----END PGP PUBLIC KEY BLOCK-----"
# in the script are replaced by the key file. Run it after the key changes
# (packaging/get/RELEASING.md); tests/get/run.sh runs it with --check.
#
# Usage: packaging/get/embed-key.sh [--check] [script] [key]
#   defaults: packaging/get/vr-telex-install.sh, packaging/apt/vr-telex.asc
#   --check   change nothing; exit 1 when the script holds another key
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
CHECK=0
if [ "${1:-}" = --check ]; then
  CHECK=1
  shift
fi
SCRIPT=${1:-$HERE/vr-telex-install.sh}
KEY=${2:-$HERE/../apt/vr-telex.asc}
BEGIN='-----BEGIN PGP PUBLIC KEY BLOCK-----'
END='-----END PGP PUBLIC KEY BLOCK-----'

die() {
  printf 'embed-key: error: %s\n' "$*" >&2
  exit 1
}
count() { grep -cxF -- "$1" "$2" || true; }

if [ "$(count "$BEGIN" "$KEY")" != 1 ] || [ "$(count "$END" "$KEY")" != 1 ]; then
  die "$KEY: expected one armored public key block"
fi
! grep -q 'PRIVATE KEY' "$KEY" || die "$KEY holds a private key"
if [ "$(count "$BEGIN" "$SCRIPT")" != 1 ] || [ "$(count "$END" "$SCRIPT")" != 1 ]; then
  die "$SCRIPT: expected one key block"
fi

NEW=$(mktemp)
trap 'rm -f -- "$NEW"' EXIT
awk -v keyfile="$KEY" -v begin="$BEGIN" -v end="$END" '
  $0 == begin { while ((getline line < keyfile) > 0) print line; skip = 1; next }
  skip && $0 == end { skip = 0; next }
  !skip { print }
' "$SCRIPT" >"$NEW"

if cmp -s "$NEW" "$SCRIPT"; then
  echo "embed-key: $SCRIPT holds $KEY"
  exit 0
fi
if [ "$CHECK" = 1 ]; then
  echo "embed-key: $SCRIPT does not hold $KEY; run packaging/get/embed-key.sh" >&2
  exit 1
fi
cat "$NEW" >"$SCRIPT" # keeps the script's mode
echo "embed-key: wrote $KEY into $SCRIPT"
