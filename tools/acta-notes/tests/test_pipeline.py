import _ctx

import contextlib
import io
import json
import os
import tempfile
import unittest
from pathlib import Path

pipeline = _ctx.load("pipeline")


# --- helpers -----------------------------------------------------------------


class Recorder:
    """A stub runner: records every stage call, returns scripted exit codes."""

    def __init__(self, codes=None, side_effects=None):
        #: ``{stage: code}`` or ``{(stage, mode): code}`` — anything absent is 0.
        self.codes = dict(codes or {})
        #: ``{stage: callable(call)}`` run before the code is returned.
        self.side_effects = dict(side_effects or {})
        self.calls = []

    def key(self, call):
        argv = call["argv"]
        stage = call["stage"]
        if stage in ("speakers", "diarize") and argv:
            return (stage, argv[0])
        return stage

    def __call__(self, call):
        self.calls.append(call)
        effect = self.side_effects.get(call["stage"])
        if effect is not None:
            effect(call)
        key = self.key(call)
        if key in self.codes:
            return self.codes[key]
        return self.codes.get(call["stage"], 0)

    @property
    def stages(self):
        return [call["stage"] for call in self.calls]

    @property
    def scripts(self):
        return [call["script"] for call in self.calls]

    def argv_for(self, stage, index=0):
        matches = [call["argv"] for call in self.calls if call["stage"] == stage]
        return matches[index]


class Clock:
    """A monotonic stub so timings are deterministic."""

    def __init__(self, step=0.5):
        self.step = step
        self.now = 0.0

    def __call__(self):
        value = self.now
        self.now += self.step
        return value


@contextlib.contextmanager
def meeting(**files):
    """A temp meeting folder; ``files`` maps relative paths to text contents."""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp) / "2026-07-29 Weekly"
        (root / pipeline.WORK_DIRNAME).mkdir(parents=True)
        for name, content in files.items():
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding="utf-8")
        yield root


def gate_json(silent=(), quiet=()):
    """``quiet`` = tracks S2 found under-levelled: recorded too low to gate, but
    not silent. They must never appear in ``silent_tracks``."""
    return json.dumps(
        {
            "stage": "gate",
            "status": "ok",
            "tracks": [
                {
                    "track": track,
                    "status": "ok",
                    "effectively_silent": track in silent,
                    "under_levelled": track in quiet,
                }
                for track in ("mic", "system")
            ],
            "silent_tracks": list(silent),
            "under_levelled_tracks": list(quiet),
        },
        ensure_ascii=False,
    )


def touch(path, mtime):
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.exists():
        path.write_text("x", encoding="utf-8")
    os.utime(path, (mtime, mtime))


def run(meeting_dir, recorder=None, **kwargs):
    recorder = recorder or Recorder()
    report = pipeline.run(
        meeting_dir, runner=recorder, clock=Clock(), **kwargs
    )
    return report, recorder


# --- stage ordering ----------------------------------------------------------


class StageOrderTests(unittest.TestCase):
    def test_full_chain_in_order(self):
        with meeting() as root:
            report, rec = run(root)

        self.assertEqual(report["status"], pipeline.STATUS_OK)
        self.assertEqual(
            rec.stages,
            [
                "doctor",
                "prep_audio",
                "gate",
                "transcribe",
                "diarize",
                "merge",
                "speakers",  # build
                "speakers",  # apply
                "dicta_overlay",
                "verify",
            ],
        )

    def test_speakers_runs_build_then_apply(self):
        with meeting() as root:
            _, rec = run(root)

        modes = [c["argv"][0] for c in rec.calls if c["stage"] == "speakers"]
        self.assertEqual(modes, ["build", "apply"])

    def test_verify_is_last(self):
        with meeting() as root:
            _, rec = run(root)
        self.assertEqual(rec.stages[-1], "verify")

    def test_stage_list_is_canonical(self):
        self.assertEqual(
            pipeline.STAGES,
            (
                "doctor",
                "prep_audio",
                "gate",
                "transcribe",
                "diarize",
                "merge",
                "speakers",
                "dicta_overlay",
                "verify",
            ),
        )

    def test_run_log_records_every_stage(self):
        with meeting() as root:
            report, _ = run(root)

        logged = [entry["stage"] for entry in report["stages"]]
        self.assertEqual(logged, list(pipeline.STAGES))
        for entry in report["stages"]:
            self.assertIn("status", entry)
            self.assertIn("detail", entry)
            self.assertIn("elapsed_seconds", entry)
            self.assertIsInstance(entry["calls"], list)
        self.assertIsInstance(report["total_seconds"], float)


# --- the Teams converter is never a stage ------------------------------------


class TeamsPathTests(unittest.TestCase):
    def test_converter_is_never_invoked(self):
        with meeting() as root:
            _, rec = run(root)

        self.assertNotIn(pipeline.TEAMS_CONVERTER_SCRIPT, rec.scripts)
        self.assertNotIn(pipeline.TEAMS_CONVERTER_SCRIPT, rec.stages)

    def test_converter_is_not_a_stage(self):
        self.assertNotIn(pipeline.TEAMS_CONVERTER_SCRIPT, pipeline.STAGES)
        for stage in pipeline.STAGES:
            for call in pipeline.stage_calls(Path("/meeting"), stage):
                self.assertNotEqual(pipeline.TEAMS_CONVERTER_SCRIPT, call["script"])

    def test_from_stage_speakers_needs_only_the_raw_transcript(self):
        with meeting(**{pipeline.RAW_TRANSCRIPT_NAME: "# transcript\n"}) as root:
            report, rec = run(root, from_stage="speakers")

        self.assertEqual(report["status"], pipeline.STATUS_OK)
        self.assertEqual(
            rec.stages, ["speakers", "speakers", "dicta_overlay", "verify"]
        )
        # No preflight, no ML: doctor sits before the cut.
        self.assertNotIn("doctor", rec.stages)
        self.assertNotIn("transcribe", rec.stages)
        self.assertNotIn("diarize", rec.stages)

    def test_from_stage_speakers_tolerates_absent_stage_jsons(self):
        with meeting(**{pipeline.RAW_TRANSCRIPT_NAME: "# transcript\n"}) as root:
            work = root / pipeline.WORK_DIRNAME
            self.assertFalse((work / "transcribe.json").exists())
            self.assertFalse((work / "diarization.json").exists())
            report, _ = run(root, from_stage="speakers")

        self.assertEqual(report["status"], pipeline.STATUS_OK)


# --- stage selection ---------------------------------------------------------


class SelectionTests(unittest.TestCase):
    def test_from_stage_is_a_suffix(self):
        self.assertEqual(
            pipeline.select_stages(from_stage="merge"),
            ("merge", "speakers", "dicta_overlay", "verify"),
        )

    def test_only_preserves_canonical_order(self):
        self.assertEqual(
            pipeline.select_stages(only=("verify", "gate")), ("gate", "verify")
        )

    def test_only_and_from_stage_are_exclusive(self):
        with self.assertRaises(pipeline.SelectionError):
            pipeline.select_stages(from_stage="merge", only=("verify",))

    def test_unknown_stage_rejected(self):
        with self.assertRaises(pipeline.SelectionError):
            pipeline.select_stages(from_stage="teams_vtt_to_transcript")
        with self.assertRaises(pipeline.SelectionError):
            pipeline.select_stages(only=("nope",))

    def test_default_is_every_stage(self):
        self.assertEqual(pipeline.select_stages(), pipeline.STAGES)

    def test_only_runs_just_that_stage(self):
        with meeting() as root:
            _, rec = run(root, only=("verify",))
        self.assertEqual(rec.stages, ["verify"])


# --- argv construction -------------------------------------------------------


class ArgvTests(unittest.TestCase):
    def test_diarize_is_always_the_system_track(self):
        with meeting() as root:
            _, rec = run(root)
            argv = rec.argv_for("diarize")

        self.assertEqual(argv[:4], ["run", str(root), "--track", "system"])
        self.assertNotIn("mic", argv)

    def test_num_speakers_forwarded_to_diarize(self):
        with meeting() as root:
            _, rec = run(root, num_speakers=4)
            argv = rec.argv_for("diarize")

        self.assertIn("--num-speakers", argv)
        self.assertEqual(argv[argv.index("--num-speakers") + 1], "4")

    def test_no_num_speakers_leaves_the_flag_off(self):
        with meeting() as root:
            _, rec = run(root)
        self.assertNotIn("--num-speakers", rec.argv_for("diarize"))

    def test_chain_forwarded_to_prep_audio(self):
        with meeting() as root:
            _, rec = run(root, chain="loudnorm")
            argv = rec.argv_for("prep_audio")

        self.assertEqual(argv, [str(root), "--chain", "loudnorm"])

    def test_default_chain_is_denoise(self):
        with meeting() as root:
            _, rec = run(root)
        self.assertEqual(rec.argv_for("prep_audio")[-1], "denoise")

    def test_attendees_passed_through_to_build(self):
        with meeting() as root:
            _, rec = run(root, attendees=("Дмитрий,Любовь", "Пётр"))
            build = rec.argv_for("speakers", 0)
            apply_ = rec.argv_for("speakers", 1)

        self.assertEqual(
            build,
            ["build", str(root), "--attendees", "Дмитрий,Любовь", "--attendees", "Пётр"],
        )
        self.assertEqual(apply_, ["apply", str(root)])

    def test_absent_attendees_still_builds(self):
        with meeting() as root:
            report, rec = run(root)

        self.assertEqual(report["status"], pipeline.STATUS_OK)
        self.assertEqual(rec.argv_for("speakers", 0), ["build", str(root)])

    def test_transcribe_asks_for_both_tracks(self):
        with meeting() as root:
            _, rec = run(root)

        self.assertEqual(
            rec.argv_for("transcribe"),
            [str(root), "--track", "mic", "--track", "system"],
        )

    def test_force_is_not_forwarded_to_merge(self):
        with meeting() as root:
            _, rec = run(root, force=True)

        self.assertNotIn("--force", rec.argv_for("merge"))

    def test_force_is_forwarded_to_every_stage_that_has_its_own_check(self):
        # Clearing only this driver's freshness check is not enough: prep_audio,
        # transcribe and diarize each keep one, so without the flag they
        # self-skip while the run log reports `1 call(s) ok`.
        with meeting() as root:
            _, rec = run(root, force=True)

        for stage in ("prep_audio", "transcribe", "diarize"):
            with self.subTest(stage=stage):
                self.assertIn("--force", rec.argv_for(stage))

    def test_without_force_no_stage_is_asked_to_force(self):
        with meeting() as root:
            _, rec = run(root)

        for call in rec.calls:
            with self.subTest(stage=call["stage"]):
                self.assertNotIn("--force", call["argv"])

    def test_the_forced_flag_a_stage_receives_is_one_it_accepts(self):
        # A --force appended to a stage that has no such flag would make argparse
        # exit 2 and fail the run.
        for stage in ("prep_audio", "transcribe", "diarize"):
            calls = pipeline.stage_calls(Path("/meeting"), stage, force=True)
            source = _ctx.script_path(stage).read_text(encoding="utf-8")
            with self.subTest(stage=stage):
                self.assertIn("--force", calls[-1]["argv"])
                self.assertIn('"--force"', source)

    def test_gate_is_not_asked_to_force_because_it_has_no_such_flag(self):
        # gate.py re-reads the wavs every time; there is no freshness check to
        # clear, and the flag would be an argparse error.
        calls = pipeline.stage_calls(Path("/meeting"), "gate", force=True)
        self.assertNotIn("--force", calls[0]["argv"])
        self.assertNotIn(
            '"--force"', _ctx.script_path("gate").read_text(encoding="utf-8")
        )

    def test_force_is_appended_after_the_stage_parameters(self):
        calls = pipeline.stage_calls(
            Path("/meeting"), "transcribe", language="ru", force=True
        )
        argv = calls[0]["argv"]
        self.assertEqual(argv[-1], "--force")
        self.assertEqual(argv[argv.index("--language") + 1], "ru")

    def test_force_refuses_up_front_when_merge_would_have_to_overwrite(self):
        """--force is not forwarded to merge, so merge would refuse (exit 2).

        The driver must say so before running anything: reaching that refusal
        the long way costs a full ASR pass and reports it as `merge exited 2`.
        """
        with meeting(**{pipeline.RAW_TRANSCRIPT_NAME: "# transcript\n"}) as root:
            report, rec = run(root, force=True)

        self.assertEqual(report["status"], pipeline.STATUS_REFUSED)
        self.assertEqual(pipeline.exit_code(report), pipeline.EXIT_USAGE)
        self.assertEqual(rec.calls, [], "nothing may run before the refusal")
        # Both escapes are named, and both have to be ones that actually clear the
        # refusal — see test_replace_transcript_clears_the_refusal.
        self.assertIn("--replace-transcript", report["detail"])
        self.assertIn("--from-stage speakers", report["detail"])
        for entry in report["stages"]:
            self.assertEqual(entry["status"], pipeline.STATUS_SKIPPED)

    def test_replace_transcript_clears_the_refusal_and_forces_merge(self):
        """The refusal's escape must be one command, not an unreachable loop.

        `merge.py --force` by hand did not clear it: the upstream stage is still
        stale (by mtime, or by a changed --num-speakers), so the next pipeline run
        refused identically and the documented advice never converged. That made
        --num-speakers unappliable to any meeting processed once.
        """
        with meeting(**{pipeline.RAW_TRANSCRIPT_NAME: "# transcript\n"}) as root:
            report, rec = run(root, force=True, replace_transcript=True)

        self.assertEqual(report["status"], pipeline.STATUS_OK)
        self.assertIn("merge", rec.stages)
        self.assertEqual(rec.argv_for("merge"), [str(root), "--force"])

    def test_merge_is_never_forced_without_the_flag(self):
        with meeting() as root:
            _, rec = run(root, force=True)

        self.assertEqual(rec.argv_for("merge"), [str(root)])

    def test_force_still_runs_merge_when_there_is_no_transcript_yet(self):
        with meeting() as root:
            _, rec = run(root, force=True)

        self.assertIn("merge", rec.stages)

    def test_a_stale_transcript_is_refused_before_the_asr_pass(self):
        # The re-diarization case: diarization.json is newer than the
        # transcript, so merge is genuinely stale — and would still refuse.
        with meeting() as root:
            touch(root / pipeline.WORK_DIRNAME / "transcribe.json", 1000)
            touch(root / pipeline.DIARIZATION_JSON_NAME, 3000)
            touch(root / pipeline.RAW_TRANSCRIPT_NAME, 2000)

            self.assertFalse(pipeline.is_fresh(root, "merge"))
            report, rec = run(root)

        self.assertEqual(report["status"], pipeline.STATUS_REFUSED)
        self.assertEqual(rec.calls, [])

    def test_a_fresh_transcript_is_not_refused(self):
        with meeting() as root:
            touch(root / pipeline.WORK_DIRNAME / "transcribe.json", 1000)
            touch(root / pipeline.DIARIZATION_JSON_NAME, 1000)
            touch(root / pipeline.RAW_TRANSCRIPT_NAME, 3000)

            report, rec = run(root)

        self.assertNotEqual(report["status"], pipeline.STATUS_REFUSED)
        self.assertNotIn("merge", rec.stages)  # skipped as fresh, not refused

    def test_a_stale_upstream_refuses_before_burning_the_asr_pass(self):
        """The refusal has to be predictive, not a snapshot.

        Re-recording `mic.wav` leaves `transcript.raw.md` newer than
        transcribe.json/diarization.json, so "is merge fresh right now" said yes
        — and the run spent the whole prep+ASR+diarization pass only to have
        merge refuse (exit 2) on a transcript it was never allowed to replace,
        with stages 1-4 already rewritten to disagree with it.
        """
        with meeting() as root:
            work = root / pipeline.WORK_DIRNAME
            touch(root / "mic.wav", 5000)  # re-recorded
            touch(root / "system.wav", 1000)
            for name in ("prep_audio.json", "gate.json", "transcribe.json", "merge.json"):
                touch(work / name, 2000)
            for track in ("mic", "system"):
                touch(work / f"{track}{pipeline.INPUT_SUFFIX}", 2000)
            touch(root / pipeline.DIARIZATION_JSON_NAME, 2000)
            touch(root / pipeline.RAW_TRANSCRIPT_NAME, 3000)

            report, rec = run(root)

        self.assertEqual(report["status"], pipeline.STATUS_REFUSED)
        self.assertEqual(pipeline.exit_code(report), pipeline.EXIT_USAGE)
        self.assertEqual(rec.stages, [])  # nothing executed
        self.assertIn("--from-stage speakers", report["detail"])

    def test_a_teams_folder_refuses_before_running_anything(self):
        """A folder holding only transcript.raw.md is the Teams path.

        merge's inputs never existed there, so freshness-by-mtime called merge
        fresh and the full ASR chain ran before merge exited 2.
        """
        with meeting(**{pipeline.RAW_TRANSCRIPT_NAME: "# transcript\n"}) as root:
            report, rec = run(root)

        self.assertEqual(report["status"], pipeline.STATUS_REFUSED)
        self.assertEqual(rec.stages, [])

    def test_resuming_from_speakers_is_never_refused(self):
        # The documented way past the refusal: keep the transcript, resume.
        with meeting(**{pipeline.RAW_TRANSCRIPT_NAME: "# transcript\n"}) as root:
            report, rec = run(root, from_stage="speakers", force=True)

        self.assertEqual(report["status"], pipeline.STATUS_OK)
        self.assertIn("speakers", rec.stages)

    def test_doctor_takes_no_meeting_dir_and_no_json(self):
        # Not just "no meeting dir": no --json either. Stages are driven
        # in-process and share this process's stdout, so a doctor asked for JSON
        # puts a second document in front of the run JSON and `--json | jq`
        # stops parsing. The driver only ever reads doctor's exit code.
        with meeting() as root:
            _, rec = run(root)
        self.assertEqual(rec.argv_for("doctor"), [])


# --- doctor abort ------------------------------------------------------------


class DoctorTests(unittest.TestCase):
    def test_red_doctor_aborts_before_any_ml_work(self):
        with meeting() as root:
            report, rec = run(root, recorder=Recorder({"doctor": 1}))

        self.assertEqual(report["status"], pipeline.STATUS_FAILED)
        self.assertEqual(rec.stages, ["doctor"])
        self.assertEqual(report["stages"][0]["status"], pipeline.STATUS_FAILED)
        self.assertEqual(pipeline.exit_code(report), pipeline.EXIT_FAILED)

    def test_unreached_stages_are_recorded_as_not_reached(self):
        with meeting() as root:
            report, _ = run(root, recorder=Recorder({"doctor": 1}))

        rest = {e["stage"]: e for e in report["stages"] if e["stage"] != "doctor"}
        self.assertEqual(set(rest), set(pipeline.STAGES) - {"doctor"})
        for entry in rest.values():
            self.assertEqual(entry["status"], pipeline.STATUS_SKIPPED)
            self.assertEqual(entry["detail"], "not reached")


# --- silent tracks -----------------------------------------------------------


class UnderLevelledTrackTests(unittest.TestCase):
    """A quiet track is re-levelled and transcribed — never dropped.

    Regression, 2026-08-03: the mic was ~30 dB below the system track, gated as
    ``effectively_silent``, was dropped from the ASR pass, and the run reported
    OK with one side of the conversation missing.
    """

    def _gate_writer(self, root, sequence):
        """Write a different gate.json on each successive `gate` call."""
        state = {"n": 0}
        path = root / pipeline.WORK_DIRNAME / pipeline.GATE_JSON_NAME

        def write(call):
            payload = sequence[min(state["n"], len(sequence) - 1)]
            path.write_text(payload, encoding="utf-8")
            state["n"] += 1

        return write

    def test_a_quiet_mic_is_relevelled_and_still_transcribed(self):
        with meeting() as root:
            rec = Recorder(
                side_effects={
                    "gate": self._gate_writer(
                        root,
                        [gate_json(quiet=("mic",)), gate_json()],
                    )
                }
            )
            report, rec = run(root, recorder=rec)

        gate_entry = next(e for e in report["stages"] if e["stage"] == "gate")
        argvs = [c["argv"] for c in gate_entry["calls"]]
        # S1 re-run for the quiet track only, at loudnorm, forced past the
        # mtime-freshness check, then a full re-gate.
        self.assertIn(
            [str(root), "--track", "mic", "--chain", "loudnorm", "--force"], argvs
        )
        self.assertEqual(report["relevelled_tracks"], ["mic"])
        self.assertEqual(report["under_levelled_tracks"], [])
        # The stage detail counts the re-level calls it actually made.
        self.assertIn("3 call(s) ok", gate_entry["detail"])
        self.assertIn("re-levelled mic", gate_entry["detail"])
        # The point of all of it: the track reaches ASR.
        self.assertEqual(
            rec.argv_for("transcribe"),
            [str(root), "--track", "mic", "--track", "system"],
        )
        self.assertEqual(report["silent_tracks"], [])
        self.assertEqual(report["status"], pipeline.STATUS_OK)

    def test_a_quiet_track_is_never_in_silent_tracks(self):
        files = {
            f"{pipeline.WORK_DIRNAME}/{pipeline.GATE_JSON_NAME}": gate_json(
                quiet=("mic",)
            )
        }
        with meeting(**files) as root:
            report, rec = run(root, only=("transcribe",))

        self.assertEqual(report["silent_tracks"], [])
        self.assertEqual(report["under_levelled_tracks"], ["mic"])
        self.assertEqual(
            rec.argv_for("transcribe"),
            [str(root), "--track", "mic", "--track", "system"],
        )

    def test_a_track_loudnorm_cannot_rescue_is_reported_not_hidden(self):
        with meeting() as root:
            rec = Recorder(
                side_effects={
                    "gate": self._gate_writer(root, [gate_json(quiet=("mic",))])
                }
            )
            report, rec = run(root, recorder=rec)

        # One remediation pass only — no loop.
        gate_entry = next(e for e in report["stages"] if e["stage"] == "gate")
        prep_calls = [c for c in gate_entry["calls"] if c["script"] == "prep_audio"]
        self.assertEqual(len(prep_calls), 1)
        self.assertEqual(report["under_levelled_tracks"], ["mic"])
        self.assertIn("still under-levelled", gate_entry["relevel_detail"])
        self.assertIn("still under-levelled", pipeline.render_human(report))

    def test_a_failed_relevel_is_recorded_rather_than_claimed(self):
        with meeting() as root:
            rec = Recorder(
                codes={"prep_audio": 1},
                side_effects={
                    "gate": self._gate_writer(root, [gate_json(quiet=("mic",))])
                },
            )
            report, rec = run(root, recorder=rec, from_stage="gate")

        gate_entry = next(e for e in report["stages"] if e["stage"] == "gate")
        self.assertEqual(gate_entry["relevelled_tracks"], [])
        self.assertIn("could not re-level", gate_entry["relevel_detail"])

    def test_a_healthy_run_does_no_relevelling(self):
        with meeting() as root:
            rec = Recorder(
                side_effects={"gate": self._gate_writer(root, [gate_json()])}
            )
            report, rec = run(root, recorder=rec)

        gate_entry = next(e for e in report["stages"] if e["stage"] == "gate")
        self.assertEqual(gate_entry["calls"], [{"script": "gate", "argv": [str(root)], "exit_code": 0}])
        self.assertEqual(report["relevelled_tracks"], [])


class SilentTrackTests(unittest.TestCase):
    def test_silent_mic_is_dropped_from_transcribe(self):
        with meeting() as root:
            rec = Recorder(
                side_effects={
                    "gate": lambda call: (
                        root / pipeline.WORK_DIRNAME / pipeline.GATE_JSON_NAME
                    ).write_text(gate_json(silent=("mic",)), encoding="utf-8")
                }
            )
            report, rec = run(root, recorder=rec)

        self.assertEqual(rec.argv_for("transcribe"), [str(root), "--track", "system"])
        entry = next(e for e in report["stages"] if e["stage"] == "transcribe")
        self.assertEqual(entry["skipped_tracks"], ["mic"])
        self.assertEqual(report["silent_tracks"], ["mic"])
        # A silent mic does not stop the run — diarization still happens.
        self.assertIn("diarize", rec.stages)
        self.assertEqual(report["status"], pipeline.STATUS_OK)

    def test_silent_system_skips_diarization_with_a_reason(self):
        with meeting() as root:
            rec = Recorder(
                side_effects={
                    "gate": lambda call: (
                        root / pipeline.WORK_DIRNAME / pipeline.GATE_JSON_NAME
                    ).write_text(gate_json(silent=("system",)), encoding="utf-8")
                }
            )
            report, rec = run(root, recorder=rec)

        self.assertNotIn("diarize", rec.stages)
        entry = next(e for e in report["stages"] if e["stage"] == "diarize")
        self.assertEqual(entry["status"], pipeline.STATUS_SKIPPED)
        self.assertIn("effectively silent", entry["detail"])

    def test_every_track_silent_stops_before_asr(self):
        with meeting() as root:
            rec = Recorder(
                side_effects={
                    "gate": lambda call: (
                        root / pipeline.WORK_DIRNAME / pipeline.GATE_JSON_NAME
                    ).write_text(
                        gate_json(silent=("mic", "system")), encoding="utf-8"
                    )
                }
            )
            report, rec = run(root, recorder=rec)

        self.assertEqual(rec.stages, ["doctor", "prep_audio", "gate"])
        self.assertEqual(report["status"], pipeline.STATUS_SILENT)
        entry = next(e for e in report["stages"] if e["stage"] == "transcribe")
        self.assertEqual(entry["status"], pipeline.STATUS_SKIPPED)
        self.assertIn("silent", entry["detail"])
        self.assertEqual(pipeline.exit_code(report), pipeline.EXIT_FAILED)

    def test_silent_tracks_read_from_a_pre_existing_gate_json(self):
        files = {f"{pipeline.WORK_DIRNAME}/{pipeline.GATE_JSON_NAME}": gate_json(
            silent=("mic",)
        )}
        with meeting(**files) as root:
            report, rec = run(root, only=("transcribe",))

        self.assertEqual(report["silent_tracks"], ["mic"])
        self.assertEqual(rec.argv_for("transcribe"), [str(root), "--track", "system"])

    def test_gate_json_without_silent_tracks_key_falls_back_to_entries(self):
        payload = json.dumps(
            {
                "stage": "gate",
                "tracks": [
                    {"track": "mic", "effectively_silent": True},
                    {"track": "system", "effectively_silent": False},
                ],
            }
        )
        with meeting(**{f"{pipeline.WORK_DIRNAME}/{pipeline.GATE_JSON_NAME}": payload}) as root:
            self.assertEqual(pipeline.read_silent_tracks(root), ["mic"])

    def test_missing_or_broken_gate_json_means_no_silent_tracks(self):
        with meeting() as root:
            self.assertEqual(pipeline.read_silent_tracks(root), [])
        with meeting(**{f"{pipeline.WORK_DIRNAME}/{pipeline.GATE_JSON_NAME}": "{not json"}) as root:
            self.assertEqual(pipeline.read_silent_tracks(root), [])

    def test_a_mic_only_recording_skips_diarize_and_finishes(self):
        """An *absent* system track, not a silent one — the other D5 shape.

        prep_audio, gate and transcribe all treat a missing track as `ok` with a
        `missing` entry, but diarize returned `missing` → exit 1, so the driver
        dead-ended at S4. That made both mic-only branches downstream
        (verify.coverage_skip_reason, speakers.provenance_note) unreachable, while
        the near-identical *silent*-system meeting ran end to end.
        """
        with meeting(**{f"mic{pipeline.TRACK_SUFFIX}": "RIFF"}) as root:
            report, rec = run(root)

        self.assertNotIn("diarize", rec.stages)
        entry = next(e for e in report["stages"] if e["stage"] == "diarize")
        self.assertEqual(entry["status"], pipeline.STATUS_SKIPPED)
        self.assertIn("mic-only", entry["detail"])
        # The whole point: the rest of the chain still runs.
        self.assertIn("merge", rec.stages)
        self.assertIn("verify", rec.stages)
        self.assertEqual(report["status"], pipeline.STATUS_OK)

    def test_a_two_track_recording_still_diarizes(self):
        files = {
            f"mic{pipeline.TRACK_SUFFIX}": "RIFF",
            f"system{pipeline.TRACK_SUFFIX}": "RIFF",
        }
        with meeting(**files) as root:
            _, rec = run(root)

        self.assertIn("diarize", rec.stages)

    def test_a_system_only_recording_still_diarizes(self):
        """The skip is keyed on "mic-only", not on "no system source".

        A folder with a system track and no mic is not the D5 case and must not
        borrow its skip.
        """
        with meeting(**{f"system{pipeline.TRACK_SUFFIX}": "RIFF"}) as root:
            _, rec = run(root)

        self.assertIn("diarize", rec.stages)


# --- stage skipping ----------------------------------------------------------


class FreshnessTests(unittest.TestCase):
    def test_fresh_stage_is_skipped(self):
        with meeting() as root:
            work = root / pipeline.WORK_DIRNAME
            touch(root / "mic.wav", 1000)
            touch(root / "system.wav", 1000)
            touch(work / "prep_audio.json", 2000)
            touch(work / f"mic{pipeline.INPUT_SUFFIX}", 2000)
            touch(work / f"system{pipeline.INPUT_SUFFIX}", 2000)

            report, rec = run(root, only=("prep_audio",))

        self.assertEqual(rec.stages, [])
        entry = report["stages"][0]
        self.assertEqual(entry["status"], pipeline.STATUS_SKIPPED)
        self.assertIn("fresh", entry["detail"])

    def test_stale_output_is_rerun(self):
        with meeting() as root:
            work = root / pipeline.WORK_DIRNAME
            touch(work / "prep_audio.json", 1000)
            touch(root / "mic.wav", 2000)
            touch(root / "system.wav", 2000)

            _, rec = run(root, only=("prep_audio",))

        self.assertEqual(rec.stages, ["prep_audio"])

    def test_force_reruns_a_fresh_stage(self):
        with meeting() as root:
            work = root / pipeline.WORK_DIRNAME
            touch(root / "mic.wav", 1000)
            touch(work / "prep_audio.json", 2000)
            touch(work / f"mic{pipeline.INPUT_SUFFIX}", 2000)

            _, rec = run(root, only=("prep_audio",), force=True)

        self.assertEqual(rec.stages, ["prep_audio"])

    def test_cleaning_up_the_wavs_makes_prep_audio_stale(self):
        """`--cleanup-wavs` deletes prep_audio's real product.

        With only the JSON in `stage_outputs`, a cleaned-up meeting reported
        prep_audio and gate as fresh with no wav on disk, and the next stage
        that needed one died with "run prep_audio.py first".
        """
        with meeting() as root:
            work = root / pipeline.WORK_DIRNAME
            touch(root / "mic.wav", 1000)
            touch(root / "system.wav", 1000)
            touch(work / "prep_audio.json", 2000)
            for track in ("mic", "system"):
                touch(work / f"{track}{pipeline.INPUT_SUFFIX}", 2000)

            self.assertTrue(pipeline.is_fresh(root, "prep_audio"))
            pipeline.cleanup_intermediates(root)
            self.assertFalse(pipeline.is_fresh(root, "prep_audio"))

    def test_a_single_track_meeting_still_caches(self):
        """Only tracks with a source are required, so mic-only stays fresh."""
        with meeting() as root:
            work = root / pipeline.WORK_DIRNAME
            touch(root / "mic.wav", 1000)
            touch(work / "prep_audio.json", 2000)
            touch(work / f"mic{pipeline.INPUT_SUFFIX}", 2000)

            self.assertTrue(pipeline.is_fresh(root, "prep_audio"))

    def test_a_recorded_stage_failure_is_never_a_cache_hit(self):
        """The silent-data-loss case: transcribe fails on `system` only.

        `transcribe.json` still holds the mic words, so an mtime-only freshness
        rule skipped the stage on the next run, merge saw no system words, and
        the run ended green with half the meeting missing.
        """
        with meeting() as root:
            work = root / pipeline.WORK_DIRNAME
            touch(work / f"mic{pipeline.INPUT_SUFFIX}", 1000)
            touch(work / f"system{pipeline.INPUT_SUFFIX}", 1000)
            (work / "transcribe.json").write_text(
                json.dumps({"status": "failed", "tracks": []}), encoding="utf-8"
            )
            self.assertFalse(pipeline.is_fresh(root, "transcribe"))

            (work / "transcribe.json").write_text(
                json.dumps({"status": "ok", "tracks": []}), encoding="utf-8"
            )
            touch(work / "transcribe.json", 2000)
            self.assertTrue(pipeline.is_fresh(root, "transcribe"))

    def test_verify_is_never_fresh(self):
        with meeting() as root:
            touch(root / pipeline.LABELED_TRANSCRIPT_NAME, 2000)
            touch(root / pipeline.WORK_DIRNAME / "verify.json", 3000)
            touch(root / pipeline.WORK_DIRNAME / pipeline.QUALITY_MD_NAME, 3000)

            self.assertFalse(pipeline.is_fresh(root, "verify"))
            _, rec = run(root, only=("verify",))

        self.assertEqual(rec.stages, ["verify"])

    def test_doctor_is_never_fresh(self):
        with meeting() as root:
            self.assertFalse(pipeline.is_fresh(root, "doctor"))

    def test_speakers_needs_both_outputs_to_be_fresh(self):
        with meeting() as root:
            touch(root / pipeline.RAW_TRANSCRIPT_NAME, 1000)
            touch(root / pipeline.SPEAKERS_JSON_NAME, 2000)
            self.assertFalse(pipeline.is_fresh(root, "speakers"))

            touch(root / pipeline.LABELED_TRANSCRIPT_NAME, 2000)
            self.assertTrue(pipeline.is_fresh(root, "speakers"))

    def test_a_map_newer_than_the_labelled_transcript_is_not_fresh(self):
        """The half-stale `speakers` stage.

        `build` derives speakers.json from transcript.raw.md and `apply` derives
        transcript.labeled.md from speakers.json. With only the raw transcript
        listed as an input, both outputs were newer than it and the stage was
        skipped — so a speakers.json that changed after `apply` ran left
        transcript.labeled.md silently carrying the previous map's names.
        """
        with meeting() as root:
            touch(root / pipeline.RAW_TRANSCRIPT_NAME, 1000)
            touch(root / pipeline.SPEAKERS_JSON_NAME, 2000)
            touch(root / pipeline.LABELED_TRANSCRIPT_NAME, 3000)
            self.assertTrue(pipeline.is_fresh(root, "speakers"))

            touch(root / pipeline.SPEAKERS_JSON_NAME, 4000)
            self.assertFalse(pipeline.is_fresh(root, "speakers"))

    def test_a_hand_edited_map_is_reapplied_not_rebuilt(self):
        """`build` would overwrite the correction it is re-running because of."""
        with meeting() as root:
            touch(root / pipeline.RAW_TRANSCRIPT_NAME, 1000)
            touch(root / pipeline.LABELED_TRANSCRIPT_NAME, 3000)
            touch(root / pipeline.SPEAKERS_JSON_NAME, 4000)

            self.assertTrue(pipeline.labeling_only_stale(root))
            report, rec = run(root, only=("speakers",))

        self.assertEqual([call["argv"][0] for call in rec.calls], ["apply"])
        entry = report["stages"][0]
        self.assertTrue(entry["apply_only"])
        self.assertIn("re-applied", entry["detail"])

    def test_a_stale_map_rebuilds_before_applying(self):
        """A raw transcript newer than the map invalidates the map itself."""
        with meeting() as root:
            touch(root / pipeline.SPEAKERS_JSON_NAME, 1000)
            touch(root / pipeline.LABELED_TRANSCRIPT_NAME, 1000)
            touch(root / pipeline.RAW_TRANSCRIPT_NAME, 2000)

            self.assertFalse(pipeline.labeling_only_stale(root))
            report, rec = run(root, only=("speakers",))

        self.assertEqual([call["argv"][0] for call in rec.calls], ["build", "apply"])
        self.assertNotIn("apply_only", report["stages"][0])

    def test_a_missing_labelled_transcript_is_applied_from_the_existing_map(self):
        with meeting() as root:
            touch(root / pipeline.RAW_TRANSCRIPT_NAME, 1000)
            touch(root / pipeline.SPEAKERS_JSON_NAME, 2000)

            self.assertTrue(pipeline.labeling_only_stale(root))
            _, rec = run(root, only=("speakers",))

        self.assertEqual([call["argv"][0] for call in rec.calls], ["apply"])

    def test_changed_attendees_rebuild_the_map_even_when_only_labelling_is_behind(self):
        """`--attendees` is a build input, so it outranks the apply-only shortcut."""
        with meeting() as root:
            touch(root / pipeline.RAW_TRANSCRIPT_NAME, 1000)
            touch(root / pipeline.LABELED_TRANSCRIPT_NAME, 3000)
            (root / pipeline.SPEAKERS_JSON_NAME).write_text(
                json.dumps({"attendees": ["Дмитрий"]}), encoding="utf-8"
            )
            touch(root / pipeline.SPEAKERS_JSON_NAME, 4000)

            params = {"attendees": ["Дмитрий", "Любовь"]}
            self.assertFalse(pipeline.labeling_only_stale(root, params))
            _, rec = run(root, only=("speakers",), attendees=("Дмитрий", "Любовь"))

        self.assertEqual([call["argv"][0] for call in rec.calls], ["build", "apply"])

    def test_a_map_built_with_attendees_is_reapplied_by_the_documented_rerun(self):
        """The regression the apply-only path exists for, on its real command.

        SKILL.md documents the recovery as the bare
        `pipeline.py <meeting> --from-stage speakers`. The map on disk was built
        by a first run that *did* pass `--attendees`, so reading the absent flag
        as "attendees dropped" made the stage rebuild — over the hand correction
        it was re-running because of.
        """
        with meeting() as root:
            touch(root / pipeline.RAW_TRANSCRIPT_NAME, 1000)
            touch(root / pipeline.LABELED_TRANSCRIPT_NAME, 3000)
            (root / pipeline.SPEAKERS_JSON_NAME).write_text(
                speakers_json(["Дмитрий Иванов", "Любовь Кузнецова"]),
                encoding="utf-8",
            )
            touch(root / pipeline.SPEAKERS_JSON_NAME, 4000)

            self.assertTrue(pipeline.labeling_only_stale(root, {"attendees": []}))
            report, rec = run(root, from_stage="speakers")

        speakers = [call for call in rec.calls if call["stage"] == "speakers"]
        self.assertEqual([call["argv"][0] for call in speakers], ["apply"])
        self.assertTrue(report["stages"][0]["apply_only"])

    def test_force_rebuilds_the_map_rather_than_only_reapplying_it(self):
        with meeting() as root:
            touch(root / pipeline.RAW_TRANSCRIPT_NAME, 1000)
            touch(root / pipeline.LABELED_TRANSCRIPT_NAME, 3000)
            touch(root / pipeline.SPEAKERS_JSON_NAME, 4000)

            _, rec = run(root, only=("speakers",), force=True)

        self.assertEqual([call["argv"][0] for call in rec.calls], ["build", "apply"])

    def test_an_output_whose_inputs_are_all_gone_is_not_fresh(self):
        """An orphan is not a cache hit.

        The case that made this matter is the Teams path: a folder holding only
        `transcript.raw.md` has no transcribe.json/diarization.json behind it,
        and calling merge "fresh" there let the whole ASR chain run before merge
        refused (exit 2) on the transcript it was never going to replace.
        """
        with meeting() as root:
            touch(root / pipeline.DIARIZATION_JSON_NAME, 2000)
            self.assertFalse(pipeline.is_fresh(root, "diarize"))

            touch(root / pipeline.WORK_DIRNAME / f"system{pipeline.INPUT_SUFFIX}", 1000)
            self.assertTrue(pipeline.is_fresh(root, "diarize"))

    def test_a_rediarization_makes_merge_stale(self):
        """The bug this pins: diarization.json lives at the meeting root, so a
        re-diarization must invalidate transcript.raw.md. When merge reads it
        from the wrong directory, the driver skips merge as fresh and leaves a
        transcript whose speaker assignment belongs to the previous run."""
        with meeting() as root:
            touch(root / pipeline.WORK_DIRNAME / "transcribe.json", 1000)
            touch(root / pipeline.DIARIZATION_JSON_NAME, 1000)
            touch(root / pipeline.RAW_TRANSCRIPT_NAME, 2000)
            self.assertTrue(pipeline.is_fresh(root, "merge"))

            touch(root / pipeline.DIARIZATION_JSON_NAME, 3000)
            self.assertFalse(pipeline.is_fresh(root, "merge"))

    def test_a_second_run_skips_diarize_and_speakers(self):
        """Both stages write to the meeting root; neither may re-run for free."""
        with meeting() as root:
            touch(root / pipeline.WORK_DIRNAME / f"system{pipeline.INPUT_SUFFIX}", 1000)
            touch(root / pipeline.DIARIZATION_JSON_NAME, 2000)
            touch(root / pipeline.RAW_TRANSCRIPT_NAME, 2000)
            touch(root / pipeline.SPEAKERS_JSON_NAME, 3000)
            touch(root / pipeline.LABELED_TRANSCRIPT_NAME, 3000)

            self.assertTrue(pipeline.is_fresh(root, "diarize"))
            self.assertTrue(pipeline.is_fresh(root, "speakers"))


# --- verify's verdict --------------------------------------------------------


class VerifyTests(unittest.TestCase):
    def test_verify_failure_propagates_and_keeps_artifacts(self):
        # `--from-stage speakers` because a full run over a folder holding only
        # transcript.raw.md is the merge refusal, tested separately.
        with meeting(**{pipeline.RAW_TRANSCRIPT_NAME: "# transcript\n"}) as root:
            report, rec = run(
                root, from_stage="speakers", recorder=Recorder({"verify": 1})
            )

            self.assertEqual(report["status"], pipeline.STATUS_FAILED)
            self.assertEqual(pipeline.exit_code(report), pipeline.EXIT_FAILED)
            self.assertTrue((root / pipeline.RAW_TRANSCRIPT_NAME).is_file())

        entry = next(e for e in report["stages"] if e["stage"] == "verify")
        self.assertEqual(entry["status"], pipeline.STATUS_FAILED)
        self.assertTrue(pipeline.verify_failed(report))
        self.assertEqual(rec.stages[-1], "verify")

    def test_quality_block_goes_to_stderr_on_a_tripped_gate(self):
        files = {
            pipeline.RAW_TRANSCRIPT_NAME: "# transcript\n",
            f"{pipeline.WORK_DIRNAME}/{pipeline.QUALITY_MD_NAME}": "⚠ повтор фразы\n",
        }
        with meeting(**files) as root:
            err = io.StringIO()
            out = io.StringIO()
            with contextlib.redirect_stderr(err), contextlib.redirect_stdout(out):
                code = pipeline.main(
                    [str(root), "--from-stage", "speakers"],
                    runner=Recorder({"verify": 1}),
                    clock=Clock(),
                )

        self.assertEqual(code, pipeline.EXIT_FAILED)
        self.assertIn("⚠ повтор фразы", err.getvalue())

    def test_no_stale_quality_block_when_an_earlier_stage_failed(self):
        files = {
            f"{pipeline.WORK_DIRNAME}/{pipeline.QUALITY_MD_NAME}": "⚠ старый прогон\n",
        }
        with meeting(**files) as root:
            err = io.StringIO()
            out = io.StringIO()
            with contextlib.redirect_stderr(err), contextlib.redirect_stdout(out):
                code = pipeline.main(
                    [str(root)], runner=Recorder({"merge": 1}), clock=Clock()
                )

        self.assertEqual(code, pipeline.EXIT_FAILED)
        self.assertNotIn("старый прогон", err.getvalue())

    def test_speakers_apply_is_skipped_when_build_fails(self):
        with meeting() as root:
            report, rec = run(root, recorder=Recorder({("speakers", "build"): 1}))

        modes = [c["argv"][0] for c in rec.calls if c["stage"] == "speakers"]
        self.assertEqual(modes, ["build"])
        self.assertNotIn("verify", rec.stages)
        self.assertEqual(report["status"], pipeline.STATUS_FAILED)


# --- cleanup -----------------------------------------------------------------


class CleanupTests(unittest.TestCase):
    def test_cleanup_removes_intermediates_after_a_green_run(self):
        with meeting() as root:
            work = root / pipeline.WORK_DIRNAME
            touch(work / f"mic{pipeline.INPUT_SUFFIX}", 1000)
            touch(work / f"system{pipeline.INPUT_SUFFIX}", 1000)

            report, _ = run(root, cleanup_wavs=True)

            self.assertFalse((work / f"mic{pipeline.INPUT_SUFFIX}").exists())
            self.assertFalse((work / f"system{pipeline.INPUT_SUFFIX}").exists())

        self.assertEqual(
            report["cleanup"]["removed"],
            [f"mic{pipeline.INPUT_SUFFIX}", f"system{pipeline.INPUT_SUFFIX}"],
        )

    def test_cleanup_suppressed_after_a_failed_gate(self):
        with meeting() as root:
            work = root / pipeline.WORK_DIRNAME
            touch(work / f"system{pipeline.INPUT_SUFFIX}", 1000)

            report, _ = run(root, cleanup_wavs=True, recorder=Recorder({"verify": 1}))

            self.assertTrue((work / f"system{pipeline.INPUT_SUFFIX}").exists())

        self.assertEqual(report["cleanup"]["removed"], [])
        self.assertIn("re-run", report["cleanup"]["detail"])

    def test_no_cleanup_without_the_flag(self):
        with meeting() as root:
            work = root / pipeline.WORK_DIRNAME
            touch(work / f"mic{pipeline.INPUT_SUFFIX}", 1000)

            report, _ = run(root)

            self.assertTrue((work / f"mic{pipeline.INPUT_SUFFIX}").exists())
        self.assertFalse(report["cleanup"]["requested"])

    def test_cleanup_suppressed_when_the_run_never_reached_verify(self):
        """A green *selection* is not a verified meeting.

        `--only doctor --cleanup-wavs` and `--only prep_audio --cleanup-wavs` both
        ended green with no gate evaluated, and deleted ~230 MB/h of intermediates
        off a meeting nothing had checked — including, in the prep_audio case, the
        wavs that same invocation had just produced.
        """
        for only in (("doctor",), ("prep_audio",)):
            with self.subTest(only=only):
                with meeting() as root:
                    work = root / pipeline.WORK_DIRNAME
                    touch(work / f"mic{pipeline.INPUT_SUFFIX}", 1000)

                    report, _ = run(root, only=only, cleanup_wavs=True)

                    self.assertTrue((work / f"mic{pipeline.INPUT_SUFFIX}").exists())

                self.assertEqual(report["status"], pipeline.STATUS_OK)
                self.assertEqual(report["cleanup"]["removed"], [])
                self.assertIn("verify", report["cleanup"]["detail"])

    def test_cleanup_runs_when_verify_is_selected_and_passes(self):
        with meeting() as root:
            work = root / pipeline.WORK_DIRNAME
            touch(work / f"mic{pipeline.INPUT_SUFFIX}", 1000)

            report, _ = run(root, only=("verify",), cleanup_wavs=True)

            self.assertFalse((work / f"mic{pipeline.INPUT_SUFFIX}").exists())
        self.assertEqual(report["cleanup"]["removed"], [f"mic{pipeline.INPUT_SUFFIX}"])


# --- CLI ---------------------------------------------------------------------


class CliTests(unittest.TestCase):
    def test_run_json_written_and_shaped(self):
        with meeting() as root:
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                code = pipeline.main(
                    [str(root), "--num-speakers", "3", "--json"],
                    runner=Recorder(),
                    clock=Clock(),
                )
            written = json.loads(
                pipeline.run_json_path(root).read_text(encoding="utf-8")
            )

        self.assertEqual(code, pipeline.EXIT_OK)
        self.assertEqual(written["stage"], "pipeline")
        self.assertEqual(written["num_speakers"], 3)
        self.assertEqual(written["selected_stages"], list(pipeline.STAGES))
        self.assertEqual(written["status"], pipeline.STATUS_OK)
        self.assertEqual(json.loads(out.getvalue())["status"], pipeline.STATUS_OK)

    def test_run_json_written_on_failure_too(self):
        with meeting() as root:
            out = io.StringIO()
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
                code = pipeline.main(
                    [str(root)], runner=Recorder({"doctor": 1}), clock=Clock()
                )
            written = json.loads(
                pipeline.run_json_path(root).read_text(encoding="utf-8")
            )

        self.assertEqual(code, pipeline.EXIT_FAILED)
        self.assertEqual(written["status"], pipeline.STATUS_FAILED)

    def test_missing_meeting_folder_is_a_usage_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            err = io.StringIO()
            with contextlib.redirect_stderr(err), self.assertRaises(SystemExit) as ctx:
                pipeline.main([str(Path(tmp) / "nope")], runner=Recorder())
        self.assertEqual(ctx.exception.code, pipeline.EXIT_USAGE)

    def test_from_stage_and_only_together_is_a_usage_error(self):
        with meeting() as root:
            err = io.StringIO()
            with contextlib.redirect_stderr(err), self.assertRaises(SystemExit) as ctx:
                pipeline.main(
                    [str(root), "--from-stage", "merge", "--only", "verify"],
                    runner=Recorder(),
                )
        self.assertEqual(ctx.exception.code, pipeline.EXIT_USAGE)

    def test_human_output_lists_every_stage(self):
        with meeting() as root:
            report, _ = run(root)
        text = pipeline.render_human(report)
        for stage in pipeline.STAGES:
            self.assertIn(stage, text)

    def test_default_runner_maps_to_real_scripts(self):
        for stage in pipeline.STAGES:
            for call in pipeline.stage_calls(Path("/meeting"), stage):
                with self.subTest(stage=stage):
                    self.assertTrue(
                        (pipeline.SCRIPTS_DIR / f"{call['script']}.py").is_file(),
                        f"{stage} points at a script that does not exist",
                    )

    def test_default_runner_returns_the_scripts_exit_code(self):
        with meeting() as root:
            err = io.StringIO()
            out = io.StringIO()
            call = {
                "stage": "speakers",
                "script": "speakers",
                "argv": ["apply", str(root)],
            }
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                # No transcript.raw.md: speakers.py exits non-zero rather than
                # inventing one — the code must come back unchanged.
                code = pipeline.default_runner(call)

        self.assertNotEqual(code, 0)


# --- parameter-aware freshness -----------------------------------------------


def prep_audio_json(chain="denoise", tracks=("mic", "system")):
    return json.dumps(
        {
            "stage": "prep_audio",
            "status": "ok",
            "chain": chain,
            "tracks": [
                {"track": t, "status": "ok", "chain": chain} for t in tracks
            ],
        },
        ensure_ascii=False,
    )


def transcribe_json(language=None, custom_vocab=None):
    return json.dumps(
        {
            "stage": "transcribe",
            "status": "ok",
            "tracks": [
                {
                    "track": t,
                    "status": "ok",
                    "language": language,
                    "custom_vocab": custom_vocab,
                    "words": [],
                }
                for t in ("mic", "system")
            ],
        },
        ensure_ascii=False,
    )


def diarization_json(num_speakers=2):
    return json.dumps(
        {
            "stage": "diarize",
            "status": "ok",
            "parameters": {
                "control": "num-speakers" if num_speakers else "threshold",
                "num_speakers": num_speakers,
            },
        },
        ensure_ascii=False,
    )


def speakers_json(attendees=()):
    return json.dumps(
        {"schema": "acta-notes/speakers@1", "attendees": list(attendees)},
        ensure_ascii=False,
    )


class ParameterFreshnessTests(unittest.TestCase):
    """The driver decides freshness *before* calling a stage, so its cache has to
    know about parameters too — otherwise each stage's own guard never runs and a
    corrected flag is silently dropped on a green exit."""

    def test_changed_chain_reruns_prep_audio(self):
        work = pipeline.WORK_DIRNAME
        with meeting(**{f"{work}/prep_audio.json": prep_audio_json("denoise")}) as root:
            self.assertFalse(
                pipeline.is_fresh(root, "prep_audio", {"chain": "loudnorm"})
            )
            self.assertTrue(pipeline.parameters_changed(
                root, "prep_audio", {"chain": "loudnorm"}
            ))
            self.assertFalse(pipeline.parameters_changed(
                root, "prep_audio", {"chain": "denoise"}
            ))

    def test_changed_num_speakers_reruns_diarize(self):
        with meeting(**{"diarization.json": diarization_json(2)}) as root:
            self.assertTrue(pipeline.parameters_changed(
                root, "diarize", {"num_speakers": 6}
            ))
            self.assertFalse(pipeline.parameters_changed(
                root, "diarize", {"num_speakers": 2}
            ))

    def test_changed_attendees_reruns_speakers(self):
        with meeting(**{"speakers.json": speakers_json(["Иван"])}) as root:
            self.assertTrue(pipeline.parameters_changed(
                root, "speakers", {"attendees": ["Иван", "Мария"]}
            ))
            self.assertFalse(pipeline.parameters_changed(
                root, "speakers", {"attendees": ["Иван"]}
            ))

    def test_one_comma_joined_attendees_argument_still_matches(self):
        # speakers.json records the *parsed* list, so comparing the raw argv
        # against it would never match and the stage would re-run every time.
        artifact = speakers_json(["Дмитрий Иванов", "Любовь Кузнецова"])
        with meeting(**{"speakers.json": artifact}) as root:
            self.assertFalse(pipeline.parameters_changed(
                root,
                "speakers",
                {"attendees": ["Дмитрий Иванов, Любовь Кузнецова"]},
            ))
            self.assertTrue(pipeline.parameters_changed(
                root, "speakers", {"attendees": ["Дмитрий Иванов"]}
            ))

    def test_normalized_attendees_mirrors_the_owning_stage(self):
        # The mirror only holds if both sides agree; assert against speakers.py's
        # own parser rather than against a hand-written expectation.
        speakers = _ctx.load("speakers")
        for raw in (
            ["Дмитрий Иванов, Любовь Кузнецова"],
            ["Дмитрий Иванов", "Любовь Кузнецова"],
            ["  Дмитрий   Иванов  ,, Любовь Кузнецова "],
            ["Дми*трий Ива:нов"],
            ["Иван", "Иван"],
            [],
        ):
            with self.subTest(raw=raw):
                self.assertEqual(
                    pipeline.normalized_attendees(raw),
                    speakers.parse_attendees(raw),
                )

    def test_a_forwarded_attendees_flag_round_trips_through_build(self):
        # End to end: what the driver forwards, parsed by the stage, must compare
        # equal to what the driver normalises — otherwise speakers is never fresh.
        with meeting() as root:
            _, rec = run(root, attendees=("Дмитрий Иванов, Любовь Кузнецова",))
            build = rec.argv_for("speakers", 0)

        forwarded = [
            build[i + 1] for i, tok in enumerate(build) if tok == "--attendees"
        ]
        speakers = _ctx.load("speakers")
        self.assertEqual(
            speakers.parse_attendees(forwarded),
            pipeline.normalized_attendees(("Дмитрий Иванов, Любовь Кузнецова",)),
        )

    def test_changed_language_reruns_transcribe(self):
        work = pipeline.WORK_DIRNAME
        with meeting(**{f"{work}/transcribe.json": transcribe_json()}) as root:
            self.assertTrue(pipeline.parameters_changed(
                root, "transcribe", {"language": "ru"}
            ))
            self.assertFalse(pipeline.parameters_changed(
                root, "transcribe", {"language": None}
            ))

    def test_an_omitted_flag_expresses_no_opinion(self):
        """Not passing a flag means "re-use what is there", not "rebuild with the
        default" — that is what `--force` is for.

        The destructive case is `speakers`: the documented recovery for a
        hand-corrected map is the bare `pipeline.py --from-stage speakers`, and
        reading the absent `--attendees` as a change sent `speakers build` over
        the correction. `--num-speakers` and the ASR opt-ins are the same rule.
        """
        work = pipeline.WORK_DIRNAME
        files = {
            "speakers.json": speakers_json(["Иван", "Мария"]),
            "diarization.json": diarization_json(4),
            f"{work}/transcribe.json": transcribe_json(
                language="ru", custom_vocab="/tmp/vocab.txt"
            ),
            f"{work}/prep_audio.json": prep_audio_json("loudnorm"),
        }
        with meeting(**files) as root:
            for stage in ("speakers", "diarize", "transcribe", "prep_audio"):
                with self.subTest(stage=stage):
                    self.assertFalse(
                        pipeline.parameters_changed(
                            root,
                            stage,
                            {
                                "attendees": [],
                                "num_speakers": None,
                                "language": None,
                                "custom_vocab": None,
                                "chain": None,
                            },
                        )
                    )

    def test_dropping_one_asr_opt_in_is_not_a_change_to_the_other(self):
        work = pipeline.WORK_DIRNAME
        recorded = transcribe_json(language="ru", custom_vocab="/tmp/vocab.txt")
        with meeting(**{f"{work}/transcribe.json": recorded}) as root:
            # `--language ru` still matches; the dropped `--custom-vocab` says
            # nothing, so this is a cache hit.
            self.assertFalse(pipeline.parameters_changed(
                root, "transcribe", {"language": "ru", "custom_vocab": None}
            ))
            # A different language is still a change, dropped vocab or not.
            self.assertTrue(pipeline.parameters_changed(
                root, "transcribe", {"language": "en", "custom_vocab": None}
            ))

    def test_a_bare_rerun_after_a_flagged_one_neither_refuses_nor_rediarizes(self):
        """End to end, the second-order cost of reading omission as change.

        A bare `pipeline.py <meeting>` over a finished `--num-speakers 4` run made
        diarize "about to re-run", which makes `merge_would_refuse` fire — so the
        whole pipeline refused up front, blaming transcript.raw.md.
        """
        work = pipeline.WORK_DIRNAME
        with meeting(**{
            "diarization.json": diarization_json(4),
            f"{work}/{pipeline.GATE_JSON_NAME}": gate_json(),
            f"{work}/prep_audio.json": prep_audio_json(),
            f"{work}/transcribe.json": transcribe_json(),
        }) as root:
            for name in ("mic.m4a", "system.m4a"):
                touch(root / name, 1000)
            for name in ("mic", "system"):
                touch(root / work / f"{name}{pipeline.INPUT_SUFFIX}", 2000)
            for name in (
                "prep_audio.json",
                pipeline.GATE_JSON_NAME,
                "transcribe.json",
            ):
                touch(root / work / name, 3000)
            touch(root / "diarization.json", 3000)
            touch(root / pipeline.RAW_TRANSCRIPT_NAME, 4000)
            touch(root / pipeline.SPEAKERS_JSON_NAME, 5000)
            touch(root / pipeline.LABELED_TRANSCRIPT_NAME, 6000)

            report, rec = run(root)

        self.assertNotEqual(report["status"], pipeline.STATUS_REFUSED)
        self.assertNotIn("diarize", rec.stages)
        self.assertNotIn("merge", rec.stages)

    def test_the_cli_can_actually_express_an_omitted_chain(self):
        """`--chain` must have no argparse default, or the guard above is dead.

        Every other flag reaches `run()` as `None` when absent, and the omission
        rule keys on exactly that. A `default=DEFAULT_CHAIN` made the bare CLI
        re-run indistinguishable from an explicit `--chain denoise`, so the one
        documented re-run of a `--chain loudnorm` meeting read as a chain switch.
        """
        parsed = pipeline.build_parser().parse_args(["/tmp/meeting"])
        self.assertIsNone(parsed.chain)
        self.assertEqual(
            pipeline.build_parser().parse_args(
                ["/tmp/meeting", "--chain", "loudnorm"]
            ).chain,
            "loudnorm",
        )

    def test_a_bare_cli_rerun_of_a_loudnorm_meeting_is_not_a_chain_switch(self):
        """The CLI half of the omission rule, end to end through `main()`.

        A finished `--chain loudnorm` run plus a bare `pipeline.py <meeting>`: the
        driver used to see `chain="denoise"` in its params, restale prep_audio,
        and — with transcript.raw.md on disk — refuse the whole run.
        """
        work = pipeline.WORK_DIRNAME
        with meeting(**{
            "diarization.json": diarization_json(),
            f"{work}/{pipeline.GATE_JSON_NAME}": gate_json(),
            f"{work}/prep_audio.json": prep_audio_json("loudnorm"),
            f"{work}/transcribe.json": transcribe_json(),
        }) as root:
            for name in ("mic", "system"):
                touch(root / f"{name}{pipeline.TRACK_SUFFIX}", 1000)
                touch(root / work / f"{name}{pipeline.INPUT_SUFFIX}", 2000)
            for name in ("prep_audio.json", pipeline.GATE_JSON_NAME, "transcribe.json"):
                touch(root / work / name, 3000)
            touch(root / "diarization.json", 3000)
            touch(root / pipeline.RAW_TRANSCRIPT_NAME, 4000)
            touch(root / pipeline.SPEAKERS_JSON_NAME, 5000)
            touch(root / pipeline.LABELED_TRANSCRIPT_NAME, 6000)

            recorder = Recorder()
            with contextlib.redirect_stdout(io.StringIO()):
                code = pipeline.main([str(root)], runner=recorder, clock=Clock())
            written = json.loads(
                pipeline.run_json_path(root).read_text(encoding="utf-8")
            )

        self.assertEqual(code, pipeline.EXIT_OK)
        self.assertNotEqual(written["status"], pipeline.STATUS_REFUSED)
        self.assertNotIn("prep_audio", recorder.stages)
        self.assertNotIn("merge", recorder.stages)
        # And the provenance the run log reports is the chain that is on disk.
        self.assertEqual(written["chain"], "loudnorm")

    def test_an_unforced_rebuild_keeps_the_recorded_chain(self):
        # prep_audio has to re-run (the source is newer than its wav) and this
        # run named no chain: rebuilding with the stage default would silently
        # turn a loudnorm folder into a denoise one.
        work = pipeline.WORK_DIRNAME
        with meeting(**{f"{work}/prep_audio.json": prep_audio_json("loudnorm")}) as root:
            for name in ("mic", "system"):
                touch(root / f"{name}{pipeline.TRACK_SUFFIX}", 5000)
                touch(root / work / f"{name}{pipeline.INPUT_SUFFIX}", 1000)

            _, rec = run(root, only=("prep_audio",))
            _, forced = run(root, only=("prep_audio",), force=True)

        self.assertEqual(rec.argv_for("prep_audio")[-1], "loudnorm")
        # `--force` is the documented deliberate way back to a default.
        self.assertEqual(forced.argv_for("prep_audio")[2], "denoise")

    def test_recorded_chain_needs_one_unambiguous_answer(self):
        work = pipeline.WORK_DIRNAME
        with meeting() as root:
            self.assertIsNone(pipeline.recorded_chain(root))
        with meeting(**{f"{work}/prep_audio.json": prep_audio_json("loudnorm")}) as root:
            self.assertEqual(pipeline.recorded_chain(root), "loudnorm")
        mixed = json.dumps({
            "stage": "prep_audio",
            "status": "ok",
            "tracks": [
                {"track": "mic", "status": "ok", "chain": "loudnorm"},
                {"track": "system", "status": "ok", "chain": "plain"},
            ],
        })
        with meeting(**{f"{work}/prep_audio.json": mixed}) as root:
            # Nothing single to preserve, so the stage default is the honest
            # answer rather than one track's chain imposed on the other.
            self.assertIsNone(pipeline.recorded_chain(root))
            _, rec = run(root, only=("prep_audio",))
        self.assertEqual(rec.argv_for("prep_audio")[-1], "denoise")

    def test_an_unforced_rebuild_keeps_the_recorded_num_speakers(self):
        """The omission rule covered `--chain` only, so D2's primary control was
        the one parameter a forced-by-circumstance re-run silently dropped.

        diarize has to re-run (its wav is newer than diarization.json) and this
        run named no `--num-speakers`: re-clustering by `--threshold` instead
        swaps the control for the fallback the plan calls measurably worse, and
        exits green having done it.
        """
        work = pipeline.WORK_DIRNAME
        with meeting(**{
            "diarization.json": diarization_json(3),
            f"{work}/{pipeline.GATE_JSON_NAME}": gate_json(),
        }) as root:
            touch(root / "diarization.json", 1000)
            touch(root / work / f"system{pipeline.INPUT_SUFFIX}", 5000)

            _, rec = run(root, only=("diarize",))
            _, forced = run(root, only=("diarize",), force=True)

        argv = rec.argv_for("diarize")
        self.assertIn("--num-speakers", argv)
        self.assertEqual(argv[argv.index("--num-speakers") + 1], "3")
        # `--force` stays the documented deliberate way back to the default.
        self.assertNotIn("--num-speakers", forced.argv_for("diarize"))

    def test_an_unforced_rerun_keeps_the_recorded_asr_options(self):
        # Same rule for the two D6 opt-ins: re-transcribing with auto-LID after
        # a `--language ru` run is a silent provenance change.
        work = pipeline.WORK_DIRNAME
        with meeting(**{
            f"{work}/transcribe.json": transcribe_json("ru", "/tmp/vocab.txt"),
            f"{work}/{pipeline.GATE_JSON_NAME}": gate_json(),
        }) as root:
            touch(root / work / "transcribe.json", 1000)
            touch(root / work / f"mic{pipeline.INPUT_SUFFIX}", 5000)

            _, rec = run(root, only=("transcribe",))
            _, forced = run(root, only=("transcribe",), force=True)

        argv = rec.argv_for("transcribe")
        self.assertEqual(argv[argv.index("--language") + 1], "ru")
        self.assertEqual(argv[argv.index("--custom-vocab") + 1], "/tmp/vocab.txt")
        self.assertNotIn("--language", forced.argv_for("transcribe"))
        self.assertNotIn("--custom-vocab", forced.argv_for("transcribe"))

    def test_an_unforced_rebuild_keeps_the_recorded_attendees(self):
        # The sharpest edge of the four: `speakers build` with no --attendees
        # produces a map with no D8 anchors at all.
        with meeting(**{
            pipeline.SPEAKERS_JSON_NAME: speakers_json(["Дмитрий", "Любовь"]),
        }) as root:
            touch(root / pipeline.SPEAKERS_JSON_NAME, 1000)
            touch(root / pipeline.RAW_TRANSCRIPT_NAME, 5000)

            _, rec = run(root, only=("speakers",))
            _, forced = run(root, only=("speakers",), force=True)

        argv = rec.argv_for("speakers")
        self.assertEqual(argv[0], "build")
        self.assertEqual(
            [argv[i + 1] for i, tok in enumerate(argv) if tok == "--attendees"],
            ["Дмитрий", "Любовь"],
        )
        self.assertNotIn("--attendees", forced.argv_for("speakers"))

    def test_the_run_log_reports_the_resolved_parameters(self):
        # provenance, not the absence of a flag: quality.md is rendered from
        # these, and reporting `null` after re-using a recorded value would make
        # the run log contradict what the stages actually ran under.
        work = pipeline.WORK_DIRNAME
        with meeting(**{
            "diarization.json": diarization_json(3),
            pipeline.SPEAKERS_JSON_NAME: speakers_json(["Дмитрий"]),
            f"{work}/prep_audio.json": prep_audio_json("loudnorm"),
            f"{work}/transcribe.json": transcribe_json("ru", "/tmp/vocab.txt"),
            f"{work}/{pipeline.GATE_JSON_NAME}": gate_json(),
        }) as root:
            report, _ = run(root, only=("verify",))

        self.assertEqual(report["chain"], "loudnorm")
        self.assertEqual(report["num_speakers"], 3)
        self.assertEqual(report["language"], "ru")
        self.assertEqual(report["custom_vocab"], "/tmp/vocab.txt")
        self.assertEqual(report["attendees"], ["Дмитрий"])

    def test_recorded_parameters_need_one_unambiguous_answer(self):
        work = pipeline.WORK_DIRNAME
        with meeting() as root:
            self.assertIsNone(pipeline.recorded_num_speakers(root))
            self.assertIsNone(pipeline.recorded_asr_option(root, "language"))
            self.assertEqual(pipeline.recorded_attendees(root), ())
        # A threshold-controlled run records `num_speakers: null` — nothing to
        # preserve, not a value to forward.
        with meeting(**{"diarization.json": diarization_json(None)}) as root:
            self.assertIsNone(pipeline.recorded_num_speakers(root))
        mixed = json.dumps({
            "stage": "transcribe",
            "status": "ok",
            "tracks": [
                {"track": "mic", "status": "ok", "language": "ru", "words": []},
                {"track": "system", "status": "ok", "language": "en", "words": []},
            ],
        })
        with meeting(**{f"{work}/transcribe.json": mixed}) as root:
            self.assertIsNone(pipeline.recorded_asr_option(root, "language"))

    def test_an_explicit_flag_still_wins_over_the_recorded_one(self):
        # The omission rule preserves; it never overrides. `--num-speakers 5`
        # over a 3-speaker folder has to reach diarize as 5.
        work = pipeline.WORK_DIRNAME
        with meeting(**{
            "diarization.json": diarization_json(3),
            f"{work}/{pipeline.GATE_JSON_NAME}": gate_json(),
        }) as root:
            report, rec = run(root, only=("diarize",), num_speakers=5)

        argv = rec.argv_for("diarize")
        self.assertEqual(argv[argv.index("--num-speakers") + 1], "5")
        self.assertEqual(report["num_speakers"], 5)

    def test_no_readable_report_leaves_the_mtime_rule_alone(self):
        # Same asymmetry as recorded_failure: absent evidence never forces a
        # re-run, it just does not prevent one.
        with meeting() as root:
            self.assertFalse(pipeline.parameters_changed(
                root, "diarize", {"num_speakers": 6}
            ))

    def test_diarize_actually_reruns_end_to_end_on_a_new_count(self):
        # The regression this file exists for: everything on disk is fresh, only
        # --num-speakers moved, and the stage must still be invoked.
        work = pipeline.WORK_DIRNAME
        with meeting(**{
            "diarization.json": diarization_json(2),
            f"{work}/{pipeline.GATE_JSON_NAME}": gate_json(),
        }) as root:
            touch(root / "system.wav", 1000)
            touch(root / pipeline.WORK_DIRNAME / "system.16k.wav", 2000)
            touch(root / "diarization.json", 3000)

            _, fresh = run(root, only=("diarize",), num_speakers=2)
            _, changed = run(root, only=("diarize",), num_speakers=6)

        self.assertNotIn("diarize", fresh.stages)
        self.assertIn("diarize", changed.stages)
        self.assertIn("--num-speakers", changed.argv_for("diarize"))


# --- ASR opt-in passthrough --------------------------------------------------


class AsrOptionTests(unittest.TestCase):
    def test_language_and_custom_vocab_reach_transcribe(self):
        with meeting() as root:
            _, rec = run(
                root,
                only=("transcribe",),
                language="ru",
                custom_vocab="/tmp/vocab.txt",
            )
        argv = rec.argv_for("transcribe")
        self.assertIn("--language", argv)
        self.assertEqual(argv[argv.index("--language") + 1], "ru")
        self.assertIn("--custom-vocab", argv)

    def test_both_are_absent_by_default(self):
        # D6: off unless asked for. A default-on hint would silently change ASR.
        with meeting() as root:
            _, rec = run(root, only=("transcribe",))
        argv = rec.argv_for("transcribe")
        self.assertNotIn("--language", argv)
        self.assertNotIn("--custom-vocab", argv)


# --- crash containment -------------------------------------------------------


class MalformedStageJsonTests(unittest.TestCase):
    """A malformed stage JSON must degrade to a report, never to a traceback.

    ``parameters_changed`` runs from ``run()``, outside the per-stage try/except,
    so an exception there escapes ``main()`` and no pipeline.json is written at
    all — the one file the skill tells the operator to read after a failure. The
    trap was ordering: in ``any(EXPR for e in xs if COND)`` the filter runs first,
    so an ``isinstance`` guard sitting in EXPR never protects COND.
    """

    def test_a_non_dict_track_entry_does_not_raise(self):
        with meeting(**{f"{pipeline.WORK_DIRNAME}/transcribe.json": '{"tracks": ["oops"]}'}) as root:
            self.assertFalse(
                pipeline.parameters_changed(root, "transcribe", {"language": "ru"})
            )

    def test_every_stage_survives_a_non_dict_track_entry(self):
        for stage in ("prep_audio", "transcribe", "diarize", "speakers"):
            for name in (
                "prep_audio.json",
                "transcribe.json",
                "diarization.json",
                "speakers.json",
            ):
                with self.subTest(stage=stage, file=name):
                    with meeting(**{f"{pipeline.WORK_DIRNAME}/{name}": '{"tracks": ["oops"], "parameters": "nope"}'}) as root:
                        pipeline.parameters_changed(
                            root,
                            stage,
                            {
                                "language": "ru",
                                "chain": "denoise",
                                "num_speakers": 3,
                                "attendees": ["A"],
                            },
                        )

    def test_a_malformed_transcribe_json_still_produces_a_run_log(self):
        with meeting(**{f"{pipeline.WORK_DIRNAME}/transcribe.json": '{"tracks": ["oops"]}'}) as root:
            out, err = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                pipeline.main(
                    [str(root), "--language", "ru"],
                    runner=Recorder(),
                    clock=Clock(),
                )
            self.assertTrue(pipeline.run_json_path(root).is_file())


class MergeRefusalScopeTests(unittest.TestCase):
    """Only a stage that *feeds* merge can restale the transcript.

    ``gate`` runs before merge but writes gate.json alone, which nothing
    downstream consumes. Treating "runs before merge" as "can rebuild the
    transcript" turned a deleted or failed gate.json into exit 2 — telling the
    operator to ``merge.py --force`` over their forensic transcript for no
    reason. ``prep_audio`` must stay in scope: it does not touch merge's inputs
    itself, but the wavs it writes are what transcribe and diarize consume.
    """

    def test_gate_is_not_counted_as_a_transcript_producer(self):
        with meeting() as root:
            for track in ("mic", "system"):
                touch(root / f"{track}.wav", 1000)
            self.assertNotIn("gate", pipeline.stages_feeding_merge(root))

    def test_prep_audio_is_counted_transitively(self):
        with meeting() as root:
            for track in ("mic", "system"):
                touch(root / f"{track}.wav", 1000)
            feeding = pipeline.stages_feeding_merge(root)
            self.assertEqual(feeding, {"prep_audio", "transcribe", "diarize"})

    def test_a_missing_gate_json_does_not_refuse_over_the_transcript(self):
        with meeting() as root:
            work = root / pipeline.WORK_DIRNAME
            for track in ("mic", "system"):
                touch(root / f"{track}.wav", 1000)
                touch(work / f"{track}.16k.wav", 2000)
            touch(work / "prep_audio.json", 2000)
            touch(work / "transcribe.json", 3000)
            touch(root / "diarization.json", 3000)
            touch(root / pipeline.RAW_TRANSCRIPT_NAME, 4000)
            # gate.json deliberately absent — gate will run, and that is fine.
            self.assertFalse(pipeline.merge_would_refuse(root, pipeline.STAGES))

    def test_a_stale_transcribe_json_still_refuses(self):
        # The guard itself must keep working: transcribe *does* feed merge.
        with meeting() as root:
            work = root / pipeline.WORK_DIRNAME
            for track in ("mic", "system"):
                touch(root / f"{track}.wav", 5000)
                touch(work / f"{track}.16k.wav", 5000)
            touch(work / "prep_audio.json", 5000)
            touch(work / "gate.json", 5000)
            touch(work / "transcribe.json", 1000)  # older than its wav input
            touch(root / "diarization.json", 5000)
            touch(root / pipeline.RAW_TRANSCRIPT_NAME, 4000)
            self.assertTrue(pipeline.merge_would_refuse(root, pipeline.STAGES))


class SilentSystemRerunTests(unittest.TestCase):
    """A stage ``run()`` will skip cannot be "about to rebuild the transcript".

    ``merge_would_refuse`` is predictive, so it has to model what ``run()``
    actually does. It modelled the *absent*-system shape and not the *silent*
    one: with a system track S2 called effectively silent, ``system.16k.wav``
    exists but ``diarization.json`` does not, so the pre-check counted diarize as
    about to run while ``run()`` skipped it for silence. The first run went
    green and **every bare re-run afterwards exited 2**, offering two wrong ways
    out — ``--replace-transcript``, which lifts the guard on the verbatim
    transcript, or ``--from-stage speakers``, which narrows the run. The
    near-identical mic-only meeting re-ran cleanly, so it looked arbitrary.
    """

    def _silent_system_meeting(self, root):
        work = root / pipeline.WORK_DIRNAME
        for track in ("mic", "system"):
            touch(root / f"{track}.wav", 1000)
            touch(work / f"{track}.16k.wav", 2000)
        touch(work / "prep_audio.json", 2000)
        (work / pipeline.GATE_JSON_NAME).write_text(
            gate_json(silent=("system",)), encoding="utf-8"
        )
        os.utime(work / pipeline.GATE_JSON_NAME, (3000, 3000))
        touch(work / "transcribe.json", 4000)
        touch(work / "merge.json", 5000)
        touch(root / pipeline.RAW_TRANSCRIPT_NAME, 5000)

    def test_a_rerun_is_not_refused_over_a_skipped_diarize(self):
        with meeting() as root:
            self._silent_system_meeting(root)
            self.assertFalse(pipeline.merge_would_refuse(root, pipeline.STAGES))

    def test_the_same_meeting_with_a_live_system_track_still_refuses(self):
        with meeting() as root:
            self._silent_system_meeting(root)
            # Nothing silent any more, so diarize really will run and really will
            # restale the transcript: the guard must still fire.
            (root / pipeline.WORK_DIRNAME / pipeline.GATE_JSON_NAME).write_text(
                gate_json(), encoding="utf-8"
            )
            self.assertTrue(pipeline.merge_would_refuse(root, pipeline.STAGES))

    def test_the_skip_reason_is_the_one_run_reports(self):
        """One helper, so the pre-check and the run cannot drift apart again."""
        with meeting() as root:
            self._silent_system_meeting(root)
            reason = pipeline.stage_skip_reason(root, "diarize", ["system"])
        self.assertIsNotNone(reason)
        self.assertIn("effectively silent", reason)

    def test_a_mic_only_meeting_reports_the_mic_only_reason(self):
        with meeting() as root:
            touch(root / "mic.wav", 1000)
            reason = pipeline.stage_skip_reason(root, "diarize", [])
        self.assertIsNotNone(reason)
        self.assertIn("mic-only", reason)

    def test_a_healthy_meeting_skips_nothing(self):
        with meeting() as root:
            for track in ("mic", "system"):
                touch(root / f"{track}.wav", 1000)
            self.assertIsNone(pipeline.stage_skip_reason(root, "diarize", []))


class UnconsumableParameterTests(unittest.TestCase):
    """A flag whose owning stage is not selected must refuse, never be dropped.

    `--from-stage speakers --num-speakers 5` exited 0 with diarization.json still
    holding the old clustering — the same "exits green having re-used the old
    2-speaker clustering" symptom parameters_changed exists to stop, reached
    through a different door. And `--from-stage speakers` is what the merge
    refusal tells the operator to run, so it is the likely next command after a
    parameter change rather than a hypothetical.
    """

    def test_num_speakers_without_diarize_is_refused(self):
        with meeting() as root:
            report, rec = run(root, from_stage="speakers", num_speakers=5)

        self.assertEqual(report["status"], pipeline.STATUS_REFUSED)
        self.assertEqual(pipeline.exit_code(report), pipeline.EXIT_USAGE)
        self.assertEqual(rec.calls, [], "nothing may run before the refusal")
        self.assertIn("--num-speakers", report["detail"])

    def test_num_speakers_zero_is_refused_too(self):
        """A falsy-but-supplied value is still supplied.

        The check was one blanket truthiness test, and `--num-speakers` is an int
        with no lower bound in the parser — so `0` slipped through and the run
        exited green having silently ignored the flag, with diarization.json
        still holding the old clustering. The operator never learned the value
        was invalid either: diarize.py rejects `< 1`, but diarize was not in the
        selected prefix, so that check never ran. `parameters_changed` already
        uses `is None` for this very parameter.
        """
        with meeting() as root:
            report, rec = run(root, from_stage="speakers", num_speakers=0)

        self.assertEqual(report["status"], pipeline.STATUS_REFUSED)
        self.assertIn("--num-speakers", report["detail"])
        self.assertEqual(rec.calls, [])

    def test_an_omitted_parameter_is_not_refused(self):
        """`is not None` must not turn every absent flag into a refusal."""
        self.assertEqual(
            pipeline.unconsumable_parameters(
                ("speakers", "verify"),
                {
                    "chain": None,
                    "num_speakers": None,
                    "attendees": [],
                    "language": None,
                    "custom_vocab": None,
                },
            ),
            [],
        )

    def test_every_parameter_is_covered(self):
        cases = {
            "chain": ("loudnorm", "--chain", ("gate",)),
            "language": ("ru", "--language", ("merge",)),
            "custom_vocab": ("vocab.txt", "--custom-vocab", ("merge",)),
            "num_speakers": (4, "--num-speakers", ("merge",)),
            "attendees": (("Дмитрий",), "--attendees", ("merge",)),
        }
        self.assertEqual(set(cases), set(pipeline.PARAMETER_OWNERS))
        for key, (value, flag, only) in cases.items():
            with self.subTest(parameter=key):
                with meeting() as root:
                    report, rec = run(root, only=only, **{key: value})
                self.assertEqual(report["status"], pipeline.STATUS_REFUSED)
                self.assertIn(flag, report["detail"])
                self.assertEqual(rec.calls, [])

    def test_a_flag_its_owner_can_consume_is_not_refused(self):
        with meeting() as root:
            report, rec = run(root, only=("diarize",), num_speakers=5)

        self.assertEqual(report["status"], pipeline.STATUS_OK)
        self.assertIn("--num-speakers", rec.argv_for("diarize"))

    def test_an_omitted_flag_is_never_a_contradiction(self):
        """The documented bare resume must stay usable."""
        with meeting(**{pipeline.RAW_TRANSCRIPT_NAME: "# t\n"}) as root:
            report, _ = run(root, from_stage="speakers")

        self.assertEqual(report["status"], pipeline.STATUS_OK)


class StageCrashTests(unittest.TestCase):
    """A stage that raises must still be a recorded stage failure: letting it
    propagate skips write_run_json, so pipeline.json — the one file the skill
    tells the operator to read after a failure — never gets written."""

    def test_a_raising_stage_becomes_a_failed_entry(self):
        def explode(call):
            raise ValueError("could not convert string to float: 'n/a'")

        with meeting() as root:
            err = io.StringIO()
            with contextlib.redirect_stderr(err):
                report, _ = run(root, recorder=Recorder(side_effects={"gate": explode}))

        entry = next(e for e in report["stages"] if e["stage"] == "gate")
        self.assertEqual(entry["status"], pipeline.STATUS_FAILED)
        self.assertIn("n/a", entry["detail"])
        self.assertIn("Traceback", entry["traceback"])
        self.assertEqual(report["status"], pipeline.STATUS_FAILED)
        self.assertIn("Traceback", err.getvalue())

    def test_the_run_log_is_still_written_after_a_crash(self):
        def explode(call):
            raise RuntimeError("boom")

        with meeting() as root:
            err, out = io.StringIO(), io.StringIO()
            with contextlib.redirect_stderr(err), contextlib.redirect_stdout(out):
                code = pipeline.main(
                    [str(root)],
                    runner=Recorder(side_effects={"gate": explode}),
                    clock=Clock(),
                )
            self.assertEqual(code, pipeline.EXIT_FAILED)
            self.assertTrue(pipeline.run_json_path(root).is_file())


# --- --json is parseable -----------------------------------------------------


class JsonOutputTests(unittest.TestCase):
    def test_stage_chatter_never_lands_on_the_json_channel(self):
        def chatty(call):
            print("acta-notes doctor — GREEN")

        with meeting() as root:
            out, err = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                pipeline.main(
                    [str(root), "--json"],
                    runner=Recorder(side_effects={"doctor": chatty}),
                    clock=Clock(),
                )

        # The whole point: stdout parses as exactly one document.
        report = json.loads(out.getvalue())
        self.assertEqual(report["stage"], "pipeline")
        self.assertIn("GREEN", err.getvalue())

    def test_human_mode_keeps_stage_output_on_stdout(self):
        def chatty(call):
            print("acta-notes doctor — GREEN")

        with meeting() as root:
            out = io.StringIO()
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
                pipeline.main(
                    [str(root)],
                    runner=Recorder(side_effects={"doctor": chatty}),
                    clock=Clock(),
                )
        self.assertIn("GREEN", out.getvalue())


# --- cleanup completeness ----------------------------------------------------


class CleanupTests(unittest.TestCase):
    def test_orphaned_partials_are_reclaimed(self):
        # prep_audio writes through <track>.16k.part.wav and only unlinks it on
        # a non-zero ffmpeg exit — a killed ffmpeg leaves ~115 MB/h/track that
        # the *.16k.wav glob does not match.
        with meeting() as root:
            work = root / pipeline.WORK_DIRNAME
            touch(work / "mic.16k.wav", 1000)
            touch(work / "system.16k.part.wav", 1000)

            removed = pipeline.cleanup_intermediates(root)

        self.assertEqual(sorted(removed), ["mic.16k.wav", "system.16k.part.wav"])


if __name__ == "__main__":
    unittest.main()
