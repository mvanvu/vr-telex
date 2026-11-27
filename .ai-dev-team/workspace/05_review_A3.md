# Review A3 — Debian package via cargo-deb

Tools: Bash, Read, Write, Skill, SendMessage, SubagentHandback. No build or suite run (qc does); shellcheck run on tests/deb/run.sh and the three maintainer scripts: clean.

## Files read
- crates/vr-telex/Cargo.toml (diff): read
- packaging/deb/postinst, prerm, postrm, copyright, vr-telex.service: read (unit diffed against packaging/vr-telex.service: only ExecStart differs)
- tests/deb/run.sh: read
- Ignored per brief: install.sh, uninstall.sh, packaging/common.sh, tests/install/**

## Findings
No blocker or major.

[minor] tests/deb/run.sh:26,87 — setup-script content is unchecked until A2 lands
Scenario: while packaging/vr-telex-setup is missing the run ends "PASS with placeholders" and skips the content compare of usr/bin/vr-telex-setup; a plain run (no STRICT) is green without it.
Fix: A4/CI must run with VR_TELEX_DEB_STRICT=1 (already supported); qc re-runs A3's test after A2 so the plain "PASS" is seen. No code change needed.

[minor] packaging/deb/copyright — SCOWL stanza refers to THIRD-PARTY-NOTICES.md instead of embedding the licence text
Scenario: lintian may flag a license stanza with no text. Content is shipped in /usr/share/doc/vr-telex/, which the spec (AC-4: "MIT + THIRD-PARTY-NOTICES") accepts.
Fix: optional; none required.

## BASE-11 judgment
Only the row's files changed, plus the one `[package] description` line in crates/vr-telex/Cargo.toml. Acceptable: cargo-deb takes the Description summary only from `[package] description`, AC-4 requires a Description, the line has no build effect. Declared in the notes.

## Rule check A3
| Rule | Result | Evidence |
|---|---|---|
| AC-4 tool: cargo-deb builds vr-telex_<ver>_amd64.deb | pass | `[package.metadata.deb]`, revision 1, name vr-telex; test checks file name |
| AC-4 files: /usr/bin/vr-telex, /usr/bin/vr-telex-setup, user unit, /usr/share/vr-telex/*, docs + copyright | pass | assets list; exact `dpkg-deb -c` list with modes/owners in run.sh:160-178 |
| AC-4 copyright MIT + THIRD-PARTY-NOTICES | pass | DEP-5 file, MIT text matches LICENSE (run.sh has_mit_text), notices shipped and referenced |
| AC-4 Depends (libc, systemd, dbus) | pass | `$auto, systemd, dbus-user-session, libglib2.0-bin`; libglib2.0-bin justified by gsettings/gdbus use |
| AC-4 Description | pass | summary + extended text via description line and extended-description |
| AC-4 Maintainer without personal email | pass | project URL, test asserts no `@` |
| AC-4 version from Cargo | pass | workspace version via cargo-deb, test compares |
| AC-4 postinst does not touch user sessions | pass | postinst only echoes; run under env -i with stubbed session tools, none called, HOME untouched |
| AC-4 prerm/postrm tell users `vr-telex-setup --remove` | pass | prerm remove and postrm purge print it; upgrades silent (tested) |
| AC-4 test of contents and control fields | pass | tests/deb/run.sh uses dpkg-deb -c / -f / -e; mutation evidence in notes |
| Plan Fixed paths | pass | all five path groups match; unit ExecStart=/usr/bin/vr-telex, no drift from source unit |
| BASE-11 | pass | see judgment above |
| Maintainer scripts never touch user sessions | pass | no systemctl/gsettings/su/loginctl/etc.; set -e, exit 0 |
| Developer evidence / Rule compliance section | pass | present, outputs trimmed with log paths |

APPROVED. Pending: after A2 writes packaging/vr-telex-setup, run the test once to see plain PASS (strict).

REVIEW_PASS
