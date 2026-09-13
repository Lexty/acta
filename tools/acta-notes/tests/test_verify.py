import _ctx

import contextlib
import io
import json
import tempfile
import time
import unittest
from pathlib import Path

verify = _ctx.load("verify")


# --- fixtures ----------------------------------------------------------------


def line(timecode, speaker, text):
    return f"**[{timecode}] {speaker}:** {text}"


def transcript(*rows, header=True):
    """A labeled transcript built from ``(timecode, speaker, text)`` triples."""
    out = ["# 2026-07-29 Weekly — транскрипт", ""] if header else []
    for timecode, speaker, text in rows:
        out.append(line(timecode, speaker, text))
        out.append("")
    return "\n".join(out)


CLEAN_ROWS = (
    ("00:00:01", "Дмитрий", "Всем привет, начинаем планёрку."),
    ("00:00:07", "SPK_02", "Я закончил интеграцию, осталось тестирование."),
    ("00:00:19", "Я", "Хорошо, тогда возьму на себя релиз."),
    ("00:00:31", "Дмитрий", "Договорились, встречаемся в четверг."),
)


def words(*specs):
    """``(word, start, end, confidence)`` → S3's normalized word shape."""
    return [
        {"word": w, "start": s, "end": e, "confidence": c} for w, s, e, c in specs
    ]


def transcribe_json(track_words=None, **overrides):
    report = {
        "stage": "transcribe",
        "status": "ok",
        "engine": "fluidaudiocli transcribe",
        "language": None,
        "extra_models": [],
        "tracks": [
            {
                "track": "system",
                "status": "ok",
                "model_version": "parakeet-tdt-0.6b-v3",
                "words": list(track_words or []),
            }
        ],
    }
    report.update(overrides)
    return report


def diarization_json(control="num-speakers", num_speakers=4, threshold=None):
    return {
        "stage": "diarize",
        "status": "ok",
        "engine": "fluidaudiocli process --mode offline",
        "parameters": {
            "mode": "offline",
            "diarizer": "vbx",
            "model": "speaker-diarization",
            "control": control,
            "num_speakers": num_speakers,
            "threshold": threshold,
            "min_segment_duration": 1.0,
            "min_gap_duration": 0.1,
        },
    }


def merge_json(coverage=0.91):
    return {
        "stage": "merge",
        "status": "ok",
        "coverage": coverage,
        "assigned_coverage": 0.99,
        "system_word_count": 100,
    }


def speakers_json():
    return {
        "schema": "acta-notes/speakers@1",
        "speakers": {
            "SPK_01": {
                "speaker": "SPK_01",
                "name": "Дмитрий",
                "status": "anchored",
                "anchored": True,
                "anchor_type": "self_intro",
                "confidence": 0.9,
                "resolved_group": None,
            },
            "SPK_02": {
                "speaker": "SPK_02",
                "name": None,
                "status": "inferred",
                "anchored": False,
                "anchor_type": None,
                "confidence": 0.0,
                "resolved_group": None,
            },
        },
    }


def full_stage_jsons(coverage=0.91, track_words=None):
    return {
        "prep_audio": {
            "stage": "prep_audio",
            "chain": "denoise",
            "filter": "highpass=f=80,afftdn=nr=12",
        },
        "gate": {"stage": "gate", "threshold": 0.02},
        "transcribe": transcribe_json(track_words),
        "merge": merge_json(coverage),
        "diarization": diarization_json(),
        "speakers": speakers_json(),
    }


@contextlib.contextmanager
def meeting(text=None, stages=None, raw=True, name="2026-07-29 Weekly"):
    """A meeting folder holding a labeled transcript and the chosen stage JSONs."""
    stages = stages or {}
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp) / name
        work = root / ".acta-notes"
        work.mkdir(parents=True)

        if text is not None:
            (root / "transcript.labeled.md").write_text(text, encoding="utf-8")
        if raw:
            (root / "transcript.raw.md").write_text(
                transcript(*CLEAN_ROWS), encoding="utf-8"
            )

        for key, payload in stages.items():
            if key in ("diarization", "speakers", "dicta"):
                path = root / f"{key}.json"
            else:
                path = work / f"{key}.json"
            path.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")

        yield root


@contextlib.contextmanager
def fake_home(tag="v0.15.5", commit="abc1234"):
    """A HOME holding a bootstrap stamp, so provenance is not read off this machine."""
    with tempfile.TemporaryDirectory() as tmp:
        home = Path(tmp)
        stamp = home / verify.CACHE_STAMP_RELPATH
        stamp.parent.mkdir(parents=True)
        if tag is not None:
            stamp.write_text(
                json.dumps({"fluidaudio_tag": tag, "commit": commit}), encoding="utf-8"
            )
        yield {"HOME": str(home)}


def run_main(argv, environ=None):
    """``main`` with stdout captured; returns ``(code, stdout)``."""
    buffer = io.StringIO()
    with contextlib.redirect_stdout(buffer):
        code = verify.main(argv, environ=environ or {"HOME": "/nonexistent"})
    return code, buffer.getvalue()


def check_named(report, name):
    for check in report["checks"]:
        if check["name"] == name:
            return check
    raise AssertionError(f"no check named {name} in {[c['name'] for c in report['checks']]}")


# --- parsing -----------------------------------------------------------------


class ParseTests(unittest.TestCase):
    def test_only_transcript_lines_are_parsed(self):
        rows = verify.parse_lines(transcript(*CLEAN_ROWS))
        self.assertEqual(len(rows), 4)
        self.assertEqual(rows[0]["speaker"], "Дмитрий")
        self.assertEqual(rows[0]["timecode"], "00:00:01")
        self.assertEqual(rows[2]["speaker"], "Я")

    def test_normalization_folds_case_punctuation_and_yo(self):
        self.assertEqual(
            verify.normalize_text("Всё, ПОЕХАЛИ!!"), "все поехали"
        )

    def test_hms_formats_a_timecode(self):
        self.assertEqual(verify.hms(3671), "01:01:11")


# --- loop detection ----------------------------------------------------------


class LoopDetectionTests(unittest.TestCase):
    def test_a_clean_transcript_has_no_loops(self):
        rows = verify.parse_lines(transcript(*CLEAN_ROWS))
        self.assertEqual(verify.find_loops(rows), [])

    def test_three_identical_lines_in_a_row_is_a_loop(self):
        rows = verify.parse_lines(
            transcript(
                ("00:00:01", "SPK_01", "Подписывайтесь на канал."),
                ("00:00:04", "SPK_01", "Подписывайтесь на канал."),
                ("00:00:07", "SPK_01", "Подписывайтесь на канал."),
            )
        )
        loops = verify.find_loops(rows)
        self.assertEqual(len(loops), 1)
        self.assertEqual(loops[0]["kind"], "line")
        self.assertEqual(loops[0]["count"], 3)
        self.assertEqual(loops[0]["from_timecode"], "00:00:01")
        self.assertEqual(loops[0]["to_timecode"], "00:00:07")

    def test_a_cross_speaker_backchannel_is_not_a_loop(self):
        """This feeds a hard gate, so it may not fire on a real conversation.

        merge.py cuts a new line at every pause over 0.7 s, so an interleaved
        two-track call producing `[Я] Да.` / `[SPK_01] Да.` / `[Я] Да.` is an
        everyday shape — and it used to fail the whole run with exit 1.
        """
        rows = verify.parse_lines(
            transcript(
                ("00:01:00", "Я", "Да."),
                ("00:01:05", "SPK_01", "Да."),
                ("00:01:09", "Я", "Да."),
            )
        )
        self.assertEqual(verify.find_loops(rows), [])

    def test_a_repeated_one_word_line_is_not_a_loop(self):
        """A decoder loop is not a one-word backchannel, even same-speaker."""
        rows = verify.parse_lines(
            transcript(
                ("00:01:00", "SPK_01", "Ага."),
                ("00:01:05", "SPK_01", "Ага."),
                ("00:01:09", "SPK_01", "Ага."),
            )
        )
        self.assertEqual(verify.find_loops(rows), [])

    def test_two_identical_lines_are_ordinary_conversation(self):
        rows = verify.parse_lines(
            transcript(
                ("00:00:01", "SPK_01", "Да, конечно."),
                ("00:00:04", "SPK_01", "Да, конечно."),
            )
        )
        self.assertEqual(verify.find_loops(rows), [])

    def test_case_and_punctuation_do_not_hide_a_line_loop(self):
        rows = verify.parse_lines(
            transcript(
                ("00:00:01", "SPK_01", "Подписывайтесь на канал."),
                ("00:00:04", "SPK_01", "подписывайтесь на канал"),
                ("00:00:07", "SPK_01", "ПОДПИСЫВАЙТЕСЬ НА КАНАЛ!"),
            )
        )
        self.assertEqual(len(verify.find_loops(rows)), 1)

    def test_an_interrupted_run_is_not_a_line_loop(self):
        rows = verify.parse_lines(
            transcript(
                ("00:00:01", "SPK_01", "Да, конечно."),
                ("00:00:04", "SPK_02", "Тогда идём дальше."),
                ("00:00:07", "SPK_01", "Да, конечно."),
                ("00:00:09", "SPK_02", "Хорошо."),
                ("00:00:12", "SPK_01", "Да, конечно."),
            )
        )
        self.assertEqual(verify.find_loops(rows), [])

    def test_a_phrase_repeated_four_times_inside_one_line_is_a_loop(self):
        rows = verify.parse_lines(
            transcript(
                (
                    "00:04:11",
                    "SPK_01",
                    "нам надо это сделать " * 4,
                )
            )
        )
        loops = verify.find_loops(rows)
        self.assertEqual(len(loops), 1)
        self.assertEqual(loops[0]["kind"], "phrase")
        self.assertEqual(loops[0]["count"], 4)
        self.assertEqual(loops[0]["from_timecode"], "00:04:11")

    def test_a_phrase_repeated_three_times_is_not_a_loop(self):
        rows = verify.parse_lines(
            transcript(("00:04:11", "SPK_01", "нам надо это сделать " * 3))
        )
        self.assertEqual(verify.find_loops(rows), [])

    def test_max_phrase_repeat_finds_the_longest_run(self):
        found = verify.max_phrase_repeat("а б в а б в а б в".split())
        self.assertEqual(found, (3, "а б в"))

    def test_max_phrase_repeat_ignores_phrases_under_three_words(self):
        # "ну ладно ну ладно" is a two-word phrase twice — ordinary speech, and
        # below the n-gram floor, so nothing is reported.
        self.assertIsNone(verify.max_phrase_repeat("ну ладно ну ладно".split()))

    def test_the_loop_gate_is_hard(self):
        self.assertIn("repeated_phrase_loop", verify.HARD_GATES)

    def test_enough_stops_the_scan_without_changing_the_verdict(self):
        words = "а б в".split() * 10
        self.assertEqual(verify.max_phrase_repeat(words), (10, "а б в"))
        # Same phrase, reported as soon as the threshold is met.
        found = verify.max_phrase_repeat(words, enough=4)
        self.assertEqual(found[1], "а б в")
        self.assertGreaterEqual(found[0], 4)

    def test_a_real_decoder_loop_line_is_scored_in_bounded_time(self):
        # merge.py cuts a line only at a pause over 0.7 s, so a continuous
        # hallucination arrives as ONE line of tens of thousands of words. Every
        # start position of it opens a run reaching the end, and scanning them all
        # was quadratic: ~15 s at 16k words, in the last stage of the run, which is
        # never skipped for freshness.
        rows = verify.parse_lines(
            transcript(("00:00:01", "Дмитрий", " ".join(["подписывайтесь на канал"] * 8000)))
        )
        started = time.monotonic()
        loops = verify.find_phrase_loops(rows)
        elapsed = time.monotonic() - started

        self.assertEqual(len(loops), 1)
        self.assertGreaterEqual(loops[0]["count"], verify.LOOP_PHRASE_REPEATS)
        self.assertLess(elapsed, 2.0, f"loop detection took {elapsed:.1f}s")


# --- ratio and tally ---------------------------------------------------------


class LineMetricsTests(unittest.TestCase):
    def test_unique_ratio_and_top_repeat(self):
        rows = verify.parse_lines(
            transcript(
                ("00:00:01", "SPK_01", "Раз."),
                ("00:00:04", "SPK_02", "Два."),
                ("00:00:07", "SPK_01", "Раз."),
                ("00:00:09", "SPK_02", "Раз."),
            )
        )
        metrics = verify.line_metrics(rows)
        self.assertEqual(metrics["line_count"], 4)
        self.assertEqual(metrics["unique_lines"], 2)
        self.assertEqual(metrics["unique_ratio"], 0.5)
        self.assertEqual(metrics["top_repeat"], {"text": "раз", "count": 3})

    def test_an_all_unique_transcript_scores_one(self):
        metrics = verify.line_metrics(verify.parse_lines(transcript(*CLEAN_ROWS)))
        self.assertEqual(metrics["unique_ratio"], 1.0)

    def test_a_low_ratio_warns_but_never_fails(self):
        rows = verify.parse_lines(
            transcript(
                ("00:00:01", "SPK_01", "Раз."),
                ("00:00:04", "SPK_02", "Два."),
                ("00:00:07", "SPK_01", "Раз."),
                ("00:00:09", "SPK_02", "Раз."),
            )
        )
        checks = verify.build_checks(
            rows,
            verify.line_metrics(rows),
            [],
            verify.low_confidence_spans(None),
            None,
            verify.SOURCE_TEAMS_VTT,
        )
        entry = [c for c in checks if c["name"] == "unique_line_ratio"][0]
        self.assertEqual(entry["status"], verify.WARN)
        self.assertNotIn("unique_line_ratio", verify.HARD_GATES)

    def test_speaker_tally_counts_lines_words_and_share(self):
        tally = verify.speaker_tally(verify.parse_lines(transcript(*CLEAN_ROWS)))
        by_speaker = {entry["speaker"]: entry for entry in tally}
        self.assertEqual(by_speaker["Дмитрий"]["lines"], 2)
        self.assertEqual(by_speaker["Дмитрий"]["line_share"], 0.5)
        self.assertEqual(by_speaker["SPK_02"]["lines"], 1)
        self.assertEqual(by_speaker["SPK_02"]["words"], 5)
        self.assertEqual(tally[0]["speaker"], "Дмитрий")


# --- low confidence ----------------------------------------------------------


class LowConfidenceTests(unittest.TestCase):
    def test_two_adjacent_low_words_make_one_span_with_a_timecode(self):
        report = transcribe_json(
            words(
                ("сегодня", 60.0, 60.4, 0.98),
                ("айрии", 60.5, 60.9, 0.31),
                ("притом", 61.0, 61.4, 0.22),
                ("работает", 61.5, 62.0, 0.97),
            )
        )
        result = verify.low_confidence_spans(report)
        self.assertEqual(result["span_count"], 1)
        span = result["spans"][0]
        self.assertEqual(span["timecode"], "00:01:00")
        self.assertEqual(span["text"], "айрии притом")
        self.assertEqual(span["track"], "system")
        self.assertEqual(span["word_count"], 2)
        self.assertEqual(span["min_confidence"], 0.22)
        self.assertEqual(result["low_confidence_words"], 2)
        self.assertEqual(result["scored_words"], 4)
        self.assertEqual(result["low_confidence_fraction"], 0.5)

    def test_a_single_low_word_is_asr_noise_not_a_span(self):
        report = transcribe_json(
            words(
                ("сегодня", 1.0, 1.4, 0.98),
                ("айрии", 1.5, 1.9, 0.31),
                ("работает", 2.0, 2.4, 0.97),
            )
        )
        result = verify.low_confidence_spans(report)
        self.assertEqual(result["span_count"], 0)
        self.assertEqual(result["low_confidence_words"], 1)

    def test_no_transcribe_json_yields_an_empty_report(self):
        result = verify.low_confidence_spans(None)
        self.assertEqual(result["span_count"], 0)
        self.assertEqual(result["scored_words"], 0)
        self.assertIsNone(result["low_confidence_fraction"])

    def test_a_high_low_confidence_fraction_warns(self):
        specs = [(f"w{i}", float(i), i + 0.4, 0.99) for i in range(90)]
        specs += [(f"x{i}", float(100 + i), 100.4 + i, 0.2) for i in range(10)]
        rows = verify.parse_lines(transcript(*CLEAN_ROWS))
        low = verify.low_confidence_spans(transcribe_json(words(*specs)))
        checks = verify.build_checks(
            rows, verify.line_metrics(rows), [], low, 0.91, verify.SOURCE_LOCAL_ASR
        )
        entry = [c for c in checks if c["name"] == "low_confidence_spans"][0]
        self.assertEqual(entry["status"], verify.WARN)
        self.assertEqual(entry["fraction"], 0.1)

    def test_a_normal_fraction_stays_green(self):
        specs = [(f"w{i}", float(i), i + 0.4, 0.99) for i in range(100)]
        specs += [("плохо", 200.0, 200.4, 0.2), ("совсем", 200.5, 200.9, 0.2)]
        rows = verify.parse_lines(transcript(*CLEAN_ROWS))
        low = verify.low_confidence_spans(transcribe_json(words(*specs)))
        checks = verify.build_checks(
            rows, verify.line_metrics(rows), [], low, 0.91, verify.SOURCE_LOCAL_ASR
        )
        entry = [c for c in checks if c["name"] == "low_confidence_spans"][0]
        self.assertEqual(entry["status"], verify.GREEN)
        self.assertEqual(entry["span_count"], 1)


# --- coverage ----------------------------------------------------------------


class CoverageTests(unittest.TestCase):
    def test_coverage_is_read_from_the_merge_stage_json(self):
        self.assertEqual(verify.coverage_from(merge_json(0.91)), 0.91)

    def test_a_missing_merge_json_has_no_coverage(self):
        self.assertIsNone(verify.coverage_from(None))
        self.assertIsNone(verify.coverage_from({"stage": "merge"}))

    def _coverage_check(self, coverage, source=None, merge_report=None):
        rows = verify.parse_lines(transcript(*CLEAN_ROWS))
        checks = verify.build_checks(
            rows,
            verify.line_metrics(rows),
            [],
            verify.low_confidence_spans(None),
            coverage,
            source or verify.SOURCE_LOCAL_ASR,
            merge_report=merge_report,
        )
        return [c for c in checks if c["name"] == "diarization_coverage"][0]

    def test_a_merge_json_with_no_coverage_is_not_reported_as_missing(self):
        """merge.py writes `coverage: null` for a mic-only or silent-system run.

        Saying "no S5 merge stage JSON" there sends a reader looking for a file
        sitting right beside the transcript.
        """
        entry = self._coverage_check(None, merge_report={"stage": "merge", "coverage": None})
        self.assertTrue(entry["skipped"])
        self.assertNotIn("no S5 merge stage JSON", entry["detail"])
        self.assertIn("no system words", entry["detail"])

        absent = self._coverage_check(None, merge_report=None)
        self.assertIn("no S5 merge stage JSON", absent["detail"])

    def test_measured_coverage_passes(self):
        self.assertEqual(self._coverage_check(0.91)["status"], verify.GREEN)

    def test_the_warn_boundary(self):
        self.assertEqual(self._coverage_check(0.85)["status"], verify.GREEN)
        self.assertEqual(self._coverage_check(0.849)["status"], verify.WARN)

    def test_the_hard_floor_boundary(self):
        self.assertEqual(self._coverage_check(0.80)["status"], verify.WARN)
        self.assertEqual(self._coverage_check(0.799)["status"], verify.RED)

    def test_absent_coverage_is_skipped_not_failed(self):
        entry = self._coverage_check(None, source=verify.SOURCE_TEAMS_VTT)
        self.assertEqual(entry["status"], verify.GREEN)
        self.assertTrue(entry["skipped"])

    def test_the_coverage_gate_is_hard(self):
        self.assertIn("diarization_coverage", verify.HARD_GATES)


# --- provenance and quality.md ----------------------------------------------


PROVENANCE_MARKERS = (
    "Источник:",
    "ASR:",
    "FluidAudio:",
    "предобработка:",
    "гейт тишины:",
    "диаризация:",
    "покрытие диаризацией:",
    "имена по якорям (D8):",
    "без якоря:",
    "transcript.raw.md",
)


class PreprocessProvenanceTests(unittest.TestCase):
    """The chain is reported per track, because it can differ per track.

    ``pipeline.relevel_calls`` re-converts an under-levelled track at
    ``loudnorm`` on its own, so the stage's top-level ``chain`` names only the
    last invocation. Reporting that for every track attributes one track's
    preprocessing to another — measured on the 2026-08-03 huddle, where
    ``quality.md`` claimed loudnorm for a ``system`` track processed at denoise.
    """

    def _provenance(self, prep):
        stages = full_stage_jsons()
        stages["prep_audio"] = prep
        with fake_home() as environ, meeting(
            transcript(*CLEAN_ROWS), stages=stages
        ) as root:
            return verify.run(root, environ=environ)["provenance"]

    def test_mixed_chains_are_named_per_track(self):
        provenance = self._provenance(
            {
                "stage": "prep_audio",
                "chain": "loudnorm",  # the last invocation — true of mic only
                "filter": "highpass=f=80,afftdn=nr=12,loudnorm",
                "tracks": [
                    {
                        "track": "mic",
                        "chain": "loudnorm",
                        "filter": "highpass=f=80,afftdn=nr=12,loudnorm",
                    },
                    {
                        "track": "system",
                        "chain": "denoise",
                        "filter": "highpass=f=80,afftdn=nr=12",
                    },
                ],
            }
        )

        self.assertEqual(
            provenance["preprocess_chain"], "mic=loudnorm, system=denoise"
        )

    def test_a_uniform_chain_still_reads_as_one_name(self):
        provenance = self._provenance(
            {
                "stage": "prep_audio",
                "chain": "denoise",
                "filter": "highpass=f=80,afftdn=nr=12",
                "tracks": [
                    {
                        "track": track,
                        "chain": "denoise",
                        "filter": "highpass=f=80,afftdn=nr=12",
                    }
                    for track in ("mic", "system")
                ],
            }
        )

        self.assertEqual(provenance["preprocess_chain"], "denoise")
        self.assertEqual(
            provenance["preprocess_filter"], "highpass=f=80,afftdn=nr=12"
        )

    def test_a_stage_json_without_track_entries_still_works(self):
        """Folders processed before per-track chains were recorded."""
        provenance = self._provenance(
            {
                "stage": "prep_audio",
                "chain": "denoise",
                "filter": "highpass=f=80,afftdn=nr=12",
            }
        )

        self.assertEqual(provenance["preprocess_chain"], "denoise")


class ProvenanceTests(unittest.TestCase):
    def test_every_field_is_filled_from_the_stage_jsons(self):
        with fake_home() as environ, meeting(
            transcript(*CLEAN_ROWS), stages=full_stage_jsons()
        ) as root:
            report = verify.run(root, environ=environ)

        provenance = report["provenance"]
        self.assertEqual(provenance["source"], verify.SOURCE_LOCAL_ASR)
        self.assertEqual(provenance["fluidaudio_tag"], "v0.15.5")
        self.assertEqual(provenance["preprocess_chain"], "denoise")
        self.assertEqual(provenance["preprocess_filter"], "highpass=f=80,afftdn=nr=12")
        self.assertEqual(provenance["gate_threshold"], "0.02")
        self.assertEqual(provenance["asr_model"], "parakeet-tdt-0.6b-v3")
        self.assertEqual(provenance["diarization_mode"], "offline")
        self.assertEqual(provenance["diarization_model"], "speaker-diarization")
        self.assertEqual(provenance["diarization_control"], "--num-speakers 4")
        self.assertEqual(provenance["min_segment_duration"], "1.0")
        self.assertEqual(provenance["min_gap_duration"], "0.1")
        self.assertEqual(provenance["diarization_coverage"], "91.0%")
        self.assertEqual(
            provenance["anchored"],
            [
                {
                    "speaker": "SPK_01",
                    "name": "Дмитрий",
                    "anchor_type": "self_intro",
                    "confidence": 0.9,
                }
            ],
        )
        self.assertEqual(provenance["inferred"], ["SPK_02"])

    def test_custom_vocab_is_disclosed_in_the_provenance_line(self):
        """D6 makes `--custom-vocab` opt-in because hotwords can force a false
        substitution, so the run that used them is the one that most needs to say
        so. It reached verify.json as `asr_extra_models` and was then dropped by
        the renderer, leaving the block prepended to transcript.md silent."""
        stages = full_stage_jsons()
        stages["transcribe"] = transcribe_json(extra_models=["custom vocabulary"])
        with fake_home() as environ, meeting(
            transcript(*CLEAN_ROWS), stages=stages
        ) as root:
            report = verify.run(root, environ=environ)

        self.assertEqual(report["provenance"]["asr_extra_models"], ["custom vocabulary"])
        line = verify.render_provenance_line(report["provenance"])
        self.assertIn("дополнительно: custom vocabulary", line)
        self.assertIn("дополнительно: custom vocabulary", verify.render_quality_md(report))

    def test_a_run_without_hotwords_says_nothing_extra(self):
        with fake_home() as environ, meeting(
            transcript(*CLEAN_ROWS), stages=full_stage_jsons()
        ) as root:
            report = verify.run(root, environ=environ)
        self.assertNotIn("дополнительно:", verify.render_provenance_line(report["provenance"]))

    def test_the_threshold_control_is_recorded_when_the_count_is_unknown(self):
        stages = full_stage_jsons()
        stages["diarization"] = diarization_json(
            control="threshold", num_speakers=None, threshold=0.75
        )
        with fake_home() as environ, meeting(
            transcript(*CLEAN_ROWS), stages=stages
        ) as root:
            report = verify.run(root, environ=environ)
        self.assertEqual(report["provenance"]["diarization_control"], "--threshold 0.75")

    def test_a_missing_stamp_reads_n_a_rather_than_guessing_the_pin(self):
        with fake_home(tag=None) as environ, meeting(
            transcript(*CLEAN_ROWS), stages=full_stage_jsons()
        ) as root:
            report = verify.run(root, environ=environ)
        self.assertEqual(report["provenance"]["fluidaudio_tag"], verify.NOT_AVAILABLE)

    def test_the_stamp_is_read_from_acta_cache_dir_like_doctor_reads_it(self):
        # bootstrap.sh writes the stamp under ${ACTA_CACHE_DIR:-…} and doctor.py
        # honours the override. Hardcoding $HOME here meant that with the override
        # set doctor reported a green pinned tag while quality.md — from the same
        # run — printed "FluidAudio: n/a", losing the pin from the document whose
        # whole purpose is provenance, with nothing to warn about it.
        with tempfile.TemporaryDirectory() as tmp:
            cache = Path(tmp) / "elsewhere" / "fluidaudio"
            cache.mkdir(parents=True)
            (cache / verify.STAMP_NAME).write_text(
                json.dumps({"fluidaudio_tag": "v0.15.5", "commit": "abc1234"}),
                encoding="utf-8",
            )
            environ = {"HOME": str(Path(tmp) / "empty-home"), "ACTA_CACHE_DIR": str(cache)}
            with meeting(
                transcript(*CLEAN_ROWS), stages=full_stage_jsons()
            ) as root:
                report = verify.run(root, environ=environ)

        self.assertEqual(verify.stamp_path(environ), cache / verify.STAMP_NAME)
        self.assertEqual(report["provenance"]["fluidaudio_tag"], "v0.15.5")

    def test_quality_md_names_every_provenance_field(self):
        with fake_home() as environ, meeting(
            transcript(*CLEAN_ROWS),
            stages=full_stage_jsons(track_words=words(("айрии", 5.0, 5.4, 0.2), ("притом", 5.5, 5.9, 0.3))),
        ) as root:
            report = verify.run(root, environ=environ)
        rendered = verify.render_quality_md(report)

        for marker in PROVENANCE_MARKERS:
            self.assertIn(marker, rendered)
        self.assertIn("⚠ Качество расшифровки", rendered)
        self.assertIn("SPK_01 → Дмитрий (self_intro)", rendered)
        self.assertIn("00:00:05", rendered)  # the low-confidence span's timecode
        self.assertIn("Реплики по спикерам:", rendered)

    def test_quality_md_lists_at_most_five_spans_and_says_how_many_are_left(self):
        specs = [(f"x{i}", float(i * 10), i * 10 + 0.4, 0.2) for i in range(20)]
        # every pair is one span: two adjacent low words, then a gap-breaking good one
        interleaved = []
        for index, spec in enumerate(specs):
            interleaved.append(spec)
            if index % 2 == 1:
                interleaved.append((f"ok{index}", spec[1] + 1, spec[1] + 1.4, 0.99))
        with fake_home() as environ, meeting(
            transcript(*CLEAN_ROWS),
            stages=full_stage_jsons(track_words=words(*interleaved)),
        ) as root:
            report = verify.run(root, environ=environ)
        rendered = verify.render_quality_md(report)
        self.assertEqual(report["low_confidence"]["span_count"], 10)
        self.assertIn("…ещё 5 фрагмент(ов)", rendered)


#: What the converter leaves behind on a landed conversion — the *positive*
#: evidence the Teams path is recognised by, rather than the absence of S3's.
TEAMS_MARKER = {"teams_vtt": {"stage": "teams-vtt", "status": "ok", "cue_count": 4}}


def dicta_report(matched=(), suspected=(), unmatched=(), **fields):
    """An S6.5 report as ``dicta_overlay.py`` writes it."""
    report = {
        "stage": "dicta_overlay",
        "status": "ok",
        "counts": {
            "candidates": len(matched) + len(suspected) + len(unmatched),
            "matched": len(matched),
            "suspected": len(suspected),
            "unmatched": len(unmatched),
        },
        "calibration": {
            "calibrated": True,
            "offset_seconds": 3.4,
            "anchors": 2,
            "spread_seconds": 0.6,
        },
        "marked_share": 0.07,
        "matched": list(matched),
        "suspected": list(suspected),
        "unmatched": list(unmatched),
    }
    report.update(fields)
    return report


MATCHED_SPAN = {
    "attempt_id": 140,
    "timecode": "00:05:03",
    "recognised": "Клод посмотри на файл контроллера",
    "score": 0.97,
    "utterances": [{"index": 2, "partial": False}],
}
SUSPECTED_SPAN = {
    "attempt_id": 141,
    "timecode": "00:07:09",
    "outcome": "capture-fault",
    "speech_seconds": 5.0,
    "recognised": "",
    "uncertainty_seconds": 90.0,
    "lines_within_uncertainty": 12,
}
SHORT_TEXT_SPAN = {
    "attempt_id": 143,
    "timecode": "00:03:20",
    "outcome": "aborted",
    "speech_seconds": 3.0,
    "recognised": "да хорошо",
    "uncertainty_seconds": 2.0,
    "lines_within_uncertainty": 2,
}
UNMATCHED_SPAN = {
    "attempt_id": 142,
    "reason": "best alignment scored 0.31, below 0.65",
    "preview": "переключись на ветку main",
}


class DictationTests(unittest.TestCase):
    """S6.5's verdict, as verify surfaces it. Never a hard gate."""

    def _check(self, stages):
        with meeting(text=transcript(*CLEAN_ROWS), stages=stages) as root:
            return verify.run(root, environ={"HOME": "/nonexistent"})

    def test_no_dicta_json_is_green_and_says_so(self):
        report = self._check({})
        check = check_named(report, "dictation")
        self.assertEqual(check["status"], verify.GREEN)
        self.assertIn("no dicta.json", check["detail"])

    def test_a_skipped_stage_is_green(self):
        report = self._check(
            {"dicta": {"stage": "dicta_overlay", "status": "skipped",
                       "detail": "no dicta record"}}
        )
        self.assertEqual(check_named(report, "dictation")["status"], verify.GREEN)

    def test_matched_spans_alone_are_green(self):
        report = self._check({"dicta": dicta_report(matched=[MATCHED_SPAN])})
        check = check_named(report, "dictation")
        self.assertEqual(check["status"], verify.GREEN)
        self.assertIn("1 фрагмент", check["detail"])

    def test_an_unmatched_attempt_warns(self):
        report = self._check({"dicta": dicta_report(unmatched=[UNMATCHED_SPAN])})
        check = check_named(report, "dictation")
        self.assertEqual(check["status"], verify.WARN)
        self.assertIn("не найдено", check["detail"])

    def test_a_textless_suspicion_warns(self):
        report = self._check({"dicta": dicta_report(suspected=[SUSPECTED_SPAN])})
        self.assertEqual(check_named(report, "dictation")["status"], verify.WARN)

    def test_quality_md_prints_the_uncertainty_beside_the_timecode(self):
        """A bare timecode reads as a location; this one is a guess."""
        report = self._check({"dicta": dicta_report(suspected=[SUSPECTED_SPAN])})
        rendered = verify.render_quality_md(report)
        self.assertIn("±90 с", rendered)
        self.assertIn("в диапазон попадает реплик: 12", rendered)

    def test_quality_md_shows_dictas_note_when_it_says_more_than_the_outcome(self):
        span = dict(
            SUSPECTED_SPAN,
            outcome="aborted",
            error="aborted; the words … could not be recognised: boom",
        )
        rendered = verify.render_quality_md(
            self._check({"dicta": dicta_report(suspected=[span])})
        )
        self.assertIn("could not be recognised", rendered)

    def test_quality_md_drops_a_note_that_only_repeats_the_outcome(self):
        span = dict(SUSPECTED_SPAN, outcome="aborted", error="aborted")
        rendered = verify.render_quality_md(
            self._check({"dicta": dicta_report(suspected=[span])})
        )
        self.assertNotIn("dicta: «aborted»", rendered)

    def test_quality_md_shows_the_words_when_a_suspicion_has_any(self):
        report = self._check({"dicta": dicta_report(suspected=[SHORT_TEXT_SPAN])})
        rendered = verify.render_quality_md(report)
        self.assertIn("«да хорошо»", rendered)
        self.assertNotIn("без текста", rendered)

    def test_it_is_never_a_hard_gate(self):
        report = self._check(
            {"dicta": dicta_report(unmatched=[UNMATCHED_SPAN, UNMATCHED_SPAN])}
        )
        self.assertNotIn("dictation", verify.HARD_GATES)
        self.assertEqual(report["gates_tripped"], [])
        self.assertNotEqual(report["status"], verify.STATUS_FAILED)

    def test_quality_md_names_every_span_a_reader_must_act_on(self):
        report = self._check(
            {
                "dicta": dicta_report(
                    matched=[MATCHED_SPAN],
                    suspected=[SUSPECTED_SPAN],
                    unmatched=[UNMATCHED_SPAN],
                )
            }
        )
        rendered = verify.render_quality_md(report)
        self.assertIn("Голосовой ввод (dicta)", rendered)
        self.assertIn("`00:05:03`", rendered)
        self.assertIn("dicta #140", rendered)
        self.assertIn("dicta #141", rendered)
        self.assertIn("dicta #142", rendered)

    def test_quality_md_stays_silent_when_nothing_leaked(self):
        report = self._check({"dicta": dicta_report()})
        self.assertNotIn("Голосовой ввод", verify.render_quality_md(report))

    def test_the_provenance_line_carries_the_measured_clock_offset(self):
        report = self._check({"dicta": dicta_report(matched=[MATCHED_SPAN])})
        line = verify.render_provenance_line(report["provenance"])
        self.assertIn("голосовой ввод (dicta)", line)
        self.assertIn("+3.4 с", line)

    def test_the_provenance_line_says_n_a_when_the_stage_never_ran(self):
        report = self._check({})
        line = verify.render_provenance_line(report["provenance"])
        self.assertIn(f"голосовой ввод (dicta): {verify.NOT_AVAILABLE}", line)


class TeamsSourceTests(unittest.TestCase):
    """The Teams path never ran S1–S5, so their stage JSONs do not exist."""

    def test_absent_stage_jsons_are_tolerated(self):
        with fake_home() as environ, meeting(
            transcript(*CLEAN_ROWS), stages=TEAMS_MARKER
        ) as root:
            report = verify.run(root, environ=environ)

        self.assertEqual(report["status"], verify.STATUS_OK)
        self.assertEqual(report["source"], verify.SOURCE_TEAMS_VTT)
        self.assertEqual(report["gates_tripped"], [])
        # None of S1–S5 ran; the converter's own marker is the only file present.
        present = report["stage_json_present"]
        self.assertTrue(present["teams_vtt"])
        self.assertFalse(
            any(value for name, value in present.items() if name != "teams_vtt")
        )

    def test_the_asr_and_diarization_provenance_fields_read_n_a(self):
        with fake_home() as environ, meeting(
            transcript(*CLEAN_ROWS), stages=TEAMS_MARKER
        ) as root:
            report = verify.run(root, environ=environ)
        provenance = report["provenance"]
        for field in (
            "asr_engine",
            "asr_model",
            "preprocess_chain",
            "gate_threshold",
            "diarization_mode",
            "diarization_control",
            "min_segment_duration",
            "min_gap_duration",
            "diarization_coverage",
        ):
            self.assertEqual(provenance[field], verify.NOT_AVAILABLE, field)
        rendered = verify.render_quality_md(report)
        for marker in PROVENANCE_MARKERS:
            self.assertIn(marker, rendered)
        self.assertIn("официальный транскрипт Teams", rendered)

    def test_the_confidence_and_coverage_gates_are_skipped(self):
        with fake_home() as environ, meeting(transcript(*CLEAN_ROWS)) as root:
            report = verify.run(root, environ=environ)
        for name in ("low_confidence_spans", "diarization_coverage"):
            entry = check_named(report, name)
            self.assertTrue(entry["skipped"], name)
            self.assertEqual(entry["status"], verify.GREEN, name)

    def test_a_loop_still_fails_on_the_teams_path(self):
        text = transcript(
            ("00:00:01", "Дмитрий", "Подписывайтесь на канал."),
            ("00:00:04", "Дмитрий", "Подписывайтесь на канал."),
            ("00:00:07", "Дмитрий", "Подписывайтесь на канал."),
        )
        with fake_home() as environ, meeting(text) as root:
            report = verify.run(root, environ=environ)
        self.assertEqual(report["status"], verify.STATUS_FAILED)
        self.assertEqual(report["gates_tripped"], ["repeated_phrase_loop"])

    def test_an_explicit_source_overrides_detection(self):
        with fake_home() as environ, meeting(
            transcript(*CLEAN_ROWS), stages=full_stage_jsons()
        ) as root:
            report = verify.run(root, source=verify.SOURCE_TEAMS_VTT, environ=environ)
        self.assertEqual(report["source"], verify.SOURCE_TEAMS_VTT)
        self.assertFalse(report["source_detected"])

    def test_neither_marker_present_names_no_source(self):
        # `.acta-notes/` is documented as disposable (PLAN.md §6 tells the
        # operator to delete it to reclaim disk), so a meeting holding a genuine
        # local-ASR transcript and no stage JSON is reachable. Inferring Teams
        # from the *absence* of transcribe.json made quality.md claim the text
        # came from Teams — and SKILL.md has Claude prepend quality.md verbatim
        # into transcript.md, so the reader was told a falsehood about provenance
        # by the one document that exists to carry it.
        with fake_home() as environ, meeting(transcript(*CLEAN_ROWS)) as root:
            report = verify.run(root, environ=environ)
        self.assertEqual(report["source"], verify.SOURCE_UNKNOWN)
        rendered = verify.render_quality_md(report)
        self.assertNotIn("официальный транскрипт Teams", rendered)
        self.assertIn("источник не определён", rendered)

    def test_a_stale_transcribe_json_is_not_read_as_teams(self):
        with fake_home() as environ, meeting(
            transcript(*CLEAN_ROWS), stages=full_stage_jsons()
        ) as root:
            report = verify.run(root, environ=environ)
        self.assertEqual(report["source"], verify.SOURCE_LOCAL_ASR)

    def test_an_unreadable_stage_json_degrades_to_n_a(self):
        with fake_home() as environ, meeting(
            transcript(*CLEAN_ROWS), stages=full_stage_jsons()
        ) as root:
            (root / "diarization.json").write_text("{not json", encoding="utf-8")
            report = verify.run(root, environ=environ)
        self.assertEqual(report["status"], verify.STATUS_OK)
        self.assertEqual(
            report["provenance"]["diarization_mode"], verify.NOT_AVAILABLE
        )


# --- the stage end to end ----------------------------------------------------


class RunTests(unittest.TestCase):
    def test_a_clean_meeting_is_green(self):
        with fake_home() as environ, meeting(
            transcript(*CLEAN_ROWS), stages=full_stage_jsons()
        ) as root:
            report = verify.run(root, environ=environ)
        self.assertEqual(report["status"], verify.STATUS_OK)
        self.assertEqual(report["gates_tripped"], [])
        self.assertEqual(report["coverage"], 0.91)
        self.assertEqual(report["metrics"]["line_count"], 4)
        self.assertEqual(verify.exit_code(report), verify.EXIT_OK)

    def test_a_collapsed_coverage_trips_the_hard_gate(self):
        with fake_home() as environ, meeting(
            transcript(*CLEAN_ROWS), stages=full_stage_jsons(coverage=0.42)
        ) as root:
            report = verify.run(root, environ=environ)
        self.assertEqual(report["status"], verify.STATUS_FAILED)
        self.assertEqual(report["gates_tripped"], ["diarization_coverage"])
        self.assertEqual(verify.exit_code(report), verify.EXIT_FAILED)

    def test_a_warn_still_passes(self):
        with fake_home() as environ, meeting(
            transcript(*CLEAN_ROWS), stages=full_stage_jsons(coverage=0.82)
        ) as root:
            report = verify.run(root, environ=environ)
        self.assertEqual(report["status"], verify.STATUS_WARN)
        self.assertEqual(report["gates_tripped"], [])
        self.assertEqual(verify.exit_code(report), verify.EXIT_OK)

    def test_a_missing_labeled_transcript_is_reported_not_crashed(self):
        with fake_home() as environ, meeting(None, stages=full_stage_jsons()) as root:
            report = verify.run(root, environ=environ)
        self.assertEqual(report["status"], verify.STATUS_MISSING)
        self.assertIn("speakers.py apply", report["detail"])
        self.assertEqual(verify.exit_code(report), verify.EXIT_FAILED)
        self.assertIn("fluidaudio_tag", report["provenance"])

    def test_an_unreadable_transcript_is_reported_not_crashed(self):
        """A UnicodeDecodeError used to escape run() entirely.

        pipeline.py's runner catches only SystemExit, so the traceback took
        pipeline.json — the whole run log — with it.
        """
        with fake_home() as environ, meeting(None, stages=full_stage_jsons()) as root:
            (root / "transcript.labeled.md").write_bytes(b"\xff\xfe\x00binary")
            report = verify.run(root, environ=environ)
        self.assertEqual(report["status"], verify.STATUS_MISSING)
        self.assertIn("unreadable transcript", report["detail"])
        self.assertEqual(verify.exit_code(report), verify.EXIT_FAILED)
        self.assertIn("fluidaudio_tag", report["provenance"])

    def test_only_hard_gates_can_turn_the_stage_red(self):
        """HARD_GATES was descriptive, not enforced: worst_status took the max
        over *every* check, so a soft check that ever emitted RED would silently
        fail the stage and the run."""
        checks = [
            {"name": "unique_line_ratio", "status": verify.RED, "detail": ""},
            {"name": "low_confidence", "status": verify.GREEN, "detail": ""},
        ]
        self.assertEqual(verify.worst_status(checks), verify.WARN)

        checks.append({"name": "transcript", "status": verify.RED, "detail": ""})
        self.assertEqual(verify.worst_status(checks), verify.RED)

    def test_a_transcript_without_speaker_lines_is_red(self):
        with fake_home() as environ, meeting(
            "# заголовок и больше ничего\n", stages=full_stage_jsons()
        ) as root:
            report = verify.run(root, environ=environ)
        self.assertEqual(report["status"], verify.STATUS_FAILED)
        self.assertEqual(check_named(report, "transcript")["status"], verify.RED)

    def test_an_explicit_transcript_path_is_honoured(self):
        with fake_home() as environ, meeting(None, stages=full_stage_jsons()) as root:
            other = root / "transcript.other.md"
            other.write_text(transcript(*CLEAN_ROWS), encoding="utf-8")
            report = verify.run(root, transcript=other, environ=environ)
        self.assertEqual(report["status"], verify.STATUS_OK)
        self.assertEqual(report["transcript"], str(other))


class ArtifactTests(unittest.TestCase):
    def test_both_artifacts_are_written_under_the_work_dir(self):
        with fake_home() as environ, meeting(
            transcript(*CLEAN_ROWS), stages=full_stage_jsons()
        ) as root:
            code, _ = run_main([str(root)], environ=environ)
            machine = root / ".acta-notes" / "verify.json"
            quality = root / ".acta-notes" / "quality.md"
            self.assertEqual(code, 0)
            self.assertTrue(machine.is_file())
            self.assertTrue(quality.is_file())

            payload = json.loads(machine.read_text(encoding="utf-8"))
            self.assertEqual(payload["stage"], "verify")
            self.assertEqual(payload["status"], "ok")
            self.assertIn("checks", payload)
            self.assertIn("provenance", payload)
            self.assertIn("⚠ Качество расшифровки", quality.read_text(encoding="utf-8"))

    def test_no_transcript_is_ever_mutated_and_none_is_created(self):
        text = transcript(*CLEAN_ROWS)
        with fake_home() as environ, meeting(text, stages=full_stage_jsons()) as root:
            labeled = root / "transcript.labeled.md"
            raw = root / "transcript.raw.md"
            before = (labeled.read_bytes(), raw.read_bytes())

            run_main([str(root)], environ=environ)

            self.assertEqual((labeled.read_bytes(), raw.read_bytes()), before)
            self.assertFalse((root / "transcript.md").exists())

    def test_the_artifacts_survive_a_hard_gate_failure(self):
        with fake_home() as environ, meeting(
            transcript(*CLEAN_ROWS), stages=full_stage_jsons(coverage=0.1)
        ) as root:
            code, _ = run_main([str(root)], environ=environ)
            self.assertEqual(code, 1)
            self.assertTrue((root / ".acta-notes" / "verify.json").is_file())
            self.assertTrue((root / ".acta-notes" / "quality.md").is_file())
            self.assertFalse((root / "transcript.md").exists())


class CliTests(unittest.TestCase):
    def test_json_output_is_the_stage_report(self):
        with fake_home() as environ, meeting(
            transcript(*CLEAN_ROWS), stages=full_stage_jsons()
        ) as root:
            code, out = run_main([str(root), "--json"], environ=environ)
        payload = json.loads(out)
        self.assertEqual(code, 0)
        self.assertEqual(payload["stage"], "verify")
        self.assertEqual(payload["source"], verify.SOURCE_LOCAL_ASR)

    def test_the_human_block_lists_every_check(self):
        with fake_home() as environ, meeting(
            transcript(*CLEAN_ROWS), stages=full_stage_jsons()
        ) as root:
            code, out = run_main([str(root)], environ=environ)
        self.assertEqual(code, 0)
        for name in (
            "transcript",
            "repeated_phrase_loop",
            "unique_line_ratio",
            "low_confidence_spans",
            "diarization_coverage",
        ):
            self.assertIn(name, out)

    def test_a_missing_meeting_folder_is_a_usage_error(self):
        with self.assertRaises(SystemExit) as caught:
            with contextlib.redirect_stderr(io.StringIO()):
                verify.main(["/nonexistent/meeting"])
        self.assertEqual(caught.exception.code, verify.EXIT_USAGE)

    def test_a_missing_transcript_exits_one(self):
        with fake_home() as environ, meeting(None) as root:
            code, out = run_main([str(root)], environ=environ)
        self.assertEqual(code, 1)
        self.assertIn("MISSING", out)


class NonNumericConfidenceTests(unittest.TestCase):
    """verify's whole job is to produce a verdict. A junk field in a stage JSON
    must degrade into "not scored", never into a traceback that suppresses it."""

    def test_a_non_numeric_confidence_is_not_scored(self):
        report = {
            "tracks": [
                {
                    "track": "mic",
                    "words": [
                        {"word": "раз", "start": 0.0, "end": 0.4, "confidence": "hi"},
                        {"word": "два", "start": 0.4, "end": 0.8, "confidence": 0.9},
                    ],
                }
            ]
        }
        result = verify.low_confidence_spans(report)
        self.assertEqual(result["scored_words"], 1)
        self.assertEqual(result["spans"], [])

    def test_a_non_numeric_timing_breaks_the_run_instead_of_raising(self):
        report = {
            "tracks": [
                {
                    "track": "mic",
                    "words": [
                        {"word": "a", "start": "x", "end": 0.4, "confidence": 0.1},
                        {"word": "b", "start": 0.4, "end": 0.8, "confidence": 0.1},
                    ],
                }
            ]
        }
        result = verify.low_confidence_spans(report, min_words=1)
        self.assertEqual(result["scored_words"], 1)
        self.assertEqual([s["text"] for s in result["spans"]], ["b"])


if __name__ == "__main__":
    unittest.main()
