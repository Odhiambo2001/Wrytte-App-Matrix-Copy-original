# Wrytte Dendrite Homeserver

This folder contains the production baseline for the Wrytte Matrix homeserver:

- Dendrite monolith
- PostgreSQL
- coturn for voice/video call NAT traversal
- nginx reverse proxy example with Matrix `.well-known`

Before first start, replace every `change_this_*` value and every
`matrix.wrytte.com` placeholder with the real production domain.

## Generate Signing Keys

```bash
cd deploy/dendrite
docker run --rm --entrypoint="" \
  -v "$(pwd)/config:/mnt" \
  ghcr.io/element-hq/dendrite-monolith:v0.15.2 \
  /usr/bin/generate-keys \
  -private-key /mnt/matrix_key.pem \
  -tls-cert /mnt/server.crt \
  -tls-key /mnt/server.key
```

Use publicly trusted TLS through nginx for production. The generated TLS files
are useful for local/internal testing, but federation and mobile clients should
use a valid certificate.

## Start

```bash
docker compose up -d
```

## Create Admin User

```bash
docker compose exec dendrite /usr/bin/create-account \
  -config /etc/dendrite/dendrite.yaml \
  -username admin \
  -admin
```

## PostgreSQL

PostgreSQL is used as Dendrite's global database pool. Do not switch production
to SQLite; SQLite is only appropriate for small local tests.

## Calls

Dendrite exposes TURN credentials to Matrix clients from `client_api.turn`.
coturn must be reachable on TCP/UDP 3478 and TCP 5349, with the UDP relay port
range open on the firewall.
