
## QC T2 — QC_PASS
Tested tree: HEAD a2777e1 plus the untracked T2 files (Cargo workspace, crates/telex-core). Engines: cargo/rustc 1.100.0 only (no browser needed).
Probe: `.ai-dev-team/workspace/qa-artifacts/T2-qc/probe/examples/probe.rs` (outside the repo crates, own target dir), logs `probe.log`, `probe2.log`, `build_locked.log`.

### AC-1 probe: 40 own cases (`<` = pop/BackSpace)
First run: 31 OK, 9 DIFF. All 9 DIFFs were errors in my expectations (typos in keys, or tone position), not engine defects; the engine output matched the spec D13 (modern placement hoà/thuý) every time. Corrected cases re-run: 40/40 consistent.
| Keys | Expected | Actual |
|---|---|---|
| Tieesng Vieejt cos daaus | Tiếng Việt có dấu | same |
| nguwowfi ddepj | người đẹp | same |
| khuyru tay | khuỷu tay | same |
| Quoocs nguwx | Quốc ngữ | same |
| giawjt giux | giặt giũ | same (first typed with an extra x = undo, engine gave "giux": correct) |
| DDUWOWNGF | ĐƯỜNG | same |
| DDuwowfng | Đường | same |
| Vieetj Nam | Việt Nam | same |
| tooi yeeu ban | tôi yêu ban | same |
| hoaf / hoafn / hoaj nooij | hoà / hoàn / hoạ nội | same (D13 second vowel) |
| thuys / quys / gias | thuý / quý / giá | same |
| tuoori / tuowir / muoons | tuổi / tưởi / muốn | same |
| Nguyeenx / xin chaof / camr own | Nguyễn / xin chào / cảm ơn | same |
| hocj sinh / traamf | học sinh / trầm | same |
| class / windows / github / https://x.vn / Windows class / GitHub / HTTPS | unchanged | same |
| vieets<j | việt | same (pop in the middle then re-tone) |
| vieet<s / tuaan<s / toans< / hoaf<s | viế / tuấ / toan / hoá | same |
| Tieesng<g Vieejt | Tiếng Việt | same |
| aaa / ddd | aa / dd | same (undo by repeat) |
| QUOOCS / DDaats nuwowcs | QUỐC / Đất nước | same |
Mixed case covered (Tiếng, ĐƯỜNG, Đường, QUỐC, GitHub, HTTPS). The golden test (31562 lines in the file) was not re-run by me; the developer's output is in 04_dev_T2.md.

## Rule check T2
| Rule | Result | Evidence |
|---|---|---|
| AC-1 | pass | 40 own cases above, 0 engine defects; golden file present with 31562 lines |
| TOOL-1 | pass | rustc 1.100.0, cargo 1.100.0, rust-toolchain.toml (stable + rustfmt, clippy), rust-version 1.100 in all 6 crates |
| TOOL-3 | pass | Cargo.lock present at repo root, not git-ignored; `cargo metadata` lists 6 members, edition 2024 |
| SEC-25 | pass | `cargo build --locked --workspace` finished OK (build_locked.log), Cargo.lock unchanged |
| SEC-26 | not checked here beyond build; deny.toml present, cargo-deny not run (not in my brief) | n-o |
| SEC-27 | pass | `#![forbid(unsafe_code)]` in all 6 crate roots (ime-core, telex-core, vr-talex main.rs, fe-fcitx, fe-xim, fe-ibus) plus workspace lint unsafe_code=forbid |
