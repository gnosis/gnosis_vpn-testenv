version = 6

${DESTINATIONS}
# the local cluster announces private/local IPs (Docker network, or loopback in
# host-native mode), which the client filters out by default
[connection]
probe_local_addresses = true

[connection.bridge]
target = "127.0.0.1:8000"

[connection.wg]
target = "127.0.0.1:51821"

# WireGuard server interface address — defined in gnosis_vpn-server/docker/wggvpn.conf
[connection.ping]
address = "10.129.0.1"

# wg-quick's DNS step shells out to resolvconf, which can't manage Docker's
# auto-generated /etc/resolv.conf and aborts the whole `up` — skip it entirely
[wireguard]
dns = { overwrite = false }

# PIX is on for the main tunnel session by default, and a localcluster cannot serve it. The
# exchange itself is fine — the exit accepts the client's parameters ("client offered acceptable
# PIX parameters … on secp256k1") — but settlement needs a `Pix` strategy on the exit, which is
# opt-in and which `hoprd-localcluster` only installs with `--enable-pix`. Without it the exit
# fails the SSA request ("deposit pool did not supply deposit data … has no listener"), poisons
# the session's service gate and closes the tunnel, so no destination ever finishes connecting.
#
# `--enable-pix` does not fix it either, for two reasons, both in the cluster's demo geometry:
#   1. it caps the accepted per-SSA quota at 1 MiB, and this client offers hopr-lib's default
#      ~649 MiB, so the exit refuses the session outright with UnacceptablePixParams;
#   2. `price_per_byte` is not negotiated on the wire — each side multiplies the quota by its own
#      configured price — so the cluster's 0.0001 wxHOPR/byte exit waits for 68026.368 wxHOPR
#      against the 1 wei/byte the settings below pay, and times out on every deposit.
# Widening the exit's quota window and matching its price makes the whole exchange work end to
# end (deposits confirmed on the exit), but both live in hoprd's `localcluster` crate, not here.
#
# Turn this back on once the cluster can be configured to match; `pix_strategy` below is already
# the pricing a matching exit would need, and is the same the client's own piz-palu-dev
# system-test config uses.
[connection.pix.ping_main]
enabled = false

[pix_strategy]
price_per_byte     = "0.000000000000000001 wxHOPR"
max_ssa_allocation = "0.000000001 wxHOPR"
