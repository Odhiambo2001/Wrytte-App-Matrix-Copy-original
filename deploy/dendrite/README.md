# Wrytte Dendrite Homeserver

This folder contains the production baseline for the Wrytte Matrix homeserver:

- Dendrite monolith
- PostgreSQL
- coturn for voice/video call NAT traversal
- nginx reverse proxy example with Matrix `.well-known`

Before first start, replace every `change_this_*` value and every
`matrix.wrytte.com` placeholder with the real production domain.

Create a DNS `A` record for `turn.matrix.wrytte.com` pointing to the public IP
of the coturn host. Copy `.env.example` to `.env`, set a long random
`TURN_SHARED_SECRET`, the coturn public IP and the TLS certificate paths, then
render the Dendrite configuration:

```bash
cp .env.example .env
# Edit .env, then:
./prepare-config.sh
```

The same `TURN_SHARED_SECRET` is injected into Dendrite and coturn. Never put
this secret in Flutter or commit `.env`/`.generated`.

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
./prepare-config.sh
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

Open these inbound firewall ports on the TURN host:

- `3478/udp` and `3478/tcp`
- `5349/tcp`
- `49160-49200/udp`

For mobile providers that permit only TLS on port 443, run coturn on a separate
public IP/hostname and map public TCP 443 to coturn TCP 5349. It cannot share
the same IP:443 listener already used by nginx without an L4 multiplexer.

After deployment, authenticate to Matrix and verify that Dendrite returns
temporary credentials (do not paste the response publicly):

```bash
curl -H "Authorization: Bearer MATRIX_ACCESS_TOKEN" \
  https://matrix.wrytte.com/_matrix/client/v3/voip/turnServer
```

The response must contain `username`, `password`, `ttl`, and all three TURN
URIs. During a cross-network call, the Flutter logs should report `TURN
available`, and WebRTC should progress from `CONNECTING` to `CONNECTED`.
