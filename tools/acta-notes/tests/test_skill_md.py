"""Doc-replay tests for ``SKILL.md``.

The skill body is a document Claude follows literally, so the things that can rot
in it are mechanical: a script name that no longer exists, a path that would not
resolve after the plugin is installed, a trigger phrase lost in an edit, a rule
quietly dropped. Each of those is asserted here against the real ``scripts/``
directory — there is nothing to mock.
"""

import _ctx

import re
import unittest

SKILL_MD = _ctx.SKILL_DIR / "SKILL.md"
PLUGIN_ROOT_PREFIX = "$CLAUDE_PLUGIN_ROOT/skills/acta-notes/"

#: Russian routing phrases salvaged from the Air skill. Losing any of these
#: breaks "как обычно" once that skill is deleted.
REQUIRED_TRIGGERS = (
    "транскрибируй встречу",
    "транскрибируй последнюю встречу",
    "сделай саммари по встрече",
    "булеты по встрече",
    "суммаризируй запись",
    "подтяни скриншоты к встрече",
    "найди когда был созвон по",
    "обработай запись из ~/Acta",
    "transcribe the meeting",
    "summarize this recording",
    "как обычно",
)

#: Every transcript file, and the producer the body must name for it.
PRODUCERS = {
    "transcript.raw.md": ("merge.py", "teams_vtt_to_transcript.py"),
    "transcript.labeled.md": ("speakers.py apply",),
    "transcript.md": ("you, at S7",),
}


def read_skill():
    return SKILL_MD.read_text(encoding="utf-8")


def front_matter(text):
    """The YAML block between the leading ``---`` fences."""
    match = re.match(r"^---\n(.*?)\n---\n", text, re.DOTALL)
    if match is None:
        raise AssertionError("SKILL.md has no front matter")
    return match.group(1)


def folded(text):
    """Front matter with YAML's folded-scalar line breaks joined back up.

    ``description: >-`` wraps mid-phrase, so a trigger phrase must be matched
    against the folded form — not against the literal file bytes.
    """
    return re.sub(r"\s*\n\s+", " ", front_matter(text))


class TestFrontMatter(unittest.TestCase):
    def test_exists(self):
        self.assertTrue(SKILL_MD.is_file(), f"missing {SKILL_MD}")

    def test_name_matches_the_skill_directory(self):
        fm = front_matter(read_skill())
        self.assertRegex(fm, r"(?m)^name:\s*acta-notes\s*$")
        self.assertEqual(_ctx.SKILL_DIR.name, "acta-notes")

    def test_carries_every_russian_trigger_phrase(self):
        fm = folded(read_skill())
        missing = [phrase for phrase in REQUIRED_TRIGGERS if phrase not in fm]
        self.assertEqual([], missing, f"trigger phrases lost from the description: {missing}")

    def test_description_is_a_single_yaml_scalar(self):
        fm = front_matter(read_skill())
        # A folded scalar (`>-`) is what the sibling plugins use; the point of
        # the assertion is that the multi-line description stays one key.
        keys = re.findall(r"^(\w[\w-]*):", fm, re.MULTILINE)
        self.assertEqual(["name", "description"], keys)


class TestScriptReferences(unittest.TestCase):
    def setUp(self):
        self.text = read_skill()
        self.scripts = {p.name for p in _ctx.SCRIPTS_DIR.iterdir() if p.suffix in (".py", ".sh")}

    def test_every_referenced_script_exists(self):
        referenced = set(re.findall(r"[\w./$-]*\b([\w_]+\.(?:py|sh))\b", self.text))
        unknown = sorted(name for name in referenced if name not in self.scripts)
        self.assertEqual([], unknown, f"SKILL.md names scripts that do not exist: {unknown}")

    def test_every_script_path_is_plugin_root_relative(self):
        # Any mention that carries a directory component must resolve after the
        # plugin is installed — i.e. start at $CLAUDE_PLUGIN_ROOT. Bare names in
        # prose ("`merge.py` writes …") are fine and are not paths.
        paths = re.findall(r"[\w$./~-]*/[\w_]+\.(?:py|sh)\b", self.text)
        self.assertTrue(paths, "SKILL.md shows no runnable script path at all")
        for path in paths:
            self.assertTrue(
                path.startswith(PLUGIN_ROOT_PREFIX),
                f"script path not rooted at $CLAUDE_PLUGIN_ROOT: {path}",
            )

    def test_no_absolute_or_home_relative_skill_path(self):
        for bad in ("~/.claude/plugins", "tools/acta-notes/plugin", "air-rescue", "_archive-2026"):
            self.assertNotIn(bad, self.text, f"SKILL.md leaks a non-installed path: {bad}")

    def test_pipeline_and_converter_are_both_invoked(self):
        for script in ("pipeline.py", "teams_vtt_to_transcript.py", "doctor.py", "bootstrap.sh"):
            self.assertIn(
                PLUGIN_ROOT_PREFIX + "scripts/" + script,
                self.text,
                f"{script} is never shown with a runnable path",
            )


class TestArtifactChain(unittest.TestCase):
    def setUp(self):
        self.text = read_skill()

    def test_all_three_transcripts_are_named(self):
        for name in PRODUCERS:
            self.assertIn(name, self.text)

    def test_each_transcript_names_its_producer(self):
        for name, producers in PRODUCERS.items():
            # The chain table row for this file: everything up to the newline.
            row = next(
                (line for line in self.text.splitlines() if line.startswith(f"| `{name}`")),
                None,
            )
            self.assertIsNotNone(row, f"no artifact-chain row for {name}")
            for producer in producers:
                self.assertIn(producer, row, f"{name}'s row does not name {producer}")

    def test_transcript_md_is_claudes_and_no_script_writes_it(self):
        self.assertRegex(self.text, r"No script ever writes `transcript\.md`")
        self.assertIn("quality.md", self.text)
        self.assertRegex(
            self.text,
            r"`\.acta-notes/quality\.md` prepended \*\*verbatim\*\*|prepended \*\*verbatim\*\*",
        )

    def test_every_meeting_artifact_is_named_where_its_script_writes_it(self):
        """A `<meeting>/…` path in the body is an instruction Claude follows.

        Naming `.acta-notes/speakers.json` when `speakers.py` writes it at the
        meeting root sends the S6 review at a file that does not exist — which
        is precisely the step that stops Claude guessing names.
        """
        producers = {
            "speakers.json": _ctx.load("speakers").speakers_json_path,
            "diarization.json": _ctx.load("diarize").stage_json_path,
            "transcript.raw.md": _ctx.load("merge").transcript_path,
            "transcript.labeled.md": _ctx.load("speakers").labeled_transcript_path,
            "dicta.json": _ctx.load("dicta_overlay").stage_json_path,
        }
        for match in re.finditer(r"`<meeting>/([^`]+)`", self.text):
            named = match.group(1)
            basename = named.rsplit("/", 1)[-1]
            producer = producers.get(basename)
            if producer is None:
                continue
            with self.subTest(path=named):
                self.assertEqual(
                    str(producer("<meeting>")),
                    f"<meeting>/{named}",
                    f"SKILL.md puts {basename} somewhere its producer does not",
                )

    def test_raw_transcript_has_exactly_two_producers(self):
        row = next(line for line in self.text.splitlines() if line.startswith("| `transcript.raw.md`"))
        self.assertIn("merge.py", row)
        self.assertIn("teams_vtt_to_transcript.py", row)
        self.assertIn("--force", row)


class TestTeamsFork(unittest.TestCase):
    def setUp(self):
        self.text = read_skill()

    def test_fork_is_described_as_mutually_exclusive(self):
        self.assertIn("mutually exclusive", self.text)

    def test_converter_is_not_a_pipeline_stage(self):
        self.assertRegex(
            self.text,
            r"converter is \*\*not\*\* a stage inside `pipeline\.py`",
        )
        self.assertIn("`pipeline.py` never invokes it", self.text)

    def test_resume_point_is_documented(self):
        self.assertIn("--from-stage speakers", self.text)

    def test_pipeline_stage_order_is_stated(self):
        order = [
            "doctor",
            "prep_audio",
            "gate",
            "transcribe",
            "diarize",
            "merge",
            "speakers build",
            "speakers apply",
            "dicta_overlay",
            "verify",
        ]
        line = next(
            (
                chunk
                for chunk in self.text.split("\n\n")
                if "prep_audio" in chunk and "speakers apply" in chunk
            ),
            None,
        )
        self.assertIsNotNone(line, "the S1–S6 stage order is not stated in one place")
        positions = [line.index(stage) for stage in order]
        self.assertEqual(sorted(positions), positions, "stages are listed out of order")


class TestDictationOverlay(unittest.TestCase):
    """S6.5 is only useful if the reader is told what each verdict licenses."""

    def setUp(self):
        self.text = read_skill()
        self.summary_format = (
            _ctx.SKILL_DIR / "references" / "summary-format.md"
        ).read_text(encoding="utf-8")

    def test_the_stage_is_documented_with_its_artifact(self):
        self.assertIn("dicta_overlay.py", self.text)
        self.assertIn("`<meeting>/dicta.json`", self.text)

    def test_all_three_verdicts_are_named(self):
        for verdict in ("`matched`", "`suspected`", "`unmatched`"):
            self.assertIn(verdict, self.text, f"SKILL.md never names {verdict}")

    def test_a_suspicion_is_not_a_licence_to_exclude(self):
        self.assertIn("never exclude on this evidence", self.text)

    def test_the_summary_rules_are_in_the_reference_claude_follows(self):
        self.assertIn("голосовой ввод, не реплика встречи", self.summary_format)
        self.assertIn("never derived from a dictation span alone", self.summary_format)

    def test_the_transcript_marking_is_specified_exactly(self):
        self.assertIn("⟨диктовка⟩", self.text)


class TestHardRules(unittest.TestCase):
    def setUp(self):
        self.text = read_skill()

    def test_source_of_truth_rule(self):
        self.assertIn("`transcript.raw.md` is the source of truth", self.text)
        self.assertIn("reversible view", self.text)

    def test_no_attribution_on_diarization_alone(self):
        self.assertIn(
            "never attributed to a person on diarization alone",
            self.text,
        )
        self.assertIn("D8", self.text)

    def test_transcripts_leave_the_machine(self):
        self.assertIn("Transcripts leave the machine", self.text)
        self.assertIn("D7", self.text)

    def test_cleanup_constraints_are_both_present(self):
        self.assertIn("Preserve speaker markers", self.text)
        self.assertIn("Never invent content", self.text)


class TestOperatorGuidance(unittest.TestCase):
    def setUp(self):
        self.text = read_skill()

    def test_num_speakers_and_attendees_are_explained(self):
        self.assertIn("--num-speakers", self.text)
        self.assertIn("--attendees", self.text)

    def test_optional_models_are_marked_non_blocking(self):
        for model in ("sortformer", "ls-eend", "parakeet-ctc-110m-coreml"):
            self.assertIn(model, self.text)
        self.assertIn("never block a run", self.text)

    def test_claude_side_stages_are_all_present(self):
        for stage in ("## S6", "## S7", "## S8", "## S9"):
            self.assertIn(stage, self.text)

    def test_references_are_all_bundled(self):
        referenced = set(re.findall(r"references/([\w.-]+\.md)", self.text))
        self.assertTrue(referenced, "SKILL.md points at no reference doc")
        present = {p.name for p in (_ctx.SKILL_DIR / "references").iterdir()}
        self.assertEqual(set(), referenced - present, "SKILL.md points at a missing reference doc")


if __name__ == "__main__":
    unittest.main()
