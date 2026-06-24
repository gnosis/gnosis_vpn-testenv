version = 6

${DESTINATIONS}[connection.bridge]
capabilities = ["segmentation", "retransmission", "retransmission_ack_only", "no_rate_control"]
target = "127.0.0.1:8000"

[connection.wg]
capabilities = ["segmentation", "no_delay"]
target = "127.0.0.1:51821"

# WireGuard server interface address — defined in gnosis_vpn-server/docker/wggvpn.conf
[connection.ping]
address = "10.129.0.1"
