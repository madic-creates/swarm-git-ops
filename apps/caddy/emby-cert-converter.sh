#!/bin/sh
set -e

apk add --no-cache redis openssl

REDIS_HOST="${REDIS_HOST:-redis}"
REDIS_PORT="${REDIS_PORT:-6379}"
REDIS_DB="${REDIS_DB:-0}"
DOMAIN=$(cat /run/secrets/emby_domain)
KEY_PREFIX="caddy"
ACME_CA="acme-v02.api.letsencrypt.org-directory"
OUTPUT="/certs/keystore.p12"
PASSWORD_FILE="/run/secrets/emby_pkcs12_password"
CHECKSUM_FILE="/tmp/last_checksum"

CERT_KEY="${KEY_PREFIX}/certificates/${ACME_CA}/${DOMAIN}/${DOMAIN}.crt"
PRIV_KEY="${KEY_PREFIX}/certificates/${ACME_CA}/${DOMAIN}/${DOMAIN}.key"

convert_cert() {
    CERT=$(redis-cli --raw -h "$REDIS_HOST" -p "$REDIS_PORT" -n "$REDIS_DB" GET "$CERT_KEY" 2>/dev/null)
    KEY=$(redis-cli --raw -h "$REDIS_HOST" -p "$REDIS_PORT" -n "$REDIS_DB" GET "$PRIV_KEY" 2>/dev/null)

    if [ -z "$CERT" ] || [ -z "$KEY" ]; then
        echo "$(date): No certificate found for $DOMAIN yet"
        return 1
    fi

    CURRENT_CHECKSUM=$(echo "$CERT" | md5sum | cut -d' ' -f1)
    if [ -f "$CHECKSUM_FILE" ] && [ "$(cat "$CHECKSUM_FILE")" = "$CURRENT_CHECKSUM" ]; then
        return 0
    fi

    echo "$CERT" > /tmp/cert.pem
    echo "$KEY" > /tmp/key.pem

    openssl pkcs12 -export \
        -in /tmp/cert.pem \
        -inkey /tmp/key.pem \
        -out "$OUTPUT" \
        -passout "file:$PASSWORD_FILE"

    rm -f /tmp/cert.pem /tmp/key.pem
    echo "$CURRENT_CHECKSUM" > "$CHECKSUM_FILE"
    echo "$(date): PKCS#12 keystore updated for $DOMAIN"
}

echo "Watching for certificate changes for $DOMAIN in Redis..."

while true; do
    convert_cert || true
    sleep 300
done
