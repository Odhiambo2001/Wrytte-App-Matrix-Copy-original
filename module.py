import json
import logging
import os
import time
from urllib.parse import parse_qsl, quote, unquote, urlencode, urlsplit, urlunsplit

import psycopg2
from psycopg2.extras import Json
from twisted.web.resource import Resource
from twisted.web.server import NOT_DONE_YET

from synapse.module_api import ModuleApi, run_in_background


ALLOWED_FIELDS = {
    "com.wrytte.avatar_image_url",
    "com.wrytte.avatar_version",
    "com.wrytte.first_name",
    "com.wrytte.last_name",
    "com.wrytte.phone_number",
    "com.wrytte.bio",
    "com.wrytte.link",
    "com.wrytte.channel_alias",
    "com.wrytte.group_alias",
}

PHONE_FIELD = "com.wrytte.phone_number"
AVATAR_FIELD = "com.wrytte.avatar_image_url"
AVATAR_VERSION_FIELD = "com.wrytte.avatar_version"
BIO_FIELD = "com.wrytte.bio"
ONLINE_VISIBILITY_FIELD = "com.wrytte.online_status"
CONTACTS_ACCOUNT_DATA_TYPE = "com.wrytte.contacts"
BLOCKLIST_ACCOUNT_DATA_TYPE = "com.wrytte.blocklist"
BBB_ACCOUNT_DATA_TYPE = "com.wrytte.bbb"
BLOCKED_MESSAGES_ACCOUNT_DATA_TYPE = "com.wrytte.blockedmsg"
PROFILE_UPDATED_EVENT = "com.wrytte.profile.updated"
VISIBILITY_FIELDS = ALLOWED_FIELDS - {AVATAR_VERSION_FIELD}

VISIBILITY_VALUES = {
    "everyone",
    "contacts",
    "approved_users",
    "nobody",
}
logger = logging.getLogger(__name__)


class ProfileError(Exception):
    def __init__(self, message, status=400):
        super().__init__(message)
        self.status = status


class ProfileResource(Resource):
    isLeaf = True

    def __init__(self, module, target_user_id):
        super().__init__()
        self.module = module
        self.target_user_id = target_user_id

    def _reply(self, request, status, payload):
        body = json.dumps(payload).encode("utf-8")
        request.setResponseCode(status)
        request.setHeader(b"Content-Type", b"application/json")
        request.setHeader(b"Cache-Control", b"no-store")
        request.write(body)
        request.finish()

    def _execute(self, request, operation):
        async def run():
            try:
                requester = await self.module.api.get_user_by_req(request)
                requester_id = requester.user.to_string()
                result = await operation(requester_id, requester)
                self._reply(request, 200, result)
            except ProfileError as error:
                self._reply(request, error.status, {"error": str(error)})
            except Exception as error:
                message = str(error)
                status = (
                    401 if message.startswith("401:")
                    else 403 if message.startswith("403:")
                    else 500
                )
                self._reply(request, status, {"error": message})

        run_in_background(run)
        return NOT_DONE_YET

    def _read_json(self, request, method=None):
        raw = request.content.read()
        if not raw:
            return {}
        try:
            payload = json.loads(raw.decode("utf-8"))
            if not isinstance(payload, dict):
                raise ProfileError("Request body must be a JSON object.", 400)
            if method:
                payload["_http_method"] = method
            return payload
        except json.JSONDecodeError:
            raise ProfileError("Request body must be valid JSON.", 400)

    def render_GET(self, request):
        return self._execute(
            request,
            lambda requester_id, requester: self.module.get_profile(
                requester_id,
                self.target_user_id,
                requester,
            ),
        )

    def render_POST(self, request):
        return self._execute(
            request,
            lambda requester_id, requester: self.module.update_profile(
                requester_id,
                self.target_user_id,
                self._read_json(request, "POST"),
                replace=False,
                requester=requester,
            ),
        )

    def render_PATCH(self, request):
        return self._execute(
            request,
            lambda requester_id, requester: self.module.update_profile(
                requester_id,
                self.target_user_id,
                self._read_json(request, "PATCH"),
                replace=False,
                requester=requester,
            ),
        )

    def render_PUT(self, request):
        return self._execute(
            request,
            lambda requester_id, requester: self.module.update_profile(
                requester_id,
                self.target_user_id,
                self._read_json(request, "PUT"),
                replace=True,
                requester=requester,
            ),
        )

    def render_DELETE(self, request):
        field = request.args.get(b"field", [b""])[0].decode("utf-8")
        return self._execute(
            request,
            lambda requester_id, requester: self.module.delete_field(
                requester_id,
                self.target_user_id,
                field,
                requester=requester,
            ),
        )


class ProfileRoot(Resource):
    def __init__(self, module):
        super().__init__()
        self.module = module

    def getChild(self, path, request):
        return ProfileResource(
            self.module,
            unquote(path.decode("utf-8")),
        )


class RecoveryResource(Resource):
    isLeaf = True

    def __init__(self, module):
        super().__init__()
        self.module = module

    def render_POST(self, request):
        async def run():
            try:
                requester = await self.module.api.get_user_by_req(request)
                raw = request.content.read()
                payload = json.loads(raw.decode("utf-8")) if raw else {}
                result = await self.module.recover_blocked_messages(
                    requester.user.to_string(),
                    payload,
                )
                body = json.dumps(result).encode("utf-8")
                request.setResponseCode(200)
                request.setHeader(b"Content-Type", b"application/json")
                request.write(body)
            except ProfileError as error:
                request.setResponseCode(error.status)
                request.write(json.dumps({"error": str(error)}).encode("utf-8"))
            except Exception as error:
                logger.exception("Blocked-message recovery failed")
                request.setResponseCode(500)
                request.write(json.dumps({"error": str(error)}).encode("utf-8"))
            finally:
                request.finish()

        run_in_background(run)
        return NOT_DONE_YET


class WrytteProfileModule:
    def __init__(self, config, api: ModuleApi):
        self.api = api
        self.default_visibility = config.get(
            "default_visibility",
            "everyone",
        )

        self.db_host = os.getenv("WRYTTE_PROFILE_DB_HOST", "profile-db")
        self.db_port = int(os.getenv("WRYTTE_PROFILE_DB_PORT", "5432"))
        self.db_name = os.environ["POSTGRES_DB"]
        self.db_user = os.environ["POSTGRES_USER"]
        self.db_password = os.environ["POSTGRES_PASSWORD"]

        path = config.get(
            "path",
            "/_synapse/client/wrytte/profile",
        )

        api.register_web_resource(path, ProfileRoot(self))
        api.register_web_resource(
            "/_synapse/client/wrytte/blocked-messages/recover",
            RecoveryResource(self),
        )
        # Wrytte presence visibility replaces Synapse's default shared-room
        # fan-out. The callbacks below return only users allowed by the owner's
        # visibility setting.
        api.register_presence_router_callbacks(
            get_users_for_states=self.get_users_for_presence_states,
            get_interested_users=self.get_presence_users_for_viewer,
            exclusive=True,
        )

    def _connection(self):
        return psycopg2.connect(
            host=self.db_host,
            port=self.db_port,
            dbname=self.db_name,
            user=self.db_user,
            password=self.db_password,
        )

    async def _db(self, function):
        def execute():
            connection = self._connection()
            try:
                return function(connection)
            finally:
                connection.close()

        # Use Synapse's context-aware threadpool wrapper. Twisted's raw
        # deferToThread can resume this coroutine with the wrong log context,
        # which leaks request contexts into reactor timers.
        threadpool = self.api._hs.get_reactor().getThreadPool()
        return await self.api.defer_to_threadpool(threadpool, execute)

    async def recover_blocked_messages(self, requester_id, payload):
        if not isinstance(payload, dict):
            raise ProfileError("Request body must be a JSON object.", 400)
        room_id = str(payload.get("room_id") or "").strip()
        messages = payload.get("messages")
        if not room_id or not isinstance(messages, list):
            raise ProfileError("room_id and messages are required.", 400)

        store = self.api._hs.get_datastores().main
        bbb = await store.get_global_account_data_by_type_for_user(
            requester_id, BBB_ACCOUNT_DATA_TYPE
        )
        bbb_entries = bbb.get("entries", []) if isinstance(bbb, dict) else []
        if any(
            isinstance(entry, dict)
            and str(entry.get("room_id") or "").strip() == room_id
            for entry in bbb_entries
        ):
            raise ProfileError("The conversation is still blocked.", 403)

        blocked_data = await store.get_global_account_data_by_type_for_user(
            requester_id, BLOCKED_MESSAGES_ACCOUNT_DATA_TYPE
        )
        blocked_entries = (
            blocked_data.get("entries", [])
            if isinstance(blocked_data, dict)
            else []
        )
        stored_by_id = {
            str(entry.get("blocked_message_id") or entry.get("event_id") or "").strip(): entry
            for entry in blocked_entries
            if isinstance(entry, dict)
        }

        valid = []
        for message in messages:
            if not isinstance(message, dict):
                continue
            blocked_id = str(
                message.get("blocked_message_id") or message.get("event_id") or ""
            ).strip()
            text = str(message.get("text") or "")
            if not blocked_id or not text:
                continue
            sequence = int(message.get("sequence") or 0)
            timestamp = str(message.get("time") or "")
            stored = stored_by_id.get(blocked_id)
            if (
                not isinstance(stored, dict)
                or str(stored.get("room_id") or "").strip() != room_id
                or str(stored.get("text") or "") != text
                or str(stored.get("time") or "") != timestamp
            ):
                raise ProfileError(
                    "Blocked message does not belong to the authenticated user.",
                    403,
                )
            valid.append((sequence, timestamp, blocked_id, text))
        valid.sort(key=lambda item: (item[0], item[1], item[2]))

        recovered = []
        for sequence, timestamp, blocked_id, text in valid:
            claimed = await self._claim_recovery(
                requester_id, room_id, blocked_id, sequence, timestamp, text
            )
            if not claimed:
                continue
            result = await self.api.create_and_send_event_into_room(
                {
                    "type": "m.room.message",
                    "room_id": room_id,
                    "sender": requester_id,
                    "content": {"msgtype": "m.text", "body": text},
                }
            )
            recovered.append({
                "blocked_message_id": blocked_id,
                "event_id": result,
                "status": "recovered",
            })
        return {"room_id": room_id, "messages": recovered}

    async def _claim_recovery(
        self, sender, room_id, blocked_id, sequence, timestamp, text
    ):
        def claim(connection):
            with connection.cursor() as cursor:
                cursor.execute(
                    """
                    CREATE TABLE IF NOT EXISTS wrytte_recovered_messages (
                        sender TEXT NOT NULL,
                        room_id TEXT NOT NULL,
                        blocked_message_id TEXT NOT NULL,
                        sequence BIGINT NOT NULL,
                        sent_time TEXT NOT NULL,
                        body TEXT NOT NULL,
                        created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
                        PRIMARY KEY (sender, room_id, blocked_message_id)
                    )
                    """
                )
                cursor.execute(
                    """
                    INSERT INTO wrytte_recovered_messages
                        (sender, room_id, blocked_message_id, sequence, sent_time, body)
                    VALUES (%s, %s, %s, %s, %s, %s)
                    ON CONFLICT (sender, room_id, blocked_message_id) DO NOTHING
                    RETURNING blocked_message_id
                    """,
                    (sender, room_id, blocked_id, sequence, timestamp, text),
                )
                inserted = cursor.fetchone() is not None
            connection.commit()
            return inserted

        return await self._db(claim)

    def _require_owner(self, requester_id, target_user_id):
        if requester_id != target_user_id:
            raise ProfileError(
                "Only the profile owner may modify this profile.",
                403,
            )

    async def _read_document(self, user_id):
        def query(connection):
            with connection.cursor() as cursor:
                cursor.execute(
                    """
                    SELECT fields, visibility, updated_at
                    FROM profile_documents
                    WHERE matrix_user_id = %s
                    """,
                    (user_id,),
                )
                row = cursor.fetchone()

                if row is None:
                    return {}, {}

                fields = row[0] or {}
                visibility = row[1] or {}
                updated_at = row[2]

                # Older profile rows predate cache versions. Seed a stable,
                # unique version from the row timestamp so existing clients
                # stop reusing the old `v=0` avatar cache entry. Persist it
                # once so unrelated profile edits do not change the version.
                if fields.get(AVATAR_FIELD) and not self._valid_avatar_version(
                    fields.get(AVATAR_VERSION_FIELD)
                ):
                    updated_at_seconds = (
                        updated_at.timestamp()
                        if updated_at is not None
                        else time.time()
                    )
                    version = max(1, int(updated_at_seconds * 1_000_000))
                    version_field = {AVATAR_VERSION_FIELD: str(version)}
                    cursor.execute(
                        """
                        UPDATE profile_documents
                        SET fields = fields || %s
                        WHERE matrix_user_id = %s
                          AND COALESCE(fields ->> %s, '') = %s
                        """,
                        (
                            Json(version_field),
                            user_id,
                            AVATAR_VERSION_FIELD,
                            str(fields.get(AVATAR_VERSION_FIELD) or ""),
                        ),
                    )
                    connection.commit()
                    fields = {**fields, **version_field}

                return fields, visibility

        return await self._db(query)

    @staticmethod
    def _valid_avatar_version(value):
        try:
            return int(value) >= 0
        except (TypeError, ValueError):
            return False

    @classmethod
    def _avatar_version(cls, fields):
        value = fields.get(AVATAR_VERSION_FIELD)
        return int(value) if cls._valid_avatar_version(value) else 0

    @staticmethod
    def _version_avatar_url(url, version):
        value = str(url or "").strip()
        parsed = urlsplit(value)
        if parsed.scheme not in {"http", "https", "mxc"}:
            return value
        query = [
            (key, item)
            for key, item in parse_qsl(parsed.query, keep_blank_values=True)
            if key.lower() != "v"
        ]
        query.append(("v", str(version)))
        return urlunsplit(parsed._replace(query=urlencode(query)))

    async def _contacts_for_user(self, owner_user_id):
        try:
            store = self.api._hs.get_datastores().main
            data = await store.get_global_account_data_by_type_for_user(
                owner_user_id,
                CONTACTS_ACCOUNT_DATA_TYPE,
            )
        except Exception:
            logger.exception("Could not read Wrytte contacts owner=%s", owner_user_id)
            return set()

        contacts = data.get("contacts", []) if isinstance(data, dict) else []
        domain = owner_user_id.split(":", 1)[1] if ":" in owner_user_id else ""
        recipients = set()
        for contact in contacts if isinstance(contacts, list) else []:
            if not isinstance(contact, dict):
                continue
            identity = str(
                contact.get("matrixUserId")
                or contact.get("userId")
                or contact.get("wrytteUserId")
                or ""
            ).strip()
            if identity.startswith("@") and ":" in identity:
                matrix_user_id = identity
            else:
                localpart = identity.lstrip("@").split(":", 1)[0]
                matrix_user_id = f"@{localpart}:{domain}" if localpart and domain else ""
            if matrix_user_id and matrix_user_id != owner_user_id:
                recipients.add(matrix_user_id)
        return recipients

    async def _approved_users_for(self, owner_user_id):
        def query(connection):
            with connection.cursor() as cursor:
                cursor.execute(
                    """
                    SELECT approved_matrix_user_id
                    FROM profile_approvals
                    WHERE owner_matrix_user_id = %s
                    """,
                    (owner_user_id,),
                )
                return {row[0] for row in cursor.fetchall()}

        return await self._db(query)

    async def _presence_rule(self, owner_user_id):
        _, visibility = await self._read_document(owner_user_id)
        return visibility.get(ONLINE_VISIBILITY_FIELD, self.default_visibility)

    async def _joined_room_users(self, owner_user_id):
        store = self.api._hs.get_datastores().main
        room_ids = await store.get_rooms_for_user(owner_user_id)
        excluded_rooms = set(
            getattr(
                self.api._hs.config.server,
                "rooms_to_exclude_from_presence",
                (),
            )
        )
        users = set()
        for room_id in room_ids:
            if room_id in excluded_rooms:
                continue
            users.update(await store.get_users_in_room(room_id) or [])
        return users

    async def _presence_recipients(self, owner_user_id, rule=None):
        if rule is None:
            rule = await self._presence_rule(owner_user_id)
        if rule == "everyone":
            return await self._joined_room_users(owner_user_id)
        if rule == "contacts":
            allowed = await self._contacts_for_user(owner_user_id)
        elif rule == "approved_users":
            allowed = await self._approved_users_for(owner_user_id)
        else:
            return set()
        return allowed & await self._joined_room_users(owner_user_id)

    async def get_users_for_presence_states(self, state_updates):
        """Route presence updates only to recipients allowed by Wrytte settings."""
        users_to_states = {}
        for state in state_updates:
            rule = await self._presence_rule(state.user_id)
            recipients = await self._presence_recipients(state.user_id, rule)
            # A user must always retain access to their own presence state.
            recipients.add(state.user_id)
            logger.info(
                "Wrytte presence route user=%s state=%s visibility=%s recipients=%d",
                state.user_id,
                state.state,
                rule,
                len(recipients),
            )
            for recipient in recipients:
                users_to_states.setdefault(recipient, set()).add(state)
        return users_to_states

    async def get_presence_users_for_viewer(self, viewer_user_id):
        """Return room-sharing users whose current visibility permits this viewer."""
        store = self.api._hs.get_datastores().main
        room_ids = await store.get_rooms_for_user(viewer_user_id)
        excluded_rooms = set(
            getattr(
                self.api._hs.config.server,
                "rooms_to_exclude_from_presence",
                (),
            )
        )
        candidates = set()
        for room_id in room_ids:
            if room_id in excluded_rooms:
                continue
            candidates.update(await store.get_users_in_room(room_id) or [])

        # Own presence remains visible independently of the profile setting.
        allowed = {viewer_user_id}
        for owner_user_id in candidates:
            rule = await self._presence_rule(owner_user_id)
            if rule == "everyone":
                allowed.add(owner_user_id)
            elif rule == "contacts":
                if viewer_user_id in await self._contacts_for_user(owner_user_id):
                    allowed.add(owner_user_id)
            elif rule == "approved_users":
                if viewer_user_id in await self._approved_users_for(owner_user_id):
                    allowed.add(owner_user_id)
        return allowed

    async def _recipients_for_visibility(self, user_id, field, visibility):
        rule = visibility.get(field, self._default_visibility_for(field))
        if rule == "contacts":
            return await self._contacts_for_user(user_id), False
        if rule == "approved_users":
            return await self._approved_users_for(user_id), False
        if rule == "everyone":
            return set(), True
        return set(), False

    async def _notify_joined_rooms_profile_changed(
        self,
        user_id,
        changed_fields,
        old_visibility,
        new_visibility,
        requester,
    ):
        """Send data-free refresh signals only to viewers allowed by settings.

        Everyone-visible changes use room events. Contacts/approved-users
        changes use Matrix to-device events. The event contains no profile data;
        recipients must GET the Module resource, which filters every field.
        """
        recipients = set()
        notify_joined_rooms = False
        for field in changed_fields:
            previous, everyone_before = await self._recipients_for_visibility(
                user_id, field, old_visibility
            )
            current, everyone_after = await self._recipients_for_visibility(
                user_id, field, new_visibility
            )
            recipients.update(previous)
            recipients.update(current)
            notify_joined_rooms |= everyone_before or everyone_after

        # Always refresh the profile owner's own logged-in devices as well.
        # This is important when an owner changes a profile through an API
        # client (for example Insomnia) while the Wrytte app is open: the
        # owner may not be included in the audience selected by visibility.
        recipients.add(user_id)

        content = {"user_id": user_id, "revision": str(time.time_ns())}
        if notify_joined_rooms:
            try:
                store = self.api._hs.get_datastores().main
                room_ids = await store.get_rooms_for_user(user_id)
            except Exception:
                logger.exception("Could not list joined rooms for profile update user=%s", user_id)
                room_ids = []
            for room_id in room_ids:
                try:
                    await self.api.create_and_send_event_into_room(
                        {
                            "type": PROFILE_UPDATED_EVENT,
                            "room_id": room_id,
                            "sender": user_id,
                            "content": content,
                        }
                    )
                except Exception:
                    logger.exception(
                        "Could not send profile refresh signal user=%s room=%s",
                        user_id,
                        room_id,
                    )

        if recipients:
            try:
                device_handler = self.api._hs.get_device_message_handler()
                await device_handler.send_device_message(
                    requester,
                    PROFILE_UPDATED_EVENT,
                    {
                        recipient: {"*": content}
                        for recipient in recipients
                        if await self.api.check_user_exists(recipient) is not None
                    },
                )
            except Exception:
                # Profile writes remain successful even if a client signal fails.
                logger.exception("Could not send targeted profile signals user=%s", user_id)

    async def _is_blocked_by_owner(self, owner_user_id, requester_id):
        try:
            store = self.api._hs.get_datastores().main
            data = await store.get_global_account_data_by_type_for_user(
                owner_user_id,
                BLOCKLIST_ACCOUNT_DATA_TYPE,
            )
        except Exception:
            logger.exception(
                "Could not read blocklist owner=%s",
                owner_user_id,
            )
            return False

        if not isinstance(data, dict):
            return False

        entries = data.get("entries")
        if not isinstance(entries, list):
            entries = data.get("blocklist", [])

        for entry in entries:
            if not isinstance(entry, dict):
                continue

            blocked_user_id = str(
                entry.get("user_id")
                or entry.get("blocked_user_id")
                or ""
            ).strip()

            if blocked_user_id == requester_id:
                return True

        return False

    async def get_profile(self, requester_id, target_user_id, requester):
        if await self.api.check_user_exists(target_user_id) is None:
            raise ProfileError("Matrix user does not exist.", 404)
        fields, visibility = await self._read_document(target_user_id)
        requester_is_blocked = (
            requester_id != target_user_id
            and await self._is_blocked_by_owner(
                target_user_id,
                requester_id,
            )
        )

        if requester_id == target_user_id:
            visible_fields = dict(fields)
        elif requester_is_blocked:
            visible_fields = {
                field: fields[field]
                for field in (
                    "com.wrytte.first_name",
                    "com.wrytte.last_name",
                    PHONE_FIELD,
                )
                if field in fields
            }
            visibility = {}
        else:
            visible_fields = {}

            for field, value in fields.items():
                if await self._can_view_field(
                    target_user_id,
                    requester_id,
                    field,
                    visibility,
                ):
                    visible_fields[field] = value

        # The custom Wrytte field is the sole avatar source. Add the Module's
        # authoritative revision to the media URL so clients never retain an
        # older image when the storage path is reused.
        if visible_fields.get(AVATAR_FIELD):
            visible_fields[AVATAR_FIELD] = self._version_avatar_url(
                visible_fields[AVATAR_FIELD],
                self._avatar_version(fields),
            )

        # The profile stores channel/group room IDs as custom fields. Return
        # their joined-member counts alongside those visible fields so clients
        # do not derive counts from incomplete local membership state or stale
        # room summaries. Counts follow the same per-field visibility decision.
        room_counts = {}
        try:
            store = self.api._hs.get_datastores().main
            for field, count_key in (
                ("com.wrytte.channel_alias", "channel"),
                ("com.wrytte.group_alias", "group"),
            ):
                room_id = visible_fields.get(field)
                if not isinstance(room_id, str) or not room_id.startswith("!"):
                    continue
                try:
                    joined_users = await store.get_users_in_room(room_id)
                    room_counts[count_key] = {
                        "room_id": room_id,
                        "joined": len(set(joined_users or [])),
                    }
                except Exception:
                    logger.exception(
                        "Could not read joined member count user=%s room=%s",
                        target_user_id,
                        room_id,
                    )
        except Exception:
            logger.exception(
                "Could not access room membership store for profile user=%s",
                target_user_id,
            )

        # Compose the display name from independently filtered custom fields.
        # Returning Matrix's global displayname here could reveal a last name
        # whose own visibility rule denies this requester.
        display_name = " ".join(
            value.strip()
            for value in (
                visible_fields.get("com.wrytte.first_name", ""),
                visible_fields.get("com.wrytte.last_name", ""),
            )
            if isinstance(value, str) and value.strip()
        ) or None

        # Log only field presence and the visibility decision, never profile
        # values or media URLs. This distinguishes missing data from filtering.
        logger.info(
            "Wrytte profile GET target=%s requester=%s owner=%s "
            "avatar_field_stored=%s "
            "avatar_rule=%s avatar_allowed=%s avatar_returned=%s "
            "avatar_version=%s "
            "bio_stored=%s bio_rule=%s bio_allowed=%s bio_returned=%s",
            target_user_id,
            requester_id,
            requester_id == target_user_id,
            bool(fields.get(AVATAR_FIELD)),
            visibility.get(AVATAR_FIELD, self._default_visibility_for(AVATAR_FIELD)),
            requester_id == target_user_id or AVATAR_FIELD in visible_fields,
            bool(visible_fields.get(AVATAR_FIELD)),
            visible_fields.get(AVATAR_VERSION_FIELD),
            bool(fields.get(BIO_FIELD)),
            visibility.get(BIO_FIELD, self._default_visibility_for(BIO_FIELD)),
            requester_id == target_user_id or await self._can_view_field(
                target_user_id,
                requester_id,
                BIO_FIELD,
                visibility,
            ),
            bool(visible_fields.get(BIO_FIELD)),
        )

        return {
            "user_id": target_user_id,
            "fields": visible_fields,
            "room_counts": room_counts,
            "visibility": (
                {
                    field: visibility.get(field, self._default_visibility_for(field))
                    for field in VISIBILITY_FIELDS | {ONLINE_VISIBILITY_FIELD}
                }
                if requester_id == target_user_id
                else {}
            ),
            "displayname": display_name,
        }

    def _default_visibility_for(self, field):
        return self.default_visibility

    async def _can_view_field(
        self,
        owner_user_id,
        requester_id,
        field,
        visibility,
    ):
        if requester_id == owner_user_id:
            return True

        if field == AVATAR_VERSION_FIELD:
            field = AVATAR_FIELD

        # Profile data is returned only when its visibility rule allows it.
        default = self._default_visibility_for(field)
        rule = visibility.get(field, default)
        if rule == "everyone":
            return True
        if rule == "approved_users":
            def approval_query(connection):
                with connection.cursor() as cursor:
                    cursor.execute(
                        """
                        SELECT EXISTS (
                            SELECT 1 FROM profile_approvals
                            WHERE owner_matrix_user_id = %s
                              AND approved_matrix_user_id = %s
                        )
                        """,
                        (owner_user_id, requester_id),
                    )
                    return cursor.fetchone()[0]

            return await self._db(approval_query)
        if rule == "contacts":
            try:
                store = self.api._hs.get_datastores().main
                data = await store.get_global_account_data_by_type_for_user(
                    owner_user_id,
                    CONTACTS_ACCOUNT_DATA_TYPE,
                )
            except Exception:
                return False
            contacts = data.get("contacts", []) if isinstance(data, dict) else []
            requester_localpart = requester_id.split(":", 1)[0].lstrip("@").lower()
            for contact in contacts if isinstance(contacts, list) else []:
                if not isinstance(contact, dict):
                    continue
                identity = str(
                    contact.get("userId")
                    or contact.get("wrytteUserId")
                    or contact.get("matrixUserId")
                    or ""
                ).strip()
                identity = identity.split(":", 1)[0].lstrip("@").lower()
                if identity and identity == requester_localpart:
                    return True
        return False

    async def _update_approvals(
        self,
        owner_user_id,
        approvals_add,
        approvals_remove,
    ):
        approvals_add = approvals_add or []
        approvals_remove = approvals_remove or []

        if not isinstance(approvals_add, list):
            raise ProfileError("approvals_add must be an array.")

        if not isinstance(approvals_remove, list):
            raise ProfileError("approvals_remove must be an array.")

        requested = set(approvals_add + approvals_remove)

        if any(
            not isinstance(user_id, str)
            or not user_id.startswith("@")
            or ":" not in user_id
            for user_id in requested
        ):
            raise ProfileError("Invalid Matrix user ID in approvals.")

        if owner_user_id in requested:
            raise ProfileError("A user cannot approve themselves.")

        for user_id in requested:
            if await self.api.check_user_exists(user_id) is None:
                raise ProfileError(
                    "Approved Matrix user does not exist: " + user_id,
                    404,
                )

        def update(connection):
            with connection.cursor() as cursor:
                for user_id in approvals_add:
                    cursor.execute(
                        """
                        INSERT INTO profile_approvals
                            (owner_matrix_user_id, approved_matrix_user_id)
                        VALUES (%s, %s)
                        ON CONFLICT DO NOTHING
                        """,
                        (owner_user_id, user_id),
                    )

                for user_id in approvals_remove:
                    cursor.execute(
                        """
                        DELETE FROM profile_approvals
                        WHERE owner_matrix_user_id = %s
                          AND approved_matrix_user_id = %s
                        """,
                        (owner_user_id, user_id),
                    )

            connection.commit()

        await self._db(update)
    async def update_profile(
        self,
        requester_id,
        target_user_id,
        payload,
        replace,
        requester,
    ):
        self._require_owner(requester_id, target_user_id)
        await self._update_approvals(
            target_user_id,
            payload.get("approvals_add", []),
            payload.get("approvals_remove", []),
        )

        if "displayname" in payload:
            raise ProfileError(
                "Use com.wrytte.first_name and com.wrytte.last_name in fields."
            )

        if "avatar_url" in payload:
            raise ProfileError(
                "Use com.wrytte.avatar_image_url in fields; Matrix avatar_url is not used."
            )

        fields = payload.get("fields", {})
        remove_fields = payload.get("remove_fields", [])
        visibility = payload.get("visibility", {})

        if not isinstance(fields, dict):
            raise ProfileError("fields must be an object.")
        if any(not isinstance(value, str) for value in fields.values()):
            raise ProfileError("Profile field values must be strings.")
        # Versions are an output of this Module; ignore client attempts to set
        # or reset the cache generation.
        fields = dict(fields)
        fields.pop(AVATAR_VERSION_FIELD, None)

        if not isinstance(remove_fields, list) or any(
            not isinstance(field, str) for field in remove_fields
        ):
            raise ProfileError("remove_fields must be an array of field names.")

        if not isinstance(visibility, dict):
            raise ProfileError("visibility must be an object.")
        if any(not isinstance(value, str) for value in visibility.values()):
            raise ProfileError("Visibility values must be strings.")

        unsupported_visibility = set(visibility) - VISIBILITY_FIELDS - {ONLINE_VISIBILITY_FIELD}
        if unsupported_visibility:
            raise ProfileError(
                "Unsupported visibility fields: "
                + ", ".join(sorted(unsupported_visibility)),
            )

        unsupported = set(fields) - ALLOWED_FIELDS
        if unsupported:
            raise ProfileError(
                "Unsupported fields: "
                + ", ".join(sorted(unsupported)),
            )

        unsupported_removals = set(remove_fields) - ALLOWED_FIELDS
        if unsupported_removals:
            raise ProfileError(
                "Unsupported fields to remove: "
                + ", ".join(sorted(unsupported_removals)),
            )

        invalid_visibility = {
            value
            for value in visibility.values()
            if value not in VISIBILITY_VALUES
        }

        if invalid_visibility:
            raise ProfileError("Invalid visibility value.")

        old_fields, old_visibility = await self._read_document(
            target_user_id,
        )

        current_avatar_version = self._avatar_version(old_fields)
        if replace:
            # PUT is replacement: omitted custom fields/settings are removed.
            new_fields = dict(fields)
            new_visibility = dict(visibility)
        else:
            # POST/PATCH are partial writes. POST may add fields but cannot
            # silently overwrite an existing value; PATCH is for replacement.
            if payload.get("_http_method") == "POST":
                conflicts = {
                    field for field, value in fields.items()
                    if field in old_fields and old_fields[field] != value
                    and field != AVATAR_VERSION_FIELD
                }
                if conflicts:
                    raise ProfileError(
                        "POST cannot replace existing fields: "
                        + ", ".join(sorted(conflicts)),
                        409,
                    )
            new_fields = {**old_fields, **fields}
            new_visibility = {**old_visibility, **visibility}
        for field in remove_fields:
            # Cache versions are managed by the Module and cannot be removed
            # independently of the avatar.
            if field == AVATAR_VERSION_FIELD:
                continue
            new_fields.pop(field, None)
            new_visibility.pop(field, None)

        # The avatar URL is the custom Wrytte field. Every explicit avatar
        # write advances the server revision, even if the storage URL is reused.
        old_avatar = old_fields.get(AVATAR_FIELD)
        requested_avatar = fields.get(AVATAR_FIELD)
        avatar_removed = (
            AVATAR_FIELD in remove_fields
            or (replace and bool(old_avatar) and AVATAR_FIELD not in fields)
            or (AVATAR_FIELD in fields and not str(requested_avatar or "").strip())
        )
        avatar_changed = AVATAR_FIELD in fields or avatar_removed
        if AVATAR_FIELD in fields:
            if avatar_removed:
                new_fields.pop(AVATAR_FIELD, None)
            else:
                new_fields[AVATAR_FIELD] = str(requested_avatar).strip()
        if avatar_changed:
            next_version = current_avatar_version + 1
            new_fields[AVATAR_VERSION_FIELD] = str(next_version)
        else:
            if AVATAR_VERSION_FIELD in old_fields or new_fields.get(AVATAR_FIELD):
                new_fields[AVATAR_VERSION_FIELD] = str(current_avatar_version)
            else:
                new_fields.pop(AVATAR_VERSION_FIELD, None)

        if new_fields.get(AVATAR_FIELD):
            new_fields[AVATAR_FIELD] = self._version_avatar_url(
                new_fields[AVATAR_FIELD],
                self._avatar_version(new_fields),
            )

        changed_fields = set(fields) | set(remove_fields) | set(visibility)
        if replace:
            changed_fields |= set(old_fields) | set(old_visibility)
        if avatar_changed:
            changed_fields.add(AVATAR_FIELD)

        def save(connection):
            with connection.cursor() as cursor:
                cursor.execute(
                    """
                    INSERT INTO profile_documents
                        (matrix_user_id, fields, visibility, updated_at)
                    VALUES (%s, %s, %s, now())
                    ON CONFLICT (matrix_user_id)
                    DO UPDATE SET
                        fields = EXCLUDED.fields,
                        visibility = EXCLUDED.visibility,
                        updated_at = now()
                    """,
                    (
                        target_user_id,
                        Json(new_fields),
                        Json(new_visibility),
                    ),
                )
            connection.commit()

        await self._db(save)
        await self._notify_joined_rooms_profile_changed(
            target_user_id,
            changed_fields,
            old_visibility,
            new_visibility,
            requester,
        )

        return await self.get_profile(
            requester_id,
            target_user_id,
            requester,
        )

    async def delete_field(
        self,
        requester_id,
        target_user_id,
        field,
        requester,
    ):
        self._require_owner(requester_id, target_user_id)

        if field.startswith("visibility:"):
            visibility_field = field.split(":", 1)[1]
            if visibility_field not in VISIBILITY_FIELDS | {ONLINE_VISIBILITY_FIELD}:
                raise ProfileError("Unsupported visibility field.")
            fields, visibility = await self._read_document(target_user_id)
            old_visibility = dict(visibility)
            visibility.pop(visibility_field, None)
            await self._save_document(target_user_id, fields, visibility)
            await self._notify_joined_rooms_profile_changed(
                target_user_id,
                {visibility_field},
                old_visibility,
                visibility,
                requester,
            )
            return await self.get_profile(
                requester_id,
                target_user_id,
                requester,
            )

        if field not in ALLOWED_FIELDS:
            raise ProfileError("Unsupported field.")

        fields, visibility = await self._read_document(
            target_user_id,
        )

        if field == AVATAR_VERSION_FIELD:
            raise ProfileError("Avatar version is managed automatically.")

        old_visibility = dict(visibility)
        if field == AVATAR_FIELD and fields.get(AVATAR_FIELD):
            fields[AVATAR_VERSION_FIELD] = str(
                self._avatar_version(fields) + 1
            )

        fields.pop(field, None)
        visibility.pop(field, None)

        await self._save_document(target_user_id, fields, visibility)
        await self._notify_joined_rooms_profile_changed(
            target_user_id,
            {field},
            old_visibility,
            visibility,
            requester,
        )
        return await self.get_profile(
            requester_id,
            target_user_id,
            requester,
        )

    async def _save_document(self, user_id, fields, visibility):
        def save(connection):
            with connection.cursor() as cursor:
                cursor.execute(
                    """
                    INSERT INTO profile_documents
                        (matrix_user_id, fields, visibility, updated_at)
                    VALUES (%s, %s, %s, now())
                    ON CONFLICT (matrix_user_id)
                    DO UPDATE SET
                        fields = EXCLUDED.fields,
                        visibility = EXCLUDED.visibility,
                        updated_at = now()
                    """,
                    (user_id, Json(fields), Json(visibility)),
                )
            connection.commit()

        await self._db(save)
