# wallet-build parity tests

Own Go module (`wallet-build/parity`, standard library only), build tag `parity`. Each case runs the same
`tools/build.sh <args>` twice, never at the same time: once with `BW_IMPL=bash`, once with `BW_IMPL=$BW_PARITY_IMPL`
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
`forwarded_timeout_env_lint` (`BW_TIMEOUT_FORMAT=1 lint`: proves the variable reaches the child in both; bash applies no timeout, so only run dir list, file names and step names are compared), `relay_bin_x64` (+ `dist/relay` names), `lsp_initialize` (initialize/shutdown/exit round trip: capability names, server name, exit code).

Heavy (skipped unless `BW_PARITY_HEAVY=1`): `core`, `analyze_core_app`, `test`, `desktop_test_small`,
`desktop_test_jobs2_a_b_layout` (`BW_JOBS=2`), `linux`, `desktop_smoke`, `apk` (needs the local signing key; also greps the
whole data dir, stdout and stderr for the keystore password values), `web_test`, `stage`.

New behaviour, Go side only (`TestNewBehaviour/<name>`, skipped for `BW_PARITY_IMPL=bash`): `step_timeout`
(`BW_TIMEOUT_FORMAT=1 lint`: `format.status` exit 124, run exit 1, `timed out after 1 s` in the log, no leftover container),
`exit3_tool_does_not_build` (copy of `tools/` and `dev/` in a temp dir with a syntax error added; exit 3, a non-empty
`dist/*build*.log`, no run dir), `interrupted_desktop_test_leaves_no_container` (heavy: SIGINT mid-run, exit 130 or 143,
no container left, no `.running`).

## What is compared (after masking)

Exit code; stdout (the step table; stderr too for usage cases); `runs/` directory list; per run dir the recursive file
name list, `last.status` (step + ok/failed, in order), `last-failed.txt`, every `<step>.status` exit field, the first
and last line of each log that has a `.status`, `tests-*-summary.txt` and `stage-summary.txt` structure; artifact name
lists; history `steps.jsonl`, `tests.jsonl`, `perf.jsonl` (parsed: key order, compact vs `json.dumps` spacing, every
field except the masked ones; `seconds` must look like `12.0`). Screenshots: file names only, never images.

Masking: ISO timestamps, run ids and run dir names (`<TS>-<cmd>-<COMMIT>`), the temp data dir, the repo path, `/tmp/tmp.*`,
seconds (`12.3 s`, bare `12.3` columns, `last.status`/`.status` seconds fields), `NN ms`, the short commit (+ `-dirty`),
whitespace runs in tables. Histogram counts and the slowest-test rows are dropped from summaries (header, bucket labels,
row count kept). `tests.jsonl` lines are sorted (completion order), as are `last.status` and `steps.jsonl` in unordered cases.
The `pub` step (`pub.log`, `pub.status`, the `pub` rows) is ignored: it runs only when resolution is stale, which the first
run clears for the second.

A failure names the case, the file and the first differing line.

Also: `lint_clean` expects `go-check` (host step, first, ok or failed) plus the 7 LINT steps ok; a failed go-check is
tolerated in `last-failed.txt`. `perf.jsonl` `ok` is masked, but any `ok:false` with exit 0 fails. `BW_SIGNING_DIR` is passed
to the children so the build and the secret grep use the same key. `lint_unformatted` cleans up with `t.Cleanup`; `TestMain`
removes a leftover `app/lib/zz_*unformatted*.dart` of a killed run.
