#!/usr/bin/env bats
#
# Offline tests for e2e/download.sh. curl is replaced by a fake whose -w output
# and exit code come from FAKE_CURL_OUT / FAKE_CURL_RC. No network is used.

setup() {
    SCRIPT="${BATS_TEST_DIRNAME}/../download.sh"
    OUT="${BATS_TEST_TMPDIR}/out"
    mkdir -p "$OUT"
    export CURL_BIN="${BATS_TEST_TMPDIR}/curl"
    cat >"$CURL_BIN" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "-V" ]; then echo "curl 8.0.0 Features: ${FAKE_CURL_FEATURES:-HTTP2}"; exit 0; fi
echo "$*" >>"$0.log"
printf '%s' "${FAKE_CURL_OUT:-200 2 104857600 1250000 83.8 0.01 0.05 0.3 1 1.2.3.4}"
exit "${FAKE_CURL_RC:-0}"
EOF
    chmod +x "$CURL_BIN"
    export DOWNLOAD_SLEEP_SECS=0
}

rows() { tail -n +2 "$OUT/Iowa.download.csv"; }

@test "classify: 200 is ok, other status is http:<code>" {
    run bash -c "source '$SCRIPT'; classify 0 200 100"
    [ "$output" = "ok" ]
    run bash -c "source '$SCRIPT'; classify 0 404 100"
    [ "$output" = "http:404" ]
}

@test "classify: timeout with bytes is truncated, without bytes is stalled" {
    run bash -c "source '$SCRIPT'; classify 28 200 5000"
    [ "$output" = "truncated" ]
    run bash -c "source '$SCRIPT'; classify 28 000 0"
    [ "$output" = "stalled" ]
    run bash -c "source '$SCRIPT'; classify 7 000 0"
    [ "$output" = "error:7" ]
}

@test "writes header plus one row per run with Mbps" {
    DOWNLOAD_RUNS=2 run "$SCRIPT" Iowa "$OUT"
    [ "$status" -eq 0 ]
    [ "$(head -1 "$OUT/Iowa.download.csv" | cut -d, -f1-4)" = "at,exit,run,outcome" ]
    [ "$(rows | wc -l | tr -d ' ')" -eq 2 ]
    [ "$(rows | cut -d, -f4 | sort -u)" = "ok" ]
    [ "$(rows | head -1 | cut -d, -f8)" = "10.00" ]
}

@test "a stalled pull is recorded, not fatal" {
    FAKE_CURL_OUT="000 0 0 0 30 0 0 0 0 " FAKE_CURL_RC=28 DOWNLOAD_RUNS=1 run "$SCRIPT" Iowa "$OUT"
    [ "$status" -eq 0 ]
    [ "$(rows | cut -d, -f4)" = "stalled" ]
}

@test "exhausted window records window-exhausted rows" {
    DOWNLOAD_RUNS=2 DOWNLOAD_WINDOW_SECS=5 run "$SCRIPT" Iowa "$OUT"
    [ "$status" -eq 0 ]
    [ "$(rows | cut -d, -f4 | sort -u)" = "window-exhausted" ]
}

@test "DOWNLOAD_HTTP3=on fails loudly without the HTTP3 feature" {
    DOWNLOAD_HTTP3=on run "$SCRIPT" Iowa "$OUT"
    [ "$status" -eq 2 ]
    [[ "$output" == *"no HTTP3 feature"* ]]
}

@test "auto mode passes --http3 when curl advertises it" {
    FAKE_CURL_FEATURES="HTTP2 HTTP3" DOWNLOAD_RUNS=1 run "$SCRIPT" Iowa "$OUT"
    [ "$status" -eq 0 ]
    grep -q -- "--http3" "$CURL_BIN.log"
}
