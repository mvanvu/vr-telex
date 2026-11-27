# Review FR-10: APPROVE (2 minor notes)
- Root cause supported: gtk3-wl.log 3897-3918 (end of injection: keyboard.leave, seat.capabilities(0), disable()+commit(), then commit_string("viêt") dropped); 4177-4193 Ctrl+Space and 4685-4700 window switch: commit_string before leave, kept. Experiment binary (probe-expcommit.log) still loses c1.
- crates/fe-ibus/src diff empty (checked).
- Protocol test pins ContentType/Cursor [], Reset [hide], FocusOut []; test-vs-expcommit.txt shows it fails on the rejected alternative. session.rs:804-808 rule matches.
- EVAL: goes through Connection.session() on DBUS_SESSION_BUS_ADDRESS, which lib.sh guard() forces to the sandbox bus; input is harness-built strings only. Shell Eval needs unsafe mode, only in the headless sandbox.
- focus-kept oracle: expected from golden_of, Chrome field must be empty, source asserted and restored.
Minor: (1) early `continue` paths after the gsettings set skip restoring `sources` (sandbox only). (2) EVAL failure only warns on stderr; the oracle still catches it.
