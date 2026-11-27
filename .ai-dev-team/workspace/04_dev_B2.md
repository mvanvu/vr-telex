# B2 — README install line to the pipe form

Files: README.md (line 24 now `wget -qO- …/vr-telex-install.sh | sh`, plus a sentence on reading the script first via `wget -qO vr-telex-install.sh <url>` and `sh vr-telex-install.sh`), packaging/get/vr-telex-install.sh (header usage comment only), tests/get/run.sh (README assertion only). packaging/get/RELEASING.md had no old line.

Red: after the README edit only, `bash tests/get/run.sh` ended `FAIL: 1 check(s) failed`.
Green: after the assertion edit, `bash tests/get/run.sh` ended `PASS`.

## Rule compliance
| Rule | Status |
|---|---|
| BASE-11 | pass |
| BASE-24 | pass |
| COST | pass |
