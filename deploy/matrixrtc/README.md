# Production MatrixRTC call fixes

The Flutter client uses the **legacy** MatrixRTC JWT endpoint:

```text
POST https://matrix.wrytte.com/livekit/jwt/sfu/get
{
  "room": "!room:matrix.wrytte.com",
  "openid_token": { ... },
  "device_id": "DEVICE"
}
```

Do not send `slot_id` to this endpoint. `slot_id` belongs to the newer
MSC4195 endpoint (`/get_token`), whose request shape instead includes
`room_id`, `slot_id`, and `member`. The two endpoints are not interchangeable.

## 1. Keep the JWT proxy routes separate

Your reverse proxy must preserve the suffix after `/livekit/jwt/`:

```nginx
location ^~ /livekit/jwt/ {
    proxy_pass http://wrytte-lk-jwt:8080/;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}

location ^~ /livekit/sfu/ {
    proxy_pass http://wrytte-livekit:7880/;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $host;
}
```

With this configuration the client request above reaches `/sfu/get`, not
`/get_token` and not the service root.

## 2. Provision the Matrix account when Wrytte registers the user

This is required. The app authenticates to Matrix with:

```text
Matrix username: Wrytte userid
Matrix password:  Wrytte secret
Matrix ID:        @<userid>:matrix.wrytte.com
```

Synapse has registration disabled, so the Wrytte backend must create that
account as part of the successful `/auth/register/rpn` transaction. Do this
server-side, never from the mobile app and never by exposing a Synapse admin
token to the app.

Use the Synapse admin API from the trusted Wrytte backend:

```text
PUT /_synapse/admin/v2/users/@<userid>:matrix.wrytte.com
Authorization: Bearer <Synapse admin access token>
Content-Type: application/json

{
  "password": "<Wrytte secret>",
  "deactivated": false,
  "displayname": "<optional profile name>"
}
```

Treat an existing account as success, and update the Matrix password whenever
the Wrytte secret is rotated. Store the admin token only in the backend secret
store. Do not enable public Synapse registration as a workaround.

## 3. Deploy and verify

1. Deploy the Flutter change in `matrixrtc_livekit_service.dart`.
2. Deploy backend Matrix provisioning.
3. Provision existing Wrytte users once (using the same trusted backend job).
4. Have affected users sign out and sign in once to discard the failed Matrix
   session; thereafter normal session restore works.
5. Make a voice and video call with two provisioned accounts while following
   `wrytte-lk-jwt` and `wrytte-livekit` logs.

Expected result: the JWT service receives a valid `/sfu/get` request and
returns `url` plus `jwt`; LiveKit no longer logs `/rtc` 401 for that join.
