FROM caddy:2.11.2-builder AS builder

RUN xcaddy build \
    --with github.com/lucaslorentz/caddy-docker-proxy/v2 \
    --with github.com/caddy-dns/cloudflare \
    --with github.com/pberkel/caddy-storage-redis

FROM caddy:2.11.2
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
