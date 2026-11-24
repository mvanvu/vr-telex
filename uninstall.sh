#!/usr/bin/env bash
# Remove vr-talex for the current user and restore what install.sh saved
# (spec B8, AC-6): input sources, ~/.xinputrc and the other changed files,
# and fcitx5 when it ran before. Files that did not exist before install
# are removed; nothing else is touched.
set -euo pipefail
umask 022

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=packaging/common.sh
. "$REPO/packaging/common.sh"

# Remove dst only when it is still the file install wrote; a version the
# user changed stays, with a warning naming it.
remove_if_ours() {
  if cmp -s -- "$1" "$2"; then
    rm -f -- "$2"
  elif exists "$2"; then
    warn "$2 was changed after install; left in place"
  fi
}

# No backup (deleted by hand): remove only what is certainly ours.
remove_without_backup() {
  warn "no backup found in $BACKUP_DIR; removing vr-talex files only"
  # The activation shadow goes, and the bus drops it, before the unit stops,
  # so a client call in between cannot start vr-talex again (see restore_all).
  if cmp -s -- <(render_dbus_svc) "$DBUS_SVC_DST"; then rm -f -- "$DBUS_SVC_DST"; fi
  reload_bus
  systemctl --user disable --now "$UNIT" >/dev/null 2>&1 || true
  rm -f -- "$BIN_DST"
  remove_if_ours "$REPO/packaging/vr-talex.service" "$UNIT_DST"
  remove_if_ours "$REPO/packaging/90-vr-talex.conf" "$ENV_DST"
  remove_if_ours "$REPO/packaging/org.fcitx.Fcitx5.desktop" "$AUTOSTART_DST"
  if cmp -s -- "$REPO/packaging/xinputrc" "$XINPUTRC"; then
    rm -f -- "$XINPUTRC"
    warn "removed ~/.xinputrc; run 'im-config' to choose an input method framework again"
  fi
  rm -f -- "$DAEMON_STATE_DIR/mode"
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  reload_bus
  warn "input sources were not changed; remove 'Vietnamese (Telex)' in Settings > Keyboard if it is listed"
}

main() {
  require_user
  init_paths
  need_commands gdbus gsettings systemctl timeout tail
  if [ ! -f "$MANIFEST" ]; then
    if [ -e "$UNIT_DST" ] || [ -e "$BIN_DST" ]; then
      remove_without_backup
      say "removed"
    else
      say "vr-talex is not installed; nothing to do"
    fi
    return 0
  fi
  if ! restore_all; then
    die "uninstall is incomplete; the files listed above were left as they are"
  fi
  say "removed; the previous input method setup is restored"
}

main "$@"
