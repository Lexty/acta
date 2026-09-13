import _ctx

import contextlib
import io
import json
import os
import stat
import tempfile
import unittest
from pathlib import Path

transcribe = _ctx.load("transcribe")

FIXTURE = "transcribe_words.json"
BIN = "/fake/bin/fluidaudiocli"


def fixture_data() -> dict:
    return json.loads(_ctx.read_fixture(FIXTURE))


_STUB_DIR = tempfile.TemporaryDirectory()


def executable_stub(name="fluidaudiocli", executable=True) -> str:
    """A real file on disk so ``is_executable`` has something to answer about.

    The stage refuses to start when the binary is not executable, so every test
    that wants to reach the runner needs one — but none of them ever execute it
    (the injected runner stands in), except RealStubBinaryTests.
    """
    path = Path(_STUB_DIR.name) / name
    if not path.exists():
        path.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        if executable:
            path.chmod(path.stat().st_mode | stat.S_IXUSR)
    return str(path)


def stub_env(**extra) -> dict:
    env = {"ACTA_FLUIDAUDIO_BIN": executable_stub()}
    env.update(extra)
    return env


class StubCLI:
    """Records argv and echoes the committed fixture to --output-json."""

    def __init__(self, code=0, stderr="", payload=None, write_output=True):
        self.calls = []
        self.code = code
        self.stderr = stderr
        self.payload = payload
        self.write_output = write_output

    def __call__(self, argv):
        self.calls.append(list(argv))
        if self.code == 0 and self.write_output:
            out = Path(argv[argv.index("--output-json") + 1])
            payload = fixture_data() if self.payload is None else self.payload
            out.parent.mkdir(parents=True, exist_ok=True)
            out.write_text(
                json.dumps(payload, ensure_ascii=False) if isinstance(payload, (dict, list))
                else payload,
                encoding="utf-8",
            )
        return self.code, self.stderr


@contextlib.contextmanager
def meeting(tracks=("mic", "system")):
    """A meeting folder that already has S1's 16 kHz outputs (contents unread)."""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp) / "2026-07-29 Weekly"
        work = root / transcribe.WORK_DIRNAME
        work.mkdir(parents=True)
        for track in tracks:
            (work / f"{track}{transcribe.INPUT_SUFFIX}").write_bytes(b"RIFFfake")
        yield root


def touch_newer(path, reference, delta=10):
    stamp = Path(reference).stat().st_mtime + delta
    os.utime(path, (stamp, stamp))


class BinaryResolutionTests(unittest.TestCase):
    def test_env_override_wins(self):
        path, source = transcribe.resolve_fluidaudio_bin(
            {"ACTA_FLUIDAUDIO_BIN": "/opt/fa/fluidaudiocli", "HOME": "/home/x"}
        )
        self.assertEqual(path, Path("/opt/fa/fluidaudiocli"))
        self.assertEqual(source, "env:ACTA_FLUIDAUDIO_BIN")

    def test_cache_path_is_the_fallback(self):
        path, source = transcribe.resolve_fluidaudio_bin({"HOME": "/home/x"})
        self.assertEqual(
            path,
            Path("/home/x/.cache/acta-notes/fluidaudio/.build/release/fluidaudiocli"),
        )
        self.assertEqual(source, "cache-default")

    def test_path_is_never_searched(self):
        # A fluidaudiocli on PATH must not be picked up: the pin is a specific
        # build, and any other one would transcribe with an unknown engine.
        with tempfile.TemporaryDirectory() as tmp:
            decoy = Path(tmp) / "fluidaudiocli"
            decoy.write_text("#!/bin/sh\n", encoding="utf-8")
            decoy.chmod(decoy.stat().st_mode | stat.S_IXUSR)
            path, source = transcribe.resolve_fluidaudio_bin(
                {"HOME": "/home/x", "PATH": tmp}
            )
        self.assertEqual(source, "cache-default")
        self.assertNotEqual(path.parent, Path(tmp))


class ArgvTests(unittest.TestCase):
    def test_default_argv_is_exact(self):
        argv = transcribe.build_argv(BIN, "/m/.acta-notes/system.16k.wav", "/m/.acta-notes/system.asr.raw.json")
        self.assertEqual(
            argv,
            [
                BIN,
                "transcribe",
                "/m/.acta-notes/system.16k.wav",
                "--word-timestamps",
                "--output-json",
                "/m/.acta-notes/system.asr.raw.json",
            ],
        )

    def test_neither_opt_in_appears_by_default(self):
        argv = transcribe.build_argv(BIN, "/m/a.wav", "/m/a.json")
        self.assertNotIn("--language", argv)
        self.assertNotIn("--custom-vocab", argv)

    def test_no_model_version_is_forced(self):
        # D1 pins Parakeet TDT 0.6B v3, which is the CLI default — the run
        # records what the CLI reports instead of overriding it.
        self.assertNotIn("--model-version", transcribe.build_argv(BIN, "/m/a.wav", "/m/a.json"))

    def test_language_opt_in(self):
        argv = transcribe.build_argv(BIN, "/m/a.wav", "/m/a.json", language="ru")
        self.assertEqual(argv[-2:], ["--language", "ru"])

    def test_custom_vocab_opt_in(self):
        argv = transcribe.build_argv(BIN, "/m/a.wav", "/m/a.json", custom_vocab="/m/terms.txt")
        self.assertEqual(argv[-2:], ["--custom-vocab", "/m/terms.txt"])

    def test_both_opt_ins_in_a_fixed_order(self):
        argv = transcribe.build_argv(
            BIN, "/m/a.wav", "/m/a.json", language="ru", custom_vocab="/m/terms.txt"
        )
        self.assertEqual(
            argv[-4:], ["--language", "ru", "--custom-vocab", "/m/terms.txt"]
        )

    def test_word_timestamps_and_output_json_are_never_optional(self):
        argv = transcribe.build_argv(BIN, "/m/a.wav", "/m/a.json", language="ru")
        self.assertIn("--word-timestamps", argv)
        self.assertIn("--output-json", argv)


class WordTimingParsingTests(unittest.TestCase):
    def test_fixture_words_are_normalized_to_snake_case(self):
        words = transcribe.parse_word_timings(fixture_data())
        self.assertEqual(len(words), 7)
        self.assertEqual(
            words[0],
            {"word": "Привет", "start": 0.24, "end": 0.72, "confidence": 0.9781},
        )
        self.assertEqual(words[-1]["word"], "первый")
        self.assertEqual(words[-1]["end"], 4.51)

    def test_absent_word_timings_key_is_empty_not_an_error(self):
        self.assertEqual(transcribe.parse_word_timings({"text": "x"}), [])
        self.assertEqual(transcribe.parse_word_timings({"wordTimings": None}), [])

    def test_entries_without_usable_timings_are_dropped(self):
        raw = {
            "wordTimings": [
                {"word": "ok", "startTime": 1.0, "endTime": 1.5, "confidence": 0.9},
                {"word": "", "startTime": 2.0, "endTime": 2.5},
                {"word": "no-start", "endTime": 3.0},
                {"word": "no-end", "startTime": 3.0},
                "not-a-dict",
            ]
        }
        words = transcribe.parse_word_timings(raw)
        self.assertEqual([w["word"] for w in words], ["ok"])

    def test_missing_confidence_stays_none(self):
        words = transcribe.parse_word_timings(
            {"wordTimings": [{"word": "a", "startTime": 0.0, "endTime": 0.1}]}
        )
        self.assertIsNone(words[0]["confidence"])


class ConfidenceAggregationTests(unittest.TestCase):
    def test_mean_and_min_over_the_fixture(self):
        words = transcribe.parse_word_timings(fixture_data())
        stats = transcribe.confidence_stats(words)
        expected = sum(w["confidence"] for w in words) / len(words)
        self.assertAlmostEqual(stats["mean_confidence"], round(expected, 4), places=4)
        self.assertEqual(stats["min_confidence"], 0.8873)
        self.assertEqual(stats["scored_words"], 7)

    def test_unscored_words_are_ignored_not_counted_as_zero(self):
        words = [
            {"word": "a", "start": 0, "end": 1, "confidence": 0.8},
            {"word": "b", "start": 1, "end": 2, "confidence": None},
        ]
        stats = transcribe.confidence_stats(words)
        self.assertEqual(stats["mean_confidence"], 0.8)
        self.assertEqual(stats["scored_words"], 1)

    def test_no_scored_words_yields_none_not_zero(self):
        stats = transcribe.confidence_stats([])
        self.assertIsNone(stats["mean_confidence"])
        self.assertIsNone(stats["min_confidence"])
        self.assertEqual(stats["scored_words"], 0)


class RunTests(unittest.TestCase):
    def _run(self, root, stub, **kwargs):
        return transcribe.run(
            root,
            environ=stub_env(),
            runner=stub,
            clock=iter([0.0, 1.5, 1.5, 3.0]).__next__,
            **kwargs,
        )

    def test_both_tracks_are_transcribed(self):
        stub = StubCLI()
        with meeting() as root:
            report = self._run(root, stub)
        self.assertEqual(report["status"], transcribe.STATUS_OK)
        self.assertEqual([e["track"] for e in report["tracks"]], ["mic", "system"])
        self.assertEqual(len(stub.calls), 2)
        self.assertEqual(report["word_count"], 14)

    def test_track_entry_carries_stats_and_provenance(self):
        stub = StubCLI()
        with meeting(("system",)) as root:
            report = transcribe.run(
                root,
                tracks=("system",),
                environ=stub_env(),
                runner=stub,
                clock=iter([0.0, 2.25]).__next__,
            )
        entry = report["tracks"][0]
        self.assertEqual(entry["status"], transcribe.STATUS_OK)
        self.assertEqual(entry["word_count"], 7)
        self.assertEqual(entry["model_version"], "v3")
        self.assertEqual(entry["mode"], "batch")
        self.assertEqual(entry["cli_confidence"], 0.9612)
        self.assertEqual(entry["audio_duration_seconds"], 6.4)
        self.assertEqual(entry["elapsed_seconds"], 2.25)
        self.assertTrue(entry["text"].startswith("Привет"))
        self.assertEqual(entry["words"][0]["word"], "Привет")

    def test_raw_cli_json_is_kept_alongside_the_stage_json(self):
        stub = StubCLI()
        with meeting(("system",)) as root:
            report = self._run(root, stub, tracks=("system",))
            raw = transcribe.raw_json_path(root, "system")
            self.assertTrue(raw.is_file())
            self.assertEqual(json.loads(raw.read_text(encoding="utf-8")), fixture_data())
            transcribe.write_stage_json(root, report)
            stage = json.loads(
                (root / transcribe.WORK_DIRNAME / transcribe.STAGE_JSON_NAME).read_text(
                    encoding="utf-8"
                )
            )
        self.assertEqual(stage["tracks"][0]["raw_json"], str(raw))
        self.assertEqual(stage["stage"], "transcribe")

    def test_missing_16k_track_is_reported_not_transcribed(self):
        stub = StubCLI()
        with meeting(("system",)) as root:
            report = self._run(root, stub)
        mic = report["tracks"][0]
        self.assertEqual(mic["status"], transcribe.STATUS_MISSING)
        self.assertIn("prep_audio.py", mic["detail"])
        self.assertEqual(len(stub.calls), 1)
        self.assertEqual(report["status"], transcribe.STATUS_OK)

    def test_all_tracks_missing_fails_the_stage(self):
        stub = StubCLI()
        with meeting(()) as root:
            report = self._run(root, stub)
        self.assertEqual(report["status"], transcribe.STATUS_FAILED)
        self.assertEqual(stub.calls, [])

    def test_fresh_output_is_reused_but_still_parsed(self):
        stub = StubCLI()
        with meeting(("system",)) as root:
            self._run(root, stub, tracks=("system",))
            touch_newer(
                transcribe.raw_json_path(root, "system"),
                transcribe.input_path(root, "system"),
            )
            again = self._run(root, StubCLI(), tracks=("system",))
        entry = again["tracks"][0]
        self.assertEqual(entry["status"], transcribe.STATUS_SKIPPED)
        self.assertIsNone(entry["argv"])
        # Skipping must not produce a half-empty stage JSON.
        self.assertEqual(entry["word_count"], 7)
        self.assertEqual(entry["words"][0]["word"], "Привет")

    def test_a_different_language_is_not_a_cache_hit(self):
        """`--language ru` over an auto-LID output used to be silently dropped.

        Worse than dropped: the entry still recorded `language: ru`, so the
        stage JSON claimed a run that never happened.
        """
        with meeting(("system",)) as root:
            first = self._run(root, StubCLI(), tracks=("system",))
            transcribe.write_stage_json(root, first)
            touch_newer(
                transcribe.raw_json_path(root, "system"),
                transcribe.input_path(root, "system"),
            )

            stub = StubCLI()
            second = self._run(root, stub, tracks=("system",), language="ru")
            transcribe.write_stage_json(root, second)
            third = self._run(root, StubCLI(), tracks=("system",), language="ru")

        self.assertIsNone(first["tracks"][0]["language"])
        self.assertEqual(second["tracks"][0]["status"], transcribe.STATUS_OK)
        self.assertIn("--language", stub.calls[0])
        # …and asking for the same language again is a cache hit.
        self.assertEqual(third["tracks"][0]["status"], transcribe.STATUS_SKIPPED)

    def test_force_re_transcribes_a_fresh_track(self):
        with meeting(("system",)) as root:
            self._run(root, StubCLI(), tracks=("system",))
            touch_newer(
                transcribe.raw_json_path(root, "system"),
                transcribe.input_path(root, "system"),
            )
            stub = StubCLI()
            report = self._run(root, stub, tracks=("system",), force=True)
        self.assertEqual(len(stub.calls), 1)
        self.assertEqual(report["tracks"][0]["status"], transcribe.STATUS_OK)


class FailureTests(unittest.TestCase):
    def test_missing_binary_fails_before_any_track(self):
        stub = StubCLI()
        with meeting() as root:
            report = transcribe.run(
                root,
                environ={"ACTA_FLUIDAUDIO_BIN": "/nope/fluidaudiocli"},
                runner=stub,
            )
        self.assertEqual(report["status"], transcribe.STATUS_FAILED)
        self.assertIn("bootstrap.sh", report["detail"])
        self.assertEqual(report["tracks"], [])
        self.assertEqual(stub.calls, [])
        self.assertEqual(transcribe.exit_code(report), transcribe.EXIT_FAILED)

    def test_non_executable_binary_fails(self):
        env = {"ACTA_FLUIDAUDIO_BIN": executable_stub("not-runnable", executable=False)}
        with meeting() as root:
            report = transcribe.run(root, environ=env, runner=StubCLI())
        self.assertEqual(report["status"], transcribe.STATUS_FAILED)

    def test_non_zero_cli_exit_fails_the_track_and_the_stage(self):
        stub = StubCLI(code=3, stderr="line one\nmodel load failed\n")
        with meeting(("system",)) as root:
            report = transcribe.run(
                root,
                tracks=("system",),
                environ=stub_env(),
                runner=stub,
            )
        entry = report["tracks"][0]
        self.assertEqual(entry["status"], transcribe.STATUS_FAILED)
        self.assertEqual(entry["exit_code"], 3)
        self.assertEqual(entry["stderr_tail"][-1], "model load failed")
        self.assertEqual(report["status"], transcribe.STATUS_FAILED)
        self.assertEqual(transcribe.exit_code(report), transcribe.EXIT_FAILED)

    def test_exit_zero_without_output_json_fails(self):
        stub = StubCLI(write_output=False)
        with meeting(("system",)) as root:
            report = transcribe.run(
                root,
                tracks=("system",),
                environ=stub_env(),
                runner=stub,
            )
        self.assertEqual(report["tracks"][0]["status"], transcribe.STATUS_FAILED)
        self.assertIn("wrote no JSON", report["tracks"][0]["detail"])

    def test_corrupt_output_json_fails(self):
        stub = StubCLI(payload="{not json")
        with meeting(("system",)) as root:
            report = transcribe.run(
                root,
                tracks=("system",),
                environ=stub_env(),
                runner=stub,
            )
        self.assertEqual(report["tracks"][0]["status"], transcribe.STATUS_FAILED)
        self.assertIn("not valid JSON", report["tracks"][0]["detail"])


class EmptyWordTimingsTests(unittest.TestCase):
    def _report(self, payload):
        stub = StubCLI(payload=payload)
        with meeting(("mic",)) as root:
            return transcribe.run(
                root,
                tracks=("mic",),
                environ=stub_env(),
                runner=stub,
            )

    def test_empty_transcript_is_empty_not_failed(self):
        report = self._report({"text": "", "wordTimings": [], "modelVersion": "v3"})
        entry = report["tracks"][0]
        self.assertEqual(entry["status"], transcribe.STATUS_EMPTY)
        self.assertEqual(entry["word_count"], 0)
        self.assertIsNone(entry["mean_confidence"])
        self.assertEqual(report["status"], transcribe.STATUS_OK)
        self.assertEqual(report["empty_tracks"], ["mic"])

    def test_an_empty_track_stays_in_empty_tracks_across_a_partial_rerun(self):
        """"This track carried no speech" is a fact about the recording.

        The tally was keyed on ``status == STATUS_EMPTY`` and taken *before* the
        carry-forward, and ``carry_forward_tracks`` overwrites a carried entry's
        status with STATUS_CARRIED — so a track a previous run found empty
        vanished from ``empty_tracks`` on any partial re-run, e.g. the
        ``--track system`` retry SKILL.md prescribes when the loop gate trips.
        ``gate.py``'s ``silent_tracks`` survives the same treatment by keying on
        a field carry-forward leaves intact; ``was_empty`` is that here.
        """
        with meeting(("mic", "system")) as root:
            silent = transcribe.run(
                root,
                tracks=("mic",),
                environ=stub_env(),
                runner=StubCLI(payload={"text": "", "wordTimings": [], "modelVersion": "v3"}),
            )
            self.assertEqual(silent["empty_tracks"], ["mic"])
            transcribe.write_stage_json(root, silent)

            # Now the `--track system` retry: mic is not selected at all.
            retry = transcribe.run(
                root,
                tracks=("system",),
                environ=stub_env(),
                runner=StubCLI(),
            )
        self.assertEqual(retry["empty_tracks"], ["mic"])
        carried = next(e for e in retry["tracks"] if e["track"] == "mic")
        self.assertEqual(carried["status"], transcribe.STATUS_CARRIED)
        self.assertTrue(carried["was_empty"])

    def test_text_without_word_timings_is_a_hard_failure(self):
        # Text but no timings means --word-timestamps did not take effect; S5
        # cannot cut utterances or assign speakers without them.
        report = self._report({"text": "что-то сказано", "wordTimings": []})
        entry = report["tracks"][0]
        self.assertEqual(entry["status"], transcribe.STATUS_FAILED)
        self.assertIn("wordTimings", entry["detail"])
        self.assertEqual(report["status"], transcribe.STATUS_FAILED)


class CustomVocabTests(unittest.TestCase):
    def test_extra_model_dependency_is_recorded_in_the_stage_json(self):
        stub = StubCLI()
        with meeting(("system",)) as root:
            vocab = root / "terms.txt"
            vocab.write_text("Contoso\nWebSDK\n", encoding="utf-8")
            report = transcribe.run(
                root,
                tracks=("system",),
                custom_vocab=str(vocab),
                environ=stub_env(),
                runner=stub,
            )
        self.assertEqual(report["extra_models"], ["parakeet-ctc-110m-coreml"])
        self.assertEqual(report["tracks"][0]["extra_models"], ["parakeet-ctc-110m-coreml"])
        self.assertIn("optional", report["extra_models_note"])
        self.assertIn("--custom-vocab", stub.calls[0])

    def test_a_default_run_records_no_extra_models(self):
        stub = StubCLI()
        with meeting(("system",)) as root:
            report = transcribe.run(
                root,
                tracks=("system",),
                environ=stub_env(),
                runner=stub,
            )
        self.assertEqual(report["extra_models"], [])
        self.assertNotIn("extra_models_note", report)
        self.assertIsNone(report["tracks"][0]["custom_vocab"])

    def test_help_documents_the_extra_model(self):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            with self.assertRaises(SystemExit):
                transcribe.main(["--help"])
        self.assertIn("parakeet-ctc-110m-coreml", buf.getvalue())


class MainTests(unittest.TestCase):
    def test_json_output_and_exit_code(self):
        stub = StubCLI()
        with meeting(("system",)) as root:
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                code = transcribe.main(
                    [str(root), "--track", "system", "--json"],
                    environ=stub_env(),
                    runner=stub,
                )
            stage_json = root / transcribe.WORK_DIRNAME / transcribe.STAGE_JSON_NAME
            self.assertTrue(stage_json.is_file())
        self.assertEqual(code, transcribe.EXIT_OK)
        payload = json.loads(buf.getvalue())
        self.assertEqual(payload["stage"], "transcribe")
        self.assertEqual(payload["word_count"], 7)

    def test_human_output_and_failure_exit_code(self):
        stub = StubCLI(code=1)
        with meeting(("system",)) as root:
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                code = transcribe.main(
                    [str(root), "--track", "system"],
                    environ=stub_env(),
                    runner=stub,
                )
        self.assertEqual(code, transcribe.EXIT_FAILED)
        self.assertIn("FAILED", buf.getvalue())

    def test_missing_meeting_folder_is_a_usage_error(self):
        buf = io.StringIO()
        with contextlib.redirect_stderr(buf):
            with self.assertRaises(SystemExit) as ctx:
                transcribe.main(["/nope/meeting"], environ={}, runner=StubCLI())
        self.assertEqual(ctx.exception.code, transcribe.EXIT_USAGE)

    def test_missing_custom_vocab_file_is_a_usage_error(self):
        buf = io.StringIO()
        with meeting(("system",)) as root:
            with contextlib.redirect_stderr(buf):
                with self.assertRaises(SystemExit) as ctx:
                    transcribe.main(
                        [str(root), "--custom-vocab", str(root / "nope.txt")],
                        environ={},
                        runner=StubCLI(),
                    )
        self.assertEqual(ctx.exception.code, transcribe.EXIT_USAGE)


class RealStubBinaryTests(unittest.TestCase):
    """One pass through the real subprocess path, not the injected runner."""

    def test_end_to_end_against_an_executable_stub(self):
        with tempfile.TemporaryDirectory() as tmp:
            stub = Path(tmp) / "fluidaudiocli"
            stub.write_text(
                "#!/bin/sh\n"
                'while [ "$#" -gt 0 ]; do\n'
                '  if [ "$1" = "--output-json" ]; then out="$2"; fi\n'
                "  shift\n"
                "done\n"
                f'cat "{_ctx.fixture(FIXTURE)}" > "$out"\n',
                encoding="utf-8",
            )
            stub.chmod(stub.stat().st_mode | stat.S_IXUSR)
            with meeting(("system",)) as root:
                report = transcribe.run(
                    root,
                    tracks=("system",),
                    environ={"ACTA_FLUIDAUDIO_BIN": str(stub)},
                )
                self.assertTrue(transcribe.raw_json_path(root, "system").is_file())
        self.assertEqual(report["status"], transcribe.STATUS_OK)
        self.assertEqual(report["tracks"][0]["word_count"], 7)
        self.assertEqual(report["binary"]["source"], "env:ACTA_FLUIDAUDIO_BIN")


class NonNumericTimingTests(unittest.TestCase):
    """The CLI's JSON is external input: a field can be present and still not be
    a number. A bare float() would escape the stage as a traceback — and because
    pipeline.py writes pipeline.json only after run() returns, the whole run log
    would go with it."""

    def test_a_non_numeric_start_drops_the_word_instead_of_raising(self):
        raw = {
            "wordTimings": [
                {"word": "раз", "startTime": 0.0, "endTime": 0.4, "confidence": 0.9},
                {"word": "два", "startTime": "n/a", "endTime": 1.0},
                {"word": "три", "startTime": 1.2, "endTime": None},
            ]
        }
        words = transcribe.parse_word_timings(raw)
        self.assertEqual([w["word"] for w in words], ["раз"])

    def test_a_non_numeric_confidence_scores_as_unscored(self):
        raw = {
            "wordTimings": [
                {"word": "раз", "startTime": 0.0, "endTime": 0.4, "confidence": "high"}
            ]
        }
        words = transcribe.parse_word_timings(raw)
        self.assertEqual(len(words), 1)
        self.assertIsNone(words[0]["confidence"])

    def test_a_reversed_or_empty_span_is_dropped_like_a_bad_segment(self):
        """`diarize.parse_segments` drops `end <= start`; this had no such guard.

        merge.split_utterances measures the pause between words as
        `word["start"] - previous["end"]`, so a reversed end fabricates a gap and
        splits one utterance into several — and skews the utterance's own
        max(end). Nothing between here and there filters it.
        """
        raw = {
            "wordTimings": [
                {"word": "раз", "startTime": 0.0, "endTime": 0.4},
                {"word": "два", "startTime": 5.0, "endTime": 1.0},  # reversed
                {"word": "три", "startTime": 2.0, "endTime": 2.0},  # zero-length
                {"word": "четыре", "startTime": 2.5, "endTime": 2.9},
            ]
        }
        words = transcribe.parse_word_timings(raw)
        self.assertEqual([w["word"] for w in words], ["раз", "четыре"])

    def test_as_number_rejects_bools_and_junk(self):
        # True would otherwise coerce to 1.0 and pass as a timing.
        self.assertIsNone(transcribe.as_number(True))
        self.assertIsNone(transcribe.as_number("n/a"))
        self.assertIsNone(transcribe.as_number([1]))
        self.assertEqual(transcribe.as_number("1.5"), 1.5)


class CarryForwardTests(unittest.TestCase):
    """A single-track rerun must not erase the other track's ASR record.

    merge.py builds transcript.raw.md out of the ``words`` this stage JSON
    records per track, so an erased entry is a silently half-missing transcript —
    reported at 100% coverage.
    """

    def _write_report(self, root, tracks, language=None):
        transcribe.write_stage_json(
            root,
            {
                "stage": "transcribe",
                "status": "ok",
                "language": language,
                "tracks": [
                    {
                        "track": track,
                        "status": "ok",
                        "language": language,
                        "custom_vocab": None,
                        "word_count": 3,
                        "words": [{"word": "раз", "start": 0.0, "end": 0.4}],
                    }
                    for track in tracks
                ],
            },
        )

    def test_a_missing_binary_run_does_not_erase_the_recorded_asr(self):
        """The failure path has to carry provenance forward too.

        prep_audio.run does exactly this for its own absent binary (pinned by
        test_a_missing_ffmpeg_run_does_not_erase_the_recorded_chains); this stage
        had the machinery and never called it on that path. main() writes the
        report unconditionally, so returning early with ``tracks: []`` erased every
        recorded word list and every recorded --language without attempting a
        single track. previous_asr_options then found no record, read that as "same
        options", and the next run skipped the CLI while reporting the language it
        was *asked* for — which verify.py copies straight into quality.md. It also
        left merge.py with no words at all.
        """
        with meeting() as root:
            self._write_report(root, ("mic", "system"), language="ru")

            stub = StubCLI()
            report = transcribe.run(
                root,
                environ={"ACTA_FLUIDAUDIO_BIN": "/nope/fluidaudiocli"},
                runner=stub,
            )
            self.assertEqual(report["status"], transcribe.STATUS_FAILED)
            self.assertEqual(stub.calls, [], "no track may be attempted")
            transcribe.write_stage_json(root, report)

            # The options that actually produced the words are still on record, so
            # the next `--language ru` run is a cache hit and not a silent skip.
            for track in ("mic", "system"):
                self.assertEqual(
                    transcribe.previous_asr_options(root, track), ("ru", None)
                )
            for entry in report["tracks"]:
                self.assertEqual(entry["status"], transcribe.STATUS_CARRIED)
            # And merge.py can still see the words it builds the transcript from.
            self.assertEqual(report["word_count"], 6)

    def test_a_missing_binary_run_with_no_prior_report_stays_empty(self):
        with meeting() as root:
            report = transcribe.run(
                root,
                environ={"ACTA_FLUIDAUDIO_BIN": "/nope/fluidaudiocli"},
                runner=StubCLI(),
            )
        self.assertEqual(report["status"], transcribe.STATUS_FAILED)
        self.assertEqual(report["tracks"], [])
        self.assertEqual(report["word_count"], 0)

    def test_an_untouched_tracks_words_survive_a_single_track_run(self):
        with meeting() as root:
            self._write_report(root, ("mic", "system"))
            report = {
                "stage": "transcribe",
                "status": "ok",
                "tracks": [{"track": "system", "status": "ok", "word_count": 5}],
            }
            transcribe.carry_forward_tracks(root, report)

            carried = next(e for e in report["tracks"] if e["track"] == "mic")
            self.assertEqual(carried["status"], transcribe.STATUS_CARRIED)
            self.assertEqual(carried["elapsed_seconds"], 0.0)
            self.assertTrue(carried["words"], "the mic words must survive for merge.py")

    def test_a_single_track_run_leaves_the_other_tracks_words_on_disk(self):
        with meeting() as root:
            self._write_report(root, ("mic", "system"))
            report = transcribe.run(
                root,
                tracks=("system",),
                force=True,
                environ=stub_env(),
                runner=StubCLI(),
            )
            transcribe.write_stage_json(root, report)

            written = json.loads(
                (root / transcribe.WORK_DIRNAME / transcribe.STAGE_JSON_NAME).read_text(
                    encoding="utf-8"
                )
            )
            tracks = {entry["track"]: entry for entry in written["tracks"]}
            self.assertEqual(set(tracks), {"mic", "system"})
            self.assertTrue(tracks["mic"]["words"])

    def test_a_carried_language_still_pins_previous_asr_options(self):
        # Without the carry-forward a follow-up `--track mic --language ru` finds
        # no recorded language, calls that "same options", skips the CLI and then
        # reports ru over an auto-LID output.
        with meeting() as root:
            self._write_report(root, ("mic", "system"), language=None)
            report = {
                "stage": "transcribe",
                "status": "ok",
                "tracks": [
                    {"track": "system", "status": "ok", "language": "ru",
                     "custom_vocab": None, "word_count": 1},
                ],
            }
            transcribe.carry_forward_tracks(root, report)
            transcribe.write_stage_json(root, report)

            self.assertEqual(transcribe.previous_asr_options(root, "mic"), (None, None))
            self.assertEqual(transcribe.previous_asr_options(root, "system"), ("ru", None))

    def test_a_track_this_run_touched_is_never_overwritten_by_the_old_record(self):
        with meeting() as root:
            self._write_report(root, ("mic",), language="en")
            report = {
                "stage": "transcribe",
                "status": "ok",
                "tracks": [
                    {"track": "mic", "status": "ok", "language": "ru",
                     "custom_vocab": None, "word_count": 9},
                ],
            }
            transcribe.carry_forward_tracks(root, report)

        self.assertEqual(len(report["tracks"]), 1)
        self.assertEqual(report["tracks"][0]["language"], "ru")

    def test_carried_words_are_counted_in_the_reports_word_count(self):
        # The count has to describe the transcript merge.py can build from this
        # file, not just the tracks this invocation touched.
        with meeting() as root:
            self._write_report(root, ("mic", "system"))
            report = transcribe.run(
                root,
                tracks=("system",),
                force=True,
                environ=stub_env(),
                runner=StubCLI(),
            )
            mic = next(e for e in report["tracks"] if e["track"] == "mic")
            self.assertEqual(
                report["word_count"],
                sum(e.get("word_count") or 0 for e in report["tracks"]),
            )
            self.assertGreater(mic["word_count"], 0)

    def test_carried_entries_never_colour_the_status_or_the_elapsed_time(self):
        with meeting() as root:
            transcribe.write_stage_json(
                root,
                {
                    "stage": "transcribe",
                    "status": "failed",
                    "tracks": [{"track": "mic", "status": "failed", "detail": "boom"}],
                },
            )
            report = transcribe.run(
                root,
                tracks=("system",),
                force=True,
                environ=stub_env(),
                runner=StubCLI(),
            )

        self.assertEqual(report["status"], transcribe.STATUS_OK)
        carried = next(e for e in report["tracks"] if e["track"] == "mic")
        self.assertEqual(carried["status"], transcribe.STATUS_CARRIED)
        self.assertEqual(
            report["total_seconds"],
            round(
                sum(
                    e.get("elapsed_seconds") or 0.0
                    for e in report["tracks"]
                    if e["track"] == "system"
                ),
                3,
            ),
        )

    def test_no_previous_report_is_not_an_error(self):
        with meeting() as root:
            report = {"stage": "transcribe", "status": "ok", "tracks": []}
            self.assertIs(transcribe.carry_forward_tracks(root, report), report)
            self.assertEqual(report["tracks"], [])

    def test_an_unreadable_previous_report_is_not_an_error(self):
        with meeting() as root:
            path = root / transcribe.WORK_DIRNAME / transcribe.STAGE_JSON_NAME
            path.write_text("{not json", encoding="utf-8")
            report = {"stage": "transcribe", "status": "ok", "tracks": []}
            self.assertIs(transcribe.carry_forward_tracks(root, report), report)
            self.assertEqual(report["tracks"], [])

    def test_a_carried_entry_renders_without_raising(self):
        with meeting() as root:
            self._write_report(root, ("mic", "system"))
            report = transcribe.run(
                root,
                tracks=("system",),
                force=True,
                environ=stub_env(),
                runner=StubCLI(),
            )
        self.assertIn(transcribe.STATUS_CARRIED, transcribe.render_human(report))


class TimeoutTests(unittest.TestCase):
    def test_a_hung_cli_becomes_a_reported_failure_not_an_endless_wait(self):
        # The stage JSON is written only after run() returns, so an unbounded wait
        # on a wedged binary left no forensic record of the stall at all.
        code, stderr = transcribe.default_runner(["/bin/sh", "-c", "sleep 30"], timeout=0.2)
        self.assertEqual(code, transcribe.TIMEOUT_EXIT_CODE)
        self.assertIn("did not exit within", stderr)
        self.assertIn(transcribe.TIMEOUT_ENV_VAR, stderr)

    def test_a_spawn_failure_inside_the_runner_is_a_failed_track(self):
        """`is_executable` checks the exec bit, not the file's format, so a
        wrong-architecture build or a text file at ACTA_FLUIDAUDIO_BIN reaches the
        runner and raised OSError straight out of run() — costing the stage the
        very JSON this module's error handling exists to preserve."""
        code, message = transcribe.default_runner(["/definitely/not/here/fluidaudiocli"])
        self.assertEqual(code, transcribe.SPAWN_FAILED_EXIT_CODE)
        self.assertIn("could not run fluidaudiocli", message)

    def test_an_unexecutable_format_is_reported_rather_than_raised(self):
        with tempfile.TemporaryDirectory() as tmp:
            fake = Path(tmp) / "fluidaudiocli"
            fake.write_text("not a mach-o binary\n", encoding="utf-8")
            fake.chmod(0o755)
            self.assertTrue(transcribe.is_executable(fake))
            code, message = transcribe.default_runner([str(fake)])
        self.assertEqual(code, transcribe.SPAWN_FAILED_EXIT_CODE)
        self.assertIn("could not run fluidaudiocli", message)

    def test_the_ceiling_is_overridable_and_falls_back_on_junk(self):
        self.assertEqual(
            transcribe.resolve_timeout({}), transcribe.DEFAULT_TIMEOUT_SECONDS
        )
        self.assertEqual(
            transcribe.resolve_timeout({transcribe.TIMEOUT_ENV_VAR: "600"}), 600.0
        )
        for junk in ("", "abc", "0", "-1"):
            with self.subTest(junk=junk):
                self.assertEqual(
                    transcribe.resolve_timeout({transcribe.TIMEOUT_ENV_VAR: junk}),
                    transcribe.DEFAULT_TIMEOUT_SECONDS,
                )


class TrackNameTests(unittest.TestCase):
    def test_a_name_that_would_escape_the_meeting_folder_is_refused(self):
        for name in ("../../../etc/passwd", "a/b", "..", "", "mic.wav"):
            with self.subTest(name=name):
                self.assertFalse(transcribe.valid_track_name(name))
        for name in ("mic", "system", "track_2", "aux-1"):
            with self.subTest(name=name):
                self.assertTrue(transcribe.valid_track_name(name))

    def test_the_cli_rejects_it(self):
        with meeting() as root:
            buf = io.StringIO()
            with contextlib.redirect_stderr(buf), self.assertRaises(SystemExit) as caught:
                transcribe.main([str(root), "--track", "../escaped"])
        self.assertEqual(caught.exception.code, transcribe.EXIT_USAGE)
        self.assertIn("not a usable track name", buf.getvalue())


if __name__ == "__main__":
    unittest.main()
