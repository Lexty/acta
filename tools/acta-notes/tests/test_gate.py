import _ctx

import contextlib
import io
import json
import tempfile
import unittest
import wave
from array import array
from pathlib import Path

gate = _ctx.load("gate")

RATE = 16000
#: RMS of a constant-magnitude signal is amplitude / 32768, so amplitudes are
#: chosen straight off the pinned 0.02 threshold.
SPEECH_AMPLITUDE = 6000  # RMS 0.183 — unambiguous speech
SILENCE_AMPLITUDE = 131  # RMS 0.004 — lab/006's measured room tone


def _block(amplitude, count):
    """``count`` samples alternating ±amplitude (RMS = amplitude / 32768)."""
    if amplitude == 0:
        return array("h", bytes(2 * count))
    pattern = array("h", [amplitude, -amplitude] * ((count + 1) // 2))
    return pattern[:count]


def write_gated_wav(
    path,
    total_seconds,
    spans=(),
    rate=RATE,
    amplitude=SPEECH_AMPLITUDE,
    floor=0,
    sampwidth=2,
):
    """A wav of ``total_seconds`` that is loud exactly inside ``spans``."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    total = int(round(total_seconds * rate))
    samples = _block(floor, total)
    for start, end in spans:
        a, b = int(round(start * rate)), int(round(end * rate))
        samples[a:b] = _block(amplitude, b - a)
    with wave.open(str(path), "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(sampwidth)
        handle.setframerate(rate)
        if sampwidth == 2:
            handle.writeframes(samples.tobytes())
        else:  # an 8-bit track — the format S2 must refuse
            handle.writeframes(bytes(total))
    return path


@contextlib.contextmanager
def meeting(tracks=("mic", "system"), total_seconds=4.0, spans=((1.0, 3.0),)):
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp) / "2026-07-29 Weekly"
        (root / ".acta-notes").mkdir(parents=True)
        for track in tracks:
            write_gated_wav(gate.input_path(root, track), total_seconds, spans)
        yield root


class ThresholdTests(unittest.TestCase):
    def test_threshold_is_pinned_to_lab_006(self):
        self.assertEqual(gate.SPEECH_RMS_THRESHOLD, 0.02)

    def test_frame_rms_normalises_to_full_scale(self):
        self.assertAlmostEqual(gate.frame_rms(_block(3276, 480)), 0.1, places=3)
        self.assertEqual(gate.frame_rms(array("h")), 0.0)

    def test_just_below_the_threshold_is_not_speech(self):
        # 655 / 32768 = 0.01999 — the 0.015 that lab/006 rejected lives here.
        with tempfile.TemporaryDirectory() as tmp:
            path = write_gated_wav(
                Path(tmp) / "quiet.wav", 3.0, [(0.0, 3.0)], amplitude=655
            )
            result = gate.analyze_wav(path)
        self.assertLess(result["peak_rms"], 0.02)
        self.assertEqual(result["spans"], [])
        self.assertTrue(result["effectively_silent"])

    def test_just_above_the_threshold_is_speech(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = write_gated_wav(
                Path(tmp) / "loud.wav", 3.0, [(0.0, 3.0)], amplitude=660
            )
            result = gate.analyze_wav(path)
        self.assertGreaterEqual(result["peak_rms"], 0.02)
        self.assertEqual(result["span_count"], 1)
        self.assertAlmostEqual(result["speech_seconds"], 3.0, delta=0.05)
        self.assertFalse(result["effectively_silent"])


class SpanTests(unittest.TestCase):
    def test_silence_only_wav_is_effectively_silent(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = write_gated_wav(Path(tmp) / "silent.wav", 10.0, spans=())
            result = gate.analyze_wav(path)
        self.assertEqual(result["spans"], [])
        self.assertEqual(result["speech_seconds"], 0.0)
        self.assertEqual(result["speech_fraction"], 0.0)
        self.assertTrue(result["effectively_silent"])
        self.assertAlmostEqual(result["duration_seconds"], 10.0, places=3)

    def test_room_tone_only_wav_is_effectively_silent(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = write_gated_wav(
                Path(tmp) / "room.wav", 10.0, spans=(), floor=SILENCE_AMPLITUDE
            )
            result = gate.analyze_wav(path)
        self.assertAlmostEqual(result["peak_rms"], 0.004, places=3)
        self.assertTrue(result["effectively_silent"])

    def test_tone_with_gaps_yields_the_expected_spans(self):
        want = [(1.0, 2.0), (4.0, 5.5), (8.0, 9.0)]
        with tempfile.TemporaryDirectory() as tmp:
            path = write_gated_wav(Path(tmp) / "gaps.wav", 10.0, want)
            result = gate.analyze_wav(path)
        self.assertEqual(result["span_count"], 3)
        for span, (start, end) in zip(result["spans"], want):
            self.assertAlmostEqual(span["start"], start, delta=0.05)
            self.assertAlmostEqual(span["end"], end, delta=0.05)
            self.assertAlmostEqual(span["duration"], end - start, delta=0.05)
        self.assertAlmostEqual(result["speech_seconds"], 3.5, delta=0.15)
        self.assertAlmostEqual(result["speech_fraction"], 0.35, delta=0.02)
        self.assertFalse(result["effectively_silent"])

    def test_room_tone_between_words_does_not_split_a_span(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = write_gated_wav(
                Path(tmp) / "words.wav",
                6.0,
                [(1.0, 1.4), (1.5, 1.9), (2.0, 2.4)],
                floor=SILENCE_AMPLITUDE,
            )
            result = gate.analyze_wav(path)
        self.assertEqual(result["span_count"], 1)
        self.assertAlmostEqual(result["spans"][0]["duration"], 1.4, delta=0.1)

    def test_merge_gap_boundary(self):
        frames = [0.5, 0.0, 0.0, 0.5]  # voiced, 0.2 s of nothing, voiced
        merged = gate.spans_from_frames(
            frames, 0.1, 0.4, merge_gap=0.2, min_span=0.05
        )
        self.assertEqual(len(merged), 1)
        self.assertAlmostEqual(merged[0]["duration"], 0.4, places=3)

        split = gate.spans_from_frames(
            frames, 0.1, 0.4, merge_gap=0.1, min_span=0.05
        )
        self.assertEqual(len(split), 2)

    def test_short_spans_are_dropped(self):
        frames = [0.5, 0.0, 0.0, 0.0, 0.0, 0.5, 0.5, 0.5]
        spans = gate.spans_from_frames(frames, 0.1, 0.8, merge_gap=0.1, min_span=0.2)
        self.assertEqual(len(spans), 1)  # the lone 0.1 s click is gone
        self.assertAlmostEqual(spans[0]["start"], 0.5, places=3)

    def test_spans_never_run_past_the_track(self):
        frames = [0.5, 0.5]
        spans = gate.spans_from_frames(frames, 0.1, 0.15, merge_gap=0.1, min_span=0.05)
        self.assertAlmostEqual(spans[0]["end"], 0.15, places=3)


class SilentVerdictTests(unittest.TestCase):
    def test_the_measured_mic_track_is_not_silent(self):
        # 164 s of real speech inside 3423 s — 4.8 % (D5). Nothing on the system
        # track covers it, so a fraction-based verdict would be wrong here.
        self.assertFalse(gate.is_effectively_silent(164.0))

    def test_verdict_boundary_is_absolute_seconds(self):
        self.assertTrue(gate.is_effectively_silent(1.99))
        self.assertFalse(gate.is_effectively_silent(2.0))
        self.assertFalse(gate.is_effectively_silent(0.5, floor=0.25))

    def test_a_sparse_listen_mostly_track_is_still_speech(self):
        # The mic ratio in miniature: 4.8 s of speech scattered over 100 s.
        spans = [(10.0, 11.2), (30.0, 31.2), (55.0, 56.2), (80.0, 81.2)]
        with tempfile.TemporaryDirectory() as tmp:
            path = write_gated_wav(
                Path(tmp) / "mic.16k.wav", 100.0, spans, floor=SILENCE_AMPLITUDE
            )
            result = gate.analyze_wav(path)
        self.assertEqual(result["span_count"], 4)
        self.assertAlmostEqual(result["speech_fraction"], 0.048, delta=0.005)
        self.assertFalse(result["effectively_silent"])


class FormatTests(unittest.TestCase):
    def test_input_path_reads_s1_output(self):
        self.assertEqual(
            gate.input_path("/Acta/m1", "system"),
            Path("/Acta/m1/.acta-notes/system.16k.wav"),
        )

    def test_eight_bit_wav_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = write_gated_wav(Path(tmp) / "u8.wav", 1.0, sampwidth=1)
            with self.assertRaises(gate.GateError) as ctx:
                gate.analyze_wav(path)
        self.assertIn("prep_audio.py", str(ctx.exception))

    def test_unreadable_file_is_a_gate_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "junk.wav"
            path.write_bytes(b"not a wav")
            with self.assertRaises(gate.GateError):
                gate.analyze_wav(path)


class RunTests(unittest.TestCase):
    def test_both_tracks_are_gated_and_timed(self):
        with meeting() as root:
            report = gate.run(root, clock=iter([0.0, 1.0, 1.0, 2.5]).__next__)
        self.assertEqual(report["status"], "ok")
        self.assertEqual([t["track"] for t in report["tracks"]], ["mic", "system"])
        self.assertEqual([t["elapsed_seconds"] for t in report["tracks"]], [1.0, 1.5])
        self.assertEqual(report["total_seconds"], 2.5)
        self.assertEqual(report["silent_tracks"], [])
        for entry in report["tracks"]:
            self.assertEqual(entry["status"], "ok")
            self.assertEqual(entry["sample_rate"], RATE)
            self.assertAlmostEqual(entry["speech_seconds"], 2.0, delta=0.1)

    def test_a_silent_track_is_reported_not_failed(self):
        with meeting(tracks=("mic",), total_seconds=10.0, spans=()) as root:
            report = gate.run(root, tracks=("mic",))
        self.assertEqual(report["status"], "ok")
        self.assertEqual(report["silent_tracks"], ["mic"])
        self.assertEqual(gate.exit_code(report), 0)
        self.assertIn("silent", report["tracks"][0]["detail"])

    def test_missing_track_is_reported(self):
        with meeting(tracks=("system",)) as root:
            report = gate.run(root)
        by_track = {t["track"]: t for t in report["tracks"]}
        self.assertEqual(by_track["mic"]["status"], "missing")
        self.assertIn("prep_audio.py", by_track["mic"]["detail"])
        self.assertEqual(by_track["system"]["status"], "ok")
        self.assertEqual(report["status"], "ok")

    def test_no_tracks_at_all_is_a_failure(self):
        with meeting(tracks=()) as root:
            report = gate.run(root)
        self.assertEqual(report["status"], "failed")
        self.assertEqual(gate.exit_code(report), 1)

    def test_an_unreadable_track_fails_the_stage(self):
        with meeting(tracks=("system",)) as root:
            gate.input_path(root, "mic").write_bytes(b"not a wav")
            report = gate.run(root)
        self.assertEqual(report["status"], "failed")
        self.assertEqual(gate.exit_code(report), 1)


class CliTests(unittest.TestCase):
    def _main(self, argv):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = gate.main(argv)
        return code, out.getvalue()

    def test_stage_json_is_written_with_the_run_shape(self):
        with meeting() as root:
            code, out = self._main([str(root)])
            stage = json.loads(
                (root / ".acta-notes" / "gate.json").read_text(encoding="utf-8")
            )
        self.assertEqual(code, 0)
        self.assertEqual(stage["stage"], "gate")
        self.assertEqual(stage["threshold"], 0.02)
        self.assertEqual(stage["silence_floor_seconds"], 2.0)
        self.assertEqual(len(stage["tracks"]), 2)
        self.assertIn("speech", out)

    def test_track_and_tuning_flags_are_honoured(self):
        # 1.5 s of speech: silent under the pinned 2.0 s floor, speech under 1.0.
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "m"
            (root / ".acta-notes").mkdir(parents=True)
            write_gated_wav(gate.input_path(root, "mic"), 10.0, [(1.0, 2.5)])

            self._main([str(root), "--track", "mic"])
            default = json.loads(
                (root / ".acta-notes" / "gate.json").read_text(encoding="utf-8")
            )
            code, _ = self._main(
                [str(root), "--track", "mic", "--silence-floor", "1.0"]
            )
            tuned = json.loads(
                (root / ".acta-notes" / "gate.json").read_text(encoding="utf-8")
            )
        self.assertEqual(code, 0)
        self.assertEqual(len(tuned["tracks"]), 1)
        self.assertTrue(default["tracks"][0]["effectively_silent"])
        self.assertEqual(tuned["silence_floor_seconds"], 1.0)
        self.assertFalse(tuned["tracks"][0]["effectively_silent"])

    def test_min_span_flag_can_drop_a_short_span(self):
        with meeting(tracks=("mic",), total_seconds=10.0, spans=((1.0, 1.5),)) as root:
            self._main([str(root), "--track", "mic", "--min-span", "2.0"])
            stage = json.loads(
                (root / ".acta-notes" / "gate.json").read_text(encoding="utf-8")
            )
        self.assertEqual(stage["tracks"][0]["span_count"], 0)
        self.assertTrue(stage["tracks"][0]["effectively_silent"])

    def test_json_flag_prints_the_report(self):
        with meeting(tracks=("mic",)) as root:
            code, out = self._main([str(root), "--track", "mic", "--json"])
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(out)["stage"], "gate")

    def test_failure_exits_one(self):
        with meeting(tracks=()) as root:
            code, out = self._main([str(root)])
        self.assertEqual(code, 1)
        self.assertIn("FAILED", out)

    def test_missing_meeting_folder_is_a_usage_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(SystemExit) as ctx:
                with contextlib.redirect_stderr(io.StringIO()):
                    gate.main([str(Path(tmp) / "nope")])
        self.assertEqual(ctx.exception.code, gate.EXIT_USAGE)


class CarryForwardTests(unittest.TestCase):
    """A single-track rerun must not erase the other track's silence verdict.

    pipeline.py drops a track from the ASR pass on ``silent_tracks`` alone, so an
    erased entry costs a full transcription pass on audio S2 already ruled out.
    """

    def _write_report(self, root, silent=("mic",), tracks=("mic", "system")):
        gate.write_stage_json(
            root,
            {
                "stage": "gate",
                "status": "ok",
                "silent_tracks": list(silent),
                "tracks": [
                    {
                        "track": track,
                        "status": "ok",
                        "effectively_silent": track in silent,
                        "speech_seconds": 0.0 if track in silent else 2.0,
                        "duration_seconds": 4.0,
                        "speech_fraction": 0.0 if track in silent else 0.5,
                        "span_count": 0 if track in silent else 1,
                    }
                    for track in tracks
                ],
            },
        )

    def test_an_untouched_tracks_silence_verdict_survives(self):
        with meeting() as root:
            self._write_report(root, silent=("mic",))
            report = gate.run(root, tracks=("system",))

        self.assertIn("mic", report["silent_tracks"])
        carried = next(e for e in report["tracks"] if e["track"] == "mic")
        self.assertEqual(carried["status"], gate.STATUS_CARRIED)
        self.assertEqual(carried["elapsed_seconds"], 0.0)

    def test_a_track_this_run_regated_is_never_overwritten_by_the_old_record(self):
        with meeting() as root:
            # The old record calls system silent; this run measures speech on it.
            self._write_report(root, silent=("mic", "system"))
            report = gate.run(root, tracks=("system",))

        system = [e for e in report["tracks"] if e["track"] == "system"]
        self.assertEqual(len(system), 1)
        self.assertFalse(system[0]["effectively_silent"])
        self.assertEqual(report["silent_tracks"], ["mic"])

    def test_carried_entries_never_colour_the_status_or_the_elapsed_time(self):
        with meeting() as root:
            gate.write_stage_json(
                root,
                {
                    "stage": "gate",
                    "status": "failed",
                    "tracks": [{"track": "mic", "status": "failed", "detail": "boom"}],
                },
            )
            report = gate.run(root, tracks=("system",))

        self.assertEqual(report["status"], gate.STATUS_OK)
        carried = next(e for e in report["tracks"] if e["track"] == "mic")
        self.assertEqual(carried["status"], gate.STATUS_CARRIED)
        system = next(e for e in report["tracks"] if e["track"] == "system")
        self.assertEqual(report["total_seconds"], round(system["elapsed_seconds"], 3))

    def test_no_previous_report_is_not_an_error(self):
        with meeting() as root:
            report = {"stage": "gate", "status": "ok", "tracks": []}
            self.assertIs(gate.carry_forward_tracks(root, report), report)
            self.assertEqual(report["tracks"], [])

    def test_an_unreadable_previous_report_is_not_an_error(self):
        with meeting() as root:
            path = gate.work_dir(root) / gate.STAGE_JSON_NAME
            path.write_text("{not json", encoding="utf-8")
            report = {"stage": "gate", "status": "ok", "tracks": []}
            self.assertIs(gate.carry_forward_tracks(root, report), report)
            self.assertEqual(report["tracks"], [])

    def test_a_carried_entry_renders_without_raising(self):
        with meeting() as root:
            self._write_report(root, silent=("mic",))
            report = gate.run(root, tracks=("system",))
        self.assertIn(gate.STATUS_CARRIED, gate.render_human(report))


class ArgumentValidationTests(unittest.TestCase):
    """Each of these degraded silently rather than erroring."""

    def _usage(self, argv):
        with meeting() as root:
            buf = io.StringIO()
            with contextlib.redirect_stderr(buf), self.assertRaises(SystemExit) as caught:
                gate.main([str(root)] + argv)
        return caught.exception.code, buf.getvalue()

    def test_a_non_positive_frame_clamped_to_one_sample_instead_of_erroring(self):
        code, err = self._usage(["--frame-ms", "0"])
        self.assertEqual(code, gate.EXIT_USAGE)
        self.assertIn("--frame-ms", err)

    def test_a_negative_silence_floor_made_the_silence_check_unsatisfiable(self):
        code, err = self._usage(["--silence-floor", "-1"])
        self.assertEqual(code, gate.EXIT_USAGE)
        self.assertIn("--silence-floor", err)

    def test_negative_span_bounds_are_refused(self):
        for flag in ("--merge-gap", "--min-span"):
            with self.subTest(flag=flag):
                code, err = self._usage([flag, "-0.5"])
                self.assertEqual(code, gate.EXIT_USAGE)
                self.assertIn(flag, err)

    def test_a_track_name_that_would_escape_the_meeting_folder_is_refused(self):
        for name in ("../../../etc/passwd", "a/b", "..", "", "mic.wav"):
            with self.subTest(name=name):
                self.assertFalse(gate.valid_track_name(name))
        code, err = self._usage(["--track", "../escaped"])
        self.assertEqual(code, gate.EXIT_USAGE)
        self.assertIn("not a usable track name", err)


#: The 2026-08-03 huddle, in numbers: speech ~30 dB below a healthy capture, so
#: every frame sits under the pinned 0.02 threshold while the track is plainly
#: not silent. Amplitude 160 is RMS 0.0049; the floor is true room tone.
QUIET_SPEECH_AMPLITUDE = 160
ROOM_TONE_AMPLITUDE = 8  # RMS 0.00024


class UnderLevelledTests(unittest.TestCase):
    """The regression this whole path exists for: quiet ≠ silent.

    A track recorded far below level cleared no span at the pinned threshold, so
    S2 called it ``effectively_silent``, ``pipeline.py`` dropped it from the ASR
    pass and the run finished green having lost one side of the conversation.
    """

    def _analyze(self, path, **kwargs):
        return gate.analyze_wav(path, **kwargs)

    def test_a_quiet_speech_track_is_under_levelled_not_silent(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = write_gated_wav(
                Path(tmp) / "mic.16k.wav",
                20.0,
                spans=((2.0, 6.0), (9.0, 14.0)),
                amplitude=QUIET_SPEECH_AMPLITUDE,
                floor=ROOM_TONE_AMPLITUDE,
            )
            report = self._analyze(path)

        # The pinned gate still sees nothing — that part is unchanged and pinned.
        self.assertEqual(report["speech_seconds"], 0.0)
        self.assertTrue(report["gated_silent_at_threshold"])
        # ...but the verdict every consumer branches on now tells the truth.
        self.assertTrue(report["under_levelled"])
        self.assertFalse(report["effectively_silent"])
        self.assertGreaterEqual(report["probe_speech_seconds"], 8.0)
        self.assertEqual(report["suggested_chain"], "loudnorm")
        self.assertGreater(report["suggested_gain"], 1.0)

    def test_room_tone_only_stays_silent(self):
        """A dead capture must never be 'remediated' — it has no speech to find."""
        with tempfile.TemporaryDirectory() as tmp:
            path = write_gated_wav(
                Path(tmp) / "mic.16k.wav", 20.0, spans=(), floor=ROOM_TONE_AMPLITUDE
            )
            report = self._analyze(path)

        self.assertTrue(report["effectively_silent"])
        self.assertFalse(report["under_levelled"])
        self.assertIsNone(report["suggested_chain"])

    def test_digital_silence_stays_silent(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = write_gated_wav(Path(tmp) / "mic.16k.wav", 10.0, spans=(), floor=0)
            report = self._analyze(path)

        self.assertTrue(report["effectively_silent"])
        self.assertFalse(report["under_levelled"])

    def test_a_lone_click_over_room_tone_stays_silent(self):
        """Dynamic range alone is not enough — the probe demands *sustained* speech."""
        with tempfile.TemporaryDirectory() as tmp:
            path = write_gated_wav(
                Path(tmp) / "mic.16k.wav",
                20.0,
                spans=((5.0, 5.05),),  # 50 ms — a keystroke, not a word
                amplitude=SPEECH_AMPLITUDE,
                floor=ROOM_TONE_AMPLITUDE,
            )
            report = self._analyze(path)

        self.assertTrue(report["effectively_silent"])
        self.assertFalse(report["under_levelled"])

    def test_loud_flat_hiss_is_not_under_levelled(self):
        """Hiss just under the threshold is flat; speech is bursty. Range decides."""
        with tempfile.TemporaryDirectory() as tmp:
            path = write_gated_wav(
                Path(tmp) / "mic.16k.wav",
                20.0,
                spans=(),
                floor=600,  # RMS 0.0183 — loud, but every frame identical
            )
            report = self._analyze(path)

        self.assertTrue(report["effectively_silent"])
        self.assertFalse(report["under_levelled"])
        self.assertLess(report["dynamic_range"], gate.MIN_DYNAMIC_RANGE)

    def test_a_healthy_track_is_not_probed_at_all(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = write_gated_wav(
                Path(tmp) / "system.16k.wav", 10.0, spans=((1.0, 6.0),)
            )
            report = self._analyze(path)

        self.assertFalse(report["effectively_silent"])
        self.assertFalse(report["under_levelled"])
        self.assertIsNone(report["probe_threshold"])

    def test_run_keeps_a_quiet_track_out_of_silent_tracks(self):
        """The load-bearing wiring: pipeline.py drops `silent_tracks` from ASR."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "2026-08-03 Huddle"
            (root / ".acta-notes").mkdir(parents=True)
            write_gated_wav(
                gate.input_path(root, "mic"),
                20.0,
                spans=((2.0, 6.0), (9.0, 14.0)),
                amplitude=QUIET_SPEECH_AMPLITUDE,
                floor=ROOM_TONE_AMPLITUDE,
            )
            write_gated_wav(
                gate.input_path(root, "system"), 20.0, spans=((1.0, 12.0),)
            )
            report = gate.run(root)

        self.assertEqual(report["silent_tracks"], [])
        self.assertEqual(report["under_levelled_tracks"], ["mic"])

    def test_the_human_render_shouts_about_it(self):
        """A JSON-only signal is how this got missed the first time."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "2026-08-03 Huddle"
            (root / ".acta-notes").mkdir(parents=True)
            write_gated_wav(
                gate.input_path(root, "mic"),
                20.0,
                spans=((2.0, 6.0), (9.0, 14.0)),
                amplitude=QUIET_SPEECH_AMPLITUDE,
                floor=ROOM_TONE_AMPLITUDE,
            )
            rendered = gate.render_human(gate.run(root, tracks=("mic",)))

        self.assertIn("QUIET", rendered)
        self.assertIn("loudnorm", rendered)

    def test_a_silent_verdict_now_says_why(self):
        """'no ASR pass is worth running' must never again be an unchecked claim."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "m"
            (root / ".acta-notes").mkdir(parents=True)
            write_gated_wav(
                gate.input_path(root, "mic"), 10.0, spans=(), floor=ROOM_TONE_AMPLITUDE
            )
            entry = gate.run(root, tracks=("mic",))["tracks"][0]

        self.assertTrue(entry["effectively_silent"])
        self.assertIn("effectively silent", entry["detail"])
        self.assertTrue(entry["level_detail"])

    def test_reference_and_range_constants_are_documented_values(self):
        self.assertEqual(gate.REFERENCE_PEAK_RMS, 0.25)
        self.assertEqual(gate.MIN_DYNAMIC_RANGE, 8.0)


if __name__ == "__main__":
    unittest.main()
