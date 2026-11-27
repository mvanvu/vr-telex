# A3 Debian package via cargo-deb: metadata, maintainer scripts, contents/control test

Tools available: Bash, Read, Edit, Write, Skill, Agent (unused, BASE-18), Artifact, ToolSearch, SubagentHandback; cargo-deb 3.8.0, dpkg-deb, dpkg-shlibdeps, shellcheck.

## Progress
- read: spec AC-4, plan Fixed paths, capabilities.md, packaging/, install.sh tool usage (gsettings/gdbus -> libglib2.0-bin)
- code: crates/vr-telex/Cargo.toml [package.metadata.deb], packaging/deb/{vr-telex.service,copyright,postinst,prerm,postrm}, tests/deb/run.sh written; shellcheck clean
- red: tests/deb/run.sh run 1 -> 6 FAIL (no Description summary, cargo-deb generated its own copyright over ours, owners print as 0/0) — qa-artifacts/A3/run1.log
- code: license-file = packaging/deb/copyright (used verbatim, DEP-5), [package] description, owners 0/0, "no cargo-deb warnings" check
- green: run 4 -> PASS with placeholders (qa-artifacts/A3/run4.log); normal path + mutation run on a temp copy (qa-artifacts/A3/normal.log, mutation.log); strict mode refuses placeholders
- guard: cargo fmt --check && clippy -D warnings -> rc 0

## Summary
- Files changed:
  - crates/vr-telex/Cargo.toml — new `[package.metadata.deb]`; plus one line `description = ...` in `[package]` (see Deviations)
  - packaging/deb/vr-telex.service — packaged user unit: packaging/vr-telex.service with `ExecStart=/usr/bin/vr-telex` (the test enforces "identical except ExecStart")
  - packaging/deb/copyright — DEP-5: Files: * MIT (full text of LICENSE), note on statically linked crates' licenses, Files: crates/telex-core/data/en*.txt SCOWL -> /usr/share/doc/vr-telex/THIRD-PARTY-NOTICES.md
  - packaging/deb/postinst, prerm, postrm — print-only, `exit 0`; postinst (configure) points to `vr-telex-setup`; prerm (remove) and postrm (purge) tell users to run `vr-telex-setup --remove` (reinstall first if already gone); upgrades print nothing; no user-session tool is called
  - tests/deb/run.sh — builds with cargo-deb (or takes a .deb argument) and checks `dpkg-deb -f` fields, `dpkg-deb -c` exact file/mode/owner list, extracted contents vs repo sources, unit ExecStart + drift, copyright, maintainer scripts (shellcheck, run under env -i with every dpkg action, stubbed systemctl/gsettings/su/... must never be called, HOME untouched), no cargo-deb warnings
  - .ai-dev-team/capabilities.md — one line
- Package (cargo-deb 3.8.0): vr-telex_0.1.0-1_amd64.deb; Version = workspace version + revision 1; Depends: dbus-user-session, libc6 (>= 2.34), libglib2.0-bin, systemd ($auto via dpkg-shlibdeps; libglib2.0-bin because the setup uses gsettings/gdbus); Maintainer: `vr-telex project <https://github.com/mvanvu/vr-telex>`; Section utils, Priority optional.
- Contents: /usr/bin/vr-telex (755), /usr/bin/vr-telex-setup (755), /usr/lib/systemd/user/vr-telex.service, /usr/share/vr-telex/{common.sh, 90-vr-telex.conf, xinputrc, org.fcitx.Fcitx5.desktop, org.fcitx.Fcitx5.service}, /usr/share/doc/vr-telex/{README.md, THIRD-PARTY-NOTICES.md, copyright}.

## What the package expects from A2
- `packaging/vr-telex-setup` (new, missing today) -> /usr/bin/vr-telex-setup; the package sets mode 755 whatever the source mode.
- Shared files are taken as they are in packaging/: common.sh, 90-vr-telex.conf, xinputrc, org.fcitx.Fcitx5.desktop, org.fcitx.Fcitx5.service -> /usr/share/vr-telex/. org.fcitx.Fcitx5.service holds `Exec=@BIN@`, so the setup must substitute it as install.sh does.
- If A2 needs any further file under /usr/share/vr-telex/ (e.g. split install/uninstall logic), both the `assets` list in crates/vr-telex/Cargo.toml and `SHARE_FILES` in tests/deb/run.sh must gain it (A3 files) — the exact file list check fails otherwise.
- Until packaging/vr-telex-setup exists, tests/deb/run.sh builds from a temp copy with a placeholder setup script, prints a PLACEHOLDER banner, skips the setup content compare and ends with `PASS with placeholders (missing A2 sources: packaging/vr-telex-setup)`. `VR_TELEX_DEB_STRICT=1` (CI / A4) makes that an error. With the file present it builds with `cargo deb -p vr-telex --locked` in the repo and ends with `PASS`.

## Commands run (trimmed)
```
$ $TEAM_BIN/run-heavy.sh bash tests/deb/run.sh            # run 1 (red), qa-artifacts/A3/run1.log
FAIL  Description summary names the input method
FAIL  dpkg-deb -c differs ... (owners 0/0)
FAIL  usr/share/doc/vr-telex/copyright matches packaging/deb/copyright
FAIL  copyright carries the full MIT text of LICENSE
FAIL: 6 check(s) failed
$ $TEAM_BIN/run-heavy.sh bash tests/deb/run.sh            # run 4 (final), qa-artifacts/A3/run4.log
PLACEHOLDER: missing A2 sources: packaging/vr-telex-setup
ok    cargo deb printed no warnings
ok    file name is vr-telex_0.1.0-1_amd64.deb
ok    Version: 0.1.0-1 (workspace version 0.1.0)
ok    Maintainer is the project URL
ok    Maintainer has no e-mail address
      Depends: dbus-user-session, libc6 (>= 2.34), libglib2.0-bin, systemd
ok    dpkg-deb -c: exactly the expected files, modes and owners (0/0 = root)
skip  usr/bin/vr-telex-setup matches packaging/vr-telex-setup (PLACEHOLDER: A2 has not written it yet)
ok    packaged unit runs ExecStart=/usr/bin/vr-telex
ok    packaged unit equals packaging/vr-telex.service except ExecStart
ok    prerm remove tells users to run vr-telex-setup --remove
ok    postrm purge tells users to run vr-telex-setup --remove
ok    maintainer scripts call no session tool (systemctl, gsettings, su, ...)
ok    maintainer scripts leave HOME untouched
PASS with placeholders (missing A2 sources: packaging/vr-telex-setup)      (58 ok, 1 skip, rc 0)
$ VR_TELEX_DEB_STRICT=1 bash tests/deb/run.sh
error: VR_TELEX_DEB_STRICT=1 and A2 sources are missing            rc=1
# normal path, temp copy of the sources with a stand-in packaging/vr-telex-setup (qa-artifacts/A3/normal.log):
building: cargo deb -p vr-telex (repo sources) ... PASS            rc=0
# mutation on that copy: prerm message removed, old ExecStart, setup asset mode 644 (qa-artifacts/A3/mutation.log):
FAIL  dpkg-deb -c differs ... +-rw-r--r-- 0/0 ./usr/bin/vr-telex-setup
FAIL  packaged unit runs ExecStart=/usr/bin/vr-telex
FAIL  prerm remove tells users to run vr-telex-setup --remove
FAIL: 3 check(s) failed                                             rc=1
$ shellcheck tests/deb/run.sh packaging/deb/postinst packaging/deb/prerm packaging/deb/postrm
(no output)
$ cargo fmt --check && $TEAM_BIN/run-heavy.sh cargo clippy --workspace --all-targets --locked -- -D warnings
    Finished `dev` profile [unoptimized + debuginfo] target(s) in 0.05s      guard rc=0
```

## Deviations from the plan
- `description = "Vietnamese Telex input method for GNOME (IBus and fcitx5 protocols)"` added to `[package]` of crates/vr-telex/Cargo.toml (outside `[package.metadata.deb]`): cargo-deb 3.8.0 takes the Description summary only from `[package] description` (its src/config.rs:1016), and AC-4 requires a Description. One line, no build effect.
- Copyright via `license-file` (used verbatim because it is a DEP-5 file) instead of a plain asset: cargo-deb always generates a copyright and the generated one wins over an asset with the same target (seen in run 1).
- Version is `0.1.0-1` (cargo-deb revision 1), file `vr-telex_0.1.0-1_amd64.deb`; A4 should glob `vr-telex_*_amd64.deb`.
- No Homepage control field: it would need `homepage`/`repository` in `[package]`; AC-4 does not require it.

## Out-of-scope issues noticed
- cargo-deb leaves `target/vr-telex/vr-telex.stripped-0.tmp` when built from the temp copy; removed (ignored dir, created by this task).
- `tests/install/run.sh` shows as modified in git status — not mine (A1/A2 area).

## Reuse
| Needed | Looked in | Result |
|---|---|---|
| packaged unit | capabilities.md, packaging/vr-telex.service | copied with ExecStart changed; the test guards drift against the source unit |
| sandbox/stub pattern for scripts | tests/install/run.sh (env -i + stubs) | same idea with small inline stubs (the install harness targets user sessions, too heavy here) |
| package test | capabilities.md, `ls tests` | none existed; new tests/deb/run.sh, indexed in capabilities.md |

## Rule compliance
| Rule | Status | Evidence |
|---|---|---|
| AC-4 | pass | tests/deb/run.sh run 4: contents, Depends, Description, Maintainer (URL, no @), version from Cargo, postinst touches nothing, prerm/postrm print `vr-telex-setup --remove`, `dpkg-deb -c/-f` checks; setup content compare pending A2 (placeholder) |
| BASE-1 | pass | diff: crates/vr-telex/Cargo.toml, packaging/deb/**, tests/deb/**, capabilities.md line; the one `[package] description` line is under Deviations |
| BASE-2 | pass | asset targets = plan Fixed paths exactly |
| BASE-3 | pass | run 1 red (6 FAIL) before the fixes; mutation run shows the checks fail on broken packaging |
| BASE-4 | pass | trimmed outputs above; full logs qa-artifacts/A3/run{1..4}.log, normal.log, mutation.log |
| BASE-5 | pass | test and clippy through run-heavy.sh; nothing left running |
| BASE-6 | pass | English; comments say why (unit drift, cargo-deb warnings, print-only scripts) |
| BASE-9 | pass | root maintainer scripts only print; no secrets; the test runs them under env -i with stubbed session tools |
| BASE-10 | pass | only tests/deb/run.sh and the guard ran |
| BASE-11 | pass | no history-rewriting or file-moving git command used |
| BASE-14 | pass | each run finished in the foreground under run-heavy (< 2 min) |
| BASE-15 | pass | no background process started |
| BASE-16 | pass | Reuse table; capabilities.md updated |
| BASE-17 | pass | pre-installed cargo-deb used; nothing installed |
| BASE-18 | pass | no agents started |
| BASE-19 | pass | notes created first, progress lines above |
| BASE-23 | pass | both build paths run (placeholder copy; repo `cargo deb -p` path on a copy); given-.deb mode shares the same checks |
| BASE-24 | pass | no git index/history command |
| BASE-25 | pass | guard output above, rc 0 |
| BASE-38 | pass | shellcheck only on my shell files; cargo fmt only --check |
| BASE-45 | pass | AC-4 text unchanged in 01_spec.md |
| BASE-46 | pass | run 4 / normal / mutation ran after the last change to packaging and the test |
| COST-1 | pass | heavy runs via run-heavy.sh |
| COST-3 | pass | no sleep/poll |
| COST-8 | pass | batched edits; perl -pi for bulk edits, no python heredocs |
| COST-9 | pass | nothing left running; temp dirs removed |
| COST-13 | pass | logs in $TEAM_WS/qa-artifacts/A3/; temp copies in mktemp dirs, removed |
| COST-16 | pass | full logs in qa-artifacts/A3, trimmed output in context |

n-a: BASE-7 (no commit) · BASE-8 (no new dependency; cargo-deb is a pre-installed tool) · BASE-12, BASE-29, BASE-40, BASE-41 (no outside system) · BASE-13 (deleted only temp dirs this task created) · BASE-20 (nothing removed) · BASE-21 (no secrets) · BASE-22 (env names follow VR_TELEX_* neighbours: VR_TELEX_DEB_STRICT, VR_TELEX_DEB_KEEP) · BASE-26, BASE-28, BASE-39, BASE-43, BASE-44, BASE-47 (no rewrite, third-party code, schema, access rule, fake or computed value) · BASE-27, BASE-30, BASE-31 (no shared data, no containers) · BASE-32 (D1-D3 kept: amd64, name vr-telex) · BASE-33, BASE-48 (no claim about real-machine state; nothing installed on the machine) · BASE-34 (no blocked step) · BASE-35 (no user-rules lines for packaging) · BASE-36 (app scope unchanged) · BASE-37 (not a runtime defect) · BASE-42 (no test settings) · COST-2, COST-4, COST-5, COST-6, COST-7, COST-10, COST-11, COST-12, COST-14, COST-15, COST-17, COST-18, COST-19, COST-20 (no browser, e2e, goldens, CI or full suite; no other test file names the changed files: grep for "metadata.deb" / "packaging/deb" under tests/ and crates/ finds only tests/deb/run.sh and the crate manifest)

DONE
