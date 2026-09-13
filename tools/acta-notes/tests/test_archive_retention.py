import _ctx

import contextlib
import io
import json
import os
import stat
import tempfile
import unittest
import wave
from array import array
from pathlib import Path

retention = _ctx.load("archive_retention")

RATE = 48000

#: A stand-in ffmpeg. Encoding writes a text file holding the source duration;
#: decoding reads that number back and emits exactly that many seconds of PCM.
#: The fake artifact therefore *carries its own duration*, which is what lets the
#: delete gate be exercised for real — including the drift and truncation paths —
#: without a codec anywhere in the suite.
STUB_FFMPEG = '''#!/usr/bin/env python3
import os, sys, wave, contextlib

args = sys.argv[1:]
fail = os.environ.get("STUB_FAIL", "")
drift = float(os.environ.get("STUB_DRIFT", "0") or 0)


def arg_after(flag):
    return args[args.index(flag) + 1] if flag in args else None


inp = arg_after("-i")
decoding = "s16le" in args and args[-1] == "-"

if decoding:
    if fail == "decode":
        sys.stderr.write("stub: refusing to decode\\n")
        sys.exit(1)
    try:
        seconds = float(open(inp).read().strip().split("=")[1])
    except Exception:
        sys.stderr.write("stub: not a stub artifact\\n")
        sys.exit(1)
    rate = int(arg_after("-ar") or 8000)
    sys.stdout.buffer.write(b"\\x00" * int(round(seconds * rate)) * 2)
    sys.exit(0)

if fail == "encode":
    sys.stderr.write("stub: encode exploded\\n")
    sys.exit(1)

out = args[-1]
if out.endswith(".wav"):
    # restore path: emit a real (silent) wav so callers can read it back
    with contextlib.closing(wave.open(out, "wb")) as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(16000)
        w.writeframes(b"\\x00" * 3200)
    sys.exit(0)

with contextlib.closing(wave.open(inp, "rb")) as w:
    seconds = w.getnframes() / float(w.getframerate())
open(out, "w").write("DUR=%.6f" % (seconds + drift))
sys.exit(0)
'''


def write_wav(path, seconds, rate=RATE, channels=2):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    frames = int(round(seconds * rate))
    with contextlib.closing(wave.open(str(path), "wb")) as handle:
        handle.setnchannels(channels)
        handle.setsampwidth(2)
        handle.setframerate(rate)
        handle.writeframes(array("h", [0] * frames * channels).tobytes())
    return path


def install_stub(root) -> Path:
    path = Path(root) / "ffmpeg-stub"
    path.write_text(STUB_FFMPEG, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)
    return path


TRANSCRIPT = "# t\n\n**[00:00:01] Я:** привет\n\n**[00:00:05] SPK_01:** ага\n"


def make_meeting(
    archive,
    name,
    *,
    summary=True,
    transcript=True,
    verify="green",
    wav_seconds=(("system.wav", 2.0), ("mic.wav", 2.0)),
    work_wavs=(),
):
    d = Path(archive) / name
    d.mkdir(parents=True, exist_ok=True)
    (d / "info.md").write_text(
        '---\ntitle: "t"\nduration: "00:00:02"\nsource: "Slack"\nstatus: done\n---\n',
        encoding="utf-8",
    )
    if summary:
        (d / "summary.md").write_text("# Тема — 2026-07-01\n", encoding="utf-8")
    if transcript:
        (d / "transcript.raw.md").write_text(TRANSCRIPT, encoding="utf-8")
    if verify is not None:
        work = d / retention.WORK_DIRNAME
        work.mkdir(parents=True, exist_ok=True)
        checks = [{"name": "transcript", "status": verify}]
        (work / "verify.json").write_text(
            json.dumps({"checks": checks}), encoding="utf-8"
        )
    for fname, secs in wav_seconds:
        write_wav(d / fname, secs)
    for fname, secs in work_wavs:
        write_wav(d / retention.WORK_DIRNAME / fname, secs, rate=16000, channels=1)
    return d


class TestArchiveInspection(unittest.TestCase):
    def test_meeting_date_parses_convention(self):
        self.assertEqual(
            retention.meeting_date("2026-07-22_1519__slack-x"),
            __import__("datetime").date(2026, 7, 22),
        )

    def test_meeting_date_rejects_non_meetings(self):
        for name in ("CLAUDE.md", "INDEX.md", "notes", "2026-13-01_0000__x"):
            self.assertIsNone(retention.meeting_date(name), name)

    def test_wav_duration_is_exact(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = write_wav(Path(tmp) / "a.wav", 1.5)
            self.assertAlmostEqual(retention.wav_duration_seconds(p), 1.5, places=4)

    def test_wav_duration_none_for_garbage(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / "bad.wav"
            p.write_text("not audio", encoding="utf-8")
            self.assertIsNone(retention.wav_duration_seconds(p))

    def test_has_transcript_requires_speaker_markers(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            (d / "transcript.md").write_text("# just prose\n", encoding="utf-8")
            self.assertFalse(retention.has_transcript(d))
            (d / "transcript.raw.md").write_text(TRANSCRIPT, encoding="utf-8")
            self.assertTrue(retention.has_transcript(d))

    def test_source_wavs_include_full_wav_and_exclude_work(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = make_meeting(
                tmp,
                "2026-07-01_1000__a",
                wav_seconds=(("system.wav", 1.0), ("system.full.wav", 1.0)),
                work_wavs=(("system.16k.wav", 1.0),),
            )
            names = [p.name for p in retention.source_wavs(d)]
            self.assertEqual(names, ["system.full.wav", "system.wav"])
            self.assertEqual(
                [p.name for p in retention.work_wavs(d)], ["system.16k.wav"]
            )


class TestEligibility(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.archive = Path(self.tmp.name)
        self.cutoff = __import__("datetime").date(2026, 7, 15)

    def tearDown(self):
        self.tmp.cleanup()

    def test_green_meeting_is_eligible(self):
        d = make_meeting(self.archive, "2026-07-01_1000__a")
        ok, reason = retention.eligibility(d, self.cutoff)
        self.assertTrue(ok, reason)

    def test_recent_meeting_is_kept(self):
        d = make_meeting(self.archive, "2026-07-20_1000__a")
        ok, reason = retention.eligibility(d, self.cutoff)
        self.assertFalse(ok)
        self.assertIn("too recent", reason)

    def test_missing_summary_is_kept(self):
        d = make_meeting(self.archive, "2026-07-01_1000__a", summary=False)
        ok, reason = retention.eligibility(d, self.cutoff)
        self.assertFalse(ok)
        self.assertIn("summary", reason)

    def test_missing_transcript_is_kept(self):
        d = make_meeting(self.archive, "2026-07-01_1000__a", transcript=False)
        ok, reason = retention.eligibility(d, self.cutoff)
        self.assertFalse(ok)
        self.assertIn("transcript", reason)

    def test_tripped_gate_keeps_audio(self):
        d = make_meeting(self.archive, "2026-07-01_1000__a", verify="red")
        ok, reason = retention.eligibility(d, self.cutoff)
        self.assertFalse(ok)
        self.assertIn("red", reason)

    def test_warn_does_not_keep_audio(self):
        """A warn is not a tripped gate, so it must not withhold the audio.

        Only ``transcript``, ``repeated_phrase_loop`` and ``diarization_coverage``
        can go red, and only those fail a pipeline run. Treating every non-green
        check as a tripped gate pinned meetings at full size over advisory
        warnings — ``dictation`` among them, which is a text-correlation gap that
        no amount of re-listening resolves.
        """
        d = make_meeting(self.archive, "2026-07-01_1000__a", verify="warn")
        ok, reason = retention.eligibility(d, self.cutoff)
        self.assertTrue(ok, reason)
        self.assertIn("warn", reason)

    def test_warn_keeps_audio_under_strict_verify(self):
        """``--strict-verify`` restores the older every-check-green rule."""
        d = make_meeting(self.archive, "2026-07-01_1000__a", verify="warn")
        ok, reason = retention.eligibility(d, self.cutoff, strict=True)
        self.assertFalse(ok)
        self.assertIn("not green", reason)

    def test_red_keeps_audio_even_without_strict_verify(self):
        """The relaxation must not reach a red check."""
        d = make_meeting(self.archive, "2026-07-01_1000__a", verify="red")
        for strict in (False, True):
            with self.subTest(strict=strict):
                ok, _ = retention.eligibility(d, self.cutoff, strict=strict)
                self.assertFalse(ok)

    def test_unknown_status_keeps_audio(self):
        """An unrecognised status is not silently treated as passable."""
        d = make_meeting(self.archive, "2026-07-01_1000__a", verify="chartreuse")
        ok, reason = retention.eligibility(d, self.cutoff)
        self.assertFalse(ok)
        self.assertIn("unknown status", reason)

    def test_absent_verify_is_allowed_when_signed_off(self):
        """The oldest meetings predate the pipeline; summary.md is the sign-off."""
        d = make_meeting(self.archive, "2026-07-01_1000__a", verify=None)
        ok, reason = retention.eligibility(d, self.cutoff)
        self.assertTrue(ok, reason)
        self.assertIn("absent", reason)

    def test_unreadable_verify_is_kept(self):
        d = make_meeting(self.archive, "2026-07-01_1000__a")
        (d / retention.WORK_DIRNAME / "verify.json").write_text("{", encoding="utf-8")
        ok, reason = retention.eligibility(d, self.cutoff)
        self.assertFalse(ok)
        self.assertIn("unreadable", reason)


class TestCompression(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.archive = self.root / "Acta"
        self.archive.mkdir()
        self.ffmpeg = install_stub(self.root)
        self._saved = {k: os.environ.get(k) for k in ("STUB_FAIL", "STUB_DRIFT")}
        for k in self._saved:
            os.environ.pop(k, None)

    def tearDown(self):
        for k, v in self._saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        self.tmp.cleanup()

    def test_dry_run_touches_nothing(self):
        d = make_meeting(self.archive, "2026-07-01_1000__a")
        rec = retention.compress_wav(
            self.ffmpeg, d / "system.wav", "opus", 32, apply=False
        )
        self.assertEqual(rec["status"], "planned")
        self.assertTrue((d / "system.wav").exists())
        self.assertFalse((d / "system.opus").exists())

    def test_apply_replaces_wav_after_verifying(self):
        d = make_meeting(self.archive, "2026-07-01_1000__a")
        rec = retention.compress_wav(
            self.ffmpeg, d / "system.wav", "opus", 32, apply=True
        )
        self.assertEqual(rec["status"], "compressed", rec.get("reason"))
        self.assertFalse((d / "system.wav").exists())
        self.assertTrue((d / "system.opus").exists())
        self.assertLess(rec["drift_seconds"], retention.DURATION_TOLERANCE_SECONDS)

    def test_encode_failure_keeps_source(self):
        os.environ["STUB_FAIL"] = "encode"
        d = make_meeting(self.archive, "2026-07-01_1000__a")
        rec = retention.compress_wav(
            self.ffmpeg, d / "system.wav", "opus", 32, apply=True
        )
        self.assertEqual(rec["status"], "failed")
        self.assertTrue((d / "system.wav").exists())
        self.assertFalse((d / "system.opus").exists())

    def test_undecodable_output_keeps_source(self):
        os.environ["STUB_FAIL"] = "decode"
        d = make_meeting(self.archive, "2026-07-01_1000__a")
        rec = retention.compress_wav(
            self.ffmpeg, d / "system.wav", "opus", 32, apply=True
        )
        self.assertEqual(rec["status"], "failed")
        self.assertIn("decode", rec["reason"])
        self.assertTrue((d / "system.wav").exists())

    def test_duration_drift_keeps_source(self):
        """A truncated encode is the failure that must never eat the original."""
        os.environ["STUB_DRIFT"] = "-5.0"
        d = make_meeting(self.archive, "2026-07-01_1000__a")
        rec = retention.compress_wav(
            self.ffmpeg, d / "system.wav", "opus", 32, apply=True
        )
        self.assertEqual(rec["status"], "failed")
        self.assertIn("drift", rec["reason"])
        self.assertTrue((d / "system.wav").exists())

    def test_unreadable_wav_is_skipped_not_failed(self):
        d = make_meeting(self.archive, "2026-07-01_1000__a", wav_seconds=())
        bad = d / "system.wav"
        bad.write_text("junk", encoding="utf-8")
        rec = retention.compress_wav(self.ffmpeg, bad, "opus", 32, apply=True)
        self.assertEqual(rec["status"], "skipped")
        self.assertTrue(bad.exists())


class TestPruneAndRestore(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.archive = self.root / "Acta"
        self.archive.mkdir()
        self.ffmpeg = install_stub(self.root)

    def tearDown(self):
        self.tmp.cleanup()

    def test_prune_dry_run_keeps_files(self):
        d = make_meeting(
            self.archive, "2026-07-01_1000__a", work_wavs=(("mic.16k.wav", 1.0),)
        )
        recs, freed = retention.prune_paths(retention.work_wavs(d), apply=False)
        self.assertEqual([r["status"] for r in recs], ["planned"])
        self.assertGreater(freed, 0)
        self.assertTrue((d / retention.WORK_DIRNAME / "mic.16k.wav").exists())

    def test_prune_apply_removes_files(self):
        d = make_meeting(
            self.archive, "2026-07-01_1000__a", work_wavs=(("mic.16k.wav", 1.0),)
        )
        recs, freed = retention.prune_paths(retention.work_wavs(d), apply=True)
        self.assertEqual([r["status"] for r in recs], ["pruned"])
        self.assertGreater(freed, 0)
        self.assertFalse((d / retention.WORK_DIRNAME / "mic.16k.wav").exists())

    def test_restore_decodes_back_to_wav(self):
        d = make_meeting(self.archive, "2026-07-01_1000__a")
        for name in ("system.wav", "mic.wav"):
            retention.compress_wav(self.ffmpeg, d / name, "opus", 32, apply=True)
        self.assertFalse((d / "system.wav").exists())

        recs = retention.restore_meeting(self.ffmpeg, d, apply=True)
        self.assertEqual({r["status"] for r in recs}, {"restored"})
        self.assertTrue((d / "system.wav").exists())
        self.assertTrue((d / "mic.wav").exists())

    def test_restore_does_not_clobber_existing_wav(self):
        d = make_meeting(self.archive, "2026-07-01_1000__a")
        (d / "system.opus").write_text("DUR=2.0", encoding="utf-8")
        before = (d / "system.wav").read_bytes()
        recs = retention.restore_meeting(self.ffmpeg, d, apply=True)
        self.assertIn("skipped", {r["status"] for r in recs})
        self.assertEqual((d / "system.wav").read_bytes(), before)


class TestBinaryResolution(unittest.TestCase):
    def test_env_override_wins(self):
        path, source = retention.resolve_ffmpeg_bin({"ACTA_FFMPEG_BIN": "/x/ffmpeg"})
        self.assertEqual(str(path), "/x/ffmpeg")
        self.assertEqual(source, "env:ACTA_FFMPEG_BIN")

    def test_empty_environ_finds_nothing(self):
        path, source = retention.resolve_ffmpeg_bin({})
        self.assertIsNone(path)
        self.assertEqual(source, "path")

    def test_path_lookup_uses_supplied_environ(self):
        with tempfile.TemporaryDirectory() as tmp:
            stub = install_stub(tmp)
            stub_dir = stub.parent / "bin"
            stub_dir.mkdir()
            target = stub_dir / "ffmpeg"
            stub.rename(target)
            path, source = retention.resolve_ffmpeg_bin({"PATH": str(stub_dir)})
            self.assertEqual(path, target)
            self.assertEqual(source, "path")


class TestMain(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.archive = self.root / "Acta"
        self.archive.mkdir()
        self.ffmpeg = install_stub(self.root)
        self.env = {"ACTA_FFMPEG_BIN": str(self.ffmpeg), "PATH": os.environ["PATH"]}
        self.today = __import__("datetime").date(2026, 7, 30)

    def tearDown(self):
        self.tmp.cleanup()

    def _run(self, *argv):
        buf = io.StringIO()
        code = retention.main(
            [str(self.archive), *argv],
            environ=self.env,
            stdout=buf,
            today=self.today,
        )
        return code, buf.getvalue()

    def test_dry_run_reports_without_changing_anything(self):
        d = make_meeting(self.archive, "2026-07-01_1000__a")
        code, text = self._run()
        self.assertEqual(code, retention.EXIT_OK)
        self.assertIn("DRY RUN", text)
        self.assertIn("eligible", text)
        self.assertTrue((d / "system.wav").exists())

    def test_apply_compresses_and_writes_report(self):
        d = make_meeting(self.archive, "2026-07-01_1000__a")
        code, text = self._run("--apply")
        self.assertEqual(code, retention.EXIT_OK)
        self.assertFalse((d / "system.wav").exists())
        self.assertTrue((d / "system.opus").exists())
        report = json.loads(
            (d / retention.WORK_DIRNAME / retention.REPORT_JSON_NAME).read_text(
                encoding="utf-8"
            )
        )
        self.assertEqual(report["codec"], "opus")
        self.assertEqual(
            {t["status"] for t in report["tracks"]}, {"compressed"}
        )

    def test_recent_meeting_survives_apply(self):
        d = make_meeting(self.archive, "2026-07-29_1000__recent")
        code, text = self._run("--apply")
        self.assertEqual(code, retention.EXIT_OK)
        self.assertTrue((d / "system.wav").exists())
        self.assertIn("too recent", text)

    def test_json_output_is_machine_readable(self):
        make_meeting(self.archive, "2026-07-01_1000__a")
        code, text = self._run("--json")
        payload = json.loads(text)
        self.assertEqual(payload["action"], "retention")
        self.assertEqual(payload["totals"]["eligible"], 1)
        self.assertFalse(payload["applied"])

    def test_failure_sets_exit_code(self):
        make_meeting(self.archive, "2026-07-01_1000__a")
        self.env["STUB_FAIL"] = "encode"
        saved = os.environ.get("STUB_FAIL")
        os.environ["STUB_FAIL"] = "encode"
        try:
            code, _ = self._run("--apply")
        finally:
            if saved is None:
                os.environ.pop("STUB_FAIL", None)
            else:
                os.environ["STUB_FAIL"] = saved
        self.assertEqual(code, retention.EXIT_FAILED)

    def test_missing_archive_is_usage_error(self):
        buf = io.StringIO()
        code = retention.main(
            [str(self.root / "nope")], environ=self.env, stdout=buf
        )
        self.assertEqual(code, retention.EXIT_USAGE)

    def test_prune_work_reports_intermediates(self):
        d = make_meeting(
            self.archive,
            "2026-07-29_1000__recent",
            work_wavs=(("mic.16k.wav", 1.0),),
        )
        code, text = self._run("--prune-work", "--apply")
        self.assertEqual(code, retention.EXIT_OK)
        self.assertFalse((d / retention.WORK_DIRNAME / "mic.16k.wav").exists())
        self.assertIn("regenerable intermediates", text)


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
