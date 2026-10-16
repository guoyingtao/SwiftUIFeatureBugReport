# Privacy guidance

This is implementation guidance, not legal advice. Adapt it to the host app's privacy policy and App
Store Connect disclosures.

## Who controls the data

All records live in the integrator's CloudKit container under its Apple Developer account. The
package author receives no data and cannot access the container.

## Data collected

- Request title and body
- Up to three optional images
- Device model, OS version, app version, build and platform
- Optional metadata supplied through `FeedbackPrefill`
- CloudKit user record ID
- Votes, follows, replies and report categories

## Visibility

Every `Request` field is public to users of the app, including its device and app-version fields.
`RequestMetadata` and `PrivateReport` are readable only by the creator and developer role.

CloudKit record creator IDs are pseudonymous, not anonymous. Requests, votes, replies and reports can
be correlated through that ID even though the package collects no name or email.

`Report` records are world-readable so every client can count reports toward the auto-hide threshold.
They therefore contain only a category, never private-feeling free text. `Follow` records are
readable only by their creator and the developer role.

`Activity` is world-readable because its recipient is not its creator. Activity messages concern
public requests and contain no private metadata.

## Private feedback

With `privateFeedback` set to `.optional` or `.bugsAndAttachments`, a submission can go to the developer
alone. It is saved as a `PrivateReport` instead of a `Request`. The record type grants:

```
GRANT READ TO "_creator",
GRANT CREATE TO "_icloud",
GRANT READ, WRITE TO dev
```

There is no `_world` grant, so CloudKit itself refuses to return the record to anyone else. The creator
can read their report but **not write it**: with WRITE they could edit the `replies` and `status` fields
directly through CloudKit and make their own text appear as a developer reply. The package also refuses
`reply` and `setStatus` for non-developers, but that client-side check is a convenience, not
authentication. The schema is what enforces it.

`_icloud: CREATE` still lets a creator choose every field's *initial* value, including `replies` and
`status`. So the package trusts those two fields only when the record's CloudKit last modifier is a
configured developer (`developerUserRecordIDs`). CloudKit sets that value and clients cannot forge it.
Until then, a report shows no replies and the status "Open". On the first developer write, any values
set at creation are discarded before the change is applied. This means `developerUserRecordIDs` must
list every account that replies, not just the accounts with the `dev` role. This is
different from `ModerationState.hidden` and `ImageState.pending`, which only control what the package
shows: those records, and their image assets, stay fetchable by any client that queries them. Use
private feedback, not moderation, for anything that must not be public, such as screenshots.

Developer replies are stored on the report itself, in its `replies` list, rather than in a separate
record type. A reply record would be created by the developer, and `_creator: READ` would then let only
the developer read it. Keeping replies on the submitter's own record is what lets both sides read them
without a `_world` grant.

Private reports carry the same device fields as requests, plus optional `FeedbackPrefill` metadata,
and up to three images processed like public ones: downscaled, re-encoded and stripped of EXIF. They
are never shown on the board, never voted on, and never generate `Activity` records.

### Deleting private reports

Because the creator has no WRITE, a submitter cannot delete their own private report either. They ask
the developer instead, by creating a `PrivateReportDeletionRequest` (same grants: `_creator` READ,
`_icloud` CREATE, `dev` READ, WRITE, no `_world`):

- **One report:** "Ask the developer to delete this" on the report's detail screen.
- **All of them:** "Delete my data" in `MyDataView` deletes the public data immediately, as before, and
  files one request covering every private report. The screen then shows "Deletion requested".

Reports covered by a pending request are marked in "My private reports". The developer sees pending
requests at the top of the "Private reports" queue and deletes the reports and the request with one
button. Only reports **created by the requesting account** are deleted, checked against each record's
CloudKit creator. A request that names someone else's report deletes nothing.

A developer using `AccountDataService.delete(creatorID:)` (for example for a request that arrived by
email) deletes that user's private reports and deletion requests directly.

**Process requests promptly.** App Store Review Guideline 5.1.1(v) requires apps that support account
creation to let people delete their data from within the app, and privacy laws such as the GDPR set
deadlines for erasure requests. Here the request is made in the app but the deletion happens when you
act on it, so check the queue regularly. A good habit is a calendar reminder, or a developer
notification subscription on `PrivateReportDeletionRequest`. The package does not create that
subscription for you. Say in your privacy policy that private reports are deleted on request and how
long that takes. This is guidance, not legal advice.

The developer is still identified by the `dev` security role, so anyone with that role in the
container can read every private report. Grant it only to people who should.

## Deletion

Users can delete their posted requests, replies and reports from `MyDataView`; their private follows
are removed as well. Deleting a request cascades to replies and votes attached to that request.

Votes the user cast on other people's requests remain because they contain no prose and removing them
would rewrite other people's totals. A user can withdraw an individual vote from its request.

Developers can perform the same deletion by creator ID when handling an external deletion request.

## Manifest

`PrivacyInfo.xcprivacy` declares user content, optional photos, diagnostic context, user ID and the
same-app UserDefaults access used for activity and local blocking. The package performs no tracking,
analytics, advertising or third-party sharing.

The manifest does not replace the host app's own privacy manifest, privacy policy or App Store Connect
answers.
