# Air-skill lessons — the operational rules that predate this plugin

The predecessor skill ran this workflow by hand for months before any of it was scripted. Its
machine steps are now stages in `pipeline.py`; what could **not** be scripted is here — the
timezone arithmetic, the screenshot alignment, the source-gathering discipline, and four rules
each learned from a specific failure.

None of it depends on the old skill still existing. This file is the whole inheritance.

---

## 1. Timezone — the one arithmetic that must not be guessed

- `~/Acta/YYYY-MM-DD_HHMM__<slug>/` folder names are **local**.
- `info.md` (`date:`) and `session.json` (`started_at`) are **UTC**, `…Z`-suffixed.
- The machine runs **WEST (+0100)** — so **local = UTC + 1 h**. Everything that crosses between a
  calendar event, a folder, a screenshot filename and a transcript timestamp passes through this
  conversion, and getting it wrong silently aligns the wrong slide to the wrong sentence.
- **Recording starts 1–3 minutes after the scheduled calendar start.** Match a calendar event to a
  folder by a time *window*, never by an exact stamp.
- Weekday of a folder: `date -j -f "%Y-%m-%d" 2026-07-21 "+%a"`.
- The offset is a fact about one machine in one season, not about the format. `+0100` is hardcoded
  nowhere in the scripts: `teams_vtt_to_transcript.py --shots-utc-offset` carries it as a flag with
  `1.0` as the default, and it is the first thing to check if alignment looks systematically off by
  a whole hour.

---

## 2. Identifying the meeting — search by root, not by the word you expect

Finding *which* recording the user means is Step 0, and it fails in a specific way.

- "last meeting" → the newest folder.
- "the call about X last week" → search the calendar, then map the event to a folder by time
  window (§1).
- **Calendar subjects contain typos, and an exact-word search silently misses the meeting.** The
  case that taught this: a review for a client whose name was misspelled in the subject, so an
  exact search returned nothing and the meeting looked like it had never happened.
  Search by a **short root** (the first few letters), by **attendees**, and by **time window** — three angles, not
  one exact string. Ordering results oldest-first helps when the window is wide.
- Confirm the folder before doing any work: open `info.md` for source and duration, and once a
  transcript exists check that the opening lines are about the topic you expected. A wrong folder
  produces a completely plausible summary of the wrong meeting.

---

## 3. Screenshots — the slide lag is the whole trick

The user screenshots slides during a meeting; macOS writes them to `~/Desktop` as
`Screenshot YYYY-MM-DD at HH.MM.SS.png`, where **the filename time is the capture time, local**.

1. Compute the meeting window: local start = `session.json.started_at` (UTC) + 1 h; end = start +
   `duration` from `info.md`.
2. Copy **only** the screenshots whose capture time falls inside that window into
   `<meeting>/screenshots/`, with `cp -p` and the original names — they sort by time.
3. **Read each PNG** — the Read tool renders images — and record what is actually on the slide.
4. **Align to the transcript with an asymmetric window.** A screenshot is grabbed **30–60 s after
   the slide appears**, so the discussion that explains it *precedes* the capture. With
   `offset = screenshot_UTC − transcript_anchor_UTC` (and `screenshot_UTC = local − 1 h`), show
   the transcript over **`[offset − 95 s, offset + 20 s]`**. A symmetric window centred on the
   capture time reliably attributes the *next* topic to the slide.
   `teams_vtt_to_transcript.py --shots <tsv>` prints exactly these windows; the TSV is
   `HH:MM:SS<TAB>label` lines of local capture times.
5. Write `screenshots.md`: per shot — time, filename, **what is on the slide**, and **what was
   being said** (a verbatim excerpt).

---

## 4. Gathering context — discipline, not enthusiasm

Findings go into `context.md` (calendar and meta) and are folded into `summary.md`.

- **Calendar** — subject, organizer, attendees **with response status**, the invitation body, and
  any dates it names. Verify the event actually matches the recording. Note follow-ups (a "part 2"
  the same or next day) — they are context, and often they answer the meeting's open questions.
  The attendee list is also what feeds `--attendees` and `--num-speakers`.
- **An official Teams transcript, when one exists, is the transcript** — real names, no decoder
  errors. It replaces the entire local ASR path (see `SKILL.md`'s fork), and it independently
  confirms who was actually speaking.
- **Jira** — search by topic text. Results are large; extract, never dump. The pattern that works:
  save the response, then
  ```
  jq -r '.issues.nodes[] | "\(.key) [\(.fields.issuetype.name)/\(.fields.status.name)] \(.fields.assignee.displayName) :: \(.fields.summary)"' saved.json
  ```
  and write a `## Ссылки (Jira)` section of key, type/status, assignee, one-line summary, URL.
  **Mark the keys approximate**: no ASR produces a bare issue key correctly, so they were matched
  by topic, and saying so is the difference between a useful pointer and a false citation.
- **Local project docs** — the very document under discussion is often already on disk. Mapping
  discussion points onto concrete requirement IDs is the highest-value connectivity this workflow
  produces. `grep` the big document for the IDs mentioned; do not read it whole.
- **Slack** — only when asked or clearly relevant (the huddle thread, a leads channel).
- **Large tool results are saved to a file, not returned.** Slice them with `jq` or a Python
  `read()[a:b]`; reading such a file line by line burns the context window for nothing.

**⚠ Secrets hygiene — a hard rule, from a real incident.** A live Tailscale auth key
was once sitting in a project `notes.md` that got pulled in as meeting context.
If a gathered source contains a credential, **it never goes into a summary, a transcript, or any
artifact** — flag it to the user instead. The gathering step reads widely by design, which is
exactly why it needs this rule.

---

## 5. Two honesty rules that outrank everything above

Both are restated in `SKILL.md` because they govern what may be *written*, not how to find things.

- **`transcript.raw.md` is the source of truth; every later transcript is a reversible view.**
  Cleanup improves readability and must never change content, and it must preserve speaker
  markers. (See `lab-verdicts.md` §4 for the measurements behind both constraints.)
- **A decision or an action item is never attributed to a person on diarization alone.** A speaker
  gets a name only from an anchor — a self-introduction or a vocative — and an unanchored speaker
  keeps its `SPK_NN` label. Ask rather than guess; a confidently wrong attribution in a meeting
  summary is worse than an unnamed one.

Also worth keeping in mind: the summary and its transcript are **the user's private meeting
material**. `summary.md` structure lives in `summary-format.md`, verbatim from the predecessor, so
"как обычно" keeps producing the same document.
