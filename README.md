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
| User profile metadata | Firestore `users` documents: `uid`, name, username, phone, profile image fields, `matrixUserId`, and `matrixHomeserver` |
| App auth bootstrap | Anonymous Firebase Auth so the app can read/write permitted Firestore data |
| Contact metadata | Saved contacts, contact display names, contact avatars, and Firestore-backed contact lookup |
| Profile edits | Name/avatar/profile metadata updates after signup and from edit profile flows |
| File/profile storage | Firebase Storage for app profile images and non-Matrix assets |
| Call/supporting app state | Firestore documents used by non-message app features |

Firebase should not be treated as the chat database. If Firestore has no `chats` collection, that is expected for the active Matrix-backed flow.

---

## Matrix vs Firebase Boundary

| Question | Answer |
|---|---|
| Where do chat messages come from? | Matrix rooms and Matrix room timelines |
| Where are conversations listed from? | Matrix rooms, then enriched with Firestore contact/profile metadata |
| Where are unread counts/read markers from? | Matrix room state |
| Where are saved contact names from? | Firestore contact/user documents |
| Where are profile names and avatars stored? | Firestore/Firebase Storage for Wrytte profile metadata, with selected Matrix profile fields also updated |
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

By default, Matrix auth uses this homeserver:

```dart
https://matrix.org
```

You can override it at build time with:

```bash
flutter run --dart-define=WRYTTE_MATRIX_HOMESERVER=https://your-homeserver.example
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
cloud_firestore
firebase_storage
```

Firestore profile/contact data is used to make Matrix rooms feel like Wrytte conversations. For example, a Matrix direct room may provide the room and events, while Firestore supplies the saved contact name, username, phone metadata, or profile image shown in the UI.

---

## Authentication Flow

1. The app creates or restores a local Wrytte auth session.
2. Firebase anonymous auth is ensured so Firestore profile/contact documents can be read and written.
3. A Firestore `users/{uid}` document is created or updated with Wrytte metadata.
4. The app logs into Matrix, or registers the Matrix account if login fails.
5. Matrix identity fields such as `matrixUserId` and `matrixHomeserver` are merged back into the Firestore user document.
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
flutter run --dart-define=WRYTTE_MATRIX_HOMESERVER=https://your-homeserver.example
```

---

## Quick Reference

| Need | Use |
|---|---|
| Chat messages and history | Matrix |
| Direct chat rooms | Matrix |
| Realtime message sync | Matrix |
| Message local cache | Matrix SDK SQLite cache |
| User profiles | Firebase Firestore |
| Saved contacts | Firebase Firestore |
| Profile images | Firebase Storage / profile metadata |
| Firebase login state | Firebase Auth |
| Matrix login state | Matrix secure storage keys |
