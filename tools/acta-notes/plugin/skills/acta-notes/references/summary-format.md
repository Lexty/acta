# `summary.md` — the format, verbatim

This is the predecessor skill's Step 4, carried over **unchanged**. "как обычно" means *this
document*: the same headings, the same order, the same Russian wording. The archive of past
summaries is the real specification — a new summary that does not match it is a regression, even
if it reads well.

Output language is **Russian**, including when the meeting audio is English. The headings below
are the exact strings to write.

---

## The skeleton

```
# <Тема> — <короткое описание> — YYYY-MM-DD

> Саммари по <источник транскрипта> + <источники>. Событие <подтверждено по календарю / не проверено>.
> ⚠️ <ASR-оговорки: что искажено, как восстановлено>.
> 🔗 <связи во времени: этот созвон → вопросы → ответы; follow-up сегодня в HH:MM>.

- **Время записи:** …(UTC/WEST, длительность)
- **Тип:** …
- **Участники:** …(по календарю; Я=mic)
- **Канал:** …

## Общее содержание
<проза: оси обсуждения>

## Что обсуждали
**<Тема 1>.** [~MM:SS]
- <буллеты, привязанные к requirement ID / тикетам / докам>
**<Тема 2>.** …

## Action points
- **<Владелец>** — <что>. 🔗 <связанный артефакт/тикет>

## Открытые вопросы
- <…, отметить что уже закрыто внешними источниками>

## Связанные материалы (`~/dev/<проект>/...`)
- **`<файл>`** — <что это, как связано>

## Ссылки (Jira)
- **KEY** (type/status, assignee) — summary: URL

_Примечание: <как подобраны ключи; ASR-интерпретации>._
```

---

## How to fill it

- **Keep bullets concrete and owner-attributed.** Tie every claim to a timestamp, a requirement
  ID, a ticket, or a source document wherever one exists. A bullet with none of those is usually a
  paraphrase of nothing.
- **The blockquote is the honesty header**, and it is not optional:
  - which transcript this was built from and which other sources were used;
  - whether the calendar event was actually confirmed, or the match is an assumption;
  - `⚠️` — what the ASR mangled and how it was reconstructed. This is the human-readable sibling of
    `.acta-notes/quality.md`; when a quality gate fired, say so here in words.
  - `🔗` — the connections in time: what this call answers, what it opens, when the follow-up is.
- **`Участники`** comes from the calendar, with `Я = mic` spelled out — the mic track is the user
  by construction, and a reader should not have to infer that.
- **Action points name an owner.** An unowned action point is an open question; put it in
  `Открытые вопросы` instead. And an owner is only named when the transcript actually supports it —
  never on diarization alone.
- **`Открытые вопросы` should note what has already been answered** by a source gathered after the
  meeting. That is often the most useful line in the document.
- **Jira keys are approximate and must be marked as such** in the closing `_Примечание:_` — no ASR
  transcribes a bare issue key correctly, so they were matched by topic.
- **Timestamps in `Что обсуждали`** are `[~MM:SS]` offsets into the transcript, deliberately
  approximate — they exist so a reader can jump to the audio, not to be exact.

## Голосовой ввод (dicta) — не реплики встречи

`<meeting>/dicta.json` (S6.5) names the spans where the user was dictating to an agent through
`dicta` while the meeting was being recorded. The microphone captured that speech, so it is in the
transcript; it was addressed to a terminal, not to the people in the call. `dicta.json`'s `target`
field says which agterm session it was aimed at.

The rules, in force whenever `dicta.json` reports `matched` spans:

1. **A dictation span is never a meeting statement.** Never quote it as someone's position, never
   read a commitment or an agreement out of it, and never let it into `Что обсуждали` as if it were
   part of the discussion.
2. **An action point is never derived from a dictation span alone.** The user instructing an agent
   is not the user taking on a task in this meeting. If the same task genuinely came up in the call,
   the bullet cites *that*, not the dictation.
3. **Content that is clearly about this meeting's subject may be used as context** — and then the
   bullet carries the qualifier `(голосовой ввод, не реплика встречи)` verbatim. That is the
   "soften" case: the substance is admitted, the framing is not.
4. **A span about something else entirely** — a prompt on another project, an unrelated instruction
   — is dropped from `summary.md` completely. It is not an open question and it is not an omission
   worth noting.
5. **A cancelled dictation is still a dictation.** Should a `matched` span carry an `outcome` of
   `aborted` or `capture-fault`, it never reached the terminal (`final` is empty) — but it was
   spoken into the room Acta was recording. Rules 1–4 apply to it unchanged; that the user thought
   better of sending it is not a reason to promote it into the meeting.
6. **A `suspected` span is a question, not a verdict.** It has no text of its own (the attempt
   produced none), so only its window places it. Read the lines under it: if they are meeting
   speech, they stay meeting speech. Raise it with the user; never exclude on this evidence.
7. **An `unmatched` attempt is worth a line in the blockquote's `⚠️`.** dicta recorded a dictation
   during the meeting that was not found in the transcript, so an unmarked one is probably in there.
   Saying so costs a sentence; discovering it later costs the reader's trust in the whole document.

## What must not appear

- **Credentials.** If a gathered source contained one, flag it to the user; it never lands here.
  (See `air-skill-lessons.md` §4.)
- **A dictation span presented as meeting content.** See the section above: excluded, or admitted
  with the qualifier — never silently folded in as a participant's words.
- **Invented specifics.** Numbers, names, dates and ticket keys that the transcript and the
  gathered sources do not support. A summary is a view over `transcript.raw.md`, under exactly the
  same rule as the cleaned transcript: readable, never fabricated.
