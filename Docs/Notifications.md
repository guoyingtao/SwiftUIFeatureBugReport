# Notifications

The package uses CloudKit query subscriptions for activity updates and new requests. It does not run
a notification server.

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
