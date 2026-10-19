# SwiftUIFeatureBugReport

An in-app feedback board for SwiftUI apps, backed entirely by your own CloudKit container.

Users can submit bugs and feature requests, vote, follow updates, reply, report content and browse a
roadmap. Developers get a triage portal for status, labels, replies, image moderation and deletion.
The package author receives no data and has no access to your container.

## Requirements

- iOS 17+ or macOS 14+
- Xcode 26+ (the package uses Swift tools 6.2)
- A paid Apple Developer account
- App Store or TestFlight distribution for production push notifications

## Installation

In Xcode, choose **File → Add Package Dependencies…**, enter:

```
https://github.com/Tom4259/SwiftUIFeatureBugReport
```

Use the **Up to Next Major Version** rule starting at `2.0.0`.

Or add the package in `Package.swift`:

```swift
.package(
    url: "https://github.com/Tom4259/SwiftUIFeatureBugReport",
    from: "2.0.0"
)
```

## Add the board

```swift
import SwiftUIFeatureBugReport

let configuration = FeedbackConfiguration(
    containerIdentifier: "iCloud.com.yourcompany.yourapp",
    developerUserRecordIDs: ["_abc123…"],
    reportThreshold: 3,
    allowComments: true,
    allowImageAttachments: true
)

NavigationStack {
    FeedbackBoardView(configuration: configuration)
}
```

`developerUserRecordIDs` controls who sees the developer portal. CloudKit's `dev` role separately
authorizes developer writes; configure both if you use the portal.

### Crash safety: nothing runs until a feedback screen is shown

Importing the package and constructing its views does no work. The public views only store their
arguments - so `NavigationLink(destination: FeedbackBoardView(configuration: ...))` on a settings
screen is safe - and `FeedbackStore` / `FeedbackContainer` initialisers create no `CKContainer`,
register no observer and start no task. There are no global or static initialisers with side effects,
no app-delegate hooks, and no work at launch.

When a feedback screen is first displayed, `FeedbackContainer.prepare()` runs once. It reads the app's
signed entitlements from its own code signature, and if they definitely lack the iCloud **CloudKit**
service or the configured container, the screen shows a "Feedback unavailable" state instead of
creating the container. This matters because `CKContainer(identifier:)` does not throw when the
entitlement is missing: CloudKit hits a `brk` trap that no `catch` or `@try` can intercept. When the
entitlements cannot be read (an unusual signing setup), the container is created as before.

Only then does the package touch CloudKit, `UserDefaults` (keys prefixed `com.swiftuifeaturebugreport.`),
the temporary directory, or notifications. It asks for notification permission at a user's first
submission or when a developer opens the portal, and re-registers for remote notifications only if the
app already has permission. If you use `FeedbackStore` or its services directly, call `prepare()` first
and do not proceed when it returns `.unavailable`.

> **Adding the iCloud capability can change your app's own data stack.** With CloudKit in the
> entitlements, SwiftData's `ModelConfiguration` defaults to `cloudKitDatabase: .automatic` and starts
> syncing to the *first* listed container - and traps if your models are not CloudKit-compatible. If
> the app does not sync, pass `cloudKitDatabase: .none`; if it does, pin its container with
> `.private("iCloud.your.existing.container")` before adding the feedback container. The same goes for
> code using `CKContainer.default()` or `NSPersistentCloudKitContainer` without explicit options.

## CloudKit setup

Budget about 20 minutes. Complete these steps in order.

### 1. Add capabilities

In your app target, open **Signing & Capabilities**:

1. Add **iCloud**, enable **CloudKit**, and select or create your container.
2. Add **Push Notifications**.

The identifier passed to `FeedbackConfiguration` must appear in the app's iCloud entitlement.

### 2. Import a schema

Choose one file from the repository root:

- `Schema.ckdb`: user replies enabled.
- `Schema-NoComments.ckdb`: users cannot reply; developer replies still work.

Create a management token in CloudKit Console under **Settings → Tokens & Keys**, then:

```sh
xcrun cktool save-token --type management
xcrun cktool get-teams

xcrun cktool validate-schema --team-id <TEAM> --container-id <CONTAINER> \
  --environment development --file Schema.ckdb

xcrun cktool import-schema --team-id <TEAM> --container-id <CONTAINER> \
  --environment development --file Schema.ckdb
```

Use `Schema-NoComments.ckdb` in both commands when comments are disabled. Do not edit the checked-in
schemas during installation.

### 3. Configure developer access

Skip this step if you do not need the developer portal.

Run the app once while signed in to iCloud, then obtain your CloudKit user record ID:

```swift
let container = CKContainer(identifier: "iCloud.com.yourcompany.yourapp")
let id = try await container.userRecordID()
print(id.recordName)
```

In CloudKit Console, open the public database's built-in `Users` record, find that ID, and add the
`dev` role. Put the same ID in `developerUserRecordIDs`.

Repeat this for every developer account. If the IDs are hard-coded in the app, adding another one
requires a new build.

### 4. Notification strings — nothing to do

Push notification text is sent as localization keys that **are** their own en-GB strings, so there is no
setup step here. An app that adds nothing shows the English:

```text
"Status updated"
"New reply"
"Marked complete"
"Your image was approved"
"Your image was removed"
"Shipped"
"New request"
"A user created a new request."
"%@"
```

To translate them, add those as keys to the host app's `Localizable.xcstrings` or
`Localizable.strings` and translate them there. `%@` is the activity notification's title, which CloudKit
fills with the request's own title.

Notification permission is requested after the user's first successful submission rather than when the
board opens. See [Notifications](Docs/Notifications.md).

### 5. Match the configuration to the schema

```swift
FeedbackConfiguration(
    containerIdentifier: "iCloud.com.yourcompany.yourapp",
    developerUserRecordIDs: ["_abc123…"],
    reportThreshold: 3,
    allowComments: true,          // use Schema.ckdb
    allowImageAttachments: true,
    privateFeedback: .disabled    // .optional, .bugsAndAttachments or .only once PrivateReport is deployed
)
```

Set `allowComments: false` when using `Schema-NoComments.ckdb`.

`privateFeedback` adds a "Private (only visible to developer)" toggle to the form. Private submissions
are saved as `PrivateReport` records that only the submitter and the `dev` role can read, enforced by
CloudKit. Users find them under "My private reports" in the board's "more" menu. Developers find them in
the developer portal, which gains a **Public / Private** switch at the top. The Private tab is the private
reports queue, with a Pending/All filter, and shares the portal's app filter and search. With
`.bugsAndAttachments`, bug reports and anything with an image are always private. Private submissions can
carry images even with `allowImageAttachments: false`.
Submitters can read but not edit or delete private reports. They ask the developer to delete them,
and the developer handles those requests at the top of the portal's Private tab.

Each private report is a **conversation**. Its detail screen, for the submitter and in the portal alike,
shows one chronological thread with a composer at the bottom. The developer's messages are stored on the
report (`replies`), as before, so existing replies keep working. The submitter's follow-ups are
`PrivateReply` records, which are immutable once sent. Submitters can write until the report's status is
**Complete** (`RequestStatus` has no separate closed or declined state). Follow-ups from anyone other than
the report's creator or a configured developer are never shown. See
[Privacy](Docs/Privacy.md#conversations).

The Private tab's title and the portal button on the board show a **pending count**:

- private reports whose conversation ends with the **sender**: a new report still Open with no reply,
  or one whose latest message is the sender's follow-up (any status except Complete). A report already
  covered by a deletion request from its own sender isn't counted (that request is what you act on). Plus
- every unprocessed deletion request (processing deletes the request, so all that remain are pending).

Replying takes a report out of the count until the sender writes again. Moving a report off Open
without replying also takes it out, as long as the sender hasn't followed up. The board's figure covers every app;
the Private tab's follows the app filter, except that deletion requests have no app and always count.
The rule is `PrivateQueuePolicy`. The Pending filter lists exactly the reports it counts.
Leave it `.disabled` until `PrivateReport` is deployed. See [Privacy](Docs/Privacy.md#private-feedback).

#### Private-only mode

`privateFeedback: .only` turns the package into a private support inbox, with no public board at all:

- `FeedbackBoardView`'s main screen is the user's own private reports ("My private reports") with a
  prominent **New feedback** button. There is no public list, roadmap, voting, comments, search of
  public requests or Updates feed, and nothing public is queried or subscribed to.
- The form has no public/private toggle; every submission is a `PrivateReport`.
- The "more" menu keeps **My data**, which still counts and deletes everything the user has stored
  (including any public data from before the switch) and still files the private deletion request.
- The developer portal shows the private queue only, with no Public / Private switch.

Every other mode behaves exactly as before. In `.only` mode don't embed `RoadmapView`, `UpdatesView`
or `RequestDetailView` yourself; they are public-board screens. The public record types can stay in
the schema; they are simply unused.

#### File attachments on private reports

Private reports can carry files: PDFs, EPUBs and other documents, for example the book that won't
open in a reader app.

```swift
FeedbackConfiguration(
    containerIdentifier: "iCloud.com.newbee.beereader",
    developerUserRecordIDs: ["_abc123…"],
    privateFeedback: .only,                        // or .optional / .bugsAndAttachments
    allowFileAttachments: true,                    // default false
    maxFileAttachmentBytes: 20 * 1024 * 1024,      // per file, default 20 MB
    maxFileAttachments: 3,                         // per report, default 3
    allowedFileTypes: [.pdf, .epub, .plainText]    // default: .pdf, .epub, .plainText, .zip; [.item] = anything
)
```

- Only effective while `privateFeedback` is not `.disabled` (`fileAttachmentsAvailable`). Files are
  stored on `PrivateReport` only. `Request` has no file field, and the public submit path takes none.
- The form shows **Attach file** (`.fileImporter`; Files on iOS, an open panel on the Mac). Each file
  is listed with its name and size and a remove button. Size, type and count are checked, with
  localisable errors. In `.optional` and `.bugsAndAttachments` modes, attaching a file **forces the
  submission private**: the toggle locks on and its footer says why.
- In both the user's own report and the portal, files show as rows with an icon, name and size.
  Tapping one downloads only that file, saves it under its original name and opens it in Quick Look.
  A share button then exports it to Files, Books and so on.
- In the portal, the developer can remove a single file or image from a private report (trash button,
  swipe or context menu, then a confirmation) to save iCloud storage. The report, its status and the
  conversation are kept; the sender no longer sees the removed attachment.
- This needs the `files`, `fileNames` and `fileSizes` fields on `PrivateReport`. Import the updated
  schema before turning it on. See [Schema and permissions](Docs/Schema-and-Permissions.md).

### Several apps, one container

Apps from the same team can share one container. Give each its own `appID`:

```swift
FeedbackConfiguration(
    containerIdentifier: "iCloud.com.newbee.feedback",   // the same in BeeDay, BeeTunes and BeeReader
    developerUserRecordIDs: ["_abc123…"],
    appID: "BeeDay"
)
```

With `appID` set, new requests, private reports and activity are stamped with it. The board, roadmap,
search, Updates and "My private reports" then show only that app's records. The developer portal, Public and
Private tabs alike, still shows every app, with an app badge on each row and an app filter. `appID: nil`,
the default, writes nothing and shows everything, exactly as before.

Records written before `appID` was set have none, and nobody can tell which app they came from. By default
they're hidden from every app that sets `appID`. They still show in the portal, where the filter lists them as
"No app". Set `includeUnscopedRecords: true` in the app that owned the container first, and its existing
feedback stays visible there.

`appID` is a display filter, **not a security boundary**. It's an ordinary client-written field and every
app shares the same record types and permissions, so a user of one app can read the others' public
feedback through CloudKit directly. If the apps' feedback must be kept apart, give each app its own
container. See [CloudKit setup](Docs/CloudKit-Setup.md#one-container-or-several).

"My data" follows the same rule. With `appID` set, its counts and "Delete my data" cover only this app's
records (plus unscoped ones if `includeUnscopedRecords` is on); the user's feedback in your other apps stays
and is deleted from those apps. See [Privacy](Docs/Privacy.md#deletion-in-a-shared-container). With
`appID: nil` it is account-wide, as before. The portal's "Delete all of this author's data" is always
account-wide.

### 6. Deploy before release

Test in CloudKit's Development environment first. When ready:

1. In CloudKit Console, choose **Deploy Schema Changes**.
2. Add the `dev` role to developer user records in Production as well.
3. Ensure distributed builds use the Production CloudKit environment.
4. Verify a request, vote and notification in Production before release.

Use Production for real feedback. Switch back to Development for schema changes and destructive
testing.

See [CloudKit setup](Docs/CloudKit-Setup.md) for environment details, verification commands and
troubleshooting.

## Sharing a store

Create one store when several screens appear in the same app. This avoids repeating board and tally
queries:

```swift
@State private var feedback = FeedbackStore(configuration: configuration)

TabView {
    FeedbackBoardView(store: feedback)
        .tabItem { Label("Feedback", systemImage: "bubble.left") }

    RoadmapView(store: feedback)
        .tabItem { Label("Roadmap", systemImage: "map") }
}
```

Every configuration-based entry view initializes its own store. Store-based views share one
idempotent startup operation, so they can safely appear together.

Open a prefilled form from a crash handler, settings screen or support action:

```swift
FeedbackFormView(
    store: feedback,
    prefill: FeedbackPrefill(
        title: "Alarm didn't fire",
        type: .bug,
        metadata: [
            "lastAlarmID": alarm.id,
            "schedulerState": scheduler.stateDescription
        ]
    )
)
```

Metadata is disclosed before submission and stored in a separate record readable only by its creator
and the developer role.

## What each screen shows

`FeedbackBoardView` lists work that is still live: open requests, ones in progress, and ones fixed
but awaiting a release. Completed requests are left off the list, because they accumulate the most
votes over time and otherwise sit permanently at the top of the default vote sort.

They remain reachable two ways. Searching the board still matches completed requests, so anyone
checking before they file finds work you have already shipped instead of reporting it again. And
`RoadmapView` groups completed requests by the version they shipped in, alongside the work still in
flight.

Pairing the two as separate tabs, as in [Sharing a store](#sharing-a-store), gives users both halves
at once. Otherwise the board reaches the roadmap from its "more" menu.

## Localisation

The package ships its own translations: English (en-GB, the source language) and **Simplified
Chinese** (zh-Hans), in `Sources/SwiftUIFeatureBugReport/Resources/Localizable.xcstrings`. Every
user-facing string - screens, buttons, confirmation dialogs, errors, accessibility labels and push
notification text - is looked up in the package's own resource bundle, never in `Bundle.main`, so the
host app needs no keys of its own. Counts use proper plural rules ("1 vote" / "2 votes"; Chinese has
no plural forms).

- **Your app must itself be localised into Chinese** (Simplified) for users to see it: iOS and macOS
  pick one language for the whole process from the languages the *app* declares, and SwiftUI's
  locale follows. If the app has no `zh-Hans` localisation, the package shows English too.
- Lookups do not fall back to the host app's catalogue, so a key in your app's `Localizable.xcstrings`
  does not override the package's wording. To change a translation, edit the package's catalogue.
- Text people typed (titles, bodies, replies) and your own metadata keys are never translated.
- The resource bundle is found without SwiftPM's generated `Bundle.module`, which calls `fatalError`
  when the bundle is missing; if it ever cannot be found, the package shows its English source strings.

`LocalizationTests` checks that every looked-up string is in the catalogue with a Chinese
translation, that no SwiftUI call takes a bare literal (which would resolve in `Bundle.main`), and
that the built bundle carries `zh-Hans.lproj`.

## Navigation

`FeedbackBoardView` uses the navigation container supplied by your app. On iOS, place it inside a
`NavigationStack`. On macOS it provides its own side-by-side board and detail layout without nesting
a `NavigationSplitView`.

Other public views accept `embedsNavigationStack: Bool = true`. Set it to `false` when placing the
view inside a navigation stack your app already owns.

## Testing

```sh
swift test
```

The test suite requires no CloudKit account or network connection.

## Detailed documentation

- [CloudKit setup and environments](Docs/CloudKit-Setup.md)
- [Schema and permissions](Docs/Schema-and-Permissions.md)
- [Notifications](Docs/Notifications.md)
- [Privacy guidance](Docs/Privacy.md)
- [Upgrading from 1.x](Docs/Migration-from-1.x.md)
- [Troubleshooting](Docs/Troubleshooting.md)

## License

MIT. See [LICENSE](LICENSE).
