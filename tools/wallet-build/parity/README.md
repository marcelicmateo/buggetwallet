# wallet-build parity tests

Own Go module (`wallet-build/parity`, standard library only), build tag `parity`. Each case runs the same
`tools/build.sh <args>` (GO2 cases: `tools/emulator.sh` or `tools/live.sh`, the `Script` field of a case) twice, never at the same time: once with `BW_IMPL=bash`, once with `BW_IMPL=$BW_PARITY_IMPL`
(default `go`), each with its own temp `BW_DATA_DIR`. Run from the host:

    cd tools/wallet-build/parity
    GOTOOLCHAIN=local go test -tags parity -timeout 60m -v -run 'Parity/lint_clean'      # one case
    GOTOOLCHAIN=local go test -tags parity -timeout 60m -v -run 'Parity'                 # cheap cases
    BW_PARITY_HEAVY=1 GOTOOLCHAIN=local go test -tags parity -timeout 600m -v .          # everything
    BW_PARITY_IMPL=bash GOTOOLCHAIN=local go test -tags parity -run Parity .             # harness proof (bash vs bash)
    GOTOOLCHAIN=local go vet -tags parity ./...                                          # compile check only

Switches: `BW_PARITY_IMPL` (`go` default, `bash` = harness proof), `BW_PARITY_HEAVY=1` (heavy cases), `BW_PARITY_REPO`
(repo root; default: first parent with `tools/build.sh`), `BW_SIGNING_DIR` (for `apk`). All other `BW_*` variables of the
caller are removed from the child environment; a case sets its own (`BW_JOBS`, `BW_QUIET`, `BW_TIMEOUT_*`).
Needs Podman and the dev image, like `tools/build.sh` itself.

## Cases (`TestParity/<name>`)

Cheap: `lint_clean` (all 7 LINT steps), `lint_unformatted`, `quiet_lint_clean` (`-q`), `quiet_env_lint_unformatted`
(`BW_QUIET=1`), `quiet_unknown_command`, `quiet_long_flag_unknown_command`, `quiet_mutate_usage` (quiet cases: zero bytes
on stdout and stderr), `usage_unknown_command`, `usage_mutate_no_args`, `usage_mutate_one_arg`, `usage_relay_bin_bad_arch`
(exit 2, stdout and stderr compared, no run dir), `core_one_file`, `analyze_core`, `shell_c_exit_3`, `image_name`,
`forwarded_timeout_env_lint` (`BW_TIMEOUT_FORMAT=600 BW_STEP_TIMEOUT=600 lint`: a limit that never fires, compared in full; a firing limit is the Go-only `step_timeout` case), `relay_bin_x64` (+ `dist/relay` names), `lsp_initialize` (initialize/shutdown/exit round trip: capability names, server name, exit code).

Heavy (skipped unless `BW_PARITY_HEAVY=1`): `core`, `analyze_core_app`, `test`, `desktop_test_small`,
`desktop_test_jobs2_a_b_layout` (`BW_JOBS=2`), `linux`, `desktop_smoke`, `apk` (needs the local signing key; also greps the
whole data dir, stdout and stderr for the keystore password values), `web_test`, `stage`.

New behaviour, Go side only (`TestNewBehaviour/<name>`, skipped for `BW_PARITY_IMPL=bash`): `step_timeout`
(`BW_TIMEOUT_FORMAT=1 lint`: `format.status` exit 124, run exit 1, `timed out after 1 s` in the log, no leftover container),
`exit3_tool_does_not_build` (copy of `tools/` and `dev/` in a temp dir with a syntax error added; exit 3, a non-empty
`dist/*build*.log`, no run dir), `interrupted_desktop_test_leaves_no_container` (heavy: SIGINT mid-run, exit 130 or 143,
no container left, no `.running`).

## GO2: emulator and live (`emu_live_test.go`)

Entry script per case (`Case.Script`); a sequence case (`Case.Steps`) runs several invocations on one data dir, one side
after the other (never two containers at once), stops at the first non-zero exit, and runs `Cleanup` (a `stop`, with
`BW_IMPL=bash`) after each side. Per step the command, exit code, masked stdout and masked stderr are compared.

Cheap (skipped with the reason when podman is missing or a `bw-emulator` / `bw-live-<checkout>` container already runs, so
nothing of the owner's is observed or touched):
- usage: `emulator_usage_unknown_command`, `live_usage_unknown_command`, `live_usage_start_bad_flag`,
  `live_usage_start_headless_bad_flag` (exit 2, stdout and stderr compared, no run dir);
- quiet (emulator: zero bytes): `emulator_quiet_flag_unknown_command`, `..._long_flag_...`, `..._env_unknown_command`,
  `emulator_quiet_flag_stop`, `emulator_quiet_env_stop`, `emulator_quiet_flag_adb_not_running`. `live.sh` has no `-q` in bash:
  `live_quiet_flag_status_parity` (`-q status` is a usage error there) and `live_quiet_env_status_parity` only compare the
  two implementations, no zero-byte assertion;
- nothing running: `emulator_stop|adb|shot|install_not_running` (+ `shot` without a name), `live_status|stop|reload|restart|
  shot|trace_start|trace_stop_not_running`, `live_no_args_is_status` (exit codes, "not running", "Start one with" lines, no run dir);
- `live_pod`: prints the checkout's pod name; the pod it created is removed after each side (skipped when the pod already
  exists, the MCP server may use it).
- Not covered on purpose: `emulator.sh reset` (with nothing running it deletes the real `bw-emulator*` volumes; "refused while
  running" would need a running emulator).

Heavy (`BW_PARITY_HEAVY=1`; emulator cases also skip when the volumes `bw-emulator` / `bw-emulator-image` are missing):
`emulator_screens`, `emulator_test_one_small_file` (history steps prepare, boot, build, install, test, total; run dir logs,
summary structure, screenshot names), `emulator_start_install_shot_stop` (needs `dist/BudgetWallet-android.apk`; also
`adb shell echo`), `live_headless_demo_session` (`start --headless --demo --fresh`, `reload`, `restart`, `shot`,
`trace start`, `trace stop t`, `status`, `stop`; run dir `flutter-run.jsonl`, `app-live.log`, `shot-*.png`, `trace-t.json`
(`traceEvents`, `displayTimeUnit`), `trace-t-summary.txt` structure; history `live-start`, `live-reload`, `live-restart`).
Heavy live cases are headless only (privacy: no window, no host X11 or Wayland). `dist/screens` (emulator screens) and
`dist/screens/live.png` are deleted before each side.

Extra masking for the sequences: `http(s)://` and `ws://` URIs, `127.0.0.1:PORT`, `NN KB`, `shot-HHMMSS.png`, the optional
`(main() to first frame: N ms)`, and every number in `timeline:` / `build` / `raster` trace lines and in
`trace-*-summary.txt`.

## What is compared (after masking)

Exit code; stdout (the step table; stderr too for usage cases); `runs/` directory list; per run dir the recursive file
name list, `last.status` (step + ok/failed as a set; each side must list its steps by the start instant of its own `.status` stamps, ties by name: stamps are whole seconds, so two runs need not share their ties), `last-failed.txt`, every `<step>.status` exit field, the first
and last line of each log that has a `.status`, `tests-*-summary.txt` and `stage-summary.txt` structure; artifact name
lists; history `steps.jsonl`, `tests.jsonl`, `perf.jsonl` (parsed: key order, compact vs `json.dumps` spacing, every
field except the masked ones; `seconds` must look like `12.0`). Screenshots: file names only, never images.

Masking: ISO timestamps, run ids and run dir names (`<TS>-<cmd>-<COMMIT>`), the temp data dir, the repo path, `/tmp/tmp.*`,
seconds (`12.3 s`, bare `12.3` columns, `last.status`/`.status` seconds fields), `NN ms`, the short commit (+ `-dirty`),
whitespace runs in tables. Histogram counts and the slowest-test rows are dropped from summaries (header, bucket labels,
row count kept). `tests.jsonl` lines are sorted (completion order), as are `steps.jsonl` lines in unordered cases.
The `pub` step (`pub.log`, `pub.status`, the `pub` rows) is ignored: it runs only when resolution is stale, which the first
run clears for the second.

A failure names the case, the file and the first differing line.

Also: `lint_clean` expects `go-check` (host step, first, ok or failed) plus the 7 LINT steps ok; a failed go-check is
tolerated in `last-failed.txt`. `perf.jsonl` `ok` is masked, but any `ok:false` with exit 0 fails. `BW_SIGNING_DIR` is passed
to the children so the build and the secret grep use the same key. `lint_unformatted` cleans up with `t.Cleanup`; `TestMain`
removes a leftover `app/lib/zz_*unformatted*.dart` of a killed run.
