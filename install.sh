#!/usr/bin/env bash
# Install vr-telex for the current user (spec B7, decisions D1, D11, D20).
#
# User-level only: builds from this checkout, writes under $HOME, uses
# systemctl --user and gsettings. Safe to run again: a second run changes no
# file; it only restarts the daemon so the running shell selects Vietnamese
# (Telex) again (D33). If the daemon does not come up healthy, every change
# is rolled back, input sources included (SEC-19).
#
# An install under the old name vr-talex (D37) is moved to vr-telex: its
# backup becomes the vr-telex backup (so uninstall still restores the setup
# from before vr-talex), its input source is renamed in place, and its own
# files go once the new daemon is healthy. If it is not, the vr-talex
# install is put back and started again (restore_legacy).
#
# Test seams: VR_TELEX_BIN (use this binary instead of building),
# VR_TELEX_TIMEOUT (seconds to wait for fcitx5 / the daemon),
# VR_TELEX_OS_RELEASE (os-release file to check).
set -euo pipefail
umask 022

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# The logic is shared with the packaged vr-telex-setup.
# shellcheck source=packaging/common.sh
. "$REPO/packaging/common.sh"
use_checkout "$REPO"

trap on_exit EXIT
install_main "$@"
