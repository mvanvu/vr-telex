# tests/e2e — headless GNOME stress harness

End-to-end checks of vr-talex in real apps: AC-2 (stress typing), AC-3 (commit on focus change),
AC-4 (Ctrl+Shift toggle), AC-5/AC-6 (install / uninstall), AC-7 (password field), AC-10 (latency) and
SEC-1 (no typed text in any output). Keys go through Mutter's RemoteDesktop D-Bus API (D12), so they
take the real compositor path: Mutter → gnome-shell → IBus → the engine → the app.

## Isolation (D2, SEC-29)
Every run happens inside `dbus-run-session` with a throwaway `HOME`, `XDG_*` dirs and `XDG_RUNTIME_DIR`
under the run directory, keyfile GSettings, and a headless `gnome-shell --headless --wayland
--virtual-monitor 1280x800 --unsafe-mode`. `lib.sh: guard` aborts (exit 97) before any launch when
`HOME`, `XDG_RUNTIME_DIR` or `DBUS_SESSION_BUS_ADDRESS` still point at the live desktop. The live
desktop, its session bus, its fcitx5 and its input sources are never touched. Teardown stops exactly the
processes carrying the run's `VRT_E2E_TAG` environment value. The install scenario runs `install.sh` /
`uninstall.sh` with `systemctl` replaced by a sandbox stand-in (runs the unit's `ExecStart` itself) and
kill-by-name tools replaced by stand-ins that refuse and log.

## Requirements
Already present on Ubuntu 24.04 GNOME: `gnome-shell` 46, `gdbus`, `dbus-run-session`, `python3` (stdlib
only), `gnome-terminal`, `google-chrome`, `code` (VS Code), `journalctl`. Nothing is installed by the
harness. For `--ime daemon`: a built daemon (`cargo build --release`, or `VR_TALEX_BIN=/path`).

## Run
```
tests/e2e/run.sh --smoke                 # ~1.5 min: stub engine, gnome-terminal + Chrome, 60 words, AC-3/4/7
tests/e2e/run.sh                         # sign-off: daemon, all five targets, 5,000 words, 3 runs each
tests/e2e/run.sh --apps "code" --runs 1 --words 300      # one target, short corpus
```
Through the team's wrapper: `$TEAM_BIN/run-heavy.sh bash tests/e2e/run.sh --smoke`.

Options: `--ime stub|daemon|none`, `--apps "term chrome omnibox code code-term"`, `--runs N`,
`--words N`, `--seed N`, `--delay S` (default 0.015 s per key), `--scenarios "password toggle focus
install"`, `--skip-install`, `--route ibus|fcitx` (Ubuntu default env, or `GTK_IM_MODULE=fcitx` so
gnome-terminal takes the fcitx D-Bus route), `--out DIR` (default `target/e2e`), `--omnibox-chunk N`
(corpus lines per address-bar tab, default 40), `--allow-incomplete`.

Key pacing: keys go out on a fixed 15 ms schedule (the D-Bus call cost is absorbed, not added). Every
injection reports its measured mean ms/key; an AC-2 check fails when the mean is above the delay + 1 ms.

Run time: 15 ms per key plus a ~1 s session warm-up; the 5,000-word corpus is ~37,000 keys, so ~10 min
per target per run. Full sign-off (5 targets × 3 runs) ≈ 2 h 30 min, plus ~1 min of start-up and
scenarios. The omnibox target adds ~1.5 s per corpus line (~500 lines ≈ +12 min per run).

## Exit status and INCOMPLETE
Each check prints `RESULT <check> PASS|FAIL|SKIP|INCOMPLETE <detail>`. Any SKIP or INCOMPLETE also prints
a loud `INCOMPLETE: <checks>` line, and the run exits 1 unless `--allow-incomplete` is given (a FAIL
always exits 1). INCOMPLETE comes from: AC-10 with the daemon (D24, below), SEC-1 when a journal could
not be read, the install scenario without a built daemon, and scenarios that need an engine under
`--ime none`.

## Targets (AC-2)
| `--apps` name | App and field | Read back from |
|---|---|---|
| `term` | gnome-terminal running `cat > file` | the file |
| `chrome` | Chrome page textarea | DevTools protocol (`Runtime.evaluate`) on a throwaway profile |
| `omnibox` | Chrome address bar, one search per corpus line | navigation history (`q=` of each search), a new tab per 40 lines because Chrome caps a tab's history |
| `code` | VS Code editor, auto-save after 200 ms | the saved file |
| `code-term` | VS Code integrated terminal running `cat > file` (F9 opens it) | the file |

Chrome runs with its proxy pointed at a closed local port and every host name unresolvable, so the
omnibox searches never leave the machine.

## Corpus
`e2e.py corpus` draws a seeded sample from `crates/telex-core/tests/golden/telex_golden.tsv`: Vietnamese
words (typed in VI mode, expected = the golden output) mixed with the list's English/code words (typed
in EN mode, switched with a Ctrl+Shift tap before and after). 20 canary words with a per-run nonce are
typed too; with 20 distinctive Vietnamese words (composed and raw keys) they are the tokens of the
SEC-1 leak scan. Only the generator is stored; each run writes `out/corpus.json`, `expected.txt`,
`tokens.txt`.

## Engines
- `--ime daemon` — the real `target/release/vr-talex`, started with `RUST_LOG=trace` and its stderr captured.
- `--ime stub` — `stub_ime.py`, a stdlib IBus pseudo bus on a private socket that does word-level
  Telex by golden-list lookup, Ctrl+Shift toggle with the panel indicator, password passthrough and
  commit on FocusOut/Reset. It lets the harness be proven before the frontends exist; it is not the product.
- `--ime none` — no engine; the apps get raw keys (proves injection and readback alone).

## Output
`<out>/run-<stamp>/`: `out/results.txt` (one `RESULT` line per check), `out/diff-<target>-<run>.txt`
(first mismatches with line, column and context), the actual text per target and run, `logs/` (shell,
engine, apps), `sandbox/` (the throwaway home).

## Latency (AC-10)
D24: the daemon has no per-key timing interface. AC-10 is proven by the ime-core latency test and the
fe-ibus / fe-fcitx round-trip tests; with `--ime daemon` the run reports `AC-10 INCOMPLETE (measured in
unit tests)`, accepted only with `--allow-incomplete`. With the stub, `AC-10:stub` reports the stub's own
handling time from `out/latency.json` (proves the reporting path, not the product).

## Install scenario (AC-5 / AC-6)
Needs a built daemon (`$VR_TALEX_BIN` or `target/release/vr-talex`), passed to `install.sh` through T8's
`VR_TALEX_BIN` seam; the scenario never builds, and `CARGO_HOME`/`RUSTUP_HOME` point into the sandbox.
It asserts: install exits 0, the engine reaches the shell within 5 s of install returning, the sources
list holds vr-talex once, Vietnamese types in a new gnome-terminal and a newly started Chrome, a second
install changes no file; then uninstall restores the sources and (when present) fcitx5.

## Files
`run.sh` (entry), `lib.sh` (sandbox, guard, shell helpers, tagged cleanup), `e2e.py` (corpus, injection,
DevTools, diff, leak scan, toggle check, latency), `dbuslite.py` (stdlib D-Bus wire protocol),
`stub_ime.py`, `fake_systemd.py` (lets Xwayland start in the headless shell), `install_scenario.sh`.
