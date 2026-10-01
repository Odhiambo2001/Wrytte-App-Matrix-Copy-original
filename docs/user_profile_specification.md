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

The Python Synapse module and profile endpoints should be implemented against this contract. Runtime implementation is intentionally separate from this initial specification.
