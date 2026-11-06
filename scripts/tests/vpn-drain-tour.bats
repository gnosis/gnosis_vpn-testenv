#!/usr/bin/env bats
# Offline tests for scripts/vpn-drain-tour.sh: pure helpers via sourcing, whole-run behavior via the curl/ping/gnosis_vpn-ctl fakes injected through GVPN_CURL/GVPN_PING/GVPN_CTL - no network or real gnosis_vpn-ctl.

setup() {
    SCRIPT="${BATS_TEST_DIRNAME}/../vpn-drain-tour.sh"
    FAKES="${BATS_TEST_DIRNAME}/fakes"
    export GVPN_CURL="${FAKES}/curl"
    export GVPN_PING="${FAKES}/ping"
    export GVPN_CTL="${FAKES}/gnosis_vpn-ctl"
    export FAKE_CTL_STATE="${BATS_TEST_TMPDIR}/ctl-state"
    OUT_DIR="${BATS_TEST_TMPDIR}/run"
}

# --- unit: ranking -----------------------------------------------------

@test "rank_destinations puts routable first, ordered by cached quick-probe RTT" {
    local status_json
    status_json='{"type":"status","data":{"destinations":[
        {"destination":{"id":"slow","address":"0xA"},
         "route_health":{"state":{"type":"routable"},"quick_probe":{"type":"checked","status_rtt":90,"load":{"slots":{"available":9,"connected":1}}}}},
        {"destination":{"id":"no-route","address":"0xC"},
         "route_health":{"state":{"type":"not_routable"},"quick_probe":null}},
        {"destination":{"id":"fast","address":"0xB"},
         "route_health":{"state":{"type":"routable"},"quick_probe":{"type":"checking","since":0,"last":{"status_rtt":20,"load":{"slots":{"available":5,"connected":5}}}}}}
    ]}}'
    run bash -c "source '$SCRIPT'; rank_destinations '$status_json' | jq -c '[.[] | [.id, .connectable, .ping_rtt_ms, .available]]'"
    [ "$status" -eq 0 ]
    [ "$output" = '[["fast",true,20,5],["slow",true,90,9],["no-route",false,null,null]]' ]
}

@test "rank_destinations puts routable without a cached quick probe after measured ones, and names why others are unconnectable" {
    local status_json
    status_json='{"type":"status","data":{"destinations":[
        {"destination":{"id":"unmeasured","address":"0xA"}, "route_health":{"state":{"type":"routable"},"quick_probe":null}},
        {"destination":{"id":"bad-api","address":"0xD"},
         "route_health":{"state":{"type":"unrecoverable","reason":{"type":"incompatible_api_version","offered":[]}},"quick_probe":null}},
        {"destination":{"id":"measured","address":"0xB"},
         "route_health":{"state":{"type":"routable"},"quick_probe":{"type":"checked","status_rtt":50,"load":{"slots":{"available":5,"connected":5}}}}},
        {"destination":{"id":"unchecked","address":"0xE"}, "route_health":null}
    ]}}'
    run bash -c "source '$SCRIPT'; rank_destinations '$status_json' | jq -c '[.[] | [.id, .state]]'"
    [ "$status" -eq 0 ]
    [ "$output" = '[["measured","routable"],["unmeasured","routable"],["bad-api","unrecoverable: incompatible_api_version"],["unchecked","no_route_health"]]' ]
}

@test "skip_reason prefers last_error over the bare state name" {
    run bash -c "source '$SCRIPT'; skip_reason '{\"state\":\"unrecoverable: not_allowed\",\"last_error\":\"not allowed\"}'"
    [ "$output" = "not allowed" ]
    run bash -c "source '$SCRIPT'; skip_reason '{\"state\":\"not_routable\",\"last_error\":null}'"
    [ "$output" = "state: not_routable" ]
}

# --- cli surface ------------------------------------------------------------

@test "--help exits 0 with usage" {
    run "$SCRIPT" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage: vpn-drain-tour.sh"* ]]
}

@test "unknown option exits 2" {
    run "$SCRIPT" --bogus
    [ "$status" -eq 2 ]
}

@test "value-taking options reject a missing value" {
    for option in --out-dir --max-rounds --connect-timeout --poll-interval -s --socket-path --targets --sizes; do
        run "$SCRIPT" "$option"
        [ "$status" -eq 2 ]
    done
}

@test "a missing dependency aborts with an apt-get hint" {
    export PATH="${FAKES}:${PATH}"
    export GVPN_CURL="${BATS_TEST_TMPDIR}/no-such-curl"
    run "$SCRIPT" --out-dir "${BATS_TEST_TMPDIR}/run" --max-rounds 1
    [ "$status" -eq 2 ]
    [[ "$output" == *"missing"* ]]
    [[ "$output" == *"apt-get install"* ]]
    [[ "$output" == *curl* ]]
}

@test "--install-deps apt-get installs the missing package and continues" {
    export PATH="${FAKES}:${PATH}"
    export FAKE_APT_GET_LOG="${BATS_TEST_TMPDIR}/apt-get.log"
    export GVPN_CURL="${BATS_TEST_TMPDIR}/no-such-curl"
    export FAKE_CTL_EMPTY_AFTER=1

    run "$SCRIPT" --out-dir "${BATS_TEST_TMPDIR}/run" --max-rounds 1 --install-deps
    [ "$status" -eq 0 ]
    [ -f "$FAKE_APT_GET_LOG" ]
    run grep -c "install -y curl" "$FAKE_APT_GET_LOG"
    [ "$output" -eq 1 ]
}

# --- whole run ---------------------------------------------------------

@test "tour connects best-first, records a rejected connect, skips a not-routable destination, and stops when funds drain" {
    export FAKE_CTL_FAIL_CONNECT="us1"
    export FAKE_CTL_EMPTY_AFTER=3

    run "$SCRIPT" --out-dir "$OUT_DIR" --max-rounds 5 --quick --poll-interval 1 --connect-timeout 5
    [ "$status" -eq 0 ]
    [[ "$output" == *"funds drained: traffic funding status is empty"* ]]

    [ -f "$OUT_DIR/runs.jsonl" ]
    run jq -s 'length' "$OUT_DIR/runs.jsonl"
    [ "$output" -eq 6 ]

    run jq -s '[.[] | select(.outcome=="connected")] | length' "$OUT_DIR/runs.jsonl"
    [ "$output" -eq 2 ]
    run jq -s '[.[] | select(.outcome=="failed" and .destination_id=="us1")] | length' "$OUT_DIR/runs.jsonl"
    [ "$output" -eq 2 ]
    run jq -s '[.[] | select(.outcome=="skipped" and .destination_id=="fr1")] | length' "$OUT_DIR/runs.jsonl"
    [ "$output" -eq 2 ]

    # de1 (cached RTT 40 ms) is attempted before us1 (80 ms) every round.
    run jq -sc '[.[] | select(.round==1) | .destination_id]' "$OUT_DIR/runs.jsonl"
    [ "$output" = '["de1","us1","fr1"]' ]

    [ "$(wc -l <"$OUT_DIR/metrics.csv")" -eq 7 ] # header + 6 attempts
}

@test "tour records a timeout when connect succeeds but the tunnel never comes up" {
    export FAKE_CTL_STALL_CONNECT="de1 us1"

    run "$SCRIPT" --out-dir "$OUT_DIR" --max-rounds 1 --quick --poll-interval 1 --connect-timeout 2
    [ "$status" -eq 0 ]
    [[ "$output" == *"no destination connectable this round"* ]]

    run jq -s '[.[] | select(.outcome=="failed") | .reason] | unique' "$OUT_DIR/runs.jsonl"
    [[ "$output" == *"did not come up"* ]]
}

@test "tour stops at --max-rounds when funding never drains" {
    export FAKE_CTL_EMPTY_AFTER=0

    run "$SCRIPT" --out-dir "$OUT_DIR" --max-rounds 2 --quick --poll-interval 1 --connect-timeout 5
    [ "$status" -eq 0 ]
    [[ "$output" == *"hit --max-rounds (2)"* ]]

    run jq -s '[.[].round] | unique | length' "$OUT_DIR/runs.jsonl"
    [ "$output" -eq 2 ]
}

@test "tour stops before round 1 when the worker is offline" {
    export FAKE_CTL_WORKER_OFFLINE=1

    run "$SCRIPT" --out-dir "$OUT_DIR" --max-rounds 5 --quick --poll-interval 1 --connect-timeout 5
    [ "$status" -eq 0 ]
    [[ "$output" == *"worker offline"* ]]
    [ ! -s "$OUT_DIR/runs.jsonl" ]
}
