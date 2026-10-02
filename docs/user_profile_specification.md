# Initial User Profile Specification

This is the initial contract for the Wrytte profile flow:

```text
Flutter -> Synapse Module API -> Matrix/Synapse profile data
```

## Profile fields

| Field | Type | Owner | Other users |
|---|---|---|---|
| Avatar | Matrix image URL | May edit/delete | Controlled by visibility |
| First name | Text | May edit/delete | May request/view |
| Last name | Text | May edit/delete | May request/view |
| Wrytte ID / phone number | Text or number | May edit/delete | Visibility logic defined later |
| Bio | Text | May edit/delete | Controlled by visibility |
| Link | URL/text | May edit/delete | Controlled by visibility |
| Channel | Channel alias | May edit/delete | May request/view |
| Group | Group alias | May edit/delete | May request/view |
| Online status | Matrix presence | Cannot edit directly | Controlled by visibility |

## Matrix custom field names

```text
com.wrytte.first_name
com.wrytte.last_name
com.wrytte.phone_number
com.wrytte.bio
com.wrytte.link
com.wrytte.channel_alias
com.wrytte.group_alias
```

Avatar uses Matrix's standard `avatar_url` field. Online status comes from Matrix presence and is not stored as an editable profile field.

## Visibility

Visibility is stored separately in `com.wrytte.profile_visibility`.

Supported values:

```text
everyone
contacts
approved_users
nobody
```

The initial default is `everyone`.

Example:

```json
{
  "com.wrytte.profile_visibility": {
    "avatar_url": "everyone",
    "bio": "everyone",
    "link": "everyone",
    "online": "everyone",
    "phone_number": "approved_users"
  }
}
```

## Access rules

1. Authenticate every request.
2. Identify the requesting Matrix user.
3. Allow the owner to create, update, and delete their own fields.
4. Allow other users to request a profile only through the profile module.
5. Apply the owner's visibility settings before returning another user's profile.
6. Never allow another user to modify the profile.
7. Return only fields permitted by the visibility rules.

## Synapse deployment on the Contabo server

This section describes the server work required before the Flutter app can use:

```text
Flutter -> /_synapse/client/wrytte/profile -> Synapse module -> Matrix profile storage
```

The standard Matrix profile API can store the fields above without a special database migration. The custom Python module is required because Wrytte wants a controlled gateway that authenticates requests and filters another user's profile before returning it.

### Required server components

The Contabo server must have:

1. A supported Linux distribution.
2. Synapse installed and running.
3. Python 3.10 or newer supported by the installed Synapse version.
4. HTTPS configured for the Matrix homeserver.
5. A reverse proxy such as Nginx or Caddy.
6. The Wrytte Synapse module installed into the same Python environment as Synapse.
7. A backup of `homeserver.yaml`, the module source, and the Synapse database.

Do not install the module into an unrelated system Python environment. The module must be importable by the Python interpreter used by the Synapse service.

### Recommended module layout

Use a dedicated directory on the Contabo server, for example:

```text
/opt/wrytte-synapse-module/
├── pyproject.toml
└── wrytte_profile/
    ├── __init__.py
    └── module.py
```

The module class must be importable using the path configured in Synapse:

```text
wrytte_profile.module.WrytteProfileModule
```

The module should register its resource during `__init__` using Synapse's `ModuleApi.register_web_resource()` method. Custom module resources should use the `/_synapse/client` namespace, not the `/_matrix/client` namespace.

Official references:

- [Synapse module configuration](https://element-hq.github.io/synapse/latest/usage/configuration/config_documentation.html#modules)
- [Writing a Synapse module](https://element-hq.github.io/synapse/latest/modules/writing_a_module.html)
- [Synapse installation](https://element-hq.github.io/synapse/latest/setup/installation.html)

### Install the module

If Synapse is installed in a virtual environment, use that environment:

```bash
sudo mkdir -p /opt/wrytte-synapse-module
sudo chown -R synapse:synapse /opt/wrytte-synapse-module

cd /opt/wrytte-synapse-module
sudo -u synapse /path/to/synapse/venv/bin/pip install -e .
```

If Synapse was installed from the Matrix.org Debian package, first identify the Python executable used by the service:

```bash
systemctl cat matrix-synapse
systemctl show matrix-synapse --property=ExecStart
```

Use the Python or `pip` belonging to that installation. Do not guess the path.

The module package should declare Synapse as a dependency only when the deployment process is designed to install it that way. A typical minimal `pyproject.toml` is:

```toml
[build-system]
requires = ["setuptools>=61"]
build-backend = "setuptools.build_meta"

[project]
name = "wrytte-synapse-module"
version = "0.1.0"
dependencies = []
```

Keep third-party dependencies to a minimum. The module should use Twisted and Synapse APIs already available in the Synapse environment.

### `homeserver.yaml` configuration

Add this top-level configuration. YAML indentation is significant:

```yaml
modules:
  - module: wrytte_profile.module.WrytteProfileModule
    config:
      path: /_synapse/client/wrytte/profile
      default_visibility: everyone
      allowed_fields:
        - avatar_url
        - com.wrytte.first_name
        - com.wrytte.last_name
        - com.wrytte.phone_number
        - com.wrytte.bio
        - com.wrytte.link
        - com.wrytte.channel_alias
        - com.wrytte.group_alias
        - com.wrytte.profile_visibility
```

If `modules:` already exists, add another list item. Do not create a second top-level `modules:` key.

The module configuration must not contain passwords, Matrix access tokens, or database credentials. Secrets belong in protected environment files or a secret manager.

No custom profile database migration is required for these fields. Synapse stores profile fields through the Matrix profile implementation. The module must not write directly to Synapse's private database tables.

### Required module endpoints

The module should expose the following resource beneath the configured path:

```text
GET    /_synapse/client/wrytte/profile/{user_id}
POST   /_synapse/client/wrytte/profile/{user_id}
PATCH  /_synapse/client/wrytte/profile/{user_id}
DELETE /_synapse/client/wrytte/profile/{user_id}/{field}
```

The `{user_id}` must be a fully-qualified Matrix ID such as `@alice:wrytte.com`. It must be URL-decoded and validated before use.

#### Owner GET

The authenticated owner may request their complete profile:

```http
GET /_synapse/client/wrytte/profile/@alice:wrytte.com
Authorization: Bearer <matrix-access-token>
```

The response may include all supported fields belonging to the owner.

#### Owner POST/PATCH

The owner may create or replace one or more fields:

```json
{
  "com.wrytte.first_name": "Alice",
  "com.wrytte.last_name": "Example",
  "com.wrytte.bio": "Hello",
  "com.wrytte.profile_visibility": {
    "bio": "everyone",
    "phone_number": "approved_users"
  }
}
```

`POST` and `PATCH` must only accept fields from the module's allow-list. Unknown fields must return `400 Bad Request`.

The module must compare the authenticated Matrix user ID with the target user ID. A user must never be able to update another user's profile through this endpoint.

#### Owner DELETE

The owner may delete one supported field:

```http
DELETE /_synapse/client/wrytte/profile/@alice:wrytte.com/com.wrytte.bio
Authorization: Bearer <matrix-access-token>
```

Deleting `avatar_url` must remove the avatar field. Online presence must not be deleted through this endpoint because it is not a profile field.

#### Public GET

Another user may request a profile:

```http
GET /_synapse/client/wrytte/profile/@alice:wrytte.com
Authorization: Bearer <bob-access-token>
```

The module must determine the requester from the validated Matrix access token, load Alice's visibility settings, and return only fields permitted for Bob. Flutter must not be trusted to perform this filtering.

### Authentication and authorization

The module must:

1. Require an `Authorization: Bearer` header.
2. Validate the access token using Synapse's supported module API/authentication context.
3. Reject missing or invalid tokens with `401 Unauthorized`.
4. Reject malformed Matrix IDs with `400 Bad Request`.
5. Permit owners to modify only their own profiles.
6. Permit other users to read only fields allowed by visibility rules.
7. Return `403 Forbidden` when the requester is not allowed to perform an operation.
8. Never log access tokens, profile phone numbers, or full profile bodies.

The module must not accept a user ID supplied in a request body as proof of identity. The authenticated requester must come from Synapse's authentication context.

### Visibility behavior

The module must interpret visibility values as follows:

| Value | Behavior |
|---|---|
| `everyone` | Return the field to any authenticated requester permitted to view profiles. |
| `contacts` | Return the field only when the requester is an approved Wrytte contact. |
| `approved_users` | Return the field only when the owner has explicitly approved the requester. |
| `nobody` | Return the field only to the owner. |

Unknown visibility values must be rejected when saved. If a field has no explicit visibility setting, the module uses `default_visibility`, initially `everyone`, except for sensitive fields such as phone number if Wrytte later changes that policy.

The module must return a consistent response shape and omit restricted fields rather than returning their values as `null`.

### Avatar and presence

`avatar_url` is a standard Matrix profile field and must contain an `mxc://` URI. An HTTP URL is not a valid Matrix avatar value unless the application separately converts it to Matrix media.

Online status must be read from Matrix presence and must not be written to `com.wrytte.profile_visibility` as a profile value. The owner may configure its visibility, but the actual status comes from Matrix presence (`online`, `offline`, or `unavailable`).

### Reverse proxy configuration

If Nginx terminates HTTPS, it must forward both Matrix and module requests to Synapse:

```nginx
location /_matrix/ {
    proxy_pass http://127.0.0.1:8008;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}

location /_synapse/ {
    proxy_pass http://127.0.0.1:8008;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}
```

The existing Matrix reverse-proxy configuration may already cover these paths. Verify it rather than adding duplicate locations.

The Synapse listener should normally remain bound to localhost, for example:

```yaml
listeners:
  - port: 8008
    bind_addresses: ['127.0.0.1']
    type: http
    x_forwarded: true
    resources:
      - names: [client, federation]
```

Do not expose port `8008` directly to the public internet when Nginx is handling TLS.

### Deployment procedure

Run the following procedure after backing up the existing configuration:

```bash
sudo cp /etc/matrix-synapse/homeserver.yaml \
  /etc/matrix-synapse/homeserver.yaml.$(date +%Y%m%d%H%M%S).backup

sudo systemctl stop matrix-synapse

# Install or update the module using Synapse's Python environment.
sudo -u synapse /path/to/synapse/venv/bin/pip install -e /opt/wrytte-synapse-module

# Edit homeserver.yaml and add the modules entry.
sudoedit /etc/matrix-synapse/homeserver.yaml

sudo nginx -t
sudo systemctl start matrix-synapse
sudo systemctl status matrix-synapse --no-pager
sudo journalctl -u matrix-synapse -n 200 --no-pager
```

If Synapse does not start, remove the new module entry or restore the configuration backup before investigating further. Never delete the Synapse database as a troubleshooting step.

### Verification checklist

Verify all of the following from a machine outside the Contabo server:

```bash
curl -i https://matrix.wrytte.com/_synapse/client/wrytte/profile/@alice:wrytte.com \
  -H 'Authorization: Bearer ACCESS_TOKEN'
```

Test that:

1. An owner can read their complete profile.
2. An owner can create each supported field.
3. An owner can replace each supported field.
4. An owner can delete each supported field.
5. Another user cannot modify the owner's profile.
6. Another user receives only fields allowed by visibility settings.
7. `nobody` fields are returned only to the owner.
8. Invalid fields are rejected.
9. Invalid tokens are rejected.
10. Online status is sourced from Matrix presence.
11. Avatar values are valid `mxc://` URIs.
12. Large payloads are rejected before they can consume excessive resources.

### Rate limits and payload limits

The module must enforce reasonable limits in addition to Synapse's normal HTTP limits:

- maximum complete profile payload: 64 KiB;
- maximum bio length: defined by Wrytte product requirements;
- maximum link length: defined by Wrytte product requirements;
- maximum aliases per field: one value initially;
- maximum request body size: reject oversized requests before parsing;
- rate-limit profile writes and public profile reads.

Do not store face embeddings, biometric templates, secrets, access tokens, or identity documents in Matrix profile fields.

### Logging and monitoring

Log only operational metadata:

```text
operation, requester Matrix ID, target Matrix ID, result status, duration
```

Never log:

```text
access tokens, phone numbers, profile bodies, biometric data
```

Monitor:

- Synapse service status;
- module import/startup errors;
- `401`, `403`, and `429` rates;
- profile endpoint latency;
- unexpected module exceptions;
- disk space and database health.

### Backups and rollback

Before deployment, back up:

- `homeserver.yaml`;
- the Synapse signing key;
- the module source and package metadata;
- the Synapse database;
- the media store if avatars are stored there;
- the reverse-proxy configuration.

To roll back the module:

1. Stop Synapse.
2. Remove the Wrytte `modules` entry.
3. Restore the previous reverse-proxy configuration if it was changed.
4. Start Synapse.
5. Confirm Matrix login, sync, profile reads, and federation.

Do not roll back by deleting profile data or directly editing Synapse's database.

### Current implementation status

The Flutter Matrix profile model and service are implemented in:

```text
lib/models/user_models/wrytte_profile.dart
lib/services/matrix/matrix_profile_service.dart
```

The Contabo deployment is not complete until the Python Synapse module exists, is installed into the Synapse environment, is configured in `homeserver.yaml`, and passes the verification checklist above.

## Contact list using Matrix account data

The Wrytte contact list should be stored as Matrix account data owned by the logged-in user.

```text
Flutter -> Matrix account-data API -> Synapse
```

This data is private to the account that created it. It is synchronized to that user's Matrix devices and is not automatically visible to the contact or to other users.

Do not store the contact list in another user's profile fields. Do not use room state for the personal contact list. Room state is shared with room members, while account data is user-specific.

### Contact fields

Each contact entry contains:

| Field | Type | Required | Description |
|---|---|---:|---|
| `user_id` | String | Yes | Fully-qualified Matrix user ID, for example `@alice:wrytte.com`. |
| `room_id` | String | No | Direct-message room ID, for example `!roomid:wrytte.com`. |
| `first_name` | String | No | Owner's local contact name or synchronized profile value. |
| `last_name` | String | No | Owner's local contact surname or synchronized profile value. |
| `number` | String | No | Phone number or Wrytte number. Store as a string to preserve `+`, leading zeroes, and formatting. |

The Matrix user ID is the stable identity key. Phone numbers must not be used as the primary key because they may change and may be private.

### Account-data event type

Use an application-namespaced account-data type:

```text
com.wrytte.contacts
```

The global account-data event should use this shape:

```json
{
  "version": 1,
  "contacts": [
    {
      "user_id": "@alice:wrytte.com",
      "room_id": "!example:wrytte.com",
      "first_name": "Alice",
      "last_name": "Example",
      "number": "+254700000000"
    }
  ]
}
```

The top-level `version` allows the schema to evolve without silently breaking older clients.

### Matrix API operations

Read the current user's contact list:

```http
GET /_matrix/client/v3/user/{user_id}/account_data/com.wrytte.contacts
Authorization: Bearer <matrix-access-token>
```

Write or replace the complete contact list:

```http
PUT /_matrix/client/v3/user/{user_id}/account_data/com.wrytte.contacts
Authorization: Bearer <matrix-access-token>
Content-Type: application/json

{
  "version": 1,
  "contacts": []
}
```

Account data is replaced atomically for that event type. The Flutter client must read the current value, apply the local change, and write the updated document.

The authenticated Matrix user may only read or write account data for their own user ID. The client must not attempt to modify another user's account data.

### Contact operations in Flutter

The Flutter contact repository should expose:

```text
getContacts()
addContact(contact)
updateContact(userId, changes)
removeContact(userId)
findContact(userId)
replaceContacts(contacts)
```

The repository must:

1. Load `com.wrytte.contacts` after Matrix login and initial sync.
2. Treat a missing account-data event as an empty contact list.
3. Validate every entry before saving.
4. Deduplicate entries by `user_id`.
5. Preserve the latest known `room_id` when a direct room is resolved.
6. Write the complete updated document back to Matrix.
7. Refresh the local cache after a successful write.
8. Reload the account data after another device changes it.
9. Never write a contact belonging to a different account.

### Validation rules

Each contact must satisfy:

```text
user_id: valid fully-qualified Matrix user ID
room_id: empty or valid Matrix room ID beginning with !
first_name: maximum length defined by product requirements
last_name: maximum length defined by product requirements
number: string, normalized for comparison but preserve display formatting if required
```

Reject duplicate `user_id` values. Empty contact objects and malformed Matrix IDs must not be persisted.

Phone numbers should be normalized to a canonical form for lookup, normally E.164 format, for example:

```text
+254700000000
```

The number must still be stored as a JSON string, never as a JSON number.

### Ownership and privacy

Account data belongs to the logged-in Matrix account. It is not a public directory and must not be returned through the Wrytte public-profile endpoint.

If another user needs to know whether they are in the owner's contact list, do not expose the account-data event directly. Implement a separate, explicit server-side operation with a narrowly defined response. In the normal case, the answer should remain private.

The contact's public profile must still be fetched through the profile flow and filtered by the profile visibility rules. A local contact entry does not automatically grant permission to see restricted profile fields unless Wrytte's server-side authorization policy explicitly defines contacts as an approved relationship.

### Direct-message room association

`room_id` is an optional association between a contact and a direct Matrix room. It is not the identity of the contact.

When opening a direct chat:

1. Resolve the contact's `user_id`.
2. Reuse the stored `room_id` if it is still a valid direct room.
3. Otherwise find or create the direct room through Matrix.
4. Save the resulting room ID back into `com.wrytte.contacts`.
5. If the room is left, forgotten, or replaced, clear or update the stored `room_id`.

For group rooms, do not store the group room as a personal contact's `room_id`. Store group relationships separately because a contact may belong to multiple groups or rooms.

### Account-data synchronization

The Matrix sync response delivers global account data in:

```text
account_data.events
```

The Flutter Matrix sync layer should listen for the `com.wrytte.contacts` event and update the local contact cache. Changes from another device must not overwrite unsaved local changes without conflict handling.

For the first implementation, use last-write-wins with a local write queue. A later version may add a document revision or per-contact timestamps.

Recommended local metadata:

```json
{
  "version": 1,
  "contacts": [],
  "updated_at": "2026-10-01T00:00:00Z"
}
```

`updated_at` is local synchronization metadata and does not need to be included in the Matrix account-data document unless the conflict strategy requires it.

### Synapse configuration for contacts

No custom Synapse module or database migration is required for the basic contact list. Matrix account data is supported by the standard Client-Server API.

The existing Synapse listener and reverse proxy must already allow the standard client API path:

```text
/_matrix/client/v3/user/{user_id}/account_data/com.wrytte.contacts
```

The Wrytte profile module must not proxy or duplicate contact account data unless product requirements later require server-side contact search, contact approval, or privacy enforcement.

If a module is later used for contact operations, it must still preserve these rules:

1. Authenticate the Matrix access token.
2. Allow account-data access only for the authenticated user's own user ID.
3. Never return another user's complete contact list.
4. Never log contact phone numbers or the complete contact document.
5. Use the Matrix account-data API or supported Synapse APIs rather than direct database writes.

### Contact-list verification checklist

Verify that:

1. A logged-in user can create an empty contact list.
2. A user can add a contact with a Matrix user ID.
3. A user can update the contact's name or number.
4. A user can associate and update a direct room ID.
5. A user can remove a contact.
6. Duplicate Matrix user IDs are rejected or merged.
7. A second device receives the updated account data through `/sync`.
8. A missing account-data event produces an empty list.
9. A user cannot read another user's account data.
10. Contact data is not included in public profile responses.
11. Malformed Matrix IDs and room IDs are rejected.
12. Phone numbers are stored as strings and are not exposed through logs.
