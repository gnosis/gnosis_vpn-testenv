version = 6

${DESTINATIONS}[connection.bridge]
capabilities = ["segmentation", "retransmission", "retransmission_ack_only", "no_rate_control"]
target = "127.0.0.1:8000"

[connection.wg]
capabilities = ["segmentation", "no_delay"]
target = "127.0.0.1:51821"

[connection.ping]
address = "10.128.0.1"
