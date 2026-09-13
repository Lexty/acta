import _ctx

import contextlib
import io
import json
import math
import os
import shutil
import struct
import tempfile
import unittest
import wave
from pathlib import Path

prep_audio = _ctx.load("prep_audio")

FFMPEG = "/fake/bin/ffmpeg"


def write_wav(path, seconds=0.25, rate=48000, channels=2, freq=440.0):
    """A real (tiny) wav on disk — the fixtures for this stage are generated."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    frames = int(seconds * rate)
    with wave.open(str(path), "wb") as handle:
        handle.setnchannels(channels)
        handle.setsampwidth(2)
        handle.setframerate(rate)
        samples = bytearray()
        for i in range(frames):
            value = int(12000 * math.sin(2 * math.pi * freq * i / rate))
            samples += struct.pack("<h", value) * channels
        handle.writeframes(bytes(samples))
    return path


class FakeFFmpeg:
    """Records argv and writes a plausible 16 kHz mono wav at the output path."""

    def __init__(self, code=0, stderr="", write_output=True):
        self.calls = []
        self.code = code
        self.stderr = stderr
        self.write_output = write_output

    def __call__(self, argv):
        self.calls.append(list(argv))
        if self.code == 0 and self.write_output:
            write_wav(argv[-1], seconds=0.1, rate=16000, channels=1)
        return self.code, self.stderr


@contextlib.contextmanager
def meeting(tracks=("mic", "system")):
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp) / "2026-07-29 Weekly"
        root.mkdir(parents=True)
        for track in tracks:
            write_wav(root / f"{track}.wav")
        yield root


def touch_newer(path, reference, delta=10):
    stamp = Path(reference).stat().st_mtime + delta
    os.utime(path, (stamp, stamp))


class ArgvTests(unittest.TestCase):
    def test_denoise_is_the_default_chain(self):
        self.assertEqual(prep_audio.DEFAULT_CHAIN, "denoise")
        self.assertEqual(
            prep_audio.CHAINS["denoise"], "highpass=f=80,afftdn=nr=12"
        )

    def test_denoise_argv_is_exact(self):
        argv = prep_audio.build_argv(FFMPEG, "/m/mic.wav", "/m/.acta-notes/mic.16k.wav", "denoise")
        self.assertEqual(
            argv,
            [
                FFMPEG, "-hide_banner", "-nostdin", "-y",
                "-i", "/m/mic.wav",
                "-af", "highpass=f=80,afftdn=nr=12",
                "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le",
                "/m/.acta-notes/mic.16k.wav",
            ],
        )

    def test_plain_chain_emits_no_filter_flag(self):
        argv = prep_audio.build_argv(FFMPEG, "/m/mic.wav", "/m/out.wav", "plain")
        self.assertNotIn("-af", argv)
        self.assertEqual(
            argv,
            [
                FFMPEG, "-hide_banner", "-nostdin", "-y",
                "-i", "/m/mic.wav",
                "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le",
                "/m/out.wav",
            ],
        )

    def test_loudnorm_chain_appends_loudnorm(self):
        argv = prep_audio.build_argv(FFMPEG, "/m/mic.wav", "/m/out.wav", "loudnorm")
        self.assertEqual(
            argv[argv.index("-af") + 1], "highpass=f=80,afftdn=nr=12,loudnorm"
        )

    def test_unknown_chain_rejected(self):
        with self.assertRaises(ValueError):
            prep_audio.build_argv(FFMPEG, "a.wav", "b.wav", "sparkle")


class PathTests(unittest.TestCase):
    def test_output_path_derivation(self):
        self.assertEqual(
            prep_audio.output_path("/Acta/m1", "system"),
            Path("/Acta/m1/.acta-notes/system.16k.wav"),
        )

    def test_input_path_derivation(self):
        self.assertEqual(prep_audio.input_path("/Acta/m1", "mic"), Path("/Acta/m1/mic.wav"))

    def test_ffmpeg_env_override_wins_over_path(self):
        path, source = prep_audio.resolve_ffmpeg_bin({"ACTA_FFMPEG_BIN": FFMPEG})
        self.assertEqual((path, source), (Path(FFMPEG), "env:ACTA_FFMPEG_BIN"))

    def test_ffmpeg_falls_back_to_the_injected_path(self):
        # Hermetic on purpose: the PATH searched must be the one handed in, not
        # the process's own, or an "injected environment" is not the whole
        # environment and the result depends on the developer's machine.
        with tempfile.TemporaryDirectory() as tmp:
            stub = Path(tmp) / "ffmpeg"
            stub.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            stub.chmod(0o755)

            path, source = prep_audio.resolve_ffmpeg_bin({"PATH": tmp})
            self.assertEqual((path, source), (stub, "path"))

    def test_ffmpeg_is_none_when_the_injected_path_holds_no_ffmpeg(self):
        with tempfile.TemporaryDirectory() as tmp:
            path, source = prep_audio.resolve_ffmpeg_bin({"PATH": tmp})
            self.assertEqual((path, source), (None, "path"))


class ConversionTests(unittest.TestCase):
    def test_both_tracks_converted_and_timed(self):
        runner = FakeFFmpeg()
        with meeting() as root:
            report = prep_audio.run(
                root, environ={"ACTA_FFMPEG_BIN": FFMPEG}, runner=runner,
                clock=iter([0.0, 2.0, 2.0, 5.5]).__next__,
            )
            self.assertEqual(report["status"], "ok")
            self.assertEqual([t["track"] for t in report["tracks"]], ["mic", "system"])
            for entry in report["tracks"]:
                self.assertEqual(entry["status"], "ok")
                self.assertEqual(entry["sample_rate"], 16000)
                self.assertEqual(entry["channels"], 1)
                self.assertGreater(entry["size_bytes"], 0)
                self.assertAlmostEqual(entry["duration_seconds"], 0.1, places=2)
                self.assertTrue(prep_audio.output_path(root, entry["track"]).is_file())
            self.assertEqual(
                [t["elapsed_seconds"] for t in report["tracks"]], [2.0, 3.5]
            )
            self.assertEqual(report["total_seconds"], 5.5)
        self.assertEqual(len(runner.calls), 2)

    def test_ffmpeg_writes_via_a_temp_path_then_renames(self):
        runner = FakeFFmpeg()
        with meeting(tracks=("mic",)) as root:
            prep_audio.run(root, tracks=("mic",), environ={"ACTA_FFMPEG_BIN": FFMPEG}, runner=runner)
            self.assertTrue(runner.calls[0][-1].endswith("mic.16k.part.wav"))
            self.assertFalse((root / ".acta-notes" / "mic.16k.part.wav").exists())
            self.assertTrue((root / ".acta-notes" / "mic.16k.wav").is_file())

    def test_missing_track_is_reported_not_run(self):
        runner = FakeFFmpeg()
        with meeting(tracks=("system",)) as root:
            report = prep_audio.run(root, environ={"ACTA_FFMPEG_BIN": FFMPEG}, runner=runner)
        self.assertEqual(report["status"], "ok")
        by_track = {t["track"]: t for t in report["tracks"]}
        self.assertEqual(by_track["mic"]["status"], "missing")
        self.assertEqual(by_track["system"]["status"], "ok")
        self.assertEqual(len(runner.calls), 1)

    def test_no_tracks_at_all_is_a_failure(self):
        runner = FakeFFmpeg()
        with meeting(tracks=()) as root:
            report = prep_audio.run(root, environ={"ACTA_FFMPEG_BIN": FFMPEG}, runner=runner)
        self.assertEqual(report["status"], "failed")
        self.assertEqual(runner.calls, [])
        self.assertEqual(prep_audio.exit_code(report), 1)

    def test_missing_ffmpeg_fails_without_running_anything(self):
        runner = FakeFFmpeg()
        with meeting() as root:
            report = prep_audio.run(root, environ={"PATH": "/nonexistent"}, runner=runner)
        self.assertEqual(report["status"], "failed")
        self.assertIn("ffmpeg", report["detail"])
        self.assertEqual(runner.calls, [])

    def test_ffmpeg_failure_is_loud_and_leaves_no_partial_output(self):
        runner = FakeFFmpeg(code=1, stderr="Invalid data found\n")
        with meeting(tracks=("mic",)) as root:
            report = prep_audio.run(
                root, tracks=("mic",), environ={"ACTA_FFMPEG_BIN": FFMPEG}, runner=runner
            )
            entry = report["tracks"][0]
            self.assertEqual(entry["status"], "failed")
            self.assertEqual(entry["exit_code"], 1)
            self.assertIn("Invalid data found", entry["stderr_tail"][-1])
            self.assertFalse(prep_audio.output_path(root, "mic").exists())
            self.assertFalse((root / ".acta-notes" / "mic.16k.part.wav").exists())
        self.assertEqual(report["status"], "failed")
        self.assertEqual(prep_audio.exit_code(report), 1)

    def test_silent_success_without_output_is_still_a_failure(self):
        runner = FakeFFmpeg(write_output=False)
        with meeting(tracks=("mic",)) as root:
            report = prep_audio.run(
                root, tracks=("mic",), environ={"ACTA_FFMPEG_BIN": FFMPEG}, runner=runner
            )
        self.assertEqual(report["tracks"][0]["status"], "failed")

    def test_failed_run_does_not_clobber_an_existing_output(self):
        runner = FakeFFmpeg(code=1)
        with meeting(tracks=("mic",)) as root:
            dst = prep_audio.output_path(root, "mic")
            write_wav(dst, seconds=0.2, rate=16000, channels=1)
            before = dst.read_bytes()
            prep_audio.run(
                root, tracks=("mic",), force=True,
                environ={"ACTA_FFMPEG_BIN": FFMPEG}, runner=runner,
            )
            self.assertEqual(dst.read_bytes(), before)


class CacheTests(unittest.TestCase):
    def test_fresh_output_is_skipped(self):
        runner = FakeFFmpeg()
        with meeting(tracks=("mic",)) as root:
            src = root / "mic.wav"
            dst = prep_audio.output_path(root, "mic")
            write_wav(dst, seconds=0.1, rate=16000, channels=1)
            touch_newer(dst, src)

            report = prep_audio.run(
                root, tracks=("mic",), environ={"ACTA_FFMPEG_BIN": FFMPEG}, runner=runner
            )
        entry = report["tracks"][0]
        self.assertEqual(entry["status"], "skipped")
        self.assertEqual(entry["sample_rate"], 16000)
        self.assertIsNone(entry["argv"])
        self.assertEqual(runner.calls, [])
        self.assertEqual(report["status"], "ok")

    def test_a_different_chain_is_not_a_cache_hit(self):
        """An mtime cannot tell loudnorm from denoise.

        Reusing the denoise-era wav under `--chain loudnorm` returned `skipped`
        while the stage JSON — and so quality.md's provenance block — went on to
        record loudnorm as the filter that ran.
        """
        runner = FakeFFmpeg()
        with meeting(tracks=("mic",)) as root:
            src = root / "mic.wav"
            dst = prep_audio.output_path(root, "mic")
            write_wav(dst, seconds=0.1, rate=16000, channels=1)
            touch_newer(dst, src)
            env = {"ACTA_FFMPEG_BIN": FFMPEG}

            first = prep_audio.run(
                root, tracks=("mic",), chain="denoise", environ=env, runner=runner
            )
            prep_audio.write_stage_json(root, first)

            second = prep_audio.run(
                root, tracks=("mic",), chain="loudnorm", environ=env, runner=runner
            )
            prep_audio.write_stage_json(root, second)

            third = prep_audio.run(
                root, tracks=("mic",), chain="loudnorm", environ=env, runner=runner
            )

        self.assertEqual(first["tracks"][0]["status"], "skipped")
        self.assertEqual(second["tracks"][0]["status"], "ok")  # reconverted
        self.assertEqual(second["tracks"][0]["chain"], "loudnorm")
        self.assertEqual(len(runner.calls), 1)
        # …and the same chain again *is* a cache hit.
        self.assertEqual(third["tracks"][0]["status"], "skipped")

    def test_force_reconverts_a_fresh_output(self):
        runner = FakeFFmpeg()
        with meeting(tracks=("mic",)) as root:
            dst = prep_audio.output_path(root, "mic")
            write_wav(dst, seconds=0.1, rate=16000, channels=1)
            touch_newer(dst, root / "mic.wav")

            report = prep_audio.run(
                root, tracks=("mic",), force=True,
                environ={"ACTA_FFMPEG_BIN": FFMPEG}, runner=runner,
            )
        self.assertEqual(report["tracks"][0]["status"], "ok")
        self.assertTrue(report["forced"])
        self.assertEqual(len(runner.calls), 1)

    def test_stale_output_is_reconverted(self):
        runner = FakeFFmpeg()
        with meeting(tracks=("mic",)) as root:
            src = root / "mic.wav"
            dst = prep_audio.output_path(root, "mic")
            write_wav(dst, seconds=0.1, rate=16000, channels=1)
            touch_newer(src, dst)  # source re-recorded after the conversion

            report = prep_audio.run(
                root, tracks=("mic",), environ={"ACTA_FFMPEG_BIN": FFMPEG}, runner=runner
            )
        self.assertEqual(report["tracks"][0]["status"], "ok")
        self.assertEqual(len(runner.calls), 1)

    def test_an_unreadable_cached_output_is_reconverted_not_raised(self):
        # A truncated .16k.wav passes the size/mtime freshness check but not
        # wave.open. The stage must reconvert it: an escaping wave.Error would
        # take down pipeline.run() before pipeline.json is written, losing the
        # run record that documents what did not happen.
        runner = FakeFFmpeg()
        with meeting(tracks=("mic",)) as root:
            src = root / "mic.wav"
            dst = prep_audio.output_path(root, "mic")
            dst.parent.mkdir(parents=True, exist_ok=True)
            dst.write_bytes(b"RIFF\x00\x00\x00\x00WAVEnonsense")
            touch_newer(dst, src)

            report = prep_audio.run(
                root, tracks=("mic",), environ={"ACTA_FFMPEG_BIN": FFMPEG}, runner=runner
            )

        entry = report["tracks"][0]
        self.assertEqual(entry["status"], "ok")
        self.assertEqual(entry["sample_rate"], 16000)
        self.assertEqual(len(runner.calls), 1)
        self.assertEqual(report["status"], "ok")

    def test_empty_output_is_never_treated_as_fresh(self):
        with meeting(tracks=("mic",)) as root:
            src = root / "mic.wav"
            dst = prep_audio.output_path(root, "mic")
            dst.parent.mkdir(parents=True, exist_ok=True)
            dst.write_bytes(b"")
            touch_newer(dst, src)
            self.assertFalse(prep_audio.is_fresh(src, dst))


class CliTests(unittest.TestCase):
    def _main(self, argv, runner):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = prep_audio.main(
                argv, environ={"ACTA_FFMPEG_BIN": FFMPEG}, runner=runner
            )
        return code, out.getvalue()

    def test_stage_json_is_written_with_the_run_shape(self):
        runner = FakeFFmpeg()
        with meeting() as root:
            code, _ = self._main([str(root)], runner)
            stage = json.loads(
                (root / ".acta-notes" / "prep_audio.json").read_text(encoding="utf-8")
            )
        self.assertEqual(code, 0)
        self.assertEqual(stage["stage"], "prep_audio")
        self.assertEqual(stage["chain"], "denoise")
        self.assertEqual(stage["filter"], "highpass=f=80,afftdn=nr=12")
        self.assertEqual(stage["sample_rate"], 16000)
        self.assertEqual(stage["channels"], 1)
        self.assertEqual(stage["ffmpeg"]["source"], "env:ACTA_FFMPEG_BIN")
        self.assertIn("total_seconds", stage)
        self.assertEqual(len(stage["tracks"]), 2)

    def test_chain_and_track_flags_reach_the_argv(self):
        runner = FakeFFmpeg()
        with meeting() as root:
            code, _ = self._main([str(root), "--track", "system", "--chain", "plain"], runner)
        self.assertEqual(code, 0)
        self.assertEqual(len(runner.calls), 1)
        self.assertNotIn("-af", runner.calls[0])
        self.assertTrue(runner.calls[0][-1].endswith("system.16k.part.wav"))

    def test_json_flag_prints_the_report(self):
        runner = FakeFFmpeg()
        with meeting(tracks=("mic",)) as root:
            code, out = self._main([str(root), "--track", "mic", "--json"], runner)
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(out)["stage"], "prep_audio")

    def test_failure_exits_one(self):
        runner = FakeFFmpeg(code=1)
        with meeting(tracks=("mic",)) as root:
            code, out = self._main([str(root), "--track", "mic"], runner)
        self.assertEqual(code, 1)
        self.assertIn("FAILED", out)

    def test_missing_meeting_folder_is_a_usage_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(SystemExit) as ctx:
                with contextlib.redirect_stderr(io.StringIO()):
                    prep_audio.main([str(Path(tmp) / "nope")], environ={}, runner=FakeFFmpeg())
        self.assertEqual(ctx.exception.code, prep_audio.EXIT_USAGE)


class RealFFmpegTests(unittest.TestCase):
    """One end-to-end run against a real ffmpeg — skipped when there is none."""

    def setUp(self):
        binary, _ = prep_audio.resolve_ffmpeg_bin(os.environ)
        if binary is None or not os.access(str(binary), os.X_OK):
            self.skipTest("no ffmpeg (set ACTA_FFMPEG_BIN or put it on PATH)")
        self.binary = binary

    def test_converts_a_generated_wav_to_16k_mono(self):
        with meeting(tracks=("mic",)) as root:
            report = prep_audio.run(
                root, tracks=("mic",), environ={"ACTA_FFMPEG_BIN": str(self.binary)}
            )
            entry = report["tracks"][0]
            self.assertEqual(entry["status"], "ok", entry.get("stderr_tail"))
            self.assertEqual(entry["sample_rate"], 16000)
            self.assertEqual(entry["channels"], 1)
            self.assertEqual(entry["sample_width_bytes"], 2)
            self.assertGreater(entry["duration_seconds"], 0.1)
            info = prep_audio.wav_info(prep_audio.output_path(root, "mic"))
            self.assertEqual(info["sample_rate"], 16000)


class CarriedProvenanceTests(unittest.TestCase):
    """run() overwrites prep_audio.json wholesale, so a single-track invocation
    used to erase the other track's recorded chain. previous_chain then returned
    None, the next run read that as "same chain", and the report claimed a chain
    the bytes on disk were not produced with."""

    def _write_report(self, root, chain, tracks):
        prep_audio.write_stage_json(
            root,
            {
                "stage": "prep_audio",
                "status": "ok",
                "chain": chain,
                "tracks": [
                    {"track": t, "status": "ok", "chain": chain} for t in tracks
                ],
            },
        )

    def test_an_untouched_tracks_chain_survives_a_single_track_run(self):
        with meeting() as root:
            self._write_report(root, "denoise", ("mic", "system"))

            report = {
                "stage": "prep_audio",
                "status": "ok",
                "chain": "loudnorm",
                "tracks": [{"track": "system", "status": "ok", "chain": "loudnorm"}],
            }
            prep_audio.carry_forward_tracks(root, report)
            prep_audio.write_stage_json(root, report)

            self.assertEqual(prep_audio.previous_chain(root, "mic"), "denoise")
            self.assertEqual(prep_audio.previous_chain(root, "system"), "loudnorm")

    def test_a_carried_entry_is_labelled_as_not_this_runs_work(self):
        with meeting() as root:
            self._write_report(root, "denoise", ("mic", "system"))
            report = {
                "stage": "prep_audio",
                "status": "ok",
                "chain": "denoise",
                "tracks": [{"track": "system", "status": "ok", "chain": "denoise"}],
            }
            prep_audio.carry_forward_tracks(root, report)

        carried = next(e for e in report["tracks"] if e["track"] == "mic")
        self.assertEqual(carried["status"], prep_audio.STATUS_CARRIED)
        self.assertEqual(carried["elapsed_seconds"], 0.0)

    def test_a_track_this_run_touched_is_never_overwritten_by_the_old_record(self):
        with meeting() as root:
            self._write_report(root, "denoise", ("mic",))
            report = {
                "stage": "prep_audio",
                "status": "ok",
                "chain": "loudnorm",
                "tracks": [{"track": "mic", "status": "ok", "chain": "loudnorm"}],
            }
            prep_audio.carry_forward_tracks(root, report)

        self.assertEqual(len(report["tracks"]), 1)
        self.assertEqual(report["tracks"][0]["chain"], "loudnorm")

    def test_no_previous_report_is_not_an_error(self):
        with meeting() as root:
            report = {"stage": "prep_audio", "status": "ok", "tracks": []}
            self.assertIs(prep_audio.carry_forward_tracks(root, report), report)
            self.assertEqual(report["tracks"], [])

    def test_a_missing_ffmpeg_run_does_not_erase_the_recorded_chains(self):
        """The failure path has to carry provenance forward too.

        main() writes the report unconditionally, so returning early with
        ``tracks: []`` erased every track's recorded chain without having
        attempted a single one. previous_chain then found no record, read that as
        "same chain", and the next run skipped the work while reporting the chain
        it was *asked* for — and verify.py copies that straight into quality.md.
        """
        with meeting() as root:
            self._write_report(root, "denoise", ("mic", "system"))

            report = prep_audio.run(root, chain="loudnorm", environ={"PATH": ""})
            self.assertEqual(report["status"], prep_audio.STATUS_FAILED)
            prep_audio.write_stage_json(root, report)

            # The chain that actually produced the bytes is still on record.
            self.assertEqual(prep_audio.previous_chain(root, "mic"), "denoise")
            self.assertEqual(prep_audio.previous_chain(root, "system"), "denoise")
            for entry in report["tracks"]:
                self.assertEqual(entry["status"], prep_audio.STATUS_CARRIED)

    def test_a_missing_ffmpeg_run_with_no_prior_report_stays_empty(self):
        with meeting() as root:
            report = prep_audio.run(root, environ={"PATH": ""})
            self.assertEqual(report["status"], prep_audio.STATUS_FAILED)
            self.assertEqual(report["tracks"], [])


class UnreadableOutputTests(unittest.TestCase):
    """ffmpeg exits 0 onto something that is not a wav — a failed conversion."""

    class StubWritesGarbage:
        def __init__(self):
            self.calls = []

        def __call__(self, argv):
            self.calls.append(list(argv))
            Path(argv[-1]).write_bytes(b"not a RIFF header at all")
            return 0, ""

    def test_it_is_failed_not_ok(self):
        # This was reported `ok` with the explanation demoted to `detail`, so the
        # run exited 0 on a broken artifact and the entry carried no
        # sample_rate/frames/duration_seconds that every reader after S1 expects
        # once status is ok.
        with meeting(tracks=("mic",)) as root:
            report = prep_audio.run(root, tracks=("mic",), runner=self.StubWritesGarbage(),
                                    environ={"ACTA_FFMPEG_BIN": FFMPEG})
            entry = report["tracks"][0]

        self.assertEqual(entry["status"], prep_audio.STATUS_FAILED)
        self.assertIn("not a readable wav", entry["detail"])
        self.assertNotIn("sample_rate", entry)
        self.assertEqual(report["status"], prep_audio.STATUS_FAILED)
        self.assertEqual(prep_audio.exit_code(report), prep_audio.EXIT_FFMPEG_FAILED)

    def test_the_stage_json_records_the_failure_so_the_driver_re_runs_it(self):
        # pipeline.py only re-runs a stage whose recorded status is
        # failed|missing|refused. Reporting `ok` here cached the broken output as
        # fresh forever, and the failure resurfaced two stages later as
        # "at least one track could not be gated".
        with meeting(tracks=("mic",)) as root:
            report = prep_audio.run(root, tracks=("mic",), runner=self.StubWritesGarbage(),
                                    environ={"ACTA_FFMPEG_BIN": FFMPEG})
            path = prep_audio.write_stage_json(root, report)
            written = json.loads(path.read_text(encoding="utf-8"))
        self.assertEqual(written["tracks"][0]["status"], prep_audio.STATUS_FAILED)


class TimeoutTests(unittest.TestCase):
    def test_a_hung_ffmpeg_becomes_a_reported_failure_not_an_endless_wait(self):
        # Without a ceiling the stage JSON — written only after run() returns —
        # never landed, so a wedged ffmpeg left no forensic record at all.
        argv = ["/bin/sh", "-c", "sleep 30"]
        code, stderr = prep_audio.default_runner(argv, timeout=0.2)
        self.assertEqual(code, prep_audio.TIMEOUT_EXIT_CODE)
        self.assertIn("did not exit within", stderr)
        self.assertIn(prep_audio.TIMEOUT_ENV_VAR, stderr)

    def test_the_ceiling_is_overridable_and_falls_back_on_junk(self):
        self.assertEqual(prep_audio.resolve_timeout({}), prep_audio.DEFAULT_TIMEOUT_SECONDS)
        self.assertEqual(
            prep_audio.resolve_timeout({prep_audio.TIMEOUT_ENV_VAR: "42"}), 42.0
        )
        for junk in ("", "  ", "abc", "0", "-5"):
            with self.subTest(junk=junk):
                self.assertEqual(
                    prep_audio.resolve_timeout({prep_audio.TIMEOUT_ENV_VAR: junk}),
                    prep_audio.DEFAULT_TIMEOUT_SECONDS,
                )


class TrackNameTests(unittest.TestCase):
    def test_a_track_name_that_would_escape_the_meeting_folder_is_refused(self):
        for name in ("../../../etc/passwd", "a/b", "..", "", "mic.wav"):
            with self.subTest(name=name):
                self.assertFalse(prep_audio.valid_track_name(name))
        for name in ("mic", "system", "track_2", "aux-1"):
            with self.subTest(name=name):
                self.assertTrue(prep_audio.valid_track_name(name))

    def test_the_cli_rejects_it_rather_than_writing_outside_the_folder(self):
        with meeting() as root:
            buffer = io.StringIO()
            with contextlib.redirect_stderr(buffer), self.assertRaises(SystemExit) as caught:
                prep_audio.main([str(root), "--track", "../../escaped"])
        self.assertEqual(caught.exception.code, prep_audio.EXIT_USAGE)
        self.assertIn("not a usable track name", buffer.getvalue())


class InjectedEnvironTests(unittest.TestCase):
    def test_an_environ_without_a_path_key_does_not_fall_back_to_the_machine(self):
        # shutil.which reads the *process* PATH when handed None, so
        # environ.get("PATH") silently resolved the machine's ffmpeg — the
        # opposite of "an injected environment really is the whole environment".
        found, source = prep_audio.resolve_ffmpeg_bin({})
        self.assertIsNone(found)
        self.assertEqual(source, "path")


class UnusableFFmpegBinaryTests(unittest.TestCase):
    """A bad ``ACTA_FFMPEG_BIN`` is a failed stage, not an uncaught traceback.

    ``resolve_ffmpeg_bin`` takes the override on trust, so the ``ffmpeg is None``
    guard never fired for it: a typo'd or stale env var reached
    ``subprocess.run`` and raised ``FileNotFoundError`` straight out of ``run()``,
    leaving *no* prep_audio.json — the one outcome the timeout ceiling in
    ``default_runner`` exists to prevent, arriving through another door.
    ``transcribe.py`` already gates its own binary this way.
    """

    def test_a_nonexistent_override_fails_the_stage_with_a_report(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "meeting"
            write_wav(root / "mic.wav")
            missing = str(Path(tmp) / "nope" / "ffmpeg")
            report = prep_audio.run(root, environ={"ACTA_FFMPEG_BIN": missing})
        self.assertEqual(report["status"], "failed")
        self.assertIn("not executable", report["detail"])
        self.assertIn(missing, report["detail"])

    def test_a_non_executable_override_fails_the_stage(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "meeting"
            write_wav(root / "mic.wav")
            fake = Path(tmp) / "ffmpeg"
            fake.write_text("#!/bin/sh\n")
            fake.chmod(0o644)
            report = prep_audio.run(root, environ={"ACTA_FFMPEG_BIN": str(fake)})
        self.assertEqual(report["status"], "failed")

    def test_the_cli_writes_the_stage_json_instead_of_crashing(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "meeting"
            write_wav(root / "mic.wav")
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(io.StringIO()):
                code = prep_audio.main(
                    [str(root)], environ={"ACTA_FFMPEG_BIN": "/nope/ffmpeg"}
                )
            self.assertNotEqual(code, 0)
            path = prep_audio.work_dir(root) / "prep_audio.json"
            self.assertTrue(path.is_file(), "no forensic record was left on disk")
            self.assertEqual(json.loads(path.read_text())["status"], "failed")

    def test_an_injected_runner_is_not_second_guessed(self):
        """Only the binary *we* would spawn is vetted.

        A caller that supplies its own runner never touches the resolved path, so
        a symbolic one must keep working — the tests in this module depend on it.
        """
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "meeting"
            write_wav(root / "mic.wav")
            report = prep_audio.run(
                root, environ={"ACTA_FFMPEG_BIN": FFMPEG}, runner=FakeFFmpeg()
            )
        self.assertEqual(report["status"], "ok")

    def test_a_spawn_failure_inside_the_runner_is_a_failed_track(self):
        code, message = prep_audio.default_runner(["/definitely/not/here/ffmpeg", "-i"])
        self.assertEqual(code, prep_audio.SPAWN_FAILED_EXIT_CODE)
        self.assertIn("could not run ffmpeg", message)


if __name__ == "__main__":
    unittest.main()
