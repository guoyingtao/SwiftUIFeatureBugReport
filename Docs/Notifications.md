# Notifications

The package uses CloudKit query subscriptions for activity updates, new requests and private
feedback. It does not run a notification server.

## Notification text

A subscription's text is fixed **when the subscription is saved**, not per event. The package saves
every subscription on the recipient's own device and sends concrete text from its own catalogue
(`Resources/Localizable.xcstrings`, English and Simplified Chinese), so the notification arrives in the
language that device was using:

| Notification | English (en-GB source) |
| --- | --- |
| Activity, body | "Status updated", "New reply", "Marked complete", "Your image was approved", "Your image was removed", "Shipped" |
| Developer, new request | "New request" / "A user created a new request." |
| Developer, new comment | "New comment" / "A user commented on a request." |

**Nothing has to be added to the host app.** Earlier versions sent these as localization keys, which
iOS resolves against the *host app's* bundle - so they stayed English unless the app copied them into
its own catalogue. The one key still sent is the activity title, `%@`: CloudKit substitutes the
triggering request's title for it, and there is no English in that line to translate. To put something
around it, give `%@` an entry in the app's catalogue — `"%@" = "Update: %@";`.

The public subscriptions are saved again every time a feedback screen starts, so a changed language
or rewording reaches the server the next time the board opens.

## Permission and registration

The system permission prompt appears after the user's first successful request submission. Opening
the board does not prompt.

A developer is asked when they first open the developer portal instead. They never submit a request,
so the first-submission prompt would never reach them and both developer subscriptions would end up
delivering to a device that had never registered with APNs. The portal is the one screen those two
pushes exist to send them back to, which makes opening it the developer's equivalent intent signal. A
developer who has already answered is not asked again.

Once permission exists, the app registers with APNs on every launch. CloudKit subscriptions use
deterministic IDs and are safely attempted again during startup.

Saving over an existing ID replaces it, which the next launch does. If old wording keeps arriving,
delete the subscription in CloudKit Console and relaunch — `ActivityService` swallows save errors by
design, since a subscription that already exists is the expected outcome rather than a failure.

Required app capabilities:

- iCloud with the configured CloudKit container
- Push Notifications

## What is delivered

Activity subscriptions fire when a developer changes status, replies, marks a request complete,
moderates an image or announces a shipped version. Two separate developer subscriptions fire for a
new request and for a new comment, in both cases only when someone else created it.

For an activity notification the title is the request title and the body is a short action such as “New
reply.” The activity feed carries the full display-ready message.

The developer's new-request notification reads “New request” over “A user created a new request.” The
new-comment notification reads “New comment” over “A user commented on a request.” Neither pushes the
request's own title: one subscription means one fixed format string, and the portal queue is a tap
away.

The developer's two notifications write no `Activity` record, so they do not appear in the Updates
feed. The portal queue is the developer's durable view and the push is only the nudge to open it. A
developer reply, by contrast, does write one, so the user sees it in Updates even if the push was
missed or notification permission was refused.

## Private feedback

With `privateFeedback` other than `.disabled` and `privateNotifications: true` (the default), three
more query subscriptions are saved on the **public** database:

| Kind | Saved on | Record type | Fires on | Predicate | Subscription ID |
| --- | --- | --- | --- | --- | --- |
| Report updated | every device that sends private feedback | `PrivateReport` | update | `creatorID == me` (+ `appID`) | `private-report-updated-<me>-<appID>` |
| New report | developer devices | `PrivateReport` | creation | `creatorID != me` (+ `appID`) | `developer-private-report-<me>-<appID>` |
| New follow-up | developer devices | `PrivateReply` | creation | `appID` (or everything when unscoped) | `developer-private-followup-<me>-<appID>` |

CloudKit only notifies a subscriber who can **read** the matching record, so the schema's grants keep
these private: `_creator` reads its own `PrivateReport`, `dev` reads all of them. A sender cannot write
their `PrivateReport` (`_creator` has READ only), so every update the first subscription sees is a
developer's: a reply (appended to `replies`), a status change, or an attachment removed. CloudKit
cannot fire on "a particular field changed", so all three notify; the text says "replied to or
updated". A forged `creatorID` gains nothing, because the push goes only to the record's real creator.

The `appID` clause is dropped when `includeUnscopedRecords` is on (CloudKit cannot match a missing
field), and the ID suffix is dropped when there is no `appID`. All predicate fields -
`PrivateReport.creatorID`, `PrivateReport.appID`, `PrivateReply.appID` - are already `QUERYABLE` in
both schemas, so **no schema import is needed**.

### Text and language

Titles and bodies are concrete strings from the package's catalogue, chosen when the subscription is
saved on the recipient's device - so in the recipient's language. They are generic on purpose:

- "Feedback update" / "The developer replied to or updated your feedback." (反馈有新进展 / 开发者回复或更新了你的反馈。)
- "New private feedback" / "A user sent new private feedback." (新的私密反馈 / 有用户提交了新的私密反馈。)
- "New reply on private feedback" / "A user replied on their private feedback." (私密反馈有新回复 / 有用户在私密反馈中发来了新回复。)

Each save is recorded under `com.swiftuifeaturebugreport.pushSubscription.<ID>` in `UserDefaults`
with a signature of the language, the text and the predicate. The subscription is saved again when that
signature changes (a new language, new wording, a different app scope) or once a day, and skipped
otherwise. Pushes are alert-only (`content-available` is off) and carry only `appID` (and the report
reference for follow-ups).

### Permission

- A sender is asked **right after** sending a private report or a follow-up, in a detached task, so
  the submission never waits on the prompt. Hosts calling `PrivateReportService.submit` /
  `sendFollowUp` directly can call `FeedbackStore.didSendPrivateFeedback()` to get the same.
- A developer is asked when they open the portal.
- Opening the board never prompts; it registers with APNs and checks the subscriptions only when
  permission already exists (authorised or provisional).
- The system prompt only ever appears while the status is undecided. Denied stays denied, silently.

Every failure - no permission, no `aps-environment`, no network, a schema without the record types -
is logged under the `com.swiftuifeaturebugreport` / `push` log category and otherwise ignored.

### Caveats

- Test pushes on a real device. CloudKit subscription pushes to the Simulator are unreliable at best.
- Development builds (Xcode) use the APNs sandbox and the CloudKit Development environment;
  TestFlight and App Store builds use production and the Production environment. Subscriptions are
  per environment and per iCloud account, so each is created separately.
- iOS shows these alerts when the app is in the background or not running. In the foreground nothing
  is shown unless the host app's `UNUserNotificationCenterDelegate` returns `.banner` from
  `willPresent`; the package does not install a delegate.
