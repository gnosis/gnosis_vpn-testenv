# Sidecar image for the e2e browser harness. Run it with
# `--network container:gnosis_vpn-client` so obscura and ping sit inside the
# client's network namespace, where the full-tunnel WireGuard routes live.
FROM node:22-bookworm-slim

# obscura is not in any package repo, so it comes from the upstream release,
# pinned per architecture (same version/hashes the nix package used).
ARG OBSCURA_VERSION=0.2.1
ARG TARGETARCH

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl iputils-ping \
    && rm -rf /var/lib/apt/lists/*

RUN set -eu; \
    case "${TARGETARCH}" in \
      amd64) asset="obscura-x86_64-linux.tar.gz";  sha="6a1a66b3f1ab118fa7d31330894a868617aea68c06d75436d851356c39df1ed3" ;; \
      arm64) asset="obscura-aarch64-linux.tar.gz"; sha="0297c26d583f598f0126a7271cc40750598a9a9cbd86d1d6f79b2b99097d5244" ;; \
      *) echo "obscura: no upstream prebuilt for TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/obscura.tar.gz \
      "https://github.com/h4ckf0r0day/obscura/releases/download/v${OBSCURA_VERSION}/${asset}"; \
    echo "${sha}  /tmp/obscura.tar.gz" | sha256sum -c -; \
    # the tarball is flat binaries, no top-level directory
    tar -xzf /tmp/obscura.tar.gz -C /usr/local/bin; \
    rm /tmp/obscura.tar.gz; \
    chmod +x /usr/local/bin/obscura*; \
    obscura --version

WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev
COPY harness.mjs aggregate.mjs entrypoint.sh ./

ENTRYPOINT ["/app/entrypoint.sh"]
