#!/usr/bin/env bash
# Remove vr-telex for the current user and restore what install.sh saved
# (spec B8, AC-6): input sources, ~/.xinputrc and the other changed files,
# and fcitx5 when it ran before. Files that did not exist before install
# are removed; nothing else is touched. An install under the old name
# vr-talex (D37) is removed the same way, from the backup it saved.
set -euo pipefail
umask 022

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# The logic is shared with the packaged vr-telex-setup --remove.
# shellcheck source=packaging/common.sh
. "$REPO/packaging/common.sh"
use_checkout "$REPO"

uninstall_main "$@"
