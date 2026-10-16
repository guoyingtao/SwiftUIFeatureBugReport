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

`PrivateReport` ships in both schema files. If your container was set up from an earlier schema:

1. In CloudKit Console, open your container's **Development** environment.
2. Import the updated `Schema.ckdb` or `Schema-NoComments.ckdb` (**Schema → Import Schema**), or add
   the `PrivateReport` record type by hand with the fields and indexes listed in
   [Schema and permissions](Schema-and-Permissions.md).
3. Open **Schema → Security Roles** and check the `PrivateReport` grants: `_creator` Read and Write,
   `_icloud` Create, `dev` Read and Write, and nothing for `_world`.
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

Then deploy the schema to Production (**Deploy Schema Changes**) and repeat steps 1, 2 and 5 against
Production before release.

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

See [Schema and permissions](Schema-and-Permissions.md) for the index and grant checklist.
