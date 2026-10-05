# PIX on the main tunnel session, sized to match `hoprd-localcluster --enable-pix`. Both halves below
# have to agree with the cluster or nothing settles, and they fail in different ways.
#
# The dimensions set the per-SSA quota — `num_ssa_parts × (ssa_part_size + additional_shares) × 3246`
# — which is the amount of exit → client data one deposit covers. hopr-lib's defaults
# (8192 × (64+16)) put it at ~1.98 GiB, so a single cycle would need that much downstream traffic
# before any key is recovered; the cluster's demo geometry is 8 × (2+2) × 3246 = 103 872 B and
# completes in seconds. The cluster's exit also only accepts quotas in 0 … 1 MiB, so an unmatched
# client is refused outright with `UnacceptablePixParams`.
#
# `price_per_byte` is *not* negotiated on the wire: each side multiplies the agreed quota by its own
# configured price, so a mismatch leaves the exit waiting for a deposit that will never arrive while
# the client believes it has paid. At the cluster's price one deposit is
# 0.0001 wxHOPR × 103 872 B = 10.3872 wxHOPR, which `max_ssa_allocation` has to clear. (3246 is
# hopr-lib's packet payload since 5.0.0-rc.5; it was 1038, and 3.3216 wxHOPR a deposit, before.)
[connection.pix.ping_main]
enabled = true

[connection.pix.dimensions]
num_ssa_parts     = 8
ssa_part_size     = 2
additional_shares = 2

[pix_strategy]
price_per_byte     = "0.0001 wxHOPR"
max_ssa_allocation = "20 wxHOPR"
