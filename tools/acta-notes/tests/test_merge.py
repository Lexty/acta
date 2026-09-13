import _ctx

import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path

merge = _ctx.load("merge")


def words(*specs):
    """``(word, start, end[, confidence])`` tuples → S3's normalized word shape."""
    out = []
    for spec in specs:
        word, start, end = spec[0], spec[1], spec[2]
        confidence = spec[3] if len(spec) > 3 else 0.95
        out.append(
            {"word": word, "start": start, "end": end, "confidence": confidence}
        )
    return out


def transcribe_json(mic=(), system=()):
    return {
        "stage": "transcribe",
        "status": "ok",
        "tracks": [
            {"track": "mic", "status": "ok", "words": list(mic)},
            {"track": "system", "status": "ok", "words": list(system)},
        ],
    }


def diarization_json(*spans):
    """``(speaker, start, end)`` tuples → S4's normalized segment shape."""
    return {
        "stage": "diarize",
        "status": "ok",
        "segments": [
            {
                "start": start,
                "end": end,
                "duration": round(end - start, 3),
                "speaker": speaker,
                "speaker_id": speaker.replace("SPK_", "Speaker "),
                "quality": 0.9,
            }
            for speaker, start, end in spans
        ],
    }


@contextlib.contextmanager
def meeting(mic=(), system=(), segments=(), name="2026-07-29 Weekly"):
    """A meeting folder holding exactly the stage JSONs S5 reads."""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp) / name
        (root / ".acta-notes").mkdir(parents=True)
        merge.transcribe_json_path(root).write_text(
            json.dumps(transcribe_json(mic=mic, system=system)), encoding="utf-8"
        )
        if segments:
            merge.diarization_json_path(root).write_text(
                json.dumps(diarization_json(*segments)), encoding="utf-8"
            )
        yield root


def utterance(start, end, count=1):
    return {"start": start, "end": end, "word_count": count}


def transcript_lines(text):
    return [line for line in text.splitlines() if line.startswith("**[")]


class PauseBoundaryTests(unittest.TestCase):
    def test_the_boundary_is_pinned_to_the_spike(self):
        self.assertEqual(merge.PAUSE_SPLIT_SECONDS, 0.7)

    def test_a_gap_of_069_keeps_one_utterance(self):
        result = merge.split_utterances(
            words(("раз", 0.0, 1.0), ("два", 1.69, 2.0))
        )
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0]["text"], "раз два")
        self.assertEqual(result[0]["word_count"], 2)

    def test_a_gap_of_071_splits(self):
        result = merge.split_utterances(
            words(("раз", 0.0, 1.0), ("два", 1.71, 2.0))
        )
        self.assertEqual([u["text"] for u in result], ["раз", "два"])

    def test_a_gap_of_exactly_070_does_not_split(self):
        # Strictly greater: making the boundary inclusive would split on the
        # very value the spike settled on.
        result = merge.split_utterances(words(("раз", 0.0, 1.0), ("два", 1.7, 2.0)))
        self.assertEqual(len(result), 1)

    def test_utterance_bounds_and_confidence(self):
        result = merge.split_utterances(
            words(("раз", 0.5, 1.0, 0.9), ("два", 1.1, 2.25, 0.7))
        )
        self.assertEqual(result[0]["start"], 0.5)
        self.assertEqual(result[0]["end"], 2.25)
        self.assertAlmostEqual(result[0]["mean_confidence"], 0.8)
        self.assertAlmostEqual(result[0]["min_confidence"], 0.7)

    def test_an_overlapping_word_tail_does_not_shorten_the_utterance(self):
        result = merge.split_utterances(
            words(("раз", 0.0, 3.0), ("два", 0.5, 1.0))
        )
        self.assertEqual(result[0]["end"], 3.0)

    def test_the_split_measures_the_gap_from_the_same_reach_the_span_reports(self):
        # The split read `current[-1]["end"]` while `_utterance` reports max(end).
        # With an overlapping tail the two disagreed: a 5 s word followed by two
        # short ones split off a second utterance whose whole span (3.0–3.5) sat
        # inside the first one's (0.0–5.0) — an impossible pair for every overlap
        # computation downstream.
        result = merge.split_utterances(
            words(("аaa", 0.0, 5.0), ("б", 1.0, 1.5), ("в", 3.0, 3.5))
        )
        self.assertEqual(len(result), 1)
        self.assertEqual((result[0]["start"], result[0]["end"]), (0.0, 5.0))
        self.assertEqual(result[0]["word_count"], 3)

    def test_a_real_pause_after_an_overlapping_tail_still_splits(self):
        result = merge.split_utterances(
            words(("аaa", 0.0, 5.0), ("б", 1.0, 1.5), ("в", 6.0, 6.5))
        )
        self.assertEqual([u["text"] for u in result], ["аaa б", "в"])
        self.assertEqual((result[0]["start"], result[0]["end"]), (0.0, 5.0))

    def test_no_words_is_no_utterances(self):
        self.assertEqual(merge.split_utterances([]), [])


class AssignmentTests(unittest.TestCase):
    segments = [
        {"start": 0.0, "end": 10.0, "speaker": "SPK_01"},
        {"start": 10.0, "end": 20.0, "speaker": "SPK_02"},
        {"start": 30.0, "end": 40.0, "speaker": "SPK_03"},
    ]

    def test_majority_by_overlapped_duration_wins(self):
        # 2 s inside SPK_01, 6 s inside SPK_02 — the utterance is SPK_02's turn,
        # even though it started while SPK_01 was still speaking.
        speaker, method, seconds = merge.assign_speaker(
            utterance(8.0, 16.0), self.segments
        )
        self.assertEqual(speaker, "SPK_02")
        self.assertEqual(method, merge.ASSIGNMENT_OVERLAP)
        self.assertEqual(seconds, 6.0)

    def test_partial_overlap_at_the_other_end(self):
        speaker, method, _ = merge.assign_speaker(utterance(2.0, 11.0), self.segments)
        self.assertEqual(speaker, "SPK_01")
        self.assertEqual(method, merge.ASSIGNMENT_OVERLAP)

    def test_split_turns_of_one_speaker_are_summed(self):
        segments = [
            {"start": 0.0, "end": 3.0, "speaker": "SPK_01"},
            {"start": 3.0, "end": 7.0, "speaker": "SPK_02"},
            {"start": 7.0, "end": 10.0, "speaker": "SPK_01"},
        ]
        speaker, _, seconds = merge.assign_speaker(utterance(0.0, 10.0), segments)
        self.assertEqual(speaker, "SPK_01")
        self.assertEqual(seconds, 6.0)

    def test_an_exact_tie_resolves_to_the_earliest_segment(self):
        segments = [
            {"start": 0.0, "end": 5.0, "speaker": "SPK_02"},
            {"start": 5.0, "end": 10.0, "speaker": "SPK_01"},
        ]
        speaker, _, _ = merge.assign_speaker(utterance(0.0, 10.0), segments)
        self.assertEqual(speaker, "SPK_02")

    def test_touching_intervals_do_not_count_as_overlap(self):
        # Ends exactly where SPK_02 begins: zero overlapped duration, so this is
        # the fallback path, not a 0-second "majority".
        speaker, method, seconds = merge.assign_speaker(
            utterance(20.0, 22.0), self.segments
        )
        self.assertEqual(method, merge.ASSIGNMENT_FALLBACK)
        self.assertEqual(seconds, 0.0)
        self.assertEqual(speaker, "SPK_02")

    def test_nearest_segment_fallback_for_an_unoverlapped_utterance(self):
        # Sits in the 20–30 s gap, 4 s after SPK_02 and 6 s before SPK_03.
        speaker, method, _ = merge.assign_speaker(
            utterance(24.0, 25.0), self.segments
        )
        self.assertEqual(speaker, "SPK_02")
        self.assertEqual(method, merge.ASSIGNMENT_FALLBACK)

    def test_nearest_segment_fallback_looks_forward_too(self):
        speaker, method, _ = merge.assign_speaker(
            utterance(28.0, 29.0), self.segments
        )
        self.assertEqual(speaker, "SPK_03")
        self.assertEqual(method, merge.ASSIGNMENT_FALLBACK)

    def test_no_segments_assigns_nothing(self):
        self.assertEqual(merge.assign_speaker(utterance(0.0, 1.0), []), (None, None, 0.0))

    def test_overlap_seconds_is_clamped_at_zero(self):
        self.assertEqual(merge.overlap_seconds(0.0, 1.0, 2.0, 3.0), 0.0)
        self.assertEqual(merge.overlap_seconds(0.0, 2.0, 1.0, 3.0), 1.0)


class InterleaveTests(unittest.TestCase):
    def test_mic_lines_are_labelled_and_ordered_by_timestamp(self):
        mic = [dict(utterance(5.0, 6.0), text="ага")]
        system = [
            dict(utterance(0.0, 4.0), text="привет", speaker="SPK_01"),
            dict(utterance(7.0, 9.0), text="дальше", speaker="SPK_02"),
        ]
        rows = merge.interleave(mic, system)
        self.assertEqual(
            [(r["speaker"], r["track"]) for r in rows],
            [("SPK_01", "system"), ("Я", "mic"), ("SPK_02", "system")],
        )
        self.assertEqual(rows[1]["assignment"], merge.ASSIGNMENT_TRACK)

    def test_a_tie_puts_the_mic_first_and_stays_stable(self):
        mic = [dict(utterance(3.0, 3.5), text="да")]
        system = [dict(utterance(3.0, 4.0), text="нет", speaker="SPK_01")]
        rows = merge.interleave(mic, system)
        self.assertEqual([r["track"] for r in rows], ["mic", "system"])
        self.assertEqual(rows, merge.interleave(mic, system))

    def test_interleaving_does_not_mutate_the_inputs(self):
        mic = [dict(utterance(1.0, 2.0), text="да")]
        merge.interleave(mic, [])
        self.assertNotIn("speaker", mic[0])


class CoverageTests(unittest.TestCase):
    def test_coverage_counts_only_overlap_assigned_words(self):
        system = [
            dict(utterance(0.0, 1.0, count=9), assignment=merge.ASSIGNMENT_OVERLAP),
            dict(utterance(2.0, 3.0, count=1), assignment=merge.ASSIGNMENT_FALLBACK),
        ]
        stats = merge.coverage_stats(system)
        self.assertEqual(stats["system_word_count"], 10)
        self.assertEqual(stats["overlap_words"], 9)
        self.assertEqual(stats["fallback_words"], 1)
        self.assertEqual(stats["unassigned_words"], 0)
        self.assertEqual(stats["coverage"], 0.9)
        self.assertEqual(stats["assigned_coverage"], 1.0)

    def test_an_empty_system_track_has_no_coverage_number(self):
        stats = merge.coverage_stats([])
        self.assertIsNone(stats["coverage"])
        self.assertEqual(stats["system_word_count"], 0)


class RunTests(unittest.TestCase):
    mic = words(("ага", 5.0, 5.4))
    system = words(
        ("привет", 0.5, 1.0),
        ("коллеги", 1.1, 1.8),
        ("да", 12.0, 12.4),
        ("конечно", 12.5, 13.0),
    )
    segments = (("SPK_01", 0.0, 4.0), ("SPK_02", 11.0, 15.0))

    def test_a_full_merge_writes_the_raw_transcript(self):
        with meeting(mic=self.mic, system=self.system, segments=self.segments) as root:
            report = merge.run(root)
        self.assertEqual(report["status"], merge.STATUS_OK)
        self.assertTrue(report["written"])
        self.assertEqual(report["utterance_count"], 3)
        self.assertEqual(report["speaker_count"], 2)
        self.assertEqual(report["coverage"], 1.0)

    def test_the_transcript_lines_read_in_timestamp_order(self):
        with meeting(mic=self.mic, system=self.system, segments=self.segments) as root:
            merge.run(root)
            text = merge.transcript_path(root).read_text(encoding="utf-8")
        self.assertEqual(
            transcript_lines(text),
            [
                "**[00:00:00] SPK_01:** привет коллеги",
                "**[00:00:05] Я:** ага",
                "**[00:00:12] SPK_02:** да конечно",
            ],
        )

    def test_the_heading_defaults_to_the_folder_name(self):
        with meeting(mic=self.mic, system=self.system, segments=self.segments) as root:
            merge.run(root)
            text = merge.transcript_path(root).read_text(encoding="utf-8")
        self.assertTrue(text.startswith("# 2026-07-29 Weekly — транскрипт"))
        self.assertIn("Дословно", text)

    def test_an_explicit_title_wins(self):
        with meeting(mic=self.mic, system=self.system, segments=self.segments) as root:
            merge.run(root, title="Стендап")
            text = merge.transcript_path(root).read_text(encoding="utf-8")
        self.assertTrue(text.startswith("# Стендап — транскрипт"))

    def test_the_run_is_reproducible_byte_for_byte(self):
        with meeting(mic=self.mic, system=self.system, segments=self.segments) as root:
            merge.run(root)
            first = merge.transcript_path(root).read_bytes()
            merge.run(root, force=True)
            self.assertEqual(merge.transcript_path(root).read_bytes(), first)

    def test_it_writes_neither_labeled_nor_clean_transcript(self):
        with meeting(mic=self.mic, system=self.system, segments=self.segments) as root:
            merge.run(root)
            self.assertFalse((root / "transcript.labeled.md").exists())
            self.assertFalse((root / "transcript.md").exists())

    def test_a_fallback_assignment_lands_in_the_report(self):
        system = words(("эхо", 30.0, 30.5))
        with meeting(system=system, segments=self.segments) as root:
            report = merge.run(root)
        self.assertEqual(report["status"], merge.STATUS_OK)
        self.assertEqual(report["fallback_words"], 1)
        self.assertEqual(report["coverage"], 0.0)
        self.assertEqual(report["assigned_coverage"], 1.0)
        self.assertEqual(report["utterances"][0]["speaker"], "SPK_02")

    def test_a_mic_only_meeting_needs_no_diarization(self):
        with meeting(mic=self.mic) as root:
            report = merge.run(root)
        self.assertEqual(report["status"], merge.STATUS_OK)
        self.assertEqual(report["utterance_count"], 1)
        self.assertEqual(report["speaker_count"], 0)
        self.assertIsNone(report["coverage"])

    def test_a_missing_transcribe_json_is_reported_not_invented(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "meeting"
            root.mkdir()
            report = merge.run(root)
        self.assertEqual(report["status"], merge.STATUS_MISSING)
        self.assertIn("transcribe.py", report["detail"])
        self.assertFalse(report["written"])

    def test_a_missing_diarization_json_stops_the_stage(self):
        with meeting(mic=self.mic, system=self.system) as root:
            report = merge.run(root)
            self.assertFalse(merge.transcript_path(root).exists())
        self.assertEqual(report["status"], merge.STATUS_MISSING)
        self.assertIn("diarize.py", report["detail"])

    def test_an_empty_diarization_stops_the_stage(self):
        with meeting(mic=self.mic, system=self.system, segments=self.segments) as root:
            merge.diarization_json_path(root).write_text(
                json.dumps({"segments": []}), encoding="utf-8"
            )
            report = merge.run(root)
            self.assertFalse(merge.transcript_path(root).exists())
        self.assertEqual(report["status"], merge.STATUS_FAILED)
        self.assertIn("no usable speaker segments", report["detail"])

    def test_no_words_on_either_track_is_a_failure(self):
        with meeting() as root:
            report = merge.run(root)
        self.assertEqual(report["status"], merge.STATUS_FAILED)
        self.assertIn("nothing to merge", report["detail"])

    def test_words_are_sorted_before_splitting(self):
        scrambled = words(("два", 1.0, 1.5), ("раз", 0.0, 0.5))
        with meeting(system=scrambled, segments=self.segments) as root:
            report = merge.run(root)
        self.assertEqual(report["utterances"][0]["text"], "раз два")


class OverwriteProtectionTests(unittest.TestCase):
    def test_an_existing_raw_transcript_is_never_replaced(self):
        with meeting(
            mic=RunTests.mic, system=RunTests.system, segments=RunTests.segments
        ) as root:
            out = merge.transcript_path(root)
            out.write_text("#手书きの真実\n", encoding="utf-8")
            before = out.read_bytes()
            report = merge.run(root)
            self.assertEqual(out.read_bytes(), before)
        self.assertEqual(report["status"], merge.STATUS_REFUSED)
        self.assertFalse(report["written"])
        self.assertEqual(merge.exit_code(report), 2)
        self.assertIn("--force", report["detail"])

    def test_force_replaces_it(self):
        with meeting(
            mic=RunTests.mic, system=RunTests.system, segments=RunTests.segments
        ) as root:
            out = merge.transcript_path(root)
            out.write_text("stale\n", encoding="utf-8")
            report = merge.run(root, force=True)
            self.assertIn("транскрипт", out.read_text(encoding="utf-8"))
        self.assertEqual(report["status"], merge.STATUS_OK)
        self.assertTrue(report["forced"])

    def test_the_refusal_message_is_shared_with_the_teams_converter(self):
        # Task 10's converter repeats this verbatim — the two producers of
        # transcript.raw.md must fail identically.
        message = merge.overwrite_refusal(Path("/x/transcript.raw.md"))
        self.assertIn("/x/transcript.raw.md", message)
        self.assertIn("--force", message)

    def test_a_refusal_leaves_no_stage_json_behind(self):
        with meeting(
            mic=RunTests.mic, system=RunTests.system, segments=RunTests.segments
        ) as root:
            merge.transcript_path(root).write_text("hand-made\n", encoding="utf-8")
            with contextlib.redirect_stdout(io.StringIO()):
                code = merge.main([str(root)])
            self.assertFalse(merge.stage_json_path(root).exists())
        self.assertEqual(code, 2)


class MainTests(unittest.TestCase):
    def test_json_output_and_stage_file(self):
        with meeting(
            mic=RunTests.mic, system=RunTests.system, segments=RunTests.segments
        ) as root:
            buffer = io.StringIO()
            with contextlib.redirect_stdout(buffer):
                code = merge.main([str(root), "--json"])
            payload = json.loads(buffer.getvalue())
            stage = json.loads(
                merge.stage_json_path(root).read_text(encoding="utf-8")
            )
        self.assertEqual(code, 0)
        self.assertEqual(payload["stage"], "merge")
        self.assertEqual(payload["coverage"], 1.0)
        self.assertEqual(stage["utterance_count"], payload["utterance_count"])

    def test_human_output_names_the_transcript(self):
        with meeting(
            mic=RunTests.mic, system=RunTests.system, segments=RunTests.segments
        ) as root:
            buffer = io.StringIO()
            with contextlib.redirect_stdout(buffer):
                code = merge.main([str(root)])
            text = buffer.getvalue()
        self.assertEqual(code, 0)
        self.assertIn("OK", text)
        self.assertIn("transcript.raw.md", text)
        self.assertIn("coverage", text)

    def test_a_missing_input_exits_one(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "meeting"
            root.mkdir()
            with contextlib.redirect_stdout(io.StringIO()):
                code = merge.main([str(root)])
        self.assertEqual(code, 1)

    def test_a_missing_meeting_folder_is_an_argparse_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            with contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as raised:
                    merge.main([str(Path(tmp) / "nope")])
        self.assertEqual(raised.exception.code, 2)


class NonNumericInputTests(unittest.TestCase):
    """merge reads stage JSONs off disk — files that can be truncated or hand
    edited. A non-numeric timing must drop the entry, not raise past run()."""

    def test_a_non_numeric_word_timing_is_dropped(self):
        report = {
            "tracks": [
                {
                    "track": "mic",
                    "words": [
                        {"word": "раз", "start": 0.0, "end": 0.4},
                        {"word": "два", "start": "n/a", "end": 1.0},
                    ],
                }
            ]
        }
        words = merge.words_for_track(report, "mic")
        self.assertEqual([w["word"] for w in words], ["раз"])

    def test_a_non_numeric_segment_bound_is_dropped(self):
        report = {
            "segments": [
                {"start": 0.0, "end": 2.0, "speaker": "SPK_01"},
                {"start": 2.0, "end": "later", "speaker": "SPK_02"},
            ]
        }
        segments = merge.segments_from(report)
        self.assertEqual([s["speaker"] for s in segments], ["SPK_01"])

    def test_a_non_numeric_confidence_is_dropped_not_summed(self):
        """`confidence` goes through as_number like the timings do.

        It used to be copied verbatim, so a string confidence reached
        ``_utterance``'s ``sum()`` and killed S5 with a raw TypeError and no
        merge.json — instead of the structured failed report every other
        malformed-input path here produces.
        """
        report = {
            "tracks": [
                {
                    "track": "mic",
                    "words": [{"word": "привет", "start": 1.0, "end": 1.4, "confidence": "n/a"}],
                }
            ]
        }
        words = merge.words_for_track(report, "mic")
        self.assertEqual([w["confidence"] for w in words], [None])
        utterance = merge._utterance(words)
        self.assertIsNone(utterance["mean_confidence"])
        self.assertIsNone(utterance["min_confidence"])

    def test_a_word_ending_before_it_starts_is_dropped(self):
        """The same rule ``segments_from`` applies, applied to words.

        An inverted word poisoned the running ``reach`` in ``split_utterances``
        (a low reach inflates the next gap and forces a spurious split) and let
        ``_utterance`` emit ``end < start``, which ``assign_speaker``'s overlap
        maths then read as no overlap at all.
        """
        report = {
            "tracks": [
                {
                    "track": "mic",
                    "words": [
                        {"word": "раз", "start": 0.0, "end": 0.4},
                        {"word": "эм", "start": 12.0, "end": 11.5},
                        {"word": "два", "start": 0.5, "end": 0.9},
                    ],
                }
            ]
        }
        self.assertEqual(
            [w["word"] for w in merge.words_for_track(report, "mic")], ["раз", "два"]
        )

    def test_a_zero_length_word_is_dropped(self):
        report = {
            "tracks": [{"track": "mic", "words": [{"word": "x", "start": 3.0, "end": 3.0}]}]
        }
        self.assertEqual(merge.words_for_track(report, "mic"), [])


class FormattingTests(unittest.TestCase):
    def test_hms(self):
        self.assertEqual(merge.hms(0), "00:00:00")
        self.assertEqual(merge.hms(59.9), "00:00:59")
        self.assertEqual(merge.hms(3661), "01:01:01")

    def test_the_header_of_a_diarized_meeting_names_vbx_and_its_coverage(self):
        text = merge.render_transcript(
            "Weekly", [], merge.coverage_stats(
                [dict(utterance(0.0, 1.0, count=10), assignment=merge.ASSIGNMENT_OVERLAP)]
            )
        )
        self.assertIn("офлайн-диаризация VBx", text)
        self.assertIn("покрытие диаризацией — 100% слов", text)
        self.assertIn("SPK_NN", text)

    def test_the_header_of_a_mic_only_meeting_claims_no_diarization(self):
        """No system words means no diarization ran, but the source line was
        hardcoded: it advertised VBx and an `SPK_NN` track that does not exist,
        contradicting the same run's `quality.md` (`диаризация: n/a`) in the file
        the operator reads first."""
        text = merge.render_transcript("Weekly", [], merge.coverage_stats([]))
        self.assertIn("без диаризации", text)
        self.assertNotIn("VBx", text)
        self.assertNotIn("SPK_NN", text)
        self.assertNotIn("покрытие диаризацией", text)
        self.assertIn("Дословно, без правок", text)


if __name__ == "__main__":
    unittest.main()
