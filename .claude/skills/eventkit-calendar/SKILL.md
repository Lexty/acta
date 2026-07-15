---
name: eventkit-calendar
description: Read calendar events with EventKit on macOS 14+ (authorization, matching an event to a recording, attendee data). Use for CalendarService / calendar metadata in info.md.
---

# EventKit: reading calendar events on macOS 14+

> The source of truth is Apple's docs (links below), in particular **TN3153**. Below are verified
> facts and the gotchas. Check exact API signatures against the docs — do not invent them.

## Goal
When a recording starts, find the calendar event happening at that moment and put its data into the
recording metadata (title, notes, participants, …), so the archive is searchable by real meeting
names rather than "Slack — 2026-07-15 18:28".

## Authorization changed in macOS 14 — this is the main trap
- Use **`requestFullAccessToEvents(completion:)`** / `requestFullAccessToEvents()`.
  The old `requestAccess(to:)` is deprecated on macOS 14+.
- Granted status is **`EKAuthorizationStatus.fullAccess`** (not `.authorized`).
- Info.plist **must** contain **`NSCalendarsFullAccessUsageDescription`** (macOS 14+).
  The pre-14 key `NSCalendarsUsageDescription` is not enough.
- 🪤 **If the key is missing, TCC refuses the request before EventKit is even reached** — no prompt
  appears at all and the failure looks like "the API is broken". Always check the key first.
- Acta only reads events → full access is what EventKit offers for reading; there is also a
  write-only variant which is **not** what we need.

## Reading events
- `EKEventStore.predicateForEvents(withStart:end:calendars:)` → `store.events(matching: predicate)`.
- Query a window around the recording start (e.g. start − 15 min … start + 15 min) and match in
  pure code, rather than trying to be clever in the predicate.

## Useful `EKEvent` fields
`title`, `notes` (the description), `location`, `startDate`, `endDate`, `isAllDay`,
`url` (often the join link), `organizer` (`EKParticipant?`), `attendees` (`[EKParticipant]?`),
`calendar.title`, `eventIdentifier`.

## `EKParticipant` — verify before using
- Confirmed: it represents a person/group/room; `EKEvent.attendees` is `[EKParticipant]?`.
- `name` is available. For the email address, the reliable path is **`url`**, which is a `mailto:`
  URL — take the address from it (e.g. `url.resourceSpecifier`).
- ⚠️ Do **not** assume a public `emailAddress` property exists on this SDK — check the docs/headers
  first and fall back to `url` if it does not.
- Also useful: `participantStatus`, `participantRole`, `isCurrentUser` (to mark yourself).

## Gotchas
0. **The calendar and reality drift apart — this is the norm.** Never match on "the event covering
   the recording start"; it breaks in ordinary cases:
   - the call is at 15:00, you hit record at 15:08 (started late);
   - you hit record at 14:50, before the scheduled start (no overlap yet);
   - the 15:00–15:30 meeting actually ran 15:35–16:05 — at record time the event has **already
     ended**, so there is zero overlap;
   - you start recording 40 minutes into a long meeting.
   Use a tiered rule: **maximum overlap** with the recording interval → else **nearest event by
   start** within a drift tolerance (default ~15 min, configurable) → else no match. Also note that
   the full recording interval is only known at stop, so a provisional match at start (for the
   title/folder) plus a re-match at stop is the honest approach.
1. **All-day events** overlap everything — exclude or de-prioritise them when matching, otherwise
   every recording matches "Vacation".
2. **Several overlapping events** are normal. Decide deterministically (see the pure matcher below);
   never pick at random.
3. **Declined events** should be de-prioritised — `participantStatus` of the current user.
4. **Recurring events**: `eventIdentifier` is shared across occurrences; use it together with
   `startDate` if you need to identify a specific occurrence.
5. **No permission / no match must be graceful** — the app records exactly as before, just without
   calendar metadata. Calendar access is a nice-to-have, never a precondition for recording.
6. **Privacy**: notes often contain join links and passcodes. They stay local, like everything in
   Acta, but never log them.

## Design rule for this project
Keep the **matching decision pure** (in `ActaKit`): feed it plain structs (title, start, end,
isAllDay, status, …) plus the recording start time, and let it return the best match. EventKit I/O
stays in the `Acta` target. That way the matching rules are unit-testable without a calendar.

## References
- TN3153 — adopting EventKit API changes in iOS 17 / macOS 14: https://developer.apple.com/documentation/technotes/tn3153-adopting-api-changes-for-eventkit-in-ios-macos-and-watchos
- requestFullAccessToEvents: https://developer.apple.com/documentation/eventkit/ekeventstore/requestfullaccesstoevents(completion:)
- Accessing Calendar using EventKit: https://developer.apple.com/documentation/EventKit/accessing-calendar-using-eventkit-and-eventkitui
- EKEvent: https://developer.apple.com/documentation/eventkit/ekevent
- EKParticipant: https://developer.apple.com/documentation/eventkit/ekparticipant
