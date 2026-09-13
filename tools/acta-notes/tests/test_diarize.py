import _ctx

import contextlib
import io
import json
import os
import stat
import tempfile
import unittest
from pathlib import Path

diarize = _ctx.load("diarize")

FIXTURE = "diarization_segments.json"
BIN = "/fake/bin/fluidaudiocli"

#: The fixture's embeddings are 4-d, not the real 256-d — nothing here reads a
#: vector's contents, only whether it survived stripping.
FIXTURE_EMBEDDING_DIM = 4


def fixture_data() -> dict:
    return json.loads(_ctx.read_fixture(FIXTURE))


_STUB_DIR = tempfile.TemporaryDirectory()


def executable_stub(name="fluidaudiocli", executable=True) -> str:
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
    """Records argv and echoes the committed fixture to --output."""

    def __init__(self, code=0, stderr="", payload=None, write_output=True):
        self.calls = []
        self.code = code
        self.stderr = stderr
        self.payload = payload
        self.write_output = write_output

    def __call__(self, argv):
        self.calls.append(list(argv))
        if self.code == 0 and self.write_output:
            out = Path(argv[argv.index("--output") + 1])
            payload = fixture_data() if self.payload is None else self.payload
            out.parent.mkdir(parents=True, exist_ok=True)
            out.write_text(
                json.dumps(payload, ensure_ascii=False)
                if isinstance(payload, (dict, list))
                else payload,
                encoding="utf-8",
            )
        return self.code, self.stderr


@contextlib.contextmanager
def meeting(tracks=("mic", "system")):
    """A meeting folder that already has S1's 16 kHz outputs (contents unread)."""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp) / "2026-07-29 Weekly"
        work = root / diarize.WORK_DIRNAME
        work.mkdir(parents=True)
        for track in tracks:
            (work / f"{track}{diarize.INPUT_SUFFIX}").write_bytes(b"RIFFfake")
        yield root


def touch_newer(path, reference, delta=10):
    stamp = Path(reference).stat().st_mtime + delta
    os.utime(path, (stamp, stamp))


def metrics_payload(**overrides) -> dict:
    payload = fixture_data()
    metrics = {
        "der": 0.1842,
        "missRate": 0.0413,
        "falseAlarmRate": 0.0227,
        "speakerErrorRate": 0.1202,
        "jer": 0.2611,
        "speakerMapping": {"Speaker 1": "spk_a", "Speaker 2": "spk_b"},
        "evaluationCollarSeconds": 0.25,
        "evaluationIgnoresOverlap": True,
    }
    metrics.update(overrides)
    payload["metrics"] = metrics
    return payload


class BinaryResolutionTests(unittest.TestCase):
    def test_env_override_wins(self):
        path, source = diarize.resolve_fluidaudio_bin(
            {"ACTA_FLUIDAUDIO_BIN": "/opt/fa/fluidaudiocli", "HOME": "/home/x"}
        )
        self.assertEqual(path, Path("/opt/fa/fluidaudiocli"))
        self.assertEqual(source, "env:ACTA_FLUIDAUDIO_BIN")

    def test_cache_path_is_the_fallback(self):
        path, source = diarize.resolve_fluidaudio_bin({"HOME": "/home/x"})
        self.assertEqual(
            path,
            Path("/home/x/.cache/acta-notes/fluidaudio/.build/release/fluidaudiocli"),
        )
        self.assertEqual(source, "cache-default")


class ParameterResolutionTests(unittest.TestCase):
    def test_unknown_count_falls_back_to_the_measured_threshold(self):
        params = diarize.resolve_parameters()
        self.assertEqual(params["control"], "threshold")
        self.assertEqual(params["threshold"], 0.75)
        self.assertIsNone(params["num_speakers"])

    def test_known_count_is_the_primary_control_and_drops_the_threshold(self):
        params = diarize.resolve_parameters(num_speakers=5)
        self.assertEqual(params["control"], "num-speakers")
        self.assertEqual(params["num_speakers"], 5)
        self.assertIsNone(params["threshold"])

    def test_segmentation_defaults_are_recorded_not_assumed(self):
        params = diarize.resolve_parameters()
        self.assertEqual(params["min_segment_duration"], 1.0)
        self.assertEqual(params["min_gap_duration"], 0.1)

    def test_offline_vbx_is_the_only_mode_recorded(self):
        params = diarize.resolve_parameters()
        self.assertEqual(params["mode"], "offline")
        self.assertEqual(params["diarizer"], "offline-vbx")
        self.assertEqual(params["model"], "speaker-diarization")

    def test_the_cli_default_threshold_is_refused(self):
        with self.assertRaises(diarize.ParameterError) as ctx:
            diarize.resolve_parameters(threshold=0.6)
        self.assertIn("collapses", str(ctx.exception))

    def test_count_and_threshold_together_are_refused(self):
        with self.assertRaises(diarize.ParameterError):
            diarize.resolve_parameters(num_speakers=4, threshold=0.75)

    def test_a_nonsense_count_is_refused(self):
        with self.assertRaises(diarize.ParameterError):
            diarize.resolve_parameters(num_speakers=0)


class ArgvTests(unittest.TestCase):
    def _argv(self, **kwargs):
        return diarize.build_argv(
            BIN,
            "/m/.acta-notes/system.16k.wav",
            "/m/.acta-notes/system.diar.raw.json",
            diarize.resolve_parameters(**kwargs),
        )

    def test_known_speaker_count_argv_is_exact(self):
        self.assertEqual(
            self._argv(num_speakers=6),
            [
                BIN,
                "process",
                "/m/.acta-notes/system.16k.wav",
                "--mode",
                "offline",
                "--output",
                "/m/.acta-notes/system.diar.raw.json",
                "--min-segment-duration",
                "1.0",
                "--min-gap-duration",
                "0.1",
                "--num-speakers",
                "6",
            ],
        )

    def test_unknown_speaker_count_uses_the_threshold_fallback(self):
        argv = self._argv()
        self.assertEqual(argv[-2:], ["--threshold", "0.75"])
        self.assertNotIn("--num-speakers", argv)

    def test_the_collapsing_default_never_appears_and_the_bounds_always_do(self):
        for kwargs in ({}, {"num_speakers": 4}, {"threshold": 0.9}):
            argv = self._argv(**kwargs)
            with self.subTest(kwargs=kwargs):
                self.assertNotIn("0.6", argv)
                self.assertIn("--min-segment-duration", argv)
                self.assertIn("1.0", argv)
                self.assertIn("--min-gap-duration", argv)
                self.assertIn("0.1", argv)

    def test_no_streaming_engine_flag_is_ever_emitted(self):
        for kwargs in ({}, {"num_speakers": 4}):
            argv = self._argv(**kwargs)
            with self.subTest(kwargs=kwargs):
                self.assertEqual(argv[argv.index("--mode") + 1], "offline")
                for flag in diarize.STREAMING_ONLY_FLAGS:
                    self.assertNotIn(flag, argv)
                for engine in ("sortformer", "ls-eend", "streaming"):
                    self.assertNotIn(engine, argv)

    def test_overridden_bounds_land_in_the_argv(self):
        argv = self._argv(min_segment_duration=1.5, min_gap_duration=0.25)
        self.assertEqual(argv[argv.index("--min-segment-duration") + 1], "1.5")
        self.assertEqual(argv[argv.index("--min-gap-duration") + 1], "0.25")

    def test_rttm_is_an_input_only_present_when_asked_for(self):
        params = diarize.resolve_parameters(num_speakers=4)
        plain = diarize.build_argv(BIN, "/m/a.wav", "/m/a.json", params)
        scored = diarize.build_argv(BIN, "/m/a.wav", "/m/a.json", params, rttm="/m/ref.rttm")
        self.assertNotIn("--rttm", plain)
        self.assertEqual(scored[-2:], ["--rttm", "/m/ref.rttm"])


class MicRefusalTests(unittest.TestCase):
    """D5 is enforced on the argument, before anything else happens."""

    def test_mic_exits_two_without_invoking_the_binary(self):
        stub = StubCLI()
        with meeting() as root:
            report = diarize.run(root, track="mic", environ=stub_env(), runner=stub)
        self.assertEqual(report["status"], diarize.STATUS_REFUSED)
        self.assertEqual(stub.calls, [])
        self.assertEqual(diarize.exit_code(report), 2)
        self.assertIn("D5", report["detail"])

    def test_the_refusal_happens_before_the_binary_is_even_resolved(self):
        # No env, no binary, no wav — the refusal must not depend on any of them.
        report = diarize.run("/nonexistent/meeting", track="mic", environ={})
        self.assertEqual(report["status"], diarize.STATUS_REFUSED)
        self.assertIsNone(report["argv"])
        self.assertNotIn("binary", report)

    def test_main_refuses_mic_and_writes_nothing(self):
        stub = StubCLI()
        with meeting() as root:
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                code = diarize.main(
                    ["run", str(root), "--track", "mic"],
                    environ=stub_env(),
                    runner=stub,
                )
            self.assertFalse(diarize.stage_json_path(root).exists())
        self.assertEqual(code, 2)
        self.assertEqual(stub.calls, [])

    def test_a_failure_never_clobbers_a_good_diarization_json(self):
        """diarization.json is a durable meeting-root artifact, not a log.

        `main` wrote every non-refusal report, so a re-run whose CLI call failed
        replaced minutes of clustering with `{"status": "failed"}`.
        """
        with meeting() as root:
            good = {"stage": "diarize", "status": "ok", "segments": [{"speaker": "SPK_00"}]}
            diarize.stage_json_path(root).write_text(
                json.dumps(good), encoding="utf-8"
            )

            with contextlib.redirect_stdout(io.StringIO()):
                code = diarize.main(
                    ["run", str(root), "--track", "system", "--force"],
                    environ=stub_env(),
                    runner=StubCLI(code=1, stderr="boom", write_output=False),
                )

            self.assertNotEqual(code, 0)
            on_disk = json.loads(
                diarize.stage_json_path(root).read_text(encoding="utf-8")
            )
        self.assertEqual(on_disk, good)

    def test_missing_track_argument_is_an_argparse_error(self):
        with meeting() as root:
            with contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as ctx:
                    diarize.main(["run", str(root)], environ=stub_env(), runner=StubCLI())
        self.assertEqual(ctx.exception.code, diarize.EXIT_USAGE)

    def test_an_unknown_track_is_an_argparse_error(self):
        with meeting() as root:
            with contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as ctx:
                    diarize.main(
                        ["run", str(root), "--track", "speaker"],
                        environ=stub_env(),
                        runner=StubCLI(),
                    )
        self.assertEqual(ctx.exception.code, diarize.EXIT_USAGE)


class SegmentParsingTests(unittest.TestCase):
    def test_fixture_segments_are_normalized_and_labelled_by_first_appearance(self):
        segments = diarize.parse_segments(fixture_data())
        self.assertEqual(len(segments), 6)
        self.assertEqual(
            segments[0],
            {
                "start": 0.52,
                "end": 12.4,
                "duration": 11.88,
                "speaker": "SPK_01",
                "speaker_id": "Speaker 1",
                "quality": 0.88,
                "embedding_dim": FIXTURE_EMBEDDING_DIM,
            },
        )
        self.assertEqual(
            [s["speaker"] for s in segments],
            ["SPK_01", "SPK_02", "SPK_01", "SPK_03", "SPK_02", "SPK_01"],
        )

    def test_unusable_segments_are_dropped(self):
        raw = {
            "segments": [
                {"startTimeSeconds": 1.0, "endTimeSeconds": 2.0, "speakerId": "A"},
                {"startTimeSeconds": 3.0, "endTimeSeconds": 3.0, "speakerId": "A"},
                {"startTimeSeconds": 5.0, "endTimeSeconds": 4.0, "speakerId": "A"},
                {"endTimeSeconds": 6.0, "speakerId": "A"},
                {"startTimeSeconds": 7.0, "endTimeSeconds": 8.0},
                "not-a-dict",
            ]
        }
        segments = diarize.parse_segments(raw)
        self.assertEqual(len(segments), 1)
        self.assertEqual(segments[0]["duration"], 1.0)

    def test_absent_segments_key_is_empty_not_an_error(self):
        self.assertEqual(diarize.parse_segments({}), [])
        self.assertEqual(diarize.parse_segments({"segments": None}), [])


class EmbeddingStrippingTests(unittest.TestCase):
    def test_embeddings_are_stripped_by_default(self):
        segments = diarize.parse_segments(fixture_data())
        for segment in segments:
            self.assertNotIn("embedding", segment)
            self.assertEqual(segment["embedding_dim"], FIXTURE_EMBEDDING_DIM)

    def test_a_scalar_embedding_is_ignored_rather_than_raised_on(self):
        """The CLI's JSON is external input, and every other field here goes
        through `as_number` — this one was handed straight to `len()`, so a scalar
        `"embedding": 5` raised TypeError out of run() and cost the stage its
        report."""
        data = {
            "segments": [
                {
                    "startTimeSeconds": 0.0,
                    "endTimeSeconds": 1.0,
                    "speakerId": "a",
                    "embedding": 5,
                }
            ]
        }
        segments = diarize.parse_segments(data)
        self.assertEqual(len(segments), 1)
        self.assertIsNone(segments[0]["embedding_dim"])
        self.assertEqual(diarize.parse_segments(data, keep_embeddings=True)[0]["embedding"], [])

    def test_keep_embeddings_retains_the_vectors(self):
        segments = diarize.parse_segments(fixture_data(), keep_embeddings=True)
        self.assertEqual(len(segments[0]["embedding"]), FIXTURE_EMBEDDING_DIM)
        self.assertAlmostEqual(segments[0]["embedding"][0], 0.0121)

    def test_the_written_artifact_carries_no_vectors_by_default(self):
        stub = StubCLI()
        with meeting(("system",)) as root:
            report = diarize.run(root, track="system", environ=stub_env(), runner=stub)
            diarize.write_stage_json(root, report)
            text = diarize.stage_json_path(root).read_text(encoding="utf-8")
        self.assertNotIn("\"embedding\"", text)
        self.assertFalse(report["embeddings_kept"])
        self.assertEqual(report["embedding_dim"], FIXTURE_EMBEDDING_DIM)


class SpeakerRollupTests(unittest.TestCase):
    def test_per_speaker_durations_are_tallied_and_ordered_by_speech(self):
        rollup = diarize.speaker_rollup(diarize.parse_segments(fixture_data()))
        self.assertEqual([e["speaker"] for e in rollup], ["SPK_01", "SPK_02", "SPK_03"])
        self.assertEqual(rollup[0]["speech_seconds"], 39.98)
        self.assertEqual(rollup[0]["segments"], 3)
        self.assertEqual(rollup[1]["speech_seconds"], 29.95)
        # The 2 s speaker: exactly the collapse signature D2 measured, and the
        # reason this rollup exists at all.
        self.assertEqual(rollup[2]["speech_seconds"], 2.05)
        self.assertEqual(rollup[2]["segments"], 1)

    def test_mean_quality_ignores_segments_without_a_score(self):
        segments = [
            {"speaker": "SPK_01", "speaker_id": "A", "duration": 1.0, "quality": 0.8},
            {"speaker": "SPK_01", "speaker_id": "A", "duration": 1.0, "quality": None},
        ]
        rollup = diarize.speaker_rollup(segments)
        self.assertEqual(rollup[0]["mean_quality"], 0.8)

    def test_no_quality_at_all_yields_none_not_zero(self):
        segments = [
            {"speaker": "SPK_01", "speaker_id": "A", "duration": 1.0, "quality": None}
        ]
        self.assertIsNone(diarize.speaker_rollup(segments)[0]["mean_quality"])


class RunTests(unittest.TestCase):
    def _run(self, root, stub, **kwargs):
        kwargs.setdefault("track", "system")
        return diarize.run(
            root,
            environ=stub_env(),
            runner=stub,
            clock=iter([0.0, 12.25]).__next__,
            **kwargs,
        )

    def test_the_system_track_is_diarized_and_summarized(self):
        stub = StubCLI()
        with meeting() as root:
            report = self._run(root, stub, num_speakers=3)
        self.assertEqual(report["status"], diarize.STATUS_OK)
        self.assertEqual(report["segment_count"], 6)
        self.assertEqual(report["speaker_count"], 3)
        self.assertEqual(report["speech_seconds"], 71.98)
        self.assertEqual(report["elapsed_seconds"], 12.25)
        self.assertEqual(report["audio_duration_seconds"], 482.5)
        self.assertEqual(report["cli_speaker_count"], 3)
        self.assertEqual(len(stub.calls), 1)
        self.assertEqual(stub.calls[0][-2:], ["--num-speakers", "3"])

    def test_the_stage_json_is_the_meeting_level_artifact(self):
        stub = StubCLI()
        with meeting(("system",)) as root:
            report = self._run(root, stub)
            path = diarize.write_stage_json(root, report)
            payload = json.loads(path.read_text(encoding="utf-8"))
            self.assertEqual(path, root / "diarization.json")
            self.assertTrue(diarize.raw_json_path(root).is_file())
        self.assertEqual(payload["stage"], "diarize")
        self.assertEqual(payload["parameters"]["threshold"], 0.75)
        self.assertEqual(payload["parameters"]["min_segment_duration"], 1.0)
        self.assertEqual(payload["parameters"]["min_gap_duration"], 0.1)

    def test_missing_16k_track_is_reported_not_diarized(self):
        stub = StubCLI()
        with meeting(("mic",)) as root:
            report = self._run(root, stub)
        self.assertEqual(report["status"], diarize.STATUS_MISSING)
        self.assertIn("prep_audio.py", report["detail"])
        self.assertEqual(stub.calls, [])
        self.assertEqual(diarize.exit_code(report), diarize.EXIT_FAILED)

    def test_a_refused_parameter_combination_never_reaches_the_binary(self):
        stub = StubCLI()
        with meeting(("system",)) as root:
            report = diarize.run(
                root, track="system", threshold=0.6, environ=stub_env(), runner=stub
            )
        self.assertEqual(report["status"], diarize.STATUS_REFUSED)
        self.assertEqual(stub.calls, [])
        self.assertEqual(diarize.exit_code(report), 2)

    def test_fresh_output_with_the_same_parameters_is_reused_but_still_parsed(self):
        with meeting(("system",)) as root:
            first = self._run(root, StubCLI(), num_speakers=3)
            diarize.write_stage_json(root, first)
            touch_newer(diarize.raw_json_path(root), diarize.input_path(root))
            stub = StubCLI()
            again = diarize.run(
                root,
                track="system",
                num_speakers=3,
                environ=stub_env(),
                runner=stub,
            )
        self.assertEqual(again["status"], diarize.STATUS_SKIPPED)
        self.assertEqual(stub.calls, [])
        self.assertIsNone(again["argv"])
        self.assertEqual(again["segment_count"], 6)
        self.assertEqual(diarize.exit_code(again), diarize.EXIT_OK)

    def test_changed_parameters_force_a_re_run_even_when_the_output_is_fresh(self):
        with meeting(("system",)) as root:
            first = self._run(root, StubCLI(), num_speakers=3)
            diarize.write_stage_json(root, first)
            touch_newer(diarize.raw_json_path(root), diarize.input_path(root))
            stub = StubCLI()
            again = diarize.run(
                root,
                track="system",
                num_speakers=6,
                environ=stub_env(),
                runner=stub,
            )
        self.assertEqual(again["status"], diarize.STATUS_OK)
        self.assertEqual(len(stub.calls), 1)
        self.assertEqual(stub.calls[0][-2:], ["--num-speakers", "6"])

    def test_force_re_diarizes_fresh_output(self):
        with meeting(("system",)) as root:
            first = self._run(root, StubCLI(), num_speakers=3)
            diarize.write_stage_json(root, first)
            touch_newer(diarize.raw_json_path(root), diarize.input_path(root))
            stub = StubCLI()
            again = diarize.run(
                root,
                track="system",
                num_speakers=3,
                force=True,
                environ=stub_env(),
                runner=stub,
            )
        self.assertEqual(again["status"], diarize.STATUS_OK)
        self.assertEqual(len(stub.calls), 1)


class FailureTests(unittest.TestCase):
    def test_missing_binary_fails_loudly(self):
        stub = StubCLI()
        with meeting(("system",)) as root:
            report = diarize.run(
                root,
                track="system",
                environ={"ACTA_FLUIDAUDIO_BIN": "/nope/fluidaudiocli"},
                runner=stub,
            )
        self.assertEqual(report["status"], diarize.STATUS_FAILED)
        self.assertIn("bootstrap.sh", report["detail"])
        self.assertEqual(stub.calls, [])

    def test_non_executable_binary_fails(self):
        env = {"ACTA_FLUIDAUDIO_BIN": executable_stub("not-runnable", executable=False)}
        with meeting(("system",)) as root:
            report = diarize.run(root, track="system", environ=env, runner=StubCLI())
        self.assertEqual(report["status"], diarize.STATUS_FAILED)

    def test_non_zero_cli_exit_fails_the_stage(self):
        stub = StubCLI(code=3, stderr="line one\nmodel load failed\n")
        with meeting(("system",)) as root:
            report = diarize.run(root, track="system", environ=stub_env(), runner=stub)
        self.assertEqual(report["status"], diarize.STATUS_FAILED)
        self.assertEqual(report["exit_code"], 3)
        self.assertEqual(report["stderr_tail"][-1], "model load failed")

    def test_exit_zero_without_output_fails(self):
        stub = StubCLI(write_output=False)
        with meeting(("system",)) as root:
            report = diarize.run(root, track="system", environ=stub_env(), runner=stub)
        self.assertEqual(report["status"], diarize.STATUS_FAILED)
        self.assertIn("wrote no JSON", report["detail"])

    def test_corrupt_output_json_fails(self):
        stub = StubCLI(payload="{not json")
        with meeting(("system",)) as root:
            report = diarize.run(root, track="system", environ=stub_env(), runner=stub)
        self.assertEqual(report["status"], diarize.STATUS_FAILED)
        self.assertIn("not valid JSON", report["detail"])

    def test_zero_segments_is_a_failure_not_an_empty_success(self):
        stub = StubCLI(payload={"segments": [], "durationSeconds": 100.0})
        with meeting(("system",)) as root:
            report = diarize.run(root, track="system", environ=stub_env(), runner=stub)
        self.assertEqual(report["status"], diarize.STATUS_FAILED)
        self.assertEqual(report["segment_count"], 0)


class ScoreTests(unittest.TestCase):
    """D4: --rttm is ground-truth input and the CLI computes DER/JER itself."""

    def test_der_and_jer_are_extracted_and_written(self):
        stub = StubCLI(payload=metrics_payload())
        with meeting(("system",)) as root:
            rttm = root / "reference.rttm"
            rttm.write_text("SPEAKER x 1 0.52 11.88 <NA> <NA> A <NA> <NA>\n", encoding="utf-8")
            report = diarize.score(
                root,
                rttm=rttm,
                num_speakers=3,
                environ=stub_env(),
                runner=stub,
                clock=iter([0.0, 13.0]).__next__,
            )
            path = diarize.write_der_json(root, report)
            payload = json.loads(path.read_text(encoding="utf-8"))
            self.assertEqual(path, root / diarize.WORK_DIRNAME / "der.json")
        self.assertEqual(report["status"], diarize.STATUS_OK)
        self.assertEqual(report["metrics"]["der"], 0.1842)
        self.assertEqual(report["metrics"]["jer"], 0.2611)
        self.assertEqual(report["metrics"]["miss_rate"], 0.0413)
        self.assertEqual(report["metrics"]["false_alarm_rate"], 0.0227)
        self.assertEqual(report["metrics"]["speaker_error_rate"], 0.1202)
        self.assertEqual(report["metrics"]["collar_seconds"], 0.25)
        self.assertTrue(report["metrics"]["ignores_overlap"])
        self.assertEqual(report["metrics"]["speaker_mapping"]["Speaker 1"], "spk_a")
        self.assertEqual(payload["stage"], "diarize-score")

    def test_a_failed_score_never_clobbers_a_good_der_json(self):
        """der.json holds the baseline every future tuning pass is measured against.

        The `run` branch already refuses to write a failure over
        diarization.json, for the same reason and with the same cost profile —
        but `score` guarded only refusals, so a lost ACTA_FLUIDAUDIO_BIN, a
        mistyped --rttm or a non-zero CLI exit replaced a hand-annotated DER/JER
        baseline with `{"status": "failed"}`. The failure is still on stdout and
        in the exit code.
        """
        with meeting(("system",)) as root:
            good = {"stage": "diarize-score", "status": "ok", "metrics": {"der": 0.1842}}
            diarize.der_json_path(root).parent.mkdir(parents=True, exist_ok=True)
            diarize.der_json_path(root).write_text(json.dumps(good), encoding="utf-8")

            rttm = root / "reference.rttm"
            rttm.write_text("SPEAKER x 1 0.0 1.0 <NA> <NA> A <NA> <NA>\n", encoding="utf-8")

            with contextlib.redirect_stdout(io.StringIO()):
                code = diarize.main(
                    ["score", str(root), "--track", "system", "--rttm", str(rttm)],
                    environ=stub_env(),
                    runner=StubCLI(code=1, stderr="boom", write_output=False),
                )

            self.assertNotEqual(code, 0)
            on_disk = json.loads(
                diarize.der_json_path(root).read_text(encoding="utf-8")
            )
        self.assertEqual(on_disk, good)

    def test_a_successful_score_does_write_der_json(self):
        with meeting(("system",)) as root:
            rttm = root / "reference.rttm"
            rttm.write_text("SPEAKER x 1 0.0 1.0 <NA> <NA> A <NA> <NA>\n", encoding="utf-8")
            with contextlib.redirect_stdout(io.StringIO()):
                code = diarize.main(
                    ["score", str(root), "--track", "system", "--rttm", str(rttm)],
                    environ=stub_env(),
                    runner=StubCLI(payload=metrics_payload()),
                )
            self.assertEqual(code, 0)
            payload = json.loads(
                diarize.der_json_path(root).read_text(encoding="utf-8")
            )
        self.assertEqual(payload["metrics"]["der"], 0.1842)

    def test_the_rttm_is_passed_as_an_input_alongside_the_run_parameters(self):
        stub = StubCLI(payload=metrics_payload())
        with meeting(("system",)) as root:
            rttm = root / "reference.rttm"
            rttm.write_text("SPEAKER x 1 0.0 1.0 <NA> <NA> A <NA> <NA>\n", encoding="utf-8")
            diarize.score(root, rttm=rttm, num_speakers=3, environ=stub_env(), runner=stub)
        argv = stub.calls[0]
        self.assertEqual(argv[argv.index("--rttm") + 1], str(rttm))
        self.assertIn("--output", argv)
        self.assertEqual(argv[argv.index("--mode") + 1], "offline")
        self.assertEqual(argv[argv.index("--num-speakers") + 1], "3")

    def test_scoring_never_overwrites_the_runs_own_cli_output(self):
        with meeting(("system",)) as root:
            run_report = diarize.run(
                root, track="system", environ=stub_env(), runner=StubCLI()
            )
            self.assertEqual(run_report["status"], diarize.STATUS_OK)
            before = diarize.raw_json_path(root).read_bytes()
            rttm = root / "reference.rttm"
            rttm.write_text("SPEAKER x 1 0.0 1.0 <NA> <NA> A <NA> <NA>\n", encoding="utf-8")
            diarize.score(
                root, rttm=rttm, environ=stub_env(), runner=StubCLI(payload=metrics_payload())
            )
            self.assertEqual(diarize.raw_json_path(root).read_bytes(), before)
            self.assertTrue(diarize.score_raw_json_path(root).is_file())

    def test_a_missing_rttm_is_reported_not_run(self):
        stub = StubCLI()
        with meeting(("system",)) as root:
            report = diarize.score(
                root, rttm=root / "nope.rttm", environ=stub_env(), runner=stub
            )
        self.assertEqual(report["status"], diarize.STATUS_MISSING)
        self.assertEqual(stub.calls, [])

    def test_a_run_without_metrics_is_a_failed_scoring_run(self):
        stub = StubCLI()  # the plain fixture carries "metrics": null
        with meeting(("system",)) as root:
            rttm = root / "reference.rttm"
            rttm.write_text("SPEAKER x 1 0.0 1.0 <NA> <NA> A <NA> <NA>\n", encoding="utf-8")
            report = diarize.score(root, rttm=rttm, environ=stub_env(), runner=stub)
        self.assertEqual(report["status"], diarize.STATUS_FAILED)
        self.assertIsNone(report["metrics"])
        self.assertIn("DER/JER", report["detail"])

    def test_a_der_without_a_jer_still_scores(self):
        # JER is reported separately and an older CLI may omit it. The baseline
        # is the DER, so a missing JER is a gap in the line, not a crash.
        stub = StubCLI(payload=metrics_payload(jer=None))
        with meeting(("system",)) as root:
            rttm = root / "reference.rttm"
            rttm.write_text("SPEAKER x 1 0.0 1.0 <NA> <NA> A <NA> <NA>\n", encoding="utf-8")
            report = diarize.score(root, rttm=rttm, environ=stub_env(), runner=stub)

        self.assertEqual(report["status"], diarize.STATUS_OK)
        self.assertEqual(report["metrics"]["der"], 0.1842)
        self.assertIsNone(report["metrics"]["jer"])
        self.assertIn("DER 0.1842", report["detail"])
        self.assertIn("JER n/a", report["detail"])
        self.assertIn("JER n/a", diarize.render_human_score(report))

    def test_every_absent_metric_renders_as_n_a_not_as_bare_none(self):
        # miss/false-alarm/speaker-error used to bypass _fmt_metric and print the
        # Python literal `None` into a line a human reads.
        report = {
            "status": diarize.STATUS_OK,
            "metrics": {
                "der": 0.1842,
                "jer": None,
                "miss_rate": None,
                "false_alarm_rate": None,
                "speaker_error_rate": None,
            },
        }
        line = diarize.render_human_score(report)
        self.assertNotIn("None", line)
        for label in ("miss", "false-alarm", "speaker-error"):
            with self.subTest(metric=label):
                self.assertIn(f"{label} n/a", line)

    def test_score_refuses_the_mic_track(self):
        stub = StubCLI()
        with meeting() as root:
            rttm = root / "reference.rttm"
            rttm.write_text("SPEAKER x 1 0.0 1.0 <NA> <NA> A <NA> <NA>\n", encoding="utf-8")
            report = diarize.score(
                root, rttm=rttm, track="mic", environ=stub_env(), runner=stub
            )
        self.assertEqual(report["status"], diarize.STATUS_REFUSED)
        self.assertEqual(stub.calls, [])


class MainTests(unittest.TestCase):
    def test_run_json_output_and_exit_code(self):
        stub = StubCLI()
        with meeting(("system",)) as root:
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                code = diarize.main(
                    ["run", str(root), "--track", "system", "--num-speakers", "3", "--json"],
                    environ=stub_env(),
                    runner=stub,
                )
            self.assertTrue(diarize.stage_json_path(root).is_file())
        self.assertEqual(code, diarize.EXIT_OK)
        payload = json.loads(buf.getvalue())
        self.assertEqual(payload["stage"], "diarize")
        self.assertEqual(payload["speaker_count"], 3)

    def test_run_human_output_names_the_speakers_and_the_parameters(self):
        stub = StubCLI()
        with meeting(("system",)) as root:
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                code = diarize.main(
                    ["run", str(root), "--track", "system"],
                    environ=stub_env(),
                    runner=stub,
                )
        text = buf.getvalue()
        self.assertEqual(code, diarize.EXIT_OK)
        self.assertIn("SPK_01", text)
        self.assertIn("--threshold 0.75", text)
        self.assertIn("--min-gap-duration 0.1", text)

    def test_keep_embeddings_flag_reaches_the_artifact(self):
        stub = StubCLI()
        with meeting(("system",)) as root:
            with contextlib.redirect_stdout(io.StringIO()):
                diarize.main(
                    ["run", str(root), "--track", "system", "--keep-embeddings"],
                    environ=stub_env(),
                    runner=stub,
                )
            payload = json.loads(diarize.stage_json_path(root).read_text(encoding="utf-8"))
        self.assertTrue(payload["embeddings_kept"])
        self.assertEqual(len(payload["segments"][0]["embedding"]), FIXTURE_EMBEDDING_DIM)

    def test_score_writes_der_json_and_exits_zero(self):
        stub = StubCLI(payload=metrics_payload())
        with meeting(("system",)) as root:
            rttm = root / "reference.rttm"
            rttm.write_text("SPEAKER x 1 0.0 1.0 <NA> <NA> A <NA> <NA>\n", encoding="utf-8")
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                code = diarize.main(
                    ["score", str(root), "--rttm", str(rttm)],
                    environ=stub_env(),
                    runner=stub,
                )
            self.assertTrue(diarize.der_json_path(root).is_file())
        self.assertEqual(code, diarize.EXIT_OK)
        self.assertIn("DER 0.1842", buf.getvalue())

    def test_failure_exit_code(self):
        stub = StubCLI(code=1)
        with meeting(("system",)) as root:
            with contextlib.redirect_stdout(io.StringIO()):
                code = diarize.main(
                    ["run", str(root), "--track", "system"],
                    environ=stub_env(),
                    runner=stub,
                )
        self.assertEqual(code, diarize.EXIT_FAILED)

    def test_missing_meeting_folder_is_a_usage_error(self):
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as ctx:
                diarize.main(
                    ["run", "/nope/meeting", "--track", "system"],
                    environ={},
                    runner=StubCLI(),
                )
        self.assertEqual(ctx.exception.code, diarize.EXIT_USAGE)

    def test_a_mode_is_required(self):
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as ctx:
                diarize.main([], environ={}, runner=StubCLI())
        self.assertEqual(ctx.exception.code, diarize.EXIT_USAGE)

    def test_help_states_the_mic_refusal_and_the_threshold_policy(self):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            with self.assertRaises(SystemExit):
                diarize.main(["run", "--help"])
        text = buf.getvalue()
        self.assertIn("D5", text)
        self.assertIn("0.6", text)


class RealStubBinaryTests(unittest.TestCase):
    """One pass through the real subprocess path, not the injected runner."""

    def test_end_to_end_against_an_executable_stub(self):
        with tempfile.TemporaryDirectory() as tmp:
            stub = Path(tmp) / "fluidaudiocli"
            stub.write_text(
                "#!/bin/sh\n"
                'while [ "$#" -gt 0 ]; do\n'
                '  if [ "$1" = "--output" ]; then out="$2"; fi\n'
                "  shift\n"
                "done\n"
                f'cat "{_ctx.fixture(FIXTURE)}" > "$out"\n',
                encoding="utf-8",
            )
            stub.chmod(stub.stat().st_mode | stat.S_IXUSR)
            with meeting(("system",)) as root:
                report = diarize.run(
                    root,
                    track="system",
                    num_speakers=3,
                    environ={"ACTA_FLUIDAUDIO_BIN": str(stub)},
                )
                self.assertTrue(diarize.raw_json_path(root).is_file())
        self.assertEqual(report["status"], diarize.STATUS_OK)
        self.assertEqual(report["segment_count"], 6)
        self.assertEqual(report["binary"]["source"], "env:ACTA_FLUIDAUDIO_BIN")


class NonNumericSegmentTests(unittest.TestCase):
    """Same contract as transcribe: a present-but-not-numeric field is treated
    exactly like a missing one, never as a traceback out of the stage."""

    def test_a_non_numeric_bound_drops_the_segment(self):
        raw = {
            "segments": [
                {"startTimeSeconds": 0.0, "endTimeSeconds": 2.0, "speakerId": "a"},
                {"startTimeSeconds": "?", "endTimeSeconds": 4.0, "speakerId": "b"},
            ]
        }
        segments = diarize.parse_segments(raw)
        self.assertEqual(len(segments), 1)
        self.assertEqual(segments[0]["speaker"], "SPK_01")

    def test_a_non_numeric_quality_is_recorded_as_unscored(self):
        raw = {
            "segments": [
                {
                    "startTimeSeconds": 0.0,
                    "endTimeSeconds": 2.0,
                    "speakerId": "a",
                    "qualityScore": "good",
                }
            ]
        }
        self.assertIsNone(diarize.parse_segments(raw)[0]["quality"])

    def test_non_numeric_metrics_do_not_raise(self):
        scored = diarize.parse_metrics({"metrics": {"der": "n/a", "jer": 0.1}})
        self.assertIsNone(scored["der"])
        self.assertEqual(scored["jer"], 0.1)


class TimeoutTests(unittest.TestCase):
    def test_a_hung_cli_becomes_a_reported_failure_not_an_endless_wait(self):
        # diarization.json and the stage report are written only after run()
        # returns, and the DER sweep may invoke this several times — one unbounded
        # hang stranded the whole sweep with nothing on disk to diagnose.
        code, stderr = diarize.default_runner(["/bin/sh", "-c", "sleep 30"], timeout=0.2)
        self.assertEqual(code, diarize.TIMEOUT_EXIT_CODE)
        self.assertIn("did not exit within", stderr)
        self.assertIn(diarize.TIMEOUT_ENV_VAR, stderr)

    def test_a_spawn_failure_inside_the_runner_is_a_failed_run(self):
        """`is_executable` checks the exec bit, not the file's format, so a
        wrong-architecture build or a text file at ACTA_FLUIDAUDIO_BIN reaches the
        runner and raised OSError straight out of run() — losing diarization.json
        and, mid-sweep, the whole DER sweep with it."""
        code, message = diarize.default_runner(["/definitely/not/here/fluidaudiocli"])
        self.assertEqual(code, diarize.SPAWN_FAILED_EXIT_CODE)
        self.assertIn("could not run fluidaudiocli", message)

    def test_an_unexecutable_format_is_reported_rather_than_raised(self):
        with tempfile.TemporaryDirectory() as tmp:
            fake = Path(tmp) / "fluidaudiocli"
            fake.write_text("not a mach-o binary\n", encoding="utf-8")
            fake.chmod(0o755)
            self.assertTrue(diarize.is_executable(fake))
            code, message = diarize.default_runner([str(fake)])
        self.assertEqual(code, diarize.SPAWN_FAILED_EXIT_CODE)
        self.assertIn("could not run fluidaudiocli", message)

    def test_the_ceiling_is_overridable_and_falls_back_on_junk(self):
        self.assertEqual(diarize.resolve_timeout({}), diarize.DEFAULT_TIMEOUT_SECONDS)
        self.assertEqual(
            diarize.resolve_timeout({diarize.TIMEOUT_ENV_VAR: "900"}), 900.0
        )
        for junk in ("", "abc", "0", "-1"):
            with self.subTest(junk=junk):
                self.assertEqual(
                    diarize.resolve_timeout({diarize.TIMEOUT_ENV_VAR: junk}),
                    diarize.DEFAULT_TIMEOUT_SECONDS,
                )


if __name__ == "__main__":
    unittest.main()
