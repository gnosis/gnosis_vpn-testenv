#!/usr/bin/env bats
#
# Offline tests for the release-gate verdict in e2e/aggregate.mjs, on hand-written per-exit records.

setup() {
    AGG="${BATS_TEST_DIRNAME}/../aggregate.mjs"
    OUT="${BATS_TEST_TMPDIR}/out"
    mkdir -p "$OUT"
    cat >"$OUT/meta.json" <<'EOF'
{"run_ts":"20261117T000000Z","client_mode":"spawn","quick":false,
 "commits":{"testenv":"abc1234","gnosis_vpn_client":"def5678"},
 "gate":{"network":"piz-palu-staging","identity":"gate-1","hoprd_version":"5.0.3-pr.287","client_version":"gnosis_vpn-root 0.101.0"}}
EOF
}

# exit_record <exit> <outcome-of-every-site> [<amazon-outcome>]
exit_record() {
    local amazon="${3:-$2}"
    jq -n --arg exit "$1" --arg o "$2" --arg a "$amazon" '{exit: $exit, navigations: [
        {label: "wikipedia", outcome: $o}, {label: "bbc", outcome: $o},
        {label: "github", outcome: $o}, {label: "amazon", outcome: $a},
        {label: "youtube-home", outcome: "timeout"}, {label: "reddit", outcome: "http_error"}]}' >"$OUT/$1.json"
}

aggregate() { OUTDIR="$OUT" node "$AGG"; }

@test "every exit loading the required sites passes, informational failures do not count" {
    exit_record Iowa ok
    exit_record Seoul ok
    run aggregate
    [ "$status" -eq 0 ]
    [ "$(jq -r .verdict "$OUT/verdict.json")" = "PASS" ]
    [ "$(jq -r .hoprd_version "$OUT/verdict.json")" = "5.0.3-pr.287" ]
    [ "$(jq -r .client.commit "$OUT/verdict.json")" = "def5678" ]
    grep -q '^# Gnosis VPN release gate: PASS' "$OUT/report.md"
    grep -q 'hoprd under test: `5.0.3-pr.287`' "$OUT/report.md"
}

@test "one required site failing on one exit fails the gate" {
    exit_record Iowa ok
    exit_record Seoul ok timeout
    run aggregate
    [ "$status" -eq 1 ]
    [ "$(jq -r .verdict "$OUT/verdict.json")" = "FAIL" ]
    [ "$(jq -r '.exits.Seoul.reasons[0]' "$OUT/verdict.json")" = "amazon: timeout" ]
    [ "$(jq -r '.exits.Iowa.pass' "$OUT/verdict.json")" = "true" ]
}

@test "an exit that never became connectable fails the gate" {
    exit_record Iowa ok
    jq -n '{exit: "Sydney", fatal_error: "not connectable (state: not_routable)"}' >"$OUT/Sydney.json"
    run aggregate
    [ "$status" -eq 1 ]
    [ "$(jq -r '.exits.Sydney.reasons[0]' "$OUT/verdict.json")" = "not connectable (state: not_routable)" ]
}

@test "GATE_REQUIRED_SITES narrows what is judged" {
    exit_record Iowa ok timeout
    GATE_REQUIRED_SITES=wikipedia,bbc run aggregate
    [ "$status" -eq 0 ]
    [ "$(jq -r .verdict "$OUT/verdict.json")" = "PASS" ]
}

@test "a download-only run is not judged and does not fail" {
    jq -n '{exit: "Iowa", browser_skipped: true}' >"$OUT/Iowa.json"
    run aggregate
    [ "$status" -eq 0 ]
    [ "$(jq -r .verdict "$OUT/verdict.json")" = "NOT JUDGED" ]
}
