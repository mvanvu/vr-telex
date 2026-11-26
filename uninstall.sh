#!/usr/bin/env bash
# Remove vr-telex for the current user and restore what install.sh saved
# (spec B8, AC-6): input sources, ~/.xinputrc and the other changed files,
# and fcitx5 when it ran before. Files that did not exist before install
# are removed; nothing else is touched. An install under the old name
# vr-talex (D37) is removed the same way, from the backup it saved.
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

# Same for a file written from a template by either the vr-telex or the
# vr-talex installer; returns 0 when it was removed.
remove_template_copy() {
  local name=$1 dst=$2
  if cmp -s -- "$REPO/packaging/$name" "$dst" || cmp -s -- <(legacy_template "$name") "$dst"; then
    rm -f -- "$dst"
    return 0
  fi
  if exists "$dst"; then warn "$dst was changed after install; left in place"; fi
  return 1
}

# No backup (deleted by hand): remove only what is certainly ours.
remove_without_backup() {
  warn "no backup found in $BACKUP_DIR; removing vr-telex files only"
  # The activation shadow goes, and the bus drops it, before the unit stops,
  # so a client call in between cannot start vr-telex again (see restore_all).
  if cmp -s -- <(render_dbus_svc) "$DBUS_SVC_DST" || cmp -s -- <(legacy_render_dbus_svc) "$DBUS_SVC_DST"; then
    rm -f -- "$DBUS_SVC_DST"
  fi
  reload_bus
  systemctl --user disable --now "$UNIT" >/dev/null 2>&1 || true
  legacy_stop_unit || warn "could not stop $LEGACY_UNIT"
  rm -f -- "$BIN_DST"
  remove_if_ours "$REPO/packaging/vr-telex.service" "$UNIT_DST"
  remove_if_ours "$REPO/packaging/90-vr-telex.conf" "$ENV_DST"
  remove_template_copy org.fcitx.Fcitx5.desktop "$AUTOSTART_DST" || true
  if remove_template_copy xinputrc "$XINPUTRC"; then
    warn "removed ~/.xinputrc; run 'im-config' to choose an input method framework again"
  fi
  rm -f -- "$DAEMON_STATE_DIR/mode"
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  reload_bus
  warn "input sources were not changed; remove 'Vietnamese (Telex)' in Settings > Keyboard if it is listed"
}

main() {
  local drop_legacy=0
  require_user
  init_paths
  need_commands gdbus gsettings systemctl timeout tail
  # vr-talex saved the setup before it; restore from a vr-telex copy of it.
  if [ ! -f "$MANIFEST" ] && [ -f "$LEGACY_MANIFEST" ] && [ ! -L "$LEGACY_MANIFEST" ]; then
    say "found an install under the old name vr-talex"
    legacy_copy_backup
    legacy_rename_sources || die "could not rename the vr-talex input source"
  fi
  if [ -f "$FROM_LEGACY" ]; then drop_legacy=1; fi
  if [ ! -f "$MANIFEST" ]; then
    if [ -e "$UNIT_DST" ] || [ -e "$BIN_DST" ] || legacy_found; then
      remove_without_backup
      legacy_cleanup 0
      say "removed"
    else
      say "vr-telex is not installed; nothing to do"
    fi
    return 0
  fi
  if ! restore_all; then
    die "uninstall is incomplete; the files listed above were left as they are"
  fi
  if legacy_found || legacy_source_listed; then
    legacy_cleanup "$drop_legacy"
    remove_created_dirs
  fi
  say "removed; the previous input method setup is restored"
}

main "$@"
