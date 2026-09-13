import _ctx

import contextlib
import datetime as dt
import io
import json
import tempfile
import unittest
from pathlib import Path

teams = _ctx.load("teams_vtt_to_transcript")
merge = _ctx.load("merge")


VTT_HEADER = "WEBVTT\n\n"


def vtt(*cues):
    """``(start, end, body)`` tuples → a WEBVTT document."""
    blocks = [VTT_HEADER.rstrip("\n")]
    for start, end, body in cues:
        blocks.append(f"{start} --> {end}\n{body}")
    return "\n\n".join(blocks) + "\n"


def envelope(content, created="2026-07-29T08:00:39.1234567Z", count=1):
    """The shape ``read_resource(meetingTranscriptUrl)`` saves."""
    transcripts = [{"content": content, "createdDateTime": created}]
    for _ in range(count - 1):
        transcripts.append({"content": "", "createdDateTime": created})
    return json.dumps({"transcripts": transcripts})


@contextlib.contextmanager
def meeting(source_text=None, source_name="read_resource.json", raw=None):
    """A meeting folder plus a source file, in a throwaway directory."""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp) / "2026-07-29_1000__weekly"
        (root / ".acta-notes").mkdir(parents=True)
        if raw is not None:
            teams.transcript_path(root).write_text(raw, encoding="utf-8")
        source = Path(tmp) / source_name
        if source_text is not None:
            source.write_text(source_text, encoding="utf-8")
        yield root, source


def transcript_lines(text):
    return [line for line in text.splitlines() if line.startswith("**[")]


def run_main(argv):
    """``main(argv)`` with stdout/stderr captured; returns ``(code, out, err)``."""
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = teams.main(argv)
    return code, out.getvalue(), err.getvalue()


class SpeakerAndTimestampParsingTests(unittest.TestCase):
    def test_a_v_tag_becomes_the_speaker_label(self):
        cues = teams.parse_cues(
            vtt(
                ("00:00:01.000", "00:00:04.000", "<v Дмитрий Иванов>Погнали.</v>"),
                ("00:01:05.500", "00:01:09.000", "<v Любовь Петрова>Я фиксирую.</v>"),
            )
        )
        self.assertEqual(
            [(cue["start"], cue["speaker"], cue["text"]) for cue in cues],
            [
                (1.0, "Дмитрий Иванов", "Погнали."),
                (65.5, "Любовь Петрова", "Я фиксирую."),
            ],
        )

    def test_timestamps_survive_the_comma_decimal_and_a_short_hour(self):
        cues = teams.parse_cues(
            vtt(("0:00:02,250", "0:00:03,750", "<v A>раз</v>"))
        )
        self.assertEqual(cues[0]["start"], 2.25)
        self.assertEqual(cues[0]["end"], 3.75)

    def test_the_hours_field_is_optional_as_webvtt_allows(self):
        """WebVTT's `MM:SS.TTT` form is legal and common in hand exports.

        Requiring `HH:MM:SS.mmm` skipped every such cue silently — no warning,
        no dropped count, just a shorter transcript.
        """
        self.assertEqual(teams.to_seconds("01:05.500"), 65.5)
        self.assertEqual(teams.to_seconds("00:01:05.500"), 65.5)

        cues = teams.parse_cues(
            vtt(
                ("00:10.000", "00:14.000", "<v Дмитрий>Начинаем.</v>"),
                ("01:05.500", "01:09.000", "<v Любовь>Записала.</v>"),
            )
        )
        self.assertEqual([c["start"] for c in cues], [10.0, 65.5])
        self.assertEqual([c["speaker"] for c in cues], ["Дмитрий", "Любовь"])

    def test_a_cue_without_a_v_tag_is_kept_as_unattributed(self):
        cues = teams.parse_cues(vtt(("00:00:00.000", "00:00:02.000", "какой-то текст")))
        self.assertEqual(cues[0]["speaker"], teams.UNKNOWN_SPEAKER)
        self.assertEqual(cues[0]["text"], "какой-то текст")

    def test_an_unattributed_speaker_is_never_given_a_spk_label(self):
        # SPK_NN means "diarization decided this". Nothing was diarized here, and
        # speakers.py would happily try to name the label if it saw one.
        self.assertNotRegex(teams.UNKNOWN_SPEAKER, r"SPK_\d+")

    def test_a_name_carrying_colon_or_star_cannot_break_the_line_shape(self):
        cues = teams.parse_cues(
            vtt(("00:00:00.000", "00:00:01.000", "<v Иванов: *Гость*>привет</v>"))
        )
        line = f"**[00:00:00] {cues[0]['speaker']}:** {cues[0]['text']}"
        # Both downstream readers must still parse the rendered line.
        speakers = _ctx.load("speakers")
        verify = _ctx.load("verify")
        self.assertIsNotNone(speakers.LINE_RE.match(line))
        self.assertIsNotNone(verify.LINE_RE.match(line))


class MultiLineCueTests(unittest.TestCase):
    def test_a_cue_wrapped_over_several_lines_becomes_one_utterance(self):
        cues = teams.parse_cues(
            vtt(
                (
                    "00:00:01.000",
                    "00:00:06.000",
                    "<v Дмитрий Иванов>нам надо решить\nчто делаем с релизом\nдо пятницы</v>",
                )
            )
        )
        self.assertEqual(len(cues), 1)
        self.assertEqual(cues[0]["text"], "нам надо решить что делаем с релизом до пятницы")

    def test_two_voices_inside_one_cue_both_survive(self):
        # The Air skill used `search` here and silently dropped the second voice.
        cues = teams.parse_cues(
            vtt(
                (
                    "00:00:01.000",
                    "00:00:05.000",
                    "<v Дмитрий>да</v>\n<v Любовь>согласна</v>",
                )
            )
        )
        self.assertEqual(
            [(cue["speaker"], cue["text"]) for cue in cues],
            [("Дмитрий", "да"), ("Любовь", "согласна")],
        )

    def test_a_final_cue_missing_its_closing_tag_is_still_read(self):
        cues = teams.parse_cues(
            vtt(("00:00:01.000", "00:00:03.000", "<v Дмитрий>хвост без закрытия"))
        )
        self.assertEqual([(c["speaker"], c["text"]) for c in cues], [("Дмитрий", "хвост без закрытия")])


class DedupTests(unittest.TestCase):
    def cues(self, *specs):
        return [
            {"start": start, "end": start + 1.0, "speaker": speaker, "text": text}
            for start, speaker, text in specs
        ]

    def test_an_identical_repeat_from_the_same_speaker_is_dropped(self):
        out = teams.dedup(
            self.cues((0.0, "Дмитрий", "нам надо решить"), (1.0, "Дмитрий", "нам надо решить"))
        )
        self.assertEqual([c["text"] for c in out], ["нам надо решить"])
        # The surviving cue keeps the earliest start and the latest end.
        self.assertEqual(out[0]["start"], 0.0)
        self.assertEqual(out[0]["end"], 2.0)

    def test_a_growing_rolling_caption_collapses_to_its_longest_form(self):
        out = teams.dedup(
            self.cues(
                (0.0, "Дмитрий", "нам надо"),
                (1.0, "Дмитрий", "нам надо решить"),
                (2.0, "Дмитрий", "нам надо решить до пятницы"),
            )
        )
        self.assertEqual([c["text"] for c in out], ["нам надо решить до пятницы"])
        self.assertEqual(out[0]["start"], 0.0)

    def test_the_same_text_from_a_different_speaker_is_kept(self):
        out = teams.dedup(self.cues((0.0, "Дмитрий", "да"), (1.0, "Любовь", "да")))
        self.assertEqual([c["speaker"] for c in out], ["Дмитрий", "Любовь"])

    def test_a_non_consecutive_repeat_is_kept_verbatim(self):
        # People do say the same short thing twice; this stage promises verbatim.
        out = teams.dedup(
            self.cues(
                (0.0, "Дмитрий", "да"),
                (1.0, "Любовь", "нет"),
                (2.0, "Дмитрий", "да"),
            )
        )
        self.assertEqual([c["text"] for c in out], ["да", "нет", "да"])

    def test_a_repeat_far_apart_in_time_is_kept_verbatim(self):
        """Neither rule looked at time, only at `out[-1]` of the same speaker.

        So a speaker who says "Понятно." at 00:05:00 and, uninterrupted, again at
        00:20:00 lost the second one — an utterance silently dropped from a file
        whose own header promises "Дословно, без правок" — and the survivor's
        `end` stretched over the 900 s between them, inflating the speaker_rollup
        tally by two orders of magnitude.
        """
        out = teams.dedup(self.cues((300.0, "Дмитрий", "Понятно."), (1200.0, "Дмитрий", "Понятно.")))
        self.assertEqual([c["text"] for c in out], ["Понятно.", "Понятно."])
        self.assertEqual(out[0]["end"], 301.0)

    def test_a_far_apart_prefix_is_not_treated_as_a_rolling_caption(self):
        out = teams.dedup(
            self.cues((300.0, "Дмитрий", "нам надо"), (1200.0, "Дмитрий", "нам надо решить"))
        )
        self.assertEqual([c["text"] for c in out], ["нам надо", "нам надо решить"])

    def test_a_rolling_repeat_within_the_window_still_collapses(self):
        # The bound is `DEDUP_WINDOW_SECONDS` past the previous cue's end, which
        # is what an actual re-send looks like — the rule itself is unchanged.
        out = teams.dedup(
            self.cues((0.0, "Дмитрий", "нам надо решить"), (2.5, "Дмитрий", "нам надо решить"))
        )
        self.assertEqual([c["text"] for c in out], ["нам надо решить"])
        self.assertEqual(out[0]["end"], 3.5)


class ParagraphMergeTests(unittest.TestCase):
    def rows(self, *specs):
        return [
            {"start": start, "end": start + 1.0, "speaker": speaker, "text": text}
            for start, speaker, text in specs
        ]

    def test_consecutive_cues_within_the_gap_join(self):
        out = teams.merge_paragraphs(
            self.rows((0.0, "Дмитрий", "раз"), (5.0, "Дмитрий", "два")), gap=35.0
        )
        self.assertEqual([r["text"] for r in out], ["раз два"])
        self.assertEqual(out[0]["cue_count"], 2)

    def test_the_gap_is_measured_from_the_paragraph_start_not_the_previous_cue(self):
        # Otherwise a chain of short pauses builds one unbounded paragraph and
        # the timestamps stop being navigable.
        out = teams.merge_paragraphs(
            self.rows(
                (0.0, "Дмитрий", "раз"),
                (30.0, "Дмитрий", "два"),
                (40.0, "Дмитрий", "три"),
            ),
            gap=35.0,
        )
        self.assertEqual([r["text"] for r in out], ["раз два", "три"])

    def test_a_speaker_change_always_starts_a_paragraph(self):
        out = teams.merge_paragraphs(
            self.rows((0.0, "Дмитрий", "раз"), (1.0, "Любовь", "два")), gap=35.0
        )
        self.assertEqual([r["speaker"] for r in out], ["Дмитрий", "Любовь"])


class OutputArtifactTests(unittest.TestCase):
    def test_the_output_filename_is_transcript_raw_md(self):
        with meeting(envelope(vtt(("00:00:01.000", "00:00:03.000", "<v Дмитрий>раз</v>")))) as (
            root,
            source,
        ):
            report = teams.run(root, source)
            self.assertEqual(report["status"], teams.STATUS_OK)
            self.assertEqual(Path(report["transcript"]).name, "transcript.raw.md")
            self.assertTrue((root / "transcript.raw.md").is_file())

    def test_no_other_transcript_in_the_chain_is_created(self):
        with meeting(envelope(vtt(("00:00:01.000", "00:00:03.000", "<v Дмитрий>раз</v>")))) as (
            root,
            source,
        ):
            teams.run(root, source)
            self.assertFalse((root / "transcript.labeled.md").exists())
            self.assertFalse((root / "transcript.md").exists())

    def test_the_line_shape_matches_the_other_producer(self):
        with meeting(
            envelope(
                vtt(
                    ("00:00:01.000", "00:00:03.000", "<v Дмитрий Иванов>раз</v>"),
                    ("00:02:05.000", "00:02:07.000", "<v Любовь Петрова>два</v>"),
                )
            )
        ) as (root, source):
            teams.run(root, source)
            text = (root / "transcript.raw.md").read_text(encoding="utf-8")
            self.assertEqual(
                transcript_lines(text),
                [
                    "**[00:00:01] Дмитрий Иванов:** раз",
                    "**[00:02:05] Любовь Петрова:** два",
                ],
            )
            speakers = _ctx.load("speakers")
            for line in transcript_lines(text):
                self.assertIsNotNone(speakers.LINE_RE.match(line))

    def test_the_provenance_paragraph_names_teams_as_the_source(self):
        with meeting(envelope(vtt(("00:00:01.000", "00:00:03.000", "<v Дмитрий>раз</v>")))) as (
            root,
            source,
        ):
            teams.run(root, source, title="Weekly")
            text = (root / "transcript.raw.md").read_text(encoding="utf-8")
            self.assertIn("# Weekly — транскрипт", text)
            self.assertIn("Microsoft Teams", text)

    def test_no_transcribe_stage_json_is_left_behind(self):
        # verify.py decides the provenance source by the *absence* of one.
        with meeting(envelope(vtt(("00:00:01.000", "00:00:03.000", "<v Дмитрий>раз</v>")))) as (
            root,
            source,
        ):
            report = teams.run(root, source)
            teams.write_stage_json(root, report)
            verify = _ctx.load("verify")
            self.assertFalse((root / ".acta-notes" / "transcribe.json").exists())
            self.assertEqual(
                verify.detect_source(verify.load_inputs(root)), verify.SOURCE_TEAMS_VTT
            )

    def test_the_stage_json_records_the_teams_source_and_the_counts(self):
        with meeting(
            envelope(
                vtt(
                    ("00:00:01.000", "00:00:03.000", "<v Дмитрий>нам надо</v>"),
                    ("00:00:03.000", "00:00:05.000", "<v Дмитрий>нам надо решить</v>"),
                    ("00:01:00.000", "00:01:02.000", "<v Любовь>ага</v>"),
                )
            )
        ) as (root, source):
            report = teams.run(root, source)
            report.pop("rows", None)
            teams.write_stage_json(root, report)
            written = json.loads(
                (root / ".acta-notes" / "teams_vtt.json").read_text(encoding="utf-8")
            )
            self.assertEqual(written["transcript_source"], "teams-vtt")
            self.assertEqual(written["cue_count"], 3)
            self.assertEqual(written["dropped_repeat_count"], 1)
            self.assertEqual(written["paragraph_count"], 2)
            self.assertEqual(written["speaker_count"], 2)
            self.assertEqual(written["created"], "2026-07-29T08:00:39.1234567Z")


class SourceShapeTests(unittest.TestCase):
    def test_a_bare_vtt_export_is_accepted(self):
        body = vtt(("00:00:01.000", "00:00:03.000", "<v Дмитрий>раз</v>"))
        with meeting(body, source_name="meeting.vtt") as (root, source):
            report = teams.run(root, source)
            self.assertEqual(report["status"], teams.STATUS_OK)
            self.assertEqual(report["source_kind"], "webvtt")
            self.assertIsNone(report["created"])

    def test_the_m365_envelope_is_recognised(self):
        with meeting(envelope(vtt(("00:00:01.000", "00:00:03.000", "<v A>раз</v>")), count=2)) as (
            root,
            source,
        ):
            report = teams.run(root, source)
            self.assertEqual(report["source_kind"], "m365-json")
            self.assertEqual(report["transcript_count"], 2)

    def test_a_missing_source_fails_without_writing_anything(self):
        with meeting(None) as (root, source):
            report = teams.run(root, source)
            self.assertEqual(report["status"], teams.STATUS_FAILED)
            self.assertFalse((root / "transcript.raw.md").exists())
            self.assertIn(str(source), report["detail"])

    def test_an_unusable_source_leaves_no_stage_json_at_all(self):
        # A stage JSON is the record of a conversion that landed. This one did
        # not, so the folder keeps whatever it had — here, nothing.
        with meeting(None) as (root, source):
            code, _, _ = run_main([str(root), str(source)])
            self.assertEqual(code, teams.EXIT_FAILED)
            self.assertFalse(teams.stage_json_path(root).exists())

    def test_json_without_transcripts_is_refused_rather_than_guessed(self):
        with meeting(json.dumps({"value": []})) as (root, source):
            report = teams.run(root, source)
            self.assertEqual(report["status"], teams.STATUS_FAILED)
            self.assertIn("transcripts[]", report["detail"])


class EmptyInputTests(unittest.TestCase):
    def test_an_empty_file_writes_no_transcript(self):
        with meeting("", source_name="meeting.vtt") as (root, source):
            report = teams.run(root, source)
            self.assertEqual(report["status"], teams.STATUS_FAILED)
            self.assertFalse((root / "transcript.raw.md").exists())
            self.assertEqual(teams.exit_code(report), teams.EXIT_FAILED)

    def test_a_header_only_vtt_writes_no_transcript(self):
        with meeting(VTT_HEADER, source_name="meeting.vtt") as (root, source):
            report = teams.run(root, source)
            self.assertEqual(report["status"], teams.STATUS_FAILED)
            self.assertEqual(report["cue_count"], 0)
            self.assertFalse((root / "transcript.raw.md").exists())

    def test_cues_holding_only_markup_count_as_empty(self):
        with meeting(
            vtt(("00:00:01.000", "00:00:02.000", "<v Дмитрий></v>")),
            source_name="meeting.vtt",
        ) as (root, source):
            report = teams.run(root, source)
            self.assertEqual(report["status"], teams.STATUS_FAILED)
            self.assertFalse((root / "transcript.raw.md").exists())


class OverwriteProtectionTests(unittest.TestCase):
    EXISTING = "# уже есть — транскрипт\n\n**[00:00:00] SPK_01:** прежний текст\n"

    def test_the_refusal_message_is_merge_pys_word_for_word(self):
        path = Path("/tmp/x/transcript.raw.md")
        self.assertEqual(teams.overwrite_refusal(path), merge.overwrite_refusal(path))

    def test_an_existing_raw_transcript_is_left_byte_identical(self):
        with meeting(
            envelope(vtt(("00:00:01.000", "00:00:03.000", "<v Дмитрий>раз</v>"))),
            raw=self.EXISTING,
        ) as (root, source):
            before = (root / "transcript.raw.md").read_bytes()
            report = teams.run(root, source)
            self.assertEqual(report["status"], teams.STATUS_REFUSED)
            self.assertEqual((root / "transcript.raw.md").read_bytes(), before)

    def test_the_refusal_exit_code_matches_merge_pys(self):
        with meeting(
            envelope(vtt(("00:00:01.000", "00:00:03.000", "<v Дмитрий>раз</v>"))),
            raw=self.EXISTING,
        ) as (root, source):
            report = teams.run(root, source)
            self.assertEqual(teams.exit_code(report), teams.EXIT_USAGE)
            self.assertEqual(teams.EXIT_USAGE, merge.EXIT_USAGE)

    def test_a_refusal_reads_no_source_at_all(self):
        # The guard fires before any input work, so a bad source still refuses.
        with meeting(None, raw=self.EXISTING) as (root, source):
            report = teams.run(root, source)
            self.assertEqual(report["status"], teams.STATUS_REFUSED)

    def test_a_refusal_leaves_the_previous_stage_json_untouched(self):
        with meeting(
            envelope(vtt(("00:00:01.000", "00:00:03.000", "<v Дмитрий>раз</v>"))),
            raw=self.EXISTING,
        ) as (root, source):
            stage = root / ".acta-notes" / "teams_vtt.json"
            stage.write_text('{"marker": "previous"}', encoding="utf-8")
            code, _, _ = run_main([str(root), str(source)])
            self.assertEqual(code, teams.EXIT_USAGE)
            self.assertEqual(
                json.loads(stage.read_text(encoding="utf-8")), {"marker": "previous"}
            )

    def test_force_replaces_the_transcript(self):
        with meeting(
            envelope(vtt(("00:00:01.000", "00:00:03.000", "<v Дмитрий>новый</v>"))),
            raw=self.EXISTING,
        ) as (root, source):
            report = teams.run(root, source, force=True)
            self.assertEqual(report["status"], teams.STATUS_OK)
            text = (root / "transcript.raw.md").read_text(encoding="utf-8")
            self.assertIn("новый", text)
            self.assertNotIn("прежний текст", text)


class CliTests(unittest.TestCase):
    def test_a_clean_run_exits_zero_and_points_at_the_next_stage(self):
        with meeting(envelope(vtt(("00:00:01.000", "00:00:03.000", "<v Дмитрий>раз</v>")))) as (
            root,
            source,
        ):
            code, out, _ = run_main([str(root), str(source)])
            self.assertEqual(code, teams.EXIT_OK)
            self.assertIn("--from-stage speakers", out)

    def test_the_help_states_it_replaces_s1_to_s5(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            with self.assertRaises(SystemExit):
                teams.main(["--help"])
        text = out.getvalue()
        self.assertIn("S1", text)
        self.assertIn("--from-stage speakers", text)

    def test_the_module_docstring_says_it_is_not_a_pipeline_stage(self):
        self.assertIn("REPLACES stages S1–S5", teams.__doc__)

    def test_json_output_is_the_stage_report(self):
        with meeting(envelope(vtt(("00:00:01.000", "00:00:03.000", "<v Дмитрий>раз</v>")))) as (
            root,
            source,
        ):
            code, out, _ = run_main([str(root), str(source), "--json"])
            self.assertEqual(code, teams.EXIT_OK)
            report = json.loads(out)
            self.assertEqual(report["stage"], "teams_vtt_to_transcript")
            self.assertNotIn("rows", report)

    def test_a_missing_meeting_folder_is_an_argparse_error(self):
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            with self.assertRaises(SystemExit):
                teams.main(["/no/such/meeting", "/no/such/source.vtt"])
        self.assertIn("no such meeting folder", err.getvalue())


class ShotAlignmentTests(unittest.TestCase):
    def test_capture_times_are_parsed_from_the_tsv(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "shots.tsv"
            path.write_text("09:12:30\tслайд про релиз\n\n", encoding="utf-8")
            self.assertEqual(teams.parse_shots(path), [((9, 12, 30), "слайд про релиз")])

    def test_a_malformed_shot_line_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "shots.tsv"
            path.write_text("не время\tлейбл\n", encoding="utf-8")
            with self.assertRaises(teams.SourceError):
                teams.parse_shots(path)

    def test_the_window_leads_the_capture_because_a_shot_lags_its_slide(self):
        anchor = teams.parse_anchor("2026-07-29T08:00:00Z")
        rows = [
            {"start": 0.0, "end": 1.0, "speaker": "Дмитрий", "text": "слишком рано"},
            {"start": 700.0, "end": 701.0, "speaker": "Дмитрий", "text": "про слайд"},
            {"start": 780.0, "end": 781.0, "speaker": "Дмитрий", "text": "слишком поздно"},
        ]
        # 09:13:00 local, WEST → 08:13:00 UTC → t = 780 s; window [685, 800].
        text = teams.render_shot_alignment(rows, [((9, 13, 0), "слайд")], anchor, 1.0)
        self.assertIn("про слайд", text)
        self.assertIn("слишком поздно", text)
        self.assertNotIn("слишком рано", text)

    def test_a_meeting_crossing_local_midnight_still_aligns(self):
        # 23:00 UTC at +01:00 is 00:00 local, so the shot's local day is the day
        # *after* the anchor's UTC day. Taking the date from the anchor
        # unconditionally put the capture ~24 h before the meeting: no row matched,
        # the section printed empty rather than erroring, and hms() was handed a
        # negative it had no rendering for.
        anchor = teams.parse_anchor("2026-07-29T23:00:00Z")
        rows = [
            {"start": 1200.0, "end": 1201.0, "speaker": "Дмитрий", "text": "про слайд"},
        ]
        self.assertAlmostEqual(
            teams.shot_offset_seconds((0, 20, 0), anchor, 1.0), 1200.0
        )
        text = teams.render_shot_alignment(rows, [((0, 20, 0), "слайд")], anchor, 1.0)
        self.assertIn("про слайд", text)
        self.assertIn("00:20:00", text)

    def test_a_shot_taken_before_the_meeting_renders_a_signed_offset(self):
        anchor = teams.parse_anchor("2026-07-29T08:00:00Z")
        offset = teams.shot_offset_seconds((8, 55, 0), anchor, 1.0)  # 07:55 UTC
        self.assertAlmostEqual(offset, -300.0)
        self.assertEqual(teams.hms(offset), "-00:05:00")
        self.assertEqual(teams.hms(0), "00:00:00")
        self.assertEqual(teams.hms(3661), "01:01:01")

    def test_shots_without_an_anchor_exit_two(self):
        body = vtt(("00:00:01.000", "00:00:03.000", "<v Дмитрий>раз</v>"))
        with meeting(body, source_name="meeting.vtt") as (root, source):
            shots = root / "shots.tsv"
            shots.write_text("09:13:00\tслайд\n", encoding="utf-8")
            code, _, err = run_main([str(root), str(source), "--shots", str(shots)])
            self.assertEqual(code, teams.EXIT_USAGE)
            self.assertIn("createdDateTime", err)
            # And nothing was written: the alignment is validated *before* the
            # conversion, so the exit 2 is not sitting on top of good artifacts
            # that make the obvious retry hit the overwrite refusal instead.
            self.assertFalse(teams.transcript_path(root).exists())
            self.assertFalse(teams.stage_json_path(root).exists())

    def test_an_unreadable_shots_file_fails_before_the_transcript_is_written(self):
        body = envelope(vtt(("00:00:01.000", "00:00:03.000", "<v Дмитрий>раз</v>")))
        with meeting(body) as (root, source):
            missing = root / "nope.tsv"
            code, _, err = run_main([str(root), str(source), "--shots", str(missing)])
            self.assertEqual(code, teams.EXIT_USAGE)
            self.assertIn("nope.tsv", err)
            self.assertFalse(teams.transcript_path(root).exists())
            self.assertFalse(teams.stage_json_path(root).exists())

    def test_a_malformed_shots_line_fails_before_the_transcript_is_written(self):
        body = envelope(vtt(("00:00:01.000", "00:00:03.000", "<v Дмитрий>раз</v>")))
        with meeting(body) as (root, source):
            shots = root / "shots.tsv"
            shots.write_text("25:00:00\tслайд\n", encoding="utf-8")
            code, _, err = run_main([str(root), str(source), "--shots", str(shots)])
            self.assertEqual(code, teams.EXIT_USAGE)
            self.assertIn("shots", err)
            self.assertFalse(teams.transcript_path(root).exists())
            self.assertFalse(teams.stage_json_path(root).exists())

    def test_a_valid_shots_run_still_prints_the_alignment_and_exits_zero(self):
        body = envelope(
            vtt(("00:13:00.000", "00:13:04.000", "<v Дмитрий>про слайд</v>")),
            created="2026-07-29T08:00:00Z",
        )
        with meeting(body) as (root, source):
            shots = root / "shots.tsv"
            shots.write_text("09:13:00\tслайд про релиз\n", encoding="utf-8")
            code, out, _ = run_main([str(root), str(source), "--shots", str(shots)])
            self.assertEqual(code, teams.EXIT_OK)
            self.assertIn("SCREENSHOT ALIGNMENT", out)
            self.assertIn("слайд про релиз", out)
            self.assertIn("про слайд", out)
            self.assertTrue(teams.transcript_path(root).is_file())

    def test_a_refused_run_with_shots_reports_the_refusal(self):
        body = envelope(
            vtt(("00:13:00.000", "00:13:04.000", "<v Дмитрий>про слайд</v>")),
            created="2026-07-29T08:00:00Z",
        )
        with meeting(body, raw="# уже есть\n") as (root, source):
            shots = root / "shots.tsv"
            shots.write_text("09:13:00\tслайд\n", encoding="utf-8")
            code, out, _ = run_main([str(root), str(source), "--shots", str(shots)])
            self.assertEqual(code, teams.EXIT_USAGE)
            self.assertNotIn("SCREENSHOT ALIGNMENT", out)
            self.assertEqual(
                teams.transcript_path(root).read_text(encoding="utf-8"), "# уже есть\n"
            )

    def test_an_over_precise_graph_timestamp_still_parses(self):
        anchor = teams.parse_anchor("2026-07-29T08:00:39.1234567Z")
        self.assertIsNotNone(anchor)
        self.assertEqual(anchor.hour, 8)

    def test_an_unparseable_anchor_is_none_rather_than_a_crash(self):
        self.assertIsNone(teams.parse_anchor("не дата"))
        self.assertIsNone(teams.parse_anchor(None))

    def test_a_stamp_without_a_timezone_designator_is_read_as_utc(self):
        # It parses fine but comes out naive, and render_shot_alignment subtracts
        # it from an aware datetime — a bare TypeError traceback *after*
        # transcript.raw.md was already written. Graph stamps UTC.
        anchor = teams.parse_anchor("2026-07-29T08:00:00")
        self.assertIsNotNone(anchor)
        self.assertEqual(anchor.utcoffset(), dt.timedelta(0))

    def test_every_parseable_anchor_shape_is_aware(self):
        for value in (
            "2026-07-29T08:00:00Z",
            "2026-07-29T08:00:00",
            "2026-07-29T08:00:39.1234567Z",
            "2026-07-29T08:00:00.123456",
            "2026-07-29T10:00:00+02:00",
            "2026-07-29 08:00:00",
        ):
            with self.subTest(value=value):
                anchor = teams.parse_anchor(value)
                self.assertIsNotNone(anchor)
                self.assertIsNotNone(anchor.utcoffset())

    def test_a_naive_stamp_aligns_shots_instead_of_raising(self):
        anchor = teams.parse_anchor("2026-07-29T08:00:00")
        rows = [{"start": 780.0, "end": 781.0, "speaker": "Дмитрий", "text": "про слайд"}]
        text = teams.render_shot_alignment(rows, [((9, 13, 0), "слайд")], anchor, 1.0)
        self.assertIn("про слайд", text)

    def test_a_naive_stamp_reaches_the_same_offset_as_the_explicit_utc_one(self):
        naive = teams.parse_anchor("2026-07-29T08:00:00")
        aware = teams.parse_anchor("2026-07-29T08:00:00Z")
        rows = [{"start": 780.0, "end": 781.0, "speaker": "Д", "text": "про слайд"}]
        shots = [((9, 13, 0), "слайд")]
        self.assertEqual(
            teams.render_shot_alignment(rows, shots, naive, 1.0),
            teams.render_shot_alignment(rows, shots, aware, 1.0),
        )


class SupersededLocalAsrTests(unittest.TestCase):
    """A conversion over a local-ASR meeting must not leave that run's stage
    JSONs readable as this transcript's provenance.

    `verify.py` decides the source from the *absence* of a transcribe stage
    JSON, so a `--force` conversion that left one behind made quality.md call an
    official Teams transcript local ASR — and then score the previous run's
    per-word confidence and put its diarization coverage through a hard gate.
    """

    EXISTING = "# прежний — транскрипт\n\n**[00:00:00] SPK_01:** прежний текст\n"
    SOURCE = staticmethod(
        lambda: envelope(vtt(("00:00:01.000", "00:00:03.000", "<v Дмитрий>новый</v>")))
    )

    def _local_asr_artifacts(self, root):
        """The S1–S5 artifacts a finished local-ASR run leaves in a meeting."""
        work = root / ".acta-notes"
        written = {}
        for name in teams.SUPERSEDED_WORK_ARTIFACTS:
            path = work / name
            path.write_text(json.dumps({"stage": name, "status": "ok"}), encoding="utf-8")
            written[name] = path
        for name in teams.SUPERSEDED_ROOT_ARTIFACTS:
            path = root / name
            path.write_text(json.dumps({"stage": name, "status": "ok"}), encoding="utf-8")
            written[name] = path
        return written

    def test_a_forced_conversion_archives_them(self):
        with meeting(self.SOURCE(), raw=self.EXISTING) as (root, source):
            written = self._local_asr_artifacts(root)
            report = teams.run(root, source, force=True)

            self.assertEqual(report["status"], teams.STATUS_OK)
            self.assertEqual(
                sorted(report["superseded"]), sorted(written)
            )
            self.assertEqual(report["supersede_failed"], [])
            archive = teams.superseded_dir(root)
            for name, path in written.items():
                self.assertFalse(path.exists(), name)
                self.assertTrue((archive / name).is_file(), name)

    def test_verify_then_calls_the_transcript_a_teams_one(self):
        verify = _ctx.load("verify")
        speakers = _ctx.load("speakers")
        with meeting(self.SOURCE(), raw=self.EXISTING) as (root, source):
            self._local_asr_artifacts(root)
            self.assertEqual(
                verify.detect_source(verify.load_inputs(root)), verify.SOURCE_LOCAL_ASR
            )
            self.assertTrue(speakers.is_local_asr(root))

            report = teams.run(root, source, force=True)
            # main() persists the stage JSON on an OK conversion, and it is that
            # file — not the *absence* of transcribe.json — that both readers key
            # the Teams path on.
            self.assertEqual(report["status"], teams.STATUS_OK)
            teams.write_stage_json(root, report)

            self.assertEqual(
                verify.detect_source(verify.load_inputs(root)), verify.SOURCE_TEAMS_VTT
            )
            self.assertFalse(speakers.is_local_asr(root))
            self.assertEqual(speakers.detect_source(root), speakers.SOURCE_TEAMS_VTT)

    def test_the_s6_artifacts_are_left_for_the_resume_to_rewrite(self):
        # `pipeline.py --from-stage speakers` rebuilds both, and it re-runs
        # precisely because they are now older than the transcript.
        with meeting(self.SOURCE(), raw=self.EXISTING) as (root, source):
            (root / "speakers.json").write_text("{}", encoding="utf-8")
            (root / "transcript.labeled.md").write_text("# labelled\n", encoding="utf-8")

            teams.run(root, source, force=True)

            self.assertTrue((root / "speakers.json").is_file())
            self.assertTrue((root / "transcript.labeled.md").is_file())

    def test_a_teams_only_meeting_archives_nothing(self):
        with meeting(self.SOURCE()) as (root, source):
            report = teams.run(root, source)
            self.assertEqual(report["superseded"], [])
            self.assertFalse(teams.superseded_dir(root).exists())

    def test_a_second_conversion_overwrites_the_earlier_archive(self):
        with meeting(self.SOURCE(), raw=self.EXISTING) as (root, source):
            archive = teams.superseded_dir(root)
            archive.mkdir(parents=True)
            (archive / "transcribe.json").write_text('{"round": 1}', encoding="utf-8")
            (root / ".acta-notes" / "transcribe.json").write_text(
                '{"round": 2}', encoding="utf-8"
            )

            report = teams.run(root, source, force=True)

            self.assertEqual(report["status"], teams.STATUS_OK)
            self.assertEqual(
                json.loads((archive / "transcribe.json").read_text(encoding="utf-8")),
                {"round": 2},
            )

    def _blocked_archive(self, root):
        """Make ``transcribe.json``'s archive destination a directory, so
        ``Path.replace`` raises and the supersession cannot finish."""
        source = root / ".acta-notes" / "transcribe.json"
        if not source.exists():
            source.write_text(
                json.dumps({"stage": "transcribe", "status": "ok"}), encoding="utf-8"
            )
        (teams.superseded_dir(root) / "transcribe.json").mkdir(parents=True)

    def test_an_archive_that_cannot_be_moved_fails_the_conversion(self):
        # The failure path is the bug this whole class exists to prevent: a Teams
        # transcript beside a readable local-ASR transcribe.json. So it must not
        # be reachable from a green exit — the conversion stops with the folder
        # exactly as it was.
        with meeting(self.SOURCE()) as (root, source):
            self._blocked_archive(root)

            report = teams.run(root, source)

            self.assertEqual(report["status"], teams.STATUS_FAILED)
            self.assertFalse(report["written"])
            self.assertEqual(report["superseded"], [])
            self.assertEqual(len(report["supersede_failed"]), 1)
            self.assertIn("transcribe.json", report["supersede_failed"][0])
            self.assertFalse(teams.transcript_path(root).exists())
            # Nor a half-written sibling left behind by the staged render.
            self.assertEqual(
                sorted(p.name for p in root.glob("transcript*")), []
            )
            self.assertIn("could not archive", teams.render_human(report))

    def test_that_failure_exits_non_zero_and_withholds_the_next_step(self):
        with meeting(self.SOURCE()) as (root, source):
            self._blocked_archive(root)

            code, out, _ = run_main([str(root), str(source)])

            self.assertEqual(code, teams.EXIT_FAILED)
            self.assertNotIn("next: pipeline.py", out)
            self.assertIn("could not archive", out)

    def test_that_failure_leaves_no_stage_json_behind_either(self):
        """"Exactly as it was" includes ``.acta-notes/teams_vtt.json``.

        The report holds this conversion's cue counts, speakers and duration —
        the numbers of a transcript that was never installed. Persisting them
        states the provenance of a file that does not exist.
        """
        with meeting(self.SOURCE()) as (root, source):
            self._blocked_archive(root)

            code, _, _ = run_main([str(root), str(source)])

            self.assertEqual(code, teams.EXIT_FAILED)
            self.assertFalse(teams.stage_json_path(root).exists())

    def test_a_failed_rerun_keeps_the_stage_json_of_the_conversion_on_disk(self):
        # Same rule as the refusal: the previous conversion's numbers still
        # describe transcript.raw.md, so a run that changed nothing must not
        # replace them with its own failure.
        with meeting(self.SOURCE(), raw=self.EXISTING) as (root, source):
            stage = teams.stage_json_path(root)
            stage.parent.mkdir(parents=True, exist_ok=True)
            stage.write_text('{"marker": "previous"}', encoding="utf-8")
            self._blocked_archive(root)

            code, _, _ = run_main([str(root), str(source), "--force"])

            self.assertEqual(code, teams.EXIT_FAILED)
            self.assertEqual(
                json.loads(stage.read_text(encoding="utf-8")), {"marker": "previous"}
            )

    def test_a_forced_conversion_keeps_the_previous_transcript_on_that_failure(self):
        verify = _ctx.load("verify")
        with meeting(self.SOURCE(), raw=self.EXISTING) as (root, source):
            written = self._local_asr_artifacts(root)
            self._blocked_archive(root)

            report = teams.run(root, source, force=True)

            self.assertEqual(report["status"], teams.STATUS_FAILED)
            self.assertEqual(
                teams.transcript_path(root).read_text(encoding="utf-8"), self.EXISTING
            )
            # Rolled back, not left half-done: the artifacts that *did* move are
            # put back, so the folder is still the coherent local-ASR run it was —
            # a transcript verify would otherwise start calling a Teams one.
            for name, path in written.items():
                self.assertTrue(path.is_file(), name)
            self.assertEqual(report["superseded"], [])
            self.assertEqual(
                verify.detect_source(verify.load_inputs(root)), verify.SOURCE_LOCAL_ASR
            )


class ShotValidationTests(unittest.TestCase):
    """An out-of-range stamp used to reach ``dt.datetime`` in
    render_shot_alignment and raise *after* transcript.raw.md was written — a
    bare traceback on an otherwise successful conversion."""

    def _shots(self, body):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "shots.tsv"
            path.write_text(body, encoding="utf-8")
            return teams.parse_shots(path)

    def test_an_impossible_hour_is_a_source_error(self):
        with self.assertRaises(teams.SourceError):
            self._shots("24:10:00\tslide\n")

    def test_impossible_minutes_and_seconds_are_source_errors(self):
        for body in ("01:60:00\tslide\n", "01:00:60\tslide\n", "-1:00:00\tslide\n"):
            with self.subTest(body=body):
                with self.assertRaises(teams.SourceError):
                    self._shots(body)

    def test_a_valid_boundary_stamp_still_parses(self):
        self.assertEqual(
            self._shots("23:59:59\tlast slide\n"),
            [((23, 59, 59), "last slide")],
        )


class NonCueBlockTests(unittest.TestCase):
    """A `NOTE`/`STYLE` block must never be read as a cue.

    WebVTT comments are free text and may legally quote a timestamp arrow. An
    unanchored scan over the whole document matched that quote as a cue, and its
    body then ran to the next blank line — swallowing the real cue that followed
    and stamping the transcript with the comment's timecodes. Silently: no
    warning, no dropped count, and every downstream artifact built on top of it.
    """

    def test_a_note_quoting_an_arrow_does_not_become_a_cue(self):
        cues = teams.parse_cues(
            "WEBVTT\n\n"
            "NOTE ошибка была в 00:00:01.000 --> 00:00:02.000 — не настоящая реплика\n\n"
            "00:00:10.000 --> 00:00:12.000\n<v Дмитрий>настоящая реплика</v>\n"
        )
        self.assertEqual(
            [(c["start"], c["end"], c["speaker"], c["text"]) for c in cues],
            [(10.0, 12.0, "Дмитрий", "настоящая реплика")],
        )

    def test_a_note_glued_to_a_cue_drops_it_loudly_rather_than_guessing(self):
        # A comment running straight into a cue is malformed, and salvaging it
        # used to recover the cue. That salvage is gone: a multi-line NOTE whose
        # own prose contains a standalone timing line is the *same shape*, and
        # there the salvage fabricated a transcript line with the comment's
        # timecodes. Between losing a cue and inventing one, losing wins — and
        # unlike the fabrication, the loss is counted and printed.
        content = (
            "WEBVTT\n\n"
            "NOTE см. 00:00:01.000 --> 00:00:02.000\n"
            "00:00:10.000 --> 00:00:12.000\n<v Дмитрий>реплика</v>\n"
        )
        self.assertEqual(teams.parse_cues(content), [])
        self.assertEqual(teams.count_unparsed_timing_blocks(content), 1)

    def test_a_webvtt_header_glued_to_a_cue_is_still_salvaged(self):
        # WEBVTT/STYLE/REGION headers are single fixed lines with no free prose
        # below them, so the ambiguity that killed the NOTE salvage does not arise.
        content = "WEBVTT\n00:00:10.000 --> 00:00:12.000\n<v Дмитрий>реплика</v>\n"
        self.assertEqual(
            [(c["start"], c["text"]) for c in teams.parse_cues(content)],
            [(10.0, "реплика")],
        )
        self.assertEqual(teams.count_unparsed_timing_blocks(content), 0)

    def test_a_comment_quoting_an_arrow_inline_is_not_counted_as_a_loss(self):
        content = (
            "WEBVTT\n\n"
            "NOTE ошибка была в 00:00:01.000 --> 00:00:02.000 — не реплика\n\n"
            "00:00:10.000 --> 00:00:12.000\n<v Дмитрий>реплика</v>\n"
        )
        self.assertEqual([c["text"] for c in teams.parse_cues(content)], ["реплика"])
        self.assertEqual(teams.count_unparsed_timing_blocks(content), 0)

    def test_a_style_block_contributes_nothing(self):
        cues = teams.parse_cues(
            "WEBVTT\n\nSTYLE\n::cue { color: red }\n\n"
            "00:00:01.000 --> 00:00:03.000\n<v A>раз</v>\n"
        )
        self.assertEqual([c["text"] for c in cues], ["раз"])

    def test_a_note_only_document_yields_no_cues(self):
        self.assertEqual(teams.parse_cues("WEBVTT\n\nNOTE просто комментарий\n"), [])

    def test_a_cue_identifier_line_is_allowed_before_the_timing(self):
        cues = teams.parse_cues(
            "WEBVTT\n\ncue-7\n00:00:01.000 --> 00:00:03.000\n<v A>раз</v>\n"
        )
        self.assertEqual([(c["start"], c["text"]) for c in cues], [(1.0, "раз")])

    def test_a_multiline_note_cannot_donate_its_own_prose_as_a_cue(self):
        # The claim "a timing line on its own is a shape prose cannot take" was
        # false: a multi-line NOTE documenting the cue format puts one on its own
        # line. Skipping every line above it made the *next* prose line a
        # transcript line with the NOTE's own timecodes — fabricated text at a
        # fabricated time, in the verbatim artifact every later stage is a view
        # over, with no dropped-cue counter to notice it by.
        content = (
            "WEBVTT\n\n"
            "NOTE таймкоды выглядят так, например:\n"
            "00:01:02.000 --> 00:01:03.000\n"
            "то есть HH:MM:SS.mmm --> HH:MM:SS.mmm\n\n"
            "00:00:01.000 --> 00:00:03.000\n<v Дмитрий>настоящая реплика</v>\n"
        )
        cues = teams.parse_cues(content)
        self.assertEqual(
            [(c["start"], c["speaker"], c["text"]) for c in cues],
            [(1.0, "Дмитрий", "настоящая реплика")],
        )
        # And the refusal is visible rather than silent.
        self.assertEqual(teams.count_unparsed_timing_blocks(content), 1)

    def test_a_style_block_is_not_counted_as_a_lost_cue(self):
        content = (
            "WEBVTT\n\nSTYLE\n::cue { color: red }\n\n"
            "00:00:01.000 --> 00:00:03.000\n<v A>раз</v>\n"
        )
        self.assertEqual([c["text"] for c in teams.parse_cues(content)], ["раз"])
        self.assertEqual(teams.count_unparsed_timing_blocks(content), 0)


class TimestampRangeTests(unittest.TestCase):
    """An out-of-range field is not a cue, and is never reinterpreted as one."""

    def test_an_out_of_range_stamp_is_refused_rather_than_folded_over(self):
        # `\\d{2}` accepted 99 minutes and 99 seconds, and to_seconds turned
        # 00:99:99.000 into a confident 1 h 40 m — a fabricated timecode on a real
        # transcript line, where parse_shots range-checks the same fields.
        content = "WEBVTT\n\n00:99:99.000 --> 00:99:99.500\n<v A>упс</v>\n"
        self.assertEqual(teams.parse_cues(content), [])
        self.assertEqual(teams.count_unparsed_timing_blocks(content), 1)

    def test_the_legal_shapes_all_still_parse(self):
        cases = {
            "00:00:01.000 --> 00:00:03.000": (1.0, 3.0),
            "00:01.000 --> 00:03.000": (1.0, 3.0),          # MM:SS, no hours
            "1:02:03.000 --> 1:02:04.000": (3723.0, 3724.0),  # single-digit hours
            "00:59:59.999 --> 01:00:00.000": (3599.999, 3600.0),
            "00:00:01,000 --> 00:00:03,000": (1.0, 3.0),    # comma decimal
        }
        for timing, expected in cases.items():
            with self.subTest(timing=timing):
                cues = teams.parse_cues(f"WEBVTT\n\n{timing}\n<v A>раз</v>\n")
                self.assertEqual(len(cues), 1, timing)
                self.assertAlmostEqual(cues[0]["start"], expected[0], places=3)
                self.assertAlmostEqual(cues[0]["end"], expected[1], places=3)

    def test_the_count_reaches_the_report_and_the_human_summary(self):
        source = (
            "WEBVTT\n\n"
            "00:99:99.000 --> 00:99:99.500\n<v A>мусор</v>\n\n"
            "00:00:01.000 --> 00:00:03.000\n<v Дмитрий>реплика</v>\n"
        )
        with meeting(envelope(source)) as (root, path):
            report = teams.run(root, path)
        self.assertEqual(report["status"], teams.STATUS_OK)
        self.assertEqual(report["cue_count"], 1)
        self.assertEqual(report["unparsed_timing_block_count"], 1)
        self.assertIn("were not well-formed cues", teams.render_human(report))


class UnclosedVoiceSpanTests(unittest.TestCase):
    def test_an_unclosed_span_does_not_absorb_the_next_speaker(self):
        """`<v A>da<v B>soglasna` is two speakers, not one saying "dasoglasna".

        Teams does not always close a voice span, and running each span to
        `</v>|\\Z` let the first speaker swallow the second's text — the same
        dropped-second-voice failure `finditer` was introduced to fix, one level
        down and with the words silently reattributed instead of lost.
        """
        cues = teams.parse_cues(
            vtt(("00:00:01.000", "00:00:03.000", "<v A>да<v B>согласна"))
        )
        self.assertEqual(
            [(c["speaker"], c["text"]) for c in cues], [("A", "да"), ("B", "согласна")]
        )

    def test_closed_spans_parse_the_same_way(self):
        cues = teams.parse_cues(
            vtt(("00:00:01.000", "00:00:03.000", "<v A>да</v><v B>согласна</v>"))
        )
        self.assertEqual(
            [(c["speaker"], c["text"]) for c in cues], [("A", "да"), ("B", "согласна")]
        )

    def test_an_explicit_close_still_ends_the_span(self):
        # Text after `</v>` belongs to nobody, and must not be credited to A.
        spans = teams.split_voice_spans("<v A>да</v> ничей текст <v B>согласна</v>")
        self.assertEqual(spans, [("A", "да"), ("B", "согласна")])


class BomTests(unittest.TestCase):
    def test_a_bom_on_the_json_envelope_is_still_parsed_as_json(self):
        """A BOM must not silently demote the envelope to raw WEBVTT.

        `json.loads` raises on a leading BOM; the generic `except ValueError`
        swallowed that, the envelope was then read as WEBVTT, found no cues, and
        the operator was told the transcript "holds no WEBVTT cues" — pointing at
        a nonexistent problem and dropping the `createdDateTime` anchor
        `--shots` needs.
        """
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "transcript.json"
            body = envelope(vtt(("00:00:01.000", "00:00:02.000", "<v A>раз</v>")))
            path.write_text("﻿" + body, encoding="utf-8")
            source = teams.read_source(path)
        self.assertEqual(source["kind"], "m365-json")
        self.assertIsNotNone(source["created"])
        self.assertEqual([c["text"] for c in teams.parse_cues(source["content"])], ["раз"])

    def test_a_bom_on_bare_webvtt_does_not_hide_the_first_cue(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "transcript.vtt"
            path.write_text(
                "﻿" + vtt(("00:00:01.000", "00:00:02.000", "<v A>раз</v>")),
                encoding="utf-8",
            )
            source = teams.read_source(path)
        self.assertEqual(source["kind"], "webvtt")
        self.assertEqual([c["text"] for c in teams.parse_cues(source["content"])], ["раз"])


class HtmlEntityTests(unittest.TestCase):
    """A WebVTT cue payload is parsed as HTML, so speech is entity-escaped.

    Nothing unescaped it, so ``AT&T``, ``R&D`` and ``M&A`` — ordinary in a real
    meeting — landed in ``transcript.raw.md`` as ``AT&amp;T``. That file is the
    verbatim forensic artifact ``speakers.py``, ``verify.py`` and the summary all
    read.
    """

    def test_ampersands_and_angle_brackets_are_unescaped(self):
        cues = teams.parse_cues(
            vtt(("00:00:01.000", "00:00:03.000", "<v A>AT&amp;T, R&amp;D и 5 &lt; 7</v>"))
        )
        self.assertEqual([c["text"] for c in cues], ["AT&T, R&D и 5 < 7"])

    def test_an_escaped_tag_stays_literal_text(self):
        """Unescaping runs after tag stripping, so it cannot mint new markup."""
        cues = teams.parse_cues(
            vtt(("00:00:01.000", "00:00:03.000", "<v A>писал &lt;v Fake&gt; в чате</v>"))
        )
        self.assertEqual([c["text"] for c in cues], ["писал <v Fake> в чате"])

    def test_a_speaker_name_is_unescaped_too(self):
        cues = teams.parse_cues(
            vtt(("00:00:01.000", "00:00:03.000", "<v Procter &amp; Gamble>привет</v>"))
        )
        self.assertEqual([c["speaker"] for c in cues], ["Procter & Gamble"])

    def test_an_escaped_colon_cannot_smuggle_itself_into_a_speaker(self):
        """The ``:``/``*`` fold runs on the unescaped name, not before it."""
        cues = teams.parse_cues(
            vtt(("00:00:01.000", "00:00:03.000", "<v A&#58;B>привет</v>"))
        )
        self.assertNotIn(":", cues[0]["speaker"])


class DroppedContentTests(unittest.TestCase):
    """Every cue this converter refuses is either kept or counted, never both-nor.

    Two shapes leaked. Text before the first ``<v>`` opener simply vanished (the
    span loop only ever read from ``opener.end()``), and a valid cue whose body
    strips to nothing was dropped by ``parse_cues`` while
    ``count_unparsed_timing_blocks`` — which re-derived readability from
    ``parse_cue_block() is None`` — counted it as fine. Both produced a clean
    report over a short transcript, which is what the counter exists to prevent.
    """

    def test_text_before_the_first_voice_tag_is_kept_as_unknown(self):
        cues = teams.parse_cues(
            vtt(("00:00:01.000", "00:00:03.000", "Say hi: <v A>Hello</v>"))
        )
        self.assertEqual(
            [(c["speaker"], c["text"]) for c in cues],
            [(teams.UNKNOWN_SPEAKER, "Say hi:"), ("A", "Hello")],
        )

    def test_markup_only_lead_text_adds_no_cue(self):
        cues = teams.parse_cues(
            vtt(("00:00:01.000", "00:00:03.000", "<c.yellow> <v A>Hello</v>"))
        )
        self.assertEqual([(c["speaker"], c["text"]) for c in cues], [("A", "Hello")])

    def test_an_empty_cue_between_two_real_ones_is_counted(self):
        content = vtt(
            ("00:00:01.000", "00:00:02.000", "<v A>раз</v>"),
            ("00:00:02.000", "00:00:03.000", "<v B></v>"),
            ("00:00:03.000", "00:00:04.000", "<v A>два</v>"),
        )
        self.assertEqual([c["text"] for c in teams.parse_cues(content)], ["раз", "два"])
        self.assertEqual(teams.count_unparsed_timing_blocks(content), 1)

    def test_a_healthy_file_still_counts_zero(self):
        content = vtt(
            ("00:00:01.000", "00:00:02.000", "<v A>раз</v>"),
            ("00:00:02.000", "00:00:03.000", "<v B>два</v>"),
        )
        self.assertEqual(teams.count_unparsed_timing_blocks(content), 0)

    def test_a_bare_header_block_is_not_counted_as_a_lost_cue(self):
        content = vtt(("00:00:01.000", "00:00:02.000", "<v A>раз</v>"))
        self.assertEqual(teams.count_unparsed_timing_blocks(content), 0)


class ShotsEncodingTests(unittest.TestCase):
    def test_a_bom_on_the_shots_file_does_not_fail_the_first_line(self):
        """``utf-8-sig``, matching ``read_source``.

        A shots file saved by a Windows editor or exported from Excel carries a
        BOM; it glued itself to the first timestamp and failed a well-formed file
        with an error naming the wrong problem.
        """
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "shots.tsv"
            path.write_text("﻿09:12:30\tslide one\n09:13:00\tslide two\n", encoding="utf-8")
            shots = teams.parse_shots(path)
        self.assertEqual(shots, [((9, 12, 30), "slide one"), ((9, 13, 0), "slide two")])


class NoSalvagePathTests(unittest.TestCase):
    def test_the_converter_names_neither_salvage_path(self):
        # Both sources are scheduled to disappear; nothing may reference them.
        text = _ctx.script_path("teams_vtt_to_transcript").read_text(encoding="utf-8")
        self.assertNotIn("air-rescue", text)
        self.assertNotIn("_archive-2026-07-28", text)


if __name__ == "__main__":
    unittest.main()
