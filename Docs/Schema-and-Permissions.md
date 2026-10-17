# Schema and permissions

The repository ships two complete schemas:

- `Schema.ckdb` includes user `Comment` records.
- `Schema-NoComments.ckdb` omits `Comment` but keeps developer `DevComment` records.

Use a checked-in variant instead of editing a schema during installation. When changing the package's
schema itself, work in Development, export the result, review the diff, and update both variants.

## Record types

| Record type | Purpose |
|---|---|
| `Request` | Public bug or feature request and optional images |
| `Vote` | One deterministic vote per user and request |
| `Report` | One categorized report per user and request |
| `Comment` | Optional user reply |
| `DevComment` | Developer-authenticated reply |
| `Activity` | User update feed and push trigger |
| `Follow` | Private subscription to a request |
| `RequestMetadata` | Private prefilling metadata |
| `PrivateReport` | Developer-only submission, with its developer replies, optional images and optional files |
| `PrivateReply` | A submitter's follow-up message in a private report's conversation |
| `PrivateReportDeletionRequest` | A submitter's request that the developer delete their private reports |

`Users` is CloudKit's built-in user type. Its queryable record ID is needed to configure the
`dev` role.

## Required indexes

Every included custom record type needs a queryable `___recordID`.

| Record type | Additional indexes |
|---|---|
| `Request` | `title` queryable/searchable; `appID`, `type`, `status`, `moderation`, `imageState`, `labels`, `resolvedInVersion`, `creatorID`, device fields queryable; `lastActivityAt` and creation time sortable |
| `Vote` | `request` queryable; creation time sortable |
| `Report` | `request` and `category` queryable |
| `Follow` | `request` queryable; creation time sortable |
| `Comment`, `DevComment` | `request`, `requestCreator`, `creatorID` queryable |
| `Activity` | `appID`, `request`, `recipientID`, `kind` queryable; creation time sortable |
| `RequestMetadata` | `request` queryable |
| `PrivateReport` | creator (`___createdBy`), `appID`, `kind`, `status` queryable; `lastActivityAt` and creation time sortable |
| `PrivateReply` | creator (`___createdBy`), `report`, `appID` queryable; creation time queryable and sortable |
| `PrivateReportDeletionRequest` | creator (`___createdBy`), `scope` queryable; creation time sortable |
| `Users` | `___recordID` queryable |

`title` is intentionally the only searchable `Request` field. Search-before-submit uses
`self CONTAINS`; marking `body` searchable silently widens that query without adding relevance
ranking.

`appID` scopes records to one app in a shared container (see `FeedbackConfiguration.appID`). It's
written only when an app sets `appID`; records without it are "unscoped". It's a display filter, not a
security boundary: it carries no grant of its own, and a request's creator can rewrite it like any
other field of their request.

### File fields on `PrivateReport`

| Field | Type | Notes |
|---|---|---|
| `files` | `LIST<ASSET>` | The attached files (`allowFileAttachments`). Fetched only when one is opened |
| `fileNames` | `LIST<STRING>` | Original name with extension of each entry in `files`, same order. A `CKAsset` keeps no name, and Quick Look and Books go by the extension |
| `fileSizes` | `LIST<INT64>` | Byte size of each entry in `files`, so lists show sizes without downloading |

None of these fields needs an index. They're written only when a report has files, so a schema without
them still accepts file-less private reports. Sending a file to a Production schema without them fails.
The names are client-written and are sanitised when stored and again when read (last path component
only, no control characters or leading dots), because the reader builds a temporary file path from them.
`Request` deliberately has no file field, and `SchemaVariantTests` checks that it never gains one.

## Permission invariants

- `RequestMetadata` allows authenticated creation but not world reading.
- `PrivateReport` grants `_creator` READ only, `_icloud` CREATE, `dev` READ, WRITE, and **no**
  `_world` grant. The creator has no WRITE so they cannot forge developer replies or status. Developer
  replies are stored on the report (`replies`, a `LIST<STRING>` of JSON entries), because a reply record
  created by the developer would not be readable by the submitter.
- `PrivateReply` has the same grants: `_creator` READ only (so a follow-up can't be edited once sent),
  `_icloud` CREATE, `dev` READ, WRITE, no `_world`. Its `report` is a `.deleteSelf` reference, so a
  conversation goes with its report. It carries only the **submitter's** messages: a record the developer
  created would be unreadable to the submitter, so developer messages stay on the report's `replies`. A
  follow-up is shown only if its CloudKit creator is the report's creator or a configured developer, so a
  third party who learns a report's record name can't inject messages into it.
- `PrivateReportDeletionRequest` has the same grants. Since the creator cannot delete a `PrivateReport`,
  they create one of these and the developer processes it. The requester is the record's CloudKit
  creator (`___createdBy`), never a field, and only reports with that same creator are deleted.
- `SchemaVariantTests` fails if any of these types gains a `_world` grant or a `_creator` WRITE.
- `DevComment` grants creation only to `dev`, making developer authorship unspoofable.
- `Comment` and `Follow` grant developer writes so account deletion can remove another user's data.
- `Vote`, `Report` and `Follow` grant their creator writes so votes can be withdrawn, follows
  cancelled and reports deleted.
- `Report` contains a category but no free-text detail because reports are world-readable for
  client-side threshold counting.
- `Request.images` is a `LIST<ASSET>`.
- `resolvedInVersion` is separate from the version from which a request was reported.

If user comments are disabled, use `Schema-NoComments.ckdb` and set `allowComments: false`. The
configuration flag controls the client; omitting the record type enforces the decision at CloudKit.
