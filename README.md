# Wrytte App

Wrytte is a Flutter messaging app backed mainly by:

- Matrix/Dendrite for chat, rooms, sync, message history, read state, media messages, and calls.
- Wrytte backend API for phone/email registration, login, backend auth tokens, registered-number lookup, and backend-owned account data.
- Local secure storage and SQLite caches for fast startup, offline access, and session restore.
- Firebase only for the pieces still used by the app: Firebase initialization, anonymous Firebase Auth support, and Firebase Storage for profile image uploads.

Firebase is not the source of truth for chats.

---

## Current Architecture

| Area | Current owner |
|---|---|
| Text/voice/media messages | Matrix |
| Direct rooms and conversation sync | Matrix |
| Read receipts, unread counts, typing/sync events | Matrix |
| Matrix access token, Matrix user ID, device ID | Matrix session in secure storage |
| Saved Wrytte contacts | Wrytte backend plus local cache |
| Phone/email registration and login | Wrytte backend |
| Backend auth token | Wrytte backend token in secure storage |
| Registered phone-number lookup | Wrytte backend |
| Profile name | Local secure profile storage plus Matrix profile update |
| Profile image upload | Firebase Storage |
| Offline chat startup | Matrix SDK SQLite plus Wrytte local chat cache |
| FE to BE realtime events | Optional WebSocket client, disabled until backend endpoint exists |

The practical rule is:

> Matrix owns chat. The Wrytte backend owns app authentication and registered-number/backend data. Firebase is only a supporting service where the code still uses it.

---

## Important Runtime Settings

### Backend API

Backend HTTP requests use this default:

```text
https://wryttedev.azurewebsites.net
```

Defined in:

```text
lib/services/auth/api_service.dart
```

To point a build at another backend deployment without changing source code:

```bash
flutter run \
  --dart-define=WRYTTE_BACKEND_API_URL=https://your-backend-host
```

Backend requests can attach:

```text
Authorization: Bearer <backend auth token>
```

### Backend WebSocket

The frontend WebSocket client exists, but it is disabled until the backend provides an endpoint.

Enable it with:

```bash
flutter run \
  --dart-define=WRYTTE_BACKEND_WS_URL=wss://your-backend-websocket-endpoint
```

The frontend service is:

```text
lib/services/backend/backend_realtime_service.dart
```

It attaches the backend auth token as an `access_token` query parameter, sends heartbeat pings, reconnects automatically, and listens for backend realtime events such as notifications, contact/profile updates, session warnings, and token invalidation alerts.

### Matrix

Matrix config lives in:

```text
lib/services/matrix/matrix_config.dart
```

Current defaults:

| Setting | Value |
|---|---|
| `WRYTTE_MATRIX_HOMESERVER` | `http://31.220.58.129:8008` |
| `WRYTTE_MATRIX_SERVER_NAME` | `matrix.wrytte.com` |
| Local Matrix database | `wrytte_matrix.sqlite` |
| Local Matrix media cache | 512 MB |
| Local Matrix media TTL | 30 days |

Run with custom Matrix settings:

```bash
flutter run \
  --dart-define=WRYTTE_MATRIX_HOMESERVER=https://matrix.wrytte.com \
  --dart-define=WRYTTE_MATRIX_SERVER_NAME=matrix.wrytte.com
```

---

## Tokens And Sessions

### Backend Auth Token

The backend auth token is stored in secure storage under:

```text
auth_token
auth_token_expiry
user_id
username
secret
phone
```

Current behavior:

- The app does not lock the user out only because the backend token expired.
- If local user data exists, the app lets the user enter.
- When active, the app immediately tries to refresh the backend token.
- If refresh succeeds, the new token replaces the old token in secure storage.
- If refresh fails because the device is offline or the backend is unavailable, the app keeps the old local session and continues with cached/local data.

Main code:

| File | Purpose |
|---|---|
| `lib/main.dart` | Auth gate lets local authenticated users into the app |
| `lib/services/auth/auth_service.dart` | Stores sessions, refreshes backend tokens, logs out |
| `lib/models/auth_models/auth_user.dart` | Authenticated when local `userId` or token exists |
| `lib/ui/screens/home_screen.dart` | Refreshes/checks backend token on app entry, resume, and tab movement |

Backend token refresh request:

```text
POST /auth/login
```

with saved `secret`, `phone`, and/or `userid`.

### Matrix Access Token

Matrix access token is stored in secure storage under:

```text
matrix_user_id
matrix_access_token
matrix_homeserver
matrix_device_id
```

Matrix login/register updates both secure storage and the live Matrix SDK client session.

Main code:

| File | Purpose |
|---|---|
| `lib/services/matrix/matrix_auth_service.dart` | Matrix login, register, restore, token validation, logout |
| `lib/services/matrix/matrix_client.dart` | Matrix SDK client and local SDK cache |
| `lib/services/chat/chat_service.dart` | Connects chat to the current Matrix session and retries on `M_UNKNOWN_TOKEN` |

If Matrix returns `M_UNKNOWN_TOKEN`, the app forces a fresh Matrix login and retries the failed chat operation once.

---

## Authentication Flow

1. User verifies phone/email through the Wrytte backend flow.
2. Backend returns user data, secret, backend token, and expiry when available.
3. App persists local session data in secure storage.
4. App logs into Matrix, or registers the Matrix user if needed.
5. Matrix access token is persisted in secure storage and loaded into the Matrix SDK client.
6. Home screen starts backend token refresh checks and optional backend WebSocket connection.
7. Chat service connects to Matrix sync and room timelines.

Development OTP code in the local fallback flow:

```text
112233
```

---

## Chat And Local Data

Wrytte keeps local cache for speed and offline access, but Matrix/Dendrite remains the server-side chat source of truth.

| Data | Local copy? | Source of truth |
|---|---|---|
| Matrix session | Yes, secure storage | Matrix/Dendrite |
| Recent Matrix rooms/timelines | Yes, Matrix SDK SQLite | Matrix/Dendrite |
| Recent Wrytte chat projections | Yes, `wrytte_chat.db` | Matrix/Dendrite |
| Media cache | Yes, bounded cache | Matrix media store |
| Full old history | Paginated on demand | Matrix/Dendrite |
| Saved contacts | Yes, local cache | Wrytte backend |
| Delete for me | Yes, local flag | Device-local only |
| Delete for everyone | Synced redaction | Matrix/Dendrite |

Recent chats can open from local cache first. If network is available, Matrix sync updates the cache and UI.

---

## Firebase Status

Firebase is still in the project, but it is not the main data layer.

Firebase packages currently listed:

```yaml
firebase_core
firebase_auth
firebase_storage
```

Current Firebase usage:

| Firebase service | Current use |
|---|---|
| Firebase Core | App initialization in `main.dart` |
| Firebase Auth | Anonymous auth helper/sign-out support in `AuthService` |
| Firebase Storage | Profile image upload in `edit_profile_screen.dart` |

Firebase is not used for Matrix chat messages, Matrix rooms, Matrix sync, read receipts, or Matrix access tokens.

---

## Key Files

| File | Purpose |
|---|---|
| `lib/main.dart` | App startup, Firebase init, auth gate |
| `lib/services/auth/api_service.dart` | Wrytte backend HTTP client |
| `lib/services/auth/auth_service.dart` | Backend auth session, token refresh, Matrix bootstrap, logout |
| `lib/services/auth/real_number_service.dart` | Phone/email backend registration/login flows |
| `lib/services/backend/backend_realtime_service.dart` | Optional FE-BE WebSocket client |
| `lib/services/matrix/matrix_config.dart` | Matrix homeserver/server config |
| `lib/services/matrix/matrix_auth_service.dart` | Matrix session lifecycle |
| `lib/services/matrix/matrix_client.dart` | Matrix SDK client and local SQLite cache |
| `lib/services/chat/chat_service.dart` | App chat service backed by Matrix |
| `lib/services/contacts/contact_backend_service.dart` | Backend saved-contact sync |
| `lib/services/contacts/contact_service.dart` | App contact flows |

---

## Getting Started

Install dependencies:

```bash
flutter pub get
```

Run the app:

```bash
flutter run
```

Run with Matrix and backend WebSocket defines:

```bash
flutter run \
  --dart-define=WRYTTE_MATRIX_HOMESERVER=https://matrix.wrytte.com \
  --dart-define=WRYTTE_MATRIX_SERVER_NAME=matrix.wrytte.com \
  --dart-define=WRYTTE_BACKEND_WS_URL=wss://your-backend-websocket-endpoint
```

Analyze:

```bash
flutter analyze
```

Note: this repository currently has existing analyzer warnings/infos, mostly deprecated `withOpacity` usage and unrelated lint cleanup.

---

## Common Debugging Notes

### Expired backend token logs user out

This should no longer happen. The app now allows local session entry and silently tries to refresh the backend token after entering.

### Offline with expired backend token

The app should still enter using local user/session data and cached content. Backend-only actions may wait/fail until network returns and token refresh succeeds.

### Matrix `M_UNKNOWN_TOKEN`

The chat service detects `M_UNKNOWN_TOKEN`, performs a fresh Matrix login with the saved secret/current user, updates the Matrix session, and retries the chat operation once.

### Firebase cleared but chats still appear

Expected. Chats come from Matrix/Dendrite and local Matrix cache, not Firebase.

### App cache cleared but chats return after login

Expected. Local cache can be rebuilt from Matrix after login and sync.
