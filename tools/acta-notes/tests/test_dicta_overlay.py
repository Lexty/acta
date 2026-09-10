import _ctx

import contextlib
import io
import json
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

overlay = _ctx.load("dicta_overlay")

START = datetime(2026, 8, 21, 11, 17, 43, tzinfo=timezone.utc)

DICTATION = "Клод посмотри пожалуйста на файл контроллера и объясни почему тест падает"
MEETING_OPENER = "да я согласен с этим предложением давайте так и сделаем"
MEETING_CLOSER = "извините я отвлекся давайте продолжим по повестке"


def iso(moment) -> str:
    return moment.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def at(seconds) -> str:
    """A wall-clock stamp ``seconds`` into the meeting."""
    return iso(START + timedelta(seconds=seconds))


def words(text, t0, rate=0.45):
    """``text`` laid out as S3 word timings starting at ``t0``."""
    out, t = [], float(t0)
    for word in text.split():
        out.append(
            {"word": word, "start": round(t, 3), "end": round(t + rate * 0.8, 3),
             "confidence": 0.95}
        )
        t += rate
    return out


def utterance(text, t0, track, speaker, rate=0.45):
    spans = words(text, t0, rate)
    return {
        "start": spans[0]["start"],
        "end": max(w["end"] for w in spans),
        "text": " ".join(w["word"] for w in spans),
        "word_count": len(spans),
        "track": track,
        "speaker": speaker,
    }


def entry(attempt_id, **fields):
    """One dicta §9 record line, with the fields a candidate needs."""
    base = {
        "id": attempt_id,
        "at": at(0),
        "outcome": "injected",
        "mode": "clean",
        "recognised": "",
        "final": "",
        "rules": {"fired": []},
        "target": {"pane": "left", "sessionID": "ABC"},
    }
    base.update(fields)
    return base


def spoken(attempt_id, text, from_seconds, duration=6.0, **fields):
    """An attempt whose speech window dicta itself recorded.

    ``final`` defaults to the recognised text, which is the delivered shape. An
    attempt that was cancelled or faulted has text and an empty ``final``, so
    callers override it.
    """
    fields.setdefault("final", text)
    return entry(
        attempt_id,
        recognised=text,
        speechStartedAt=at(from_seconds),
        speechEndedAt=at(from_seconds + duration),
        audioSeconds=duration,
        at=at(from_seconds + duration + 0.2),
        **fields,
    )


@contextlib.contextmanager
def meeting(mic=None, system=None, utterances=None, record=(), started_at=iso(START)):
    """A meeting folder with the three inputs S6.5 reads, plus a record file."""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp) / "2026-08-21_1617__demo"
        work = root / ".acta-notes"
        work.mkdir(parents=True)

        manifest = {"segment_count": 10, "segment_seconds": 15, "status": "done"}
        if started_at is not None:
            manifest["started_at"] = started_at
        (root / "session.json").write_text(json.dumps(manifest), encoding="utf-8")

        if mic is not None or system is not None:
            (work / "transcribe.json").write_text(
                json.dumps(
                    {
                        "stage": "transcribe",
                        "status": "ok",
                        "tracks": [
                            {"track": "mic", "status": "ok", "words": mic or []},
                            {"track": "system", "status": "ok", "words": system or []},
                        ],
                    },
                    ensure_ascii=False,
                ),
                encoding="utf-8",
            )
        if utterances is not None:
            (work / "merge.json").write_text(
                json.dumps(
                    {"stage": "merge", "status": "ok", "utterances": utterances},
                    ensure_ascii=False,
                ),
                encoding="utf-8",
            )

        record_path = Path(tmp) / "record.jsonl"
        if record is not None:
            record_path.write_text(
                "".join(json.dumps(e, ensure_ascii=False) + "\n" for e in record),
                encoding="utf-8",
            )
        yield root, record_path


def leaked_meeting(**overrides):
    """The canonical shape: meeting speech, one dictation at 5:03, meeting speech."""
    mic = (
        words(MEETING_OPENER, 10.0)
        + words(DICTATION, 303.4)
        + words(MEETING_CLOSER, 340.0)
    )
    utterances = [
        utterance(MEETING_OPENER, 10.0, "mic", "Я"),
        utterance("тогда переходим к следующему пункту повестки", 60.0, "system", "SPK_01"),
        utterance(DICTATION, 303.4, "mic", "Я"),
        utterance(MEETING_CLOSER, 340.0, "mic", "Я"),
    ]
    kwargs = {
        "mic": mic,
        "system": words("тогда переходим к следующему пункту повестки", 60.0),
        "utterances": utterances,
    }
    kwargs.update(overrides)
    return meeting(**kwargs)


class RecordReadingTest(unittest.TestCase):
    """§9's file: append-only, last line per id wins, a torn tail costs itself."""

    def _read(self, lines):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "record.jsonl"
            path.write_text("\n".join(lines) + "\n", encoding="utf-8")
            return overlay.read_record(path)

    def test_one_entry_per_attempt_last_line_wins(self):
        entries, error = self._read(
            [
                json.dumps(entry(1, outcome="injected")),
                json.dumps(entry(2, outcome="injected")),
                json.dumps(entry(1, outcome="injection-partial")),
            ]
        )
        self.assertIsNone(error)
        self.assertEqual([e["id"] for e in entries], [1, 2])
        self.assertEqual(entries[0]["outcome"], "injection-partial")

    def test_a_torn_tail_costs_only_its_own_entry(self):
        entries, error = self._read(
            [json.dumps(entry(1)), '{"id": 2, "outcome": "inj']
        )
        self.assertIsNone(error)
        self.assertEqual([e["id"] for e in entries], [1])

    def test_a_line_without_an_id_is_not_an_entry(self):
        entries, _ = self._read([json.dumps({"outcome": "injected"})])
        self.assertEqual(entries, [])

    def test_a_missing_file_reports_rather_than_raises(self):
        entries, error = overlay.read_record(Path("/nonexistent/record.jsonl"))
        self.assertEqual(entries, [])
        self.assertIsNotNone(error)


class RealRecordFixtureTest(unittest.TestCase):
    """Two lines produced by the real daemon, not by this test file.

    ``fixtures/dicta-record-real.jsonl`` holds one entry from before the window
    fields existed (id 1) and one from after (id 167, an abort through a real
    microphone). Fabricating the shapes this stage reads would only assert that
    the reader agrees with the test's idea of dicta.
    """

    def setUp(self):
        self.entries, self.error = overlay.read_record(
            _ctx.fixture("dicta-record-real.jsonl")
        )

    def test_both_generations_of_the_record_are_read(self):
        self.assertIsNone(self.error)
        self.assertEqual([e["id"] for e in self.entries], [1, 167])

    def test_a_pre_window_line_falls_back_to_an_estimate(self):
        _, _, source = overlay.speech_window(self.entries[0])
        self.assertEqual(source, "estimated")

    def test_a_recorded_window_does_not_imply_a_recorded_duration(self):
        """`abort` discards the buffer, so `audioSeconds` is absent — not zero.

        Reading a present ``speechStartedAt`` as a promise that ``audioSeconds``
        is there too would make the whole abort class — the one with no text,
        and so the one this stage most needs the window for — unreadable.
        """
        entry_167 = self.entries[1]
        self.assertNotIn("audioSeconds", entry_167)
        began, ended, source = overlay.speech_window(entry_167)
        self.assertEqual(source, "recorded")
        self.assertAlmostEqual((ended - began).total_seconds(), 3.055, places=3)

    def test_an_attested_window_without_a_duration_can_still_be_suspected(self):
        self.assertIn("recorded", overlay.ATTESTED_WINDOW_SOURCES)

    def test_at_equals_the_end_on_this_shape_and_nothing_reads_that(self):
        """The coincidence is pinned here so no one keys on it there.

        On an attempt ended while collecting, dicta resolves the end from the
        same clock reading the record line is written with, so ``at`` and
        ``speechEndedAt`` are identical to the microsecond. That makes
        ``at != speechEndedAt`` look like a way to tell this shape from a drained
        one — it is not, it is an implementation detail. ``audioSeconds``,
        present or absent, is the real discriminator.

        **This equality is dicta's to break, and this assertion is the only code
        here that reads it.** dicta does not guarantee it: the end is resolved
        from the writer's clock because taking a second reading consumed a
        one-shot hook one of its daemon tests needs. If that stops being true —
        the discard moves before the append, or teardown becomes cheap enough to
        time properly — dicta would start writing a real end timestamp, which is
        a correctness improvement on its side and would turn this red.

        **When that happens, delete this assertion.** Do not look for a
        regression here, and do not ask dicta to keep the two equal. The
        docstring above is what this test exists to lead a reader to; the
        equality is scaffolding for that, and nothing in this tree — this test
        included — may depend on it.
        """
        entry_167 = self.entries[1]
        self.assertEqual(entry_167["at"], entry_167["speechEndedAt"])
        self.assertNotIn("speechEndedAt", overlay.ATTESTED_WINDOW_SOURCES)


class TimestampTest(unittest.TestCase):
    def test_reads_dictas_fractional_z(self):
        parsed = overlay.parse_timestamp("2026-08-23T10:49:06.842Z")
        self.assertEqual(parsed.tzinfo, timezone.utc)
        self.assertEqual(parsed.year, 2026)

    def test_reads_actas_whole_second_z(self):
        self.assertEqual(overlay.parse_timestamp("2026-08-21T11:17:43Z"), START)

    def test_a_naive_stamp_is_read_as_utc(self):
        self.assertEqual(overlay.parse_timestamp("2026-08-21T11:17:43"), START)

    def test_garbage_is_none_rather_than_an_exception(self):
        for value in ("", None, "yesterday", 17):
            self.assertIsNone(overlay.parse_timestamp(value))


class NormalizationTest(unittest.TestCase):
    """The three things the two recognisers disagree about, and nothing else."""

    def test_case_punctuation_and_yo_are_folded(self):
        self.assertEqual(
            overlay.tokenize("Ещё, раз: проверим!"), ["еще", "раз", "проверим"]
        )

    def test_the_same_speech_decoded_twice_tokenizes_alike(self):
        self.assertEqual(
            overlay.tokenize("Клод, посмотри пожалуйста — почему тест падает?"),
            overlay.tokenize("клод посмотри пожалуйста почему тест падает"),
        )


class SpeechWindowTest(unittest.TestCase):
    def test_recorded_boundaries_are_used_verbatim(self):
        began, ended, source = overlay.speech_window(
            spoken(1, "раз два три четыре", 100.0, duration=5.0)
        )
        self.assertEqual(source, "recorded")
        self.assertEqual((ended - began).total_seconds(), 5.0)

    def test_audio_seconds_places_the_window_back_from_at(self):
        began, ended, source = overlay.speech_window(
            entry(1, at=at(200.0), audioSeconds=8.0, recognised="раз два три четыре")
        )
        self.assertEqual(source, "audio_seconds")
        self.assertEqual((ended - began).total_seconds(), 8.0)
        self.assertEqual(ended, START + timedelta(seconds=200.0))

    def test_a_record_without_the_fields_is_estimated_from_the_text(self):
        _, _, source = overlay.speech_window(
            entry(1, at=at(200.0), recognised="раз два три четыре пять шесть")
        )
        self.assertEqual(source, "estimated")

    def test_an_entry_with_no_usable_stamp_has_no_window(self):
        began, ended, source = overlay.speech_window(entry(1, at="nonsense"))
        self.assertIsNone(began)
        self.assertIsNone(ended)
        self.assertEqual(source, "none")


class CandidateTest(unittest.TestCase):
    def test_only_attempts_reaching_the_recording_are_candidates(self):
        found = overlay.candidates(
            [
                spoken(1, "внутри встречи раз два", 300.0),
                spoken(2, "задолго до встречи", -100000.0),
                spoken(3, "спустя часы после", 100000.0),
            ],
            START,
            600.0,
        )
        self.assertEqual([c["attempt_id"] for c in found], [1])

    def test_candidates_come_back_in_transcript_order(self):
        found = overlay.candidates(
            [spoken(2, "второй раз два", 400.0), spoken(1, "первый раз два", 100.0)],
            START,
            600.0,
        )
        self.assertEqual([c["attempt_id"] for c in found], [1, 2])

    def test_the_projection_is_the_offset_the_clocks_would_agree_on(self):
        found = overlay.candidates([spoken(1, "раз два три", 250.0)], START, 600.0)
        self.assertEqual(found[0]["projected_start"], 250.0)


class AlignmentTest(unittest.TestCase):
    def test_the_same_speech_scores_one(self):
        stream = words(MEETING_OPENER, 0.0) + words(DICTATION, 100.0)
        found = overlay.align(overlay.tokenize(DICTATION), stream, 0.0, 1000.0)
        self.assertEqual(found["score"], 1.0)
        self.assertEqual(found["start"], 100.0)

    def test_unrelated_speech_of_the_same_length_does_not_reach_the_threshold(self):
        stream = words(MEETING_OPENER + " " + MEETING_CLOSER, 0.0)
        found = overlay.align(overlay.tokenize(DICTATION), stream, 0.0, 1000.0)
        self.assertLess(found["score"], overlay.DEFAULT_THRESHOLD)

    def test_the_band_is_what_stops_a_repeated_phrase_matching_an_hour_later(self):
        stream = words(DICTATION, 3600.0)
        self.assertIsNone(overlay.align(overlay.tokenize(DICTATION), stream, 0.0, 90.0))

    def test_frequent_function_words_are_not_junked_out_of_a_long_stream(self):
        """difflib's autojunk would drop exactly the tokens Russian aligns on.

        Over 200 elements it treats anything appearing in more than 1 % of the
        sequence as junk — which here is ``и``, ``в``, ``не``. With it left on,
        a perfect match in a long meeting scores below the threshold.
        """
        filler = " ".join(["и в не что мы это"] * 40)
        stream = words(filler, 0.0) + words(DICTATION, 500.0)
        self.assertGreater(len(stream), 200)
        found = overlay.align(overlay.tokenize(DICTATION), stream, 0.0, 10000.0)
        self.assertEqual(found["score"], 1.0)

    def test_punctuation_only_words_do_not_depress_precision(self):
        stream = words(DICTATION, 100.0)
        stream.insert(3, {"word": "—", "start": 101.3, "end": 101.35, "confidence": 0.4})
        found = overlay.align(overlay.tokenize(DICTATION), stream, 0.0, 1000.0)
        self.assertEqual(found["score"], 1.0)


class SearchTest(unittest.TestCase):
    def test_too_few_tokens_is_never_a_match(self):
        stream = words("да хорошо", 100.0)
        candidate = overlay.candidates([spoken(1, "да хорошо", 100.0)], START, 600.0)[0]
        self.assertIsNone(overlay.search(candidate, stream, 0.0, 90.0))


class CalibrationTest(unittest.TestCase):
    def _candidates_and_stream(self, drift):
        first, second = "первая диктовка раз два три", "вторая диктовка четыре пять шесть"
        stream = words(first, 100.0 + drift) + words(second, 300.0 + drift)
        found = overlay.candidates(
            [spoken(1, first, 100.0), spoken(2, second, 300.0)], START, 600.0
        )
        return found, stream

    def test_one_anchor_is_not_enough_to_move_the_clock(self):
        found, stream = self._candidates_and_stream(0.0)
        calibration = overlay.calibrate(found[:1], stream, 90.0)
        self.assertFalse(calibration["calibrated"])
        self.assertEqual(calibration["offset_seconds"], 0.0)

    def test_two_anchors_measure_the_drift(self):
        found, stream = self._candidates_and_stream(12.0)
        calibration = overlay.calibrate(found, stream, 90.0)
        self.assertTrue(calibration["calibrated"])
        self.assertAlmostEqual(calibration["offset_seconds"], 12.0, places=1)
        self.assertLess(calibration["spread_seconds"], 0.5)

    def test_a_weak_alignment_is_not_allowed_to_vote(self):
        found, stream = self._candidates_and_stream(0.0)
        # Only the first attempt's text is in the stream at all.
        stream = words("первая диктовка раз два три", 100.0)
        calibration = overlay.calibrate(found, stream, 90.0)
        self.assertFalse(calibration["calibrated"])


class CoverageTest(unittest.TestCase):
    def test_a_span_names_the_lines_it_touches_by_merge_index(self):
        rows = overlay.mic_utterances(
            {
                "utterances": [
                    utterance("первая реплика тут", 0.0, "mic", "Я"),
                    utterance("системная реплика", 30.0, "system", "SPK_01"),
                    utterance(DICTATION, 100.0, "mic", "Я"),
                ]
            }
        )
        covered = overlay.covered_utterances(100.0, 106.0, rows)
        self.assertEqual([c["index"] for c in covered], [2])
        self.assertFalse(covered[0]["partial"])

    def test_a_clipped_line_is_reported_as_partial(self):
        rows = overlay.mic_utterances(
            {"utterances": [utterance(MEETING_CLOSER, 100.0, "mic", "Я")]}
        )
        covered = overlay.covered_utterances(99.0, 100.5, rows)
        self.assertEqual(len(covered), 1)
        self.assertTrue(covered[0]["partial"])

    def test_the_system_track_is_never_a_candidate_for_marking(self):
        rows = overlay.mic_utterances(
            {"utterances": [utterance("чужая речь", 100.0, "system", "SPK_01")]}
        )
        self.assertEqual(rows, [])


class RunTest(unittest.TestCase):
    def test_a_leaked_dictation_is_matched_onto_its_line(self):
        with leaked_meeting() as (root, record_path):
            record_path.write_text(
                json.dumps(spoken(140, DICTATION, 303.0), ensure_ascii=False) + "\n",
                encoding="utf-8",
            )
            report = overlay.run(root, record=record_path)

        self.assertEqual(report["status"], "ok")
        self.assertEqual(report["counts"]["matched"], 1)
        marked = report["matched"][0]
        self.assertEqual(marked["attempt_id"], 140)
        self.assertGreaterEqual(marked["score"], 0.95)
        self.assertEqual([u["index"] for u in marked["utterances"]], [2])
        self.assertEqual(marked["target"]["sessionID"], "ABC")

    def test_real_meeting_speech_is_left_alone(self):
        """The harmful error, asserted directly rather than implied."""
        with leaked_meeting() as (root, record_path):
            record_path.write_text(
                json.dumps(spoken(140, DICTATION, 303.0), ensure_ascii=False) + "\n",
                encoding="utf-8",
            )
            report = overlay.run(root, record=record_path)

        marked = {
            u["index"] for row in report["matched"] for u in row["utterances"]
        }
        self.assertNotIn(0, marked)  # MEETING_OPENER
        self.assertNotIn(3, marked)  # MEETING_CLOSER

    def test_a_dictation_that_is_not_in_the_transcript_is_reported_loudly(self):
        absent = "переключись на ветку main и собери релиз для дева пожалуйста"
        with leaked_meeting() as (root, record_path):
            record_path.write_text(
                json.dumps(spoken(141, absent, 200.0), ensure_ascii=False) + "\n",
                encoding="utf-8",
            )
            report = overlay.run(root, record=record_path)

        self.assertEqual(report["counts"]["unmatched"], 1)
        self.assertEqual(report["counts"]["matched"], 0)

    def test_an_unmatched_attempt_carries_a_preview_and_not_its_text(self):
        """It may be about another project entirely; the folder is not its home."""
        absent = "переключись на ветку main и собери релиз для дева пожалуйста " * 3
        with leaked_meeting() as (root, record_path):
            record_path.write_text(
                json.dumps(spoken(141, absent, 200.0), ensure_ascii=False) + "\n",
                encoding="utf-8",
            )
            report = overlay.run(root, record=record_path)

        row = report["unmatched"][0]
        self.assertNotIn("recognised", row)
        self.assertLessEqual(len(row["preview"]), overlay.UNMATCHED_PREVIEW_CHARS)

    def test_an_aborted_attempt_that_carries_text_is_matched_like_any_other(self):
        """The verdict keys on text, never on outcome — and must keep doing so.

        This is an invariant of *this* stage, asserted independently of what
        dicta chooses to log. Today the discarded classes carry no text and so
        arrive as suspicions; whether dicta should recognise a cancelled buffer
        for its journal is undecided over there. If it ever does, nothing here
        needs to change — and an `outcome` this stage special-cased would
        quietly demote the whole class back to a suspicion the day it did.

        Either way the reasoning holds: such speech went into the microphone
        Acta was recording, and it was addressed to a terminal, whether or not
        the keystrokes were ever delivered.
        """
        with leaked_meeting() as (root, record_path):
            record_path.write_text(
                json.dumps(
                    spoken(140, DICTATION, 303.0, outcome="aborted", final=""),
                    ensure_ascii=False,
                )
                + "\n",
                encoding="utf-8",
            )
            report = overlay.run(root, record=record_path)

        self.assertEqual(report["counts"]["matched"], 1)
        self.assertEqual(report["counts"]["suspected"], 0)
        row = report["matched"][0]
        self.assertEqual(row["outcome"], "aborted")
        self.assertEqual(row["final"], "")  # it never reached the terminal
        self.assertEqual([u["index"] for u in row["utterances"]], [2])

    def test_an_aborted_attempt_with_text_can_anchor_the_clock(self):
        """And it would anchor the clock, which helps place every other span.

        The value of text on a cancelled attempt is not only that the attempt
        itself gets placed: with no anchors at all a window-only placement is
        worth ±90 s. This asserts the mechanism is outcome-blind, so that
        benefit needs no work here if dicta ever supplies the text.
        """
        drift = 9.0
        second = "собери релиз и выложи его на стенд пожалуйста"
        mic = words(DICTATION, 100.0 + drift) + words(second, 300.0 + drift)
        with meeting(mic=mic, utterances=[]) as (root, record_path):
            record_path.write_text(
                json.dumps(
                    spoken(1, DICTATION, 100.0, outcome="aborted", final=""),
                    ensure_ascii=False,
                )
                + "\n"
                + json.dumps(spoken(2, second, 300.0), ensure_ascii=False) + "\n",
                encoding="utf-8",
            )
            report = overlay.run(root, record=record_path)

        self.assertTrue(report["calibration"]["calibrated"])
        self.assertEqual(report["calibration"]["anchors"], 2)
        self.assertAlmostEqual(report["calibration"]["offset_seconds"], drift, places=0)

    def test_a_textless_attempt_over_the_audio_is_a_suspicion(self):
        with leaked_meeting() as (root, record_path):
            record_path.write_text(
                json.dumps(
                    spoken(142, "", 200.0, duration=5.0, outcome="capture-fault"),
                    ensure_ascii=False,
                )
                + "\n",
                encoding="utf-8",
            )
            report = overlay.run(root, record=record_path)

        self.assertEqual(report["counts"]["suspected"], 1)
        self.assertEqual(report["suspected"][0]["outcome"], "capture-fault")

    def test_a_suspicion_with_a_few_words_shows_them(self):
        """Too short to align on is not the same as nothing heard.

        "да хорошо" aligns with any two words in a real meeting, so it cannot
        place anything — but it is exactly what lets a reader dismiss the
        suspicion in one second instead of listening to the audio.
        """
        with leaked_meeting() as (root, record_path):
            record_path.write_text(
                json.dumps(
                    spoken(150, "да хорошо", 250.0, duration=3.0,
                           outcome="aborted", final=""),
                    ensure_ascii=False,
                )
                + "\n",
                encoding="utf-8",
            )
            report = overlay.run(root, record=record_path)

        row = report["suspected"][0]
        self.assertEqual(row["recognised"], "да хорошо")
        self.assertEqual(row["text_words"], 2)
        self.assertIn("2 word(s) recognised", row["reason"])

    def test_a_suspicion_with_nothing_heard_says_so(self):
        with leaked_meeting() as (root, record_path):
            record_path.write_text(
                json.dumps(
                    spoken(151, "", 250.0, duration=5.0, outcome="capture-fault"),
                    ensure_ascii=False,
                )
                + "\n",
                encoding="utf-8",
            )
            report = overlay.run(root, record=record_path)

        row = report["suspected"][0]
        self.assertEqual(row["text_words"], 0)
        self.assertIn("no text on this attempt", row["reason"])

    def test_dictas_own_note_is_carried_through_unparsed(self):
        """The words that say whether anyone looked — passed on, never read.

        §9's `error` accumulates notes and is human-readable, so a rule keying
        on its wording breaks quietly the day a message is reworded — and in the
        reassuring direction, which is the one that hides a real leak. It is
        forwarded verbatim so the person reading quality.md can judge, and this
        report decides nothing from it.
        """
        note = "aborted; the words spoken before this attempt ended could not be recognised: boom"
        with leaked_meeting() as (root, record_path):
            record_path.write_text(
                json.dumps(
                    spoken(152, "", 250.0, duration=4.0, outcome="aborted",
                           final="", error=note),
                    ensure_ascii=False,
                )
                + "\n",
                encoding="utf-8",
            )
            report = overlay.run(root, record=record_path)

        row = report["suspected"][0]
        self.assertEqual(row["error"], note)
        # A recogniser that fell over establishes nothing, so the suspicion is
        # not softened by any wording in that note.
        self.assertIn("no text on this attempt", row["reason"])

    def test_an_uncalibrated_suspicion_admits_it_is_not_placed(self):
        """With no text match anywhere, the clocks were never compared."""
        with leaked_meeting() as (root, record_path):
            record_path.write_text(
                json.dumps(
                    spoken(142, "", 250.0, duration=5.0, outcome="aborted"),
                    ensure_ascii=False,
                )
                + "\n",
                encoding="utf-8",
            )
            report = overlay.run(root, record=record_path)

        row = report["suspected"][0]
        self.assertEqual(row["placement"], "uncalibrated")
        self.assertEqual(row["uncertainty_seconds"], overlay.DEFAULT_BAND_SECONDS)
        # The whole transcript is inside ±90 s of the guess, and saying so is
        # what stops a reader marking the two lines the guess happens to hit.
        self.assertGreater(row["lines_within_uncertainty"], len(row["utterances"]))

    def test_a_calibrated_suspicion_is_placed_far_more_tightly(self):
        drift = 8.0
        second = "собери релиз и выложи его на стенд пожалуйста"
        mic = (
            words(DICTATION, 100.0 + drift)
            + words(second, 300.0 + drift)
            + words(MEETING_CLOSER, 500.0)
        )  # the transcript's own clock ends a little past 503 s
        with meeting(mic=mic, utterances=[]) as (root, record_path):
            record_path.write_text(
                json.dumps(spoken(1, DICTATION, 100.0), ensure_ascii=False) + "\n"
                + json.dumps(spoken(2, second, 300.0), ensure_ascii=False) + "\n"
                + json.dumps(
                    spoken(3, "", 470.0, duration=5.0, outcome="aborted"),
                    ensure_ascii=False,
                )
                + "\n",
                encoding="utf-8",
            )
            report = overlay.run(root, record=record_path)

        row = report["suspected"][0]
        self.assertEqual(row["placement"], "calibrated")
        self.assertLessEqual(
            row["uncertainty_seconds"], overlay.MIN_CALIBRATED_UNCERTAINTY_SECONDS + 1
        )
        self.assertAlmostEqual(row["transcript_start"], 470.0 + drift, delta=1.0)

    def test_a_calibrated_placement_never_claims_zero_uncertainty(self):
        drift = 8.0
        second = "собери релиз и выложи его на стенд пожалуйста"
        mic = words(DICTATION, 100.0 + drift) + words(second, 300.0 + drift)
        with meeting(mic=mic, utterances=[]) as (root, record_path):
            record_path.write_text(
                json.dumps(spoken(1, DICTATION, 100.0), ensure_ascii=False) + "\n"
                + json.dumps(spoken(2, second, 300.0), ensure_ascii=False) + "\n",
                encoding="utf-8",
            )
            report = overlay.run(root, record=record_path)

        self.assertTrue(report["calibration"]["calibrated"])
        self.assertGreaterEqual(
            report["placement_uncertainty_seconds"],
            overlay.MIN_CALIBRATED_UNCERTAINTY_SECONDS,
        )

    def test_a_textless_attempt_clear_of_the_audio_names_no_line(self):
        with leaked_meeting() as (root, record_path):
            # The transcript ends around 00:05:43; this sits well past it but
            # still inside the candidacy band.
            record_path.write_text(
                json.dumps(
                    spoken(143, "", 400.0, duration=5.0, outcome="capture-fault"),
                    ensure_ascii=False,
                )
                + "\n",
                encoding="utf-8",
            )
            report = overlay.run(root, record=record_path)

        self.assertEqual(report["counts"]["suspected"], 0)

    def test_a_misfired_chord_raises_no_suspicion(self):
        """Three aborts a second apart is what the real record is full of."""
        with leaked_meeting() as (root, record_path):
            record_path.write_text(
                "".join(
                    json.dumps(
                        entry(i, at=at(200.0 + i), outcome="aborted", error="aborted"),
                        ensure_ascii=False,
                    )
                    + "\n"
                    for i in (163, 164, 165)
                ),
                encoding="utf-8",
            )
            report = overlay.run(root, record=record_path)

        self.assertEqual(report["counts"], {
            "candidates": 3, "matched": 0, "suspected": 0, "unmatched": 0
        })

    def test_the_clock_is_calibrated_from_two_matches_and_reported(self):
        drift = 11.0
        mic = (
            words(MEETING_OPENER, 10.0)
            + words(DICTATION, 100.0 + drift)
            + words("собери релиз и выложи его на стенд пожалуйста", 300.0 + drift)
        )
        second = "собери релиз и выложи его на стенд пожалуйста"
        with meeting(mic=mic, utterances=[]) as (root, record_path):
            record_path.write_text(
                json.dumps(spoken(1, DICTATION, 100.0), ensure_ascii=False) + "\n"
                + json.dumps(spoken(2, second, 300.0), ensure_ascii=False) + "\n",
                encoding="utf-8",
            )
            report = overlay.run(root, record=record_path)

        self.assertTrue(report["calibration"]["calibrated"])
        self.assertAlmostEqual(report["calibration"]["offset_seconds"], drift, places=0)
        self.assertEqual(report["counts"]["matched"], 2)

    def test_no_dicta_record_is_a_skip_and_not_a_failure(self):
        with leaked_meeting() as (root, record_path):
            record_path.unlink()
            report = overlay.run(root, record=record_path)

        self.assertEqual(report["status"], "skipped")
        self.assertEqual(overlay.exit_code(report), overlay.EXIT_OK)

    def test_a_teams_folder_with_no_asr_report_is_a_skip(self):
        with meeting(record=[spoken(1, DICTATION, 100.0)]) as (root, record_path):
            report = overlay.run(root, record=record_path)

        self.assertEqual(report["status"], "skipped")
        self.assertIn("S3 has not run here", report["detail"])

    def test_a_recording_with_no_mic_track_is_a_different_skip(self):
        """A silent or absent mic is not the Teams path, and does not read as it."""
        with meeting(
            mic=[], system=words("одна только системная дорожка тут", 0.0)
        ) as (root, record_path):
            record_path.write_text(
                json.dumps(spoken(1, DICTATION, 100.0), ensure_ascii=False) + "\n",
                encoding="utf-8",
            )
            report = overlay.run(root, record=record_path)

        self.assertEqual(report["status"], "skipped")
        self.assertIn("no mic track", report["detail"])

    def test_a_meeting_with_no_start_time_cannot_be_placed(self):
        with leaked_meeting(started_at=None) as (root, record_path):
            record_path.write_text(
                json.dumps(spoken(1, DICTATION, 303.0), ensure_ascii=False) + "\n",
                encoding="utf-8",
            )
            report = overlay.run(root, record=record_path)

        self.assertEqual(report["status"], "failed")
        self.assertEqual(overlay.exit_code(report), overlay.EXIT_FAILED)


class MainTest(unittest.TestCase):
    def test_it_writes_dicta_json_at_the_meeting_root(self):
        with leaked_meeting() as (root, record_path):
            record_path.write_text(
                json.dumps(spoken(140, DICTATION, 303.0), ensure_ascii=False) + "\n",
                encoding="utf-8",
            )
            buffer = io.StringIO()
            with contextlib.redirect_stdout(buffer):
                code = overlay.main([str(root), "--record", str(record_path), "--json"])

            self.assertEqual(code, overlay.EXIT_OK)
            written = json.loads((root / "dicta.json").read_text(encoding="utf-8"))
            self.assertEqual(written["counts"]["matched"], 1)
            self.assertEqual(json.loads(buffer.getvalue())["stage"], "dicta_overlay")

    def test_it_writes_no_transcript(self):
        with leaked_meeting() as (root, record_path):
            record_path.write_text(
                json.dumps(spoken(140, DICTATION, 303.0), ensure_ascii=False) + "\n",
                encoding="utf-8",
            )
            before = sorted(p.name for p in root.iterdir())
            with contextlib.redirect_stdout(io.StringIO()):
                overlay.main([str(root), "--record", str(record_path)])
            after = sorted(p.name for p in root.iterdir())

            self.assertEqual(set(after) - set(before), {"dicta.json"})

    def test_a_missing_meeting_folder_is_a_usage_error(self):
        with self.assertRaises(SystemExit) as raised:
            with contextlib.redirect_stderr(io.StringIO()):
                overlay.main(["/nonexistent/meeting"])
        self.assertEqual(raised.exception.code, overlay.EXIT_USAGE)


if __name__ == "__main__":
    unittest.main()
