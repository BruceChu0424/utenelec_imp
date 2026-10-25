# Validation environment only. Never publish or use this as the company runtime.
FROM ubuntu:24.04
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    python3 nginx libnginx-mod-stream openssl nftables wireguard-tools iproute2 util-linux ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --no-create-home --shell /usr/sbin/nologin uten-remote
WORKDIR /src
CMD ["python3", "tests/integration_linux.py"]
