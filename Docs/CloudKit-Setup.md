# CloudKit setup and environments

This guide expands the six-step setup in the README. Complete the README first, then use this page
for verification or environment changes.

## Importing the schema

CloudKit schema commands require a management token. Create one in CloudKit Console under
**Settings → Tokens & Keys → Management Tokens**:

```sh
xcrun cktool save-token --type management
xcrun cktool get-teams
```

Choose the schema that matches your configuration:

- `Schema.ckdb` with `allowComments: true`
- `Schema-NoComments.ckdb` with `allowComments: false`

```sh
xcrun cktool validate-schema --team-id <TEAM> --container-id <CONTAINER> \
  --environment development --file Schema.ckdb

xcrun cktool import-schema --team-id <TEAM> --container-id <CONTAINER> \
  --environment development --file Schema.ckdb
```

Importing is supported only in Development. Verify what CloudKit stored without overwriting the
checked-in schema:

```sh
xcrun cktool export-schema --team-id <TEAM> --container-id <CONTAINER> \
  --environment development --output-file ExportedSchema.ckdb
```

The exported format contains no explanatory comments. Keep documentation outside schema files.

## Developer access

The developer portal has two independent gates:

1. `developerUserRecordIDs` makes the portal visible.
2. Membership in the CloudKit `dev` role authorizes its writes.

Run the app at least once for each developer Apple Account so CloudKit creates its built-in user
record. Find the record in the public database's `Users` type and add `dev` to its roles.

Development and Production have separate user records and role memberships. Repeat the assignment
after deploying the schema.

## Development and Production

An Xcode development build normally uses CloudKit Development. App Store and TestFlight builds use
Production. To inspect real feedback from a debug build, set the app entitlement explicitly:

```xml
<key>com.apple.developer.icloud-container-environment</key>
<string>Production</string>
```

Entitlements are applied when the app is signed. Rebuild and reinstall after changing the value.
Leave `aps-environment` under Xcode's control; APNs and CloudKit environment entitlements serve
different purposes.

Use Development for schema changes, disposable feedback and destructive moderation tests. Use
Production for real user data. Production fields and record types can be added but cannot be removed,
renamed or retyped, so validate changes in Development first.

## Release flow

`Update Pending` and `Complete` distinguish a finished fix from an available release:

- **Update Pending:** the change is written but users cannot install it yet.
- **Complete:** the release is available. The portal records the version that contains the fix.

`RoadmapView` groups completed requests by their resolved version. Version sorting is numeric, so
`2.10` sorts after `2.9`.

## Private feedback

`PrivateReport` and `PrivateReportDeletionRequest` ship in both schema files. If your container was set
up from an earlier schema:

1. In CloudKit Console, open your container's **Development** environment.
2. Import the updated `Schema.ckdb` or `Schema-NoComments.ckdb` (**Schema → Import Schema**), or add
   both record types by hand with the fields and indexes listed in
   [Schema and permissions](Schema-and-Permissions.md).
3. Open **Schema → Security Roles** and check the grants on both types: `_creator` Read **only**,
   `_icloud` Create, `dev` Read and Write, and nothing for `_world`. If you imported an earlier
   version of this branch, `_creator` may still have Write on `PrivateReport`: remove it.
4. Set `privateFeedback` to `.optional` or `.bugsAndAttachments` in a Development build.

Verify the privacy before deploying, with two Apple Accounts on two devices or simulators:

1. **Account A** (not a developer) submits a private report with an image. It appears under
   "My private reports" on A.
2. **Account B** (also not a developer) opens "My private reports": A's report must not appear. Its
   public board must not show it either.
3. As B, try to read A's record directly, for example with a temporary debug call to
   `publicCloudDatabase.record(for:)` using the record name copied from the Console. It must fail with
   a permission error. Delete the debug call afterwards.
4. In CloudKit Console's **Records** view, query `PrivateReport` while acting as a user without the
   `dev` role (**Act as iCloud Account**). Only that account's own reports should be listed.
5. **The developer account** (in `developerUserRecordIDs`, with the `dev` role) opens "Private reports"
   from the board's "more" menu: reports from both A and B must be listed. Open one, change its status
   and send a reply.
6. Back on **A**, refresh "My private reports": the status and the reply must show.
7. As **A**, try to modify and to delete A's own report directly, for example with temporary debug
   calls to `publicCloudDatabase.save(_:)` after changing `status` and to `deleteRecord(withID:)`. Both
   must fail with a permission error. Delete the debug calls afterwards.
8. As **A**, choose "Ask the developer to delete this" on one report, then "Delete my data" in
   "My requests". The report is marked "Deletion requested", and "My requests" shows the pending request.
9. As the **developer**, open "Private reports": both requests are listed under "Deletion requests".
   Delete them: A's reports and the requests disappear. A request naming B's report, created by hand in
   the Console as A, must delete nothing of B's.

Then deploy the schema to Production (**Deploy Schema Changes**) and repeat steps 1, 2 and 5 against
Production before release.

## One container or several

**Shared container with `appID`.** Add the same container to every app's iCloud capability and set a
different `FeedbackConfiguration.appID` in each. CloudKit user record IDs are per container, so one
`developerUserRecordIDs` list and one set of `dev` role assignments cover every app. Deploy the schema
once. The `appID` index ships in both `.ckdb` files. If your container predates it, re-import the schema
in Development, or add `appID` (String, Queryable) to `Request`, `PrivateReport` and `Activity` in
CloudKit Console. Then deploy to Production. **Deploy before shipping a build that sets `appID`**: a
scoped query against a field with no index fails.

Existing records have no `appID`. Either leave them hidden (they still show in the portal under
"No app"), set `includeUnscopedRecords: true` in the app they belong to, or backfill the field in
CloudKit Console. Activity subscriptions saved by builds without `appID` keep their old, unscoped
predicate until the user deletes the app. That means pushes about other apps' requests can still
arrive for a while.

Treat `appID` as a display filter, not a security boundary. Every app in the container shares the
same records and permissions.

**Separate containers.** Each app gets its own container and its own `containerIdentifier`, and nothing
is shared at all. One Xcode app can use several containers: list them all in that target's iCloud
capability and create one `FeedbackStore` per container, for example in an internal triage app that
shows `DeveloperPortalView(store:)` for each. User record IDs differ between containers, so collect
the developer's ID and assign the `dev` role in every container.

## Production checklist

- [ ] The schema is deployed to Production.
- [ ] Developer user records have the `dev` role in Production.
- [ ] The release build uses the intended CloudKit container and Production environment.
- [ ] A Production request can be created and read.
- [ ] Voting, following and reporting work.
- [ ] A developer can change status and reply.
- [ ] Notification permission can be granted and a push is delivered.
- [ ] Delete-my-data succeeds.
- [ ] If private feedback is on: another account cannot see a private report, and the developer can
      list, reply to and update all of them.
- [ ] A submitter cannot modify or delete their own private report, and a deletion request from them
      shows up in the developer queue and can be processed.
- [ ] Someone is responsible for processing deletion requests promptly.

See [Schema and permissions](Schema-and-Permissions.md) for the index and grant checklist.
