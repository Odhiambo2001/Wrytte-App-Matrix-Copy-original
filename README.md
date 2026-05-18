# Wrytte App - Matrix Messaging + Firebase App Data

Wrytte is a Flutter chat app that uses the **Matrix protocol** for messaging and **Firebase** for app identity/profile data, contacts, storage, and supporting metadata.

The important architectural rule is:

> Matrix is the source of truth for chat. Firebase is the source of truth for Wrytte app metadata.

Clearing Firebase data does not clear Matrix rooms, messages, or the local Matrix SDK cache.

---

## Messaging Architecture

### Matrix Handles

Matrix is responsible for the chat protocol and all message-related state.

| Area | Details |
|---|---|
| Chat messages | Text, voice/media messages, event IDs, sender IDs, timestamps, and message status |
| Conversations | Matrix rooms, direct rooms, room IDs, latest event data, unread counts, and read markers |
| Realtime sync | Matrix client sync and timeline event streams |
| Message history | History is fetched from Matrix room timelines |
| Chat auth/session | Matrix user ID, access token, homeserver, and device ID stored in secure storage |
| User presence in chat | Matrix client login, restore, logout, and room membership |
| Media in chat | Matrix media upload/download through the Matrix SDK |

Relevant app code:

| File | Purpose |
|---|---|
| `lib/services/matrix/matrix_client.dart` | Creates and initializes the Matrix SDK client and local SQLite cache |
| `lib/services/matrix/matrix_auth_service.dart` | Logs in, registers, restores, persists, and logs out Matrix sessions |
| `lib/services/matrix/matrix_chat_service.dart` | Matrix room and chat helpers |
| `lib/services/matrix/matrix_sync_service.dart` | Matrix sync lifecycle |
| `lib/services/chat/chat_service.dart` | App-level chat facade backed by Matrix rooms and events |
| `lib/models/chat_models/chat_message.dart` | Converts Matrix events into Wrytte chat messages |
| `lib/models/chat_models/chat_conversation.dart` | Converts Matrix rooms into Wrytte conversations |

### Firebase Handles

Firebase is responsible for Wrytte app data around the chat experience, but not the chat messages themselves.

| Area | Details |
|---|---|
| User profile metadata | Matrix profile plus local secure profile storage |
| App auth bootstrap | Matrix auth plus local secure session storage |
| Contact metadata | Saved contacts in Matrix account data, contact display names, contact avatars, and Matrix user-directory lookup |
| Profile edits | Name/avatar/profile metadata updates after signup and from edit profile flows |
| File/profile storage | Firebase Storage for app profile images and non-Matrix assets |
| Supporting app state | Matrix and local app metadata; calls use Matrix VoIP signaling |

Matrix is the chat database for rooms, messages, contacts, and sync.

---

## Matrix vs Firebase Boundary

| Question | Answer |
|---|---|
| Where do chat messages come from? | Matrix rooms and Matrix room timelines |
| Where are conversations listed from? | Matrix rooms enriched with Matrix account-data contacts and Matrix profile data |
| Where are unread counts/read markers from? | Matrix room state |
| Where are saved contact names from? | Matrix account data `com.wrytte.contacts` |
| Where are profile names and avatars stored? | Matrix profile and local secure profile storage |
| Does clearing Firebase delete chats? | No |
| Does clearing app cache delete server-side Matrix messages? | No, it only affects local cache/session data |
| What deletes server-side messages/rooms? | Matrix room/message administration or user room actions on the Matrix homeserver |

---

## Matrix Configuration

The app uses the `matrix` Dart package.

```yaml
matrix: ^7.1.2
```

Package page:

```text
https://pub.dev/packages/matrix
```

You do **not** clone the Matrix SDK into this repository. Flutter downloads it from pub.dev and stores it in the local pub cache after you run `flutter pub get`.

### Getting the Matrix SDK

If the package is already listed in `pubspec.yaml`, install all project dependencies with:

```bash
flutter pub get
```

If the package is missing, add it with:

```bash
flutter pub add matrix
```

Then fetch dependencies:

```bash
flutter pub get
```

After that, Wrytte code can import the SDK directly:

```dart
import 'package:matrix/matrix.dart';
```

That import is resolved locally from Flutter's pub cache. The app does not load the SDK from pub.dev at runtime; pub.dev is only where Flutter downloads the package during dependency setup.

By default, Matrix auth uses the Wrytte Dendrite homeserver:

```dart
https://matrix.wrytte.com
```

You can override it at build time with:

```bash
flutter run \
  --dart-define=WRYTTE_MATRIX_HOMESERVER=https://matrix.wrytte.com \
  --dart-define=WRYTTE_MATRIX_SERVER_NAME=matrix.wrytte.com
```

The Matrix session is stored with `flutter_secure_storage` using these keys:

| Key | Meaning |
|---|---|
| `matrix_user_id` | Logged-in Matrix user ID, for example `@254712345678:matrix.org` |
| `matrix_access_token` | Matrix access token |
| `matrix_homeserver` | Homeserver URL |
| `matrix_device_id` | Matrix device ID, when available |

The local Matrix SDK cache is stored in the app support directory as:

```text
wrytte_matrix.sqlite
```

The app config lives in:

```text
lib/services/matrix/matrix_config.dart
```

That file defines:

| Setting | Value |
|---|---|
| Homeserver URL | `WRYTTE_MATRIX_HOMESERVER`, default `https://matrix.wrytte.com` |
| Matrix server name | `WRYTTE_MATRIX_SERVER_NAME`, default `matrix.wrytte.com` |
| SDK SQLite DB | `wrytte_matrix.sqlite` |
| Local Matrix media cache budget | 512 MB |
| Local Matrix media cache TTL | 30 days |

---

## Dendrite Homeserver

Wrytte is configured to use **Dendrite** as the Matrix homeserver. Dendrite is a Matrix server, not a Flutter dependency. The Flutter app talks to it through the Matrix Client-Server API via the `matrix` Dart SDK.

Upstream currently describes Dendrite as beta/maintenance-mode software suitable for small deployments, commonly tens to hundreds of users. It is a good Wrytte baseline if we operate it conservatively with PostgreSQL, persistent volumes, backups, TLS, TURN, and monitoring. It should not be treated as a massive/high-availability homeserver stack.

Production baseline files are in:

```text
deploy/dendrite/
```

| File | Purpose |
|---|---|
| `deploy/dendrite/docker-compose.yml` | Runs Dendrite monolith, PostgreSQL, and coturn |
| `deploy/dendrite/config/dendrite.yaml` | Dendrite homeserver configuration |
| `deploy/dendrite/nginx/matrix.wrytte.com.conf` | Reverse proxy and Matrix `.well-known` example |
| `deploy/dendrite/.env.example` | Values to rotate and replace for production |
| `deploy/dendrite/README.md` | Server bootstrap commands |

### Dendrite Production Shape

Use this architecture for Wrytte production:

| Layer | Production choice |
|---|---|
| Homeserver | Dendrite monolith |
| Server database | PostgreSQL |
| Media store | Persistent Docker volume or mounted disk at `/var/dendrite/media` |
| JetStream | Persistent volume at `/var/dendrite/jetstream` |
| Search index | Persistent volume at `/var/dendrite/searchindex` |
| Reverse proxy | nginx or equivalent HTTPS proxy |
| Calls NAT traversal | coturn, advertised through `client_api.turn` |
| Client local cache | Matrix SDK SQLite on each device |

Do not use Dendrite SQLite for production. SQLite is acceptable for local tests, but PostgreSQL performs better with many users and larger rooms.

### First-Time Server Setup

1. Copy `deploy/dendrite/.env.example` and replace all `change_this_*` values.
2. Replace `matrix.wrytte.com` in the Dendrite and nginx configs with the real domain.
3. Generate Dendrite signing keys:

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

4. Put nginx in front of Dendrite with a publicly trusted TLS certificate.
5. Start the services:

```bash
docker compose -f deploy/dendrite/docker-compose.yml up -d
```

6. Create an admin user:

```bash
docker compose -f deploy/dendrite/docker-compose.yml exec dendrite \
  /usr/bin/create-account \
  -config /etc/dendrite/dendrite.yaml \
  -username admin \
  -admin
```

### Dendrite Operations

| Operation | Where it happens |
|---|---|
| Register/login Matrix users | Dendrite Client API, wrapped by `MatrixAuthService` |
| Text messages | Dendrite rooms/events via Matrix `m.room.message` events |
| Replies | Matrix `m.relates_to` / `m.in_reply_to` relation plus a local preview fallback |
| Forwards | New Matrix message event with Wrytte forwarded metadata |
| Delete for everyone | Matrix redaction through `Room.redactEvent()` |
| Delete for me | Device-local visibility flag in Wrytte SQLite cache |
| Starred messages | Device-local Wrytte SQLite flag; does not mutate server history |
| Voice notes | Matrix media upload and `m.audio` events via `Room.sendAudioEvent()` |
| File/image/video messages | Matrix media upload via `Room.sendFileEvent()` |
| 1:1 voice calls | Matrix VoIP call events plus TURN from Dendrite/coturn |
| 1:1 video calls | Matrix VoIP call events plus TURN from Dendrite/coturn |
| Read markers/unread counts | Matrix room read markers and sync state |
| Offline startup cache | Matrix SDK SQLite plus Wrytte chat SQLite projections |
| Permanent server-side history | Dendrite PostgreSQL and media store |
| Saved contacts | Matrix per-user account data `com.wrytte.contacts`; app also mirrors to `users/{uid}/contacts` during migration |

For public production, avoid unrestricted open registration. The current Flutter flow can register Matrix accounts directly, so `registration_disabled` is set to `false` in the provided baseline. Before a public launch, put registration behind a backend/appservice/shared-secret flow or enable CAPTCHA/rate limits appropriate for the deployment.

---

## Local Data Policy

Wrytte keeps a **local cache**, not a second source of truth.

| Data | Kept locally? | Why |
|---|---|---|
| Matrix session credentials | Yes, secure storage | Restore login securely |
| Recent room state and timelines | Yes, Matrix SDK SQLite | Fast startup and offline reading |
| Recent Wrytte chat projections | Yes, `wrytte_chat.db` | WhatsApp-like offline open, date grouping, stars, and delete-for-me |
| Media files | Yes, bounded cache | Avoid repeat downloads, support offline playback |
| Full infinite room history | Not guaranteed | Fetched from Dendrite on demand when pagination needs older events |
| Server-side message truth | Dendrite PostgreSQL/media store | Durable canonical history |
| Saved Wrytte contacts | Yes, Matrix account data | Contacts sync with the Matrix account across devices |
| Wrytte profile/contact metadata | Matrix account data plus local caches | UI names, avatars, contacts |

So the answer to “do we keep all messages and all data on the user side?” is:

> We keep enough synced Matrix room state, timeline history, and media cache locally for fast startup and offline access. We do not treat the device database as the permanent complete archive. Dendrite remains the canonical source, and older history can be paginated from the homeserver.

This gives the practical benefits we want:

- The app does not redownload every message on every launch.
- Recent conversations open quickly.
- Users can read cached messages offline.
- Server and bandwidth pressure is reduced.
- If local storage is cleared, the cache can be rebuilt from Dendrite after login.

### WhatsApp-Like Message Behavior

The Flutter client now exposes these chat actions from the service/model layer:

| Feature | Production behavior |
|---|---|
| Reply | Sends Matrix reply relation and keeps a short local preview for offline rendering |
| Forward | Re-sends the selected message/media to the destination Matrix direct room and marks it as forwarded |
| Delete for everyone | Redacts the Matrix event on Dendrite; synced devices render it as deleted |
| Delete for me | Hides the message only on this device by setting a local cache flag |
| Cancel | Removes an unsent local/optimistic message from the local cache |
| Star | Stores a device-local starred flag so the server event is not mutated |
| Dates | Message timestamps come from Matrix event time or local send time and are grouped into Today, Yesterday, weekday, or date dividers |
| Offline recent chats | Chat screens read cached messages before connecting to Matrix, so recent chats open without network access |

The server remains authoritative for message history, media, redactions, timestamps, calls, and sync. The device database is optimized for speed, offline access, and user-private local choices.

---

## Firebase Configuration

Firebase is initialized from:

```text
lib/firebase_options.dart
```

The Flutter app currently uses Firebase packages for:

```yaml
firebase_core
firebase_auth
firebase_storage
```

Matrix account data and Matrix profile data make Matrix rooms feel like Wrytte conversations.

---

## Authentication Flow

1. The app creates or restores a local Wrytte auth session.
2. Matrix session restore is attempted for profile and contact sync.
3. Local secure profile storage is updated with Wrytte metadata.
4. The app logs into Matrix, or registers the Matrix account if login fails.
5. Matrix identity stays in Matrix secure storage and account data.
6. Chat screens connect to Matrix and listen for Matrix timeline/sync updates.

Development OTPs are generated locally in `AuthService` and currently use:

```text
123456
```

---

## Common Debugging Notes

### I cleared Firebase but chats still appear

That is expected. Those chats are coming from Matrix, not Firebase.

Matrix stores server-side room history on the configured homeserver and also keeps a local SDK cache on the device. Firebase only stores Wrytte profile/contact/supporting metadata.

### I cleared app cache but chats still return

That is also expected. Clearing local cache can remove local Matrix SDK data, but when the user logs in again, Matrix can sync room history back from the homeserver.

### I need to clear local Matrix session/cache

Use the app logout flow, which calls Matrix logout and clears stored Matrix session keys. Uninstalling the app also removes local app storage on the device.

### I need to remove server-side chat history

Do this through Matrix room administration or homeserver-level tools. Firebase cleanup will not remove Matrix room events.

---

## Getting Started

Install dependencies:

```bash
flutter pub get
```

Confirm the Matrix SDK dependency is installed:

```bash
flutter pub deps | findstr matrix
```

On macOS/Linux, use:

```bash
flutter pub deps | grep matrix
```

Run the app:

```bash
flutter run
```

Run with a custom Matrix homeserver:

```bash
flutter run \
  --dart-define=WRYTTE_MATRIX_HOMESERVER=https://matrix.wrytte.com \
  --dart-define=WRYTTE_MATRIX_SERVER_NAME=matrix.wrytte.com
```

---

## Quick Reference

| Need | Use |
|---|---|
| Chat messages and history | Matrix |
| Direct chat rooms | Matrix |
| Realtime message sync | Matrix |
| Message local cache | Matrix SDK SQLite cache |
| User profiles | Matrix profile and secure local storage |
| Saved contacts | Matrix account data, mirrored to Firebase during migration |
| Profile images | Firebase Storage / profile metadata |
| Firebase login state | Firebase Auth |
| Matrix login state | Matrix secure storage keys |
