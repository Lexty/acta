"""Mechanical layout invariants for the acta-notes skill.

The conventions this plugin relies on are the kind that rot silently: a script
added without a test module, a test that quietly re-invents ``sys.path``
juggling instead of using the ``_ctx`` shim, a salvage path from the Air skill
or the lab archive left hardcoded in shipped code, a binary resolved from a
fixed location so no test (and no user with a hand-built ``fluidaudiocli``) can
redirect it.

Nothing here mocks anything — every assertion reads the real ``scripts/`` and
``tests/`` directories, which is the point: the suite fails the moment the tree
stops matching the convention.
"""

import _ctx

import ast
import json
import re
import unittest
from pathlib import Path

#: Test modules that legitimately have no matching ``scripts/<stem>.py``.
TEST_ALLOWLIST = frozenset({"test_layout", "test_skill_md"})

#: Paths that gated the Phase-5 salvage. Both are scheduled to disappear, so a
#: runtime reference to either would be a time bomb in shipped code.
SALVAGE_PATTERNS = ("air-rescue", "_archive-2026-07-28")

#: The only environment overrides a script may use to locate a binary.
BINARY_ENV_VARS = frozenset({"ACTA_FLUIDAUDIO_BIN", "ACTA_FFMPEG_BIN"})

#: Sanctioned ``ACTA_*`` overrides that locate something *other* than a binary,
#: and so are exempt from the one-override-per-tool rule below. ``ACTA_CACHE_DIR``
#: is bootstrap.sh's: it moves the checkout, and therefore the stamp doctor.py
#: has to read to know which tag was built.
LOCATION_ENV_VARS = frozenset({"ACTA_CACHE_DIR"})

#: executable token found in the source -> the override that must govern it.
TOOL_ENV_VAR = {
    "fluidaudiocli": "ACTA_FLUIDAUDIO_BIN",
    "ffmpeg": "ACTA_FFMPEG_BIN",
}

#: A resolver must degrade to *something* when the override is unset: the
#: bootstrap cache path, or a PATH lookup.
FALLBACK_MARKERS = ("which(", "CACHE_BIN_RELPATH", "cache_dir")

_RESOLVER_NAME = re.compile(r"^resolve_.*_bin$")

#: Claims that must appear in *both* manifest descriptions. The two texts are
#: deliberately worded differently — ``plugin.json`` is the trigger-rich routing
#: description, ``marketplace.json`` the short catalogue blurb — so equality
#: would be the wrong assertion; agreeing on what the plugin actually does is
#: the right one.
SHARED_DESCRIPTION_CLAIMS = (
    "~/Acta",
    "Parakeet",
    "VBx",
    "fluidaudiocli",
    "utterance-level merge",
    "anchor-based speaker naming",
    "quality gates",
    "provenance",
    "summary.md",
    "screenshots",
    "calendar",
    "Jira",
    "Slack",
    "local project docs",
    "Teams",
    "Audio never leaves the machine",
    "skills-only",
)

_SEMVER = re.compile(r"^\d+\.\d+\.\d+$")


def _scripts() -> list[Path]:
    return sorted(_ctx.SCRIPTS_DIR.glob("*.py"))


def _test_modules() -> list[Path]:
    return sorted(p for p in _ctx.TESTS_DIR.glob("test_*.py"))


def _parse(path: Path) -> ast.Module:
    return ast.parse(path.read_text(encoding="utf-8"), filename=str(path))


def _first_import(tree: ast.Module):
    """The first ``import``/``from ... import`` statement at module level."""
    for node in tree.body:
        if isinstance(node, (ast.Import, ast.ImportFrom)):
            return node
    return None


def _touches_sys_path(tree: ast.Module) -> bool:
    """True when the module reads or writes ``sys.path`` in *code*.

    AST-based on purpose: the prose in ``_ctx``'s docstring (and in this one)
    names ``sys.path`` repeatedly, and a text search would flag it.
    """
    for node in ast.walk(tree):
        if (
            isinstance(node, ast.Attribute)
            and node.attr == "path"
            and isinstance(node.value, ast.Name)
            and node.value.id == "sys"
        ):
            return True
    return False


def _env_get_names(tree: ast.Module) -> set[str]:
    """Literal names passed to any ``....environ.get("NAME")`` call."""
    names: set[str] = set()
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        func = node.func
        if not (isinstance(func, ast.Attribute) and func.attr == "get"):
            continue
        target = func.value
        if not (isinstance(target, ast.Attribute) and target.attr == "environ"):
            if not (isinstance(target, ast.Name) and target.id == "environ"):
                continue
        if node.args and isinstance(node.args[0], ast.Constant):
            value = node.args[0].value
            if isinstance(value, str):
                names.add(value)
    return names


def _shells_out(tree: ast.Module) -> bool:
    for node in ast.walk(tree):
        if isinstance(node, ast.Call):
            func = node.func
            if isinstance(func, ast.Attribute) and isinstance(func.value, ast.Name):
                if func.value.id == "subprocess":
                    return True
    return False


def _defines_resolver(tree: ast.Module) -> bool:
    return any(
        isinstance(node, ast.FunctionDef) and _RESOLVER_NAME.match(node.name)
        for node in ast.walk(tree)
    )


class ScriptTestPairingTest(unittest.TestCase):
    """(a) and (b): one test module per script, and no orphan test modules."""

    def test_every_script_has_a_test_module(self):
        missing = [
            script.name
            for script in _scripts()
            if not (_ctx.TESTS_DIR / f"test_{script.stem}.py").is_file()
        ]
        self.assertEqual(
            [],
            missing,
            "every scripts/*.py needs a matching tests/test_<stem>.py; missing for: "
            + ", ".join(missing),
        )

    def test_scripts_directory_is_not_empty(self):
        # Guards the pairing test above from passing vacuously if the scripts
        # directory ever moves.
        self.assertTrue(_scripts(), f"no scripts found under {_ctx.SCRIPTS_DIR}")

    def test_every_test_module_maps_to_a_script_or_the_allowlist(self):
        orphans = []
        for module in _test_modules():
            stem = module.stem
            if stem in TEST_ALLOWLIST:
                continue
            if not _ctx.script_path(stem[len("test_") :]).is_file():
                orphans.append(module.name)
        self.assertEqual(
            [],
            orphans,
            "these test modules target no script and are not allowlisted: "
            + ", ".join(orphans),
        )

    def test_allowlist_entries_all_exist(self):
        # An allowlist that outlives its files silently weakens the check above.
        for stem in sorted(TEST_ALLOWLIST):
            with self.subTest(module=stem):
                self.assertTrue(
                    (_ctx.TESTS_DIR / f"{stem}.py").is_file(),
                    f"allowlisted test module {stem}.py does not exist",
                )


class ImportConventionTest(unittest.TestCase):
    """(c): every test module imports ``_ctx`` first and touches no sys.path."""

    def test_ctx_is_the_first_import_of_every_test_module(self):
        for module in _test_modules():
            with self.subTest(module=module.name):
                first = _first_import(_parse(module))
                self.assertIsNotNone(first, f"{module.name} imports nothing at all")
                self.assertIsInstance(
                    first,
                    ast.Import,
                    f"{module.name}'s first import must be the plain `import _ctx`",
                )
                self.assertEqual(
                    ["_ctx"],
                    [alias.name for alias in first.names],
                    f"{module.name} must open with `import _ctx` before anything else",
                )

    def test_no_test_module_manipulates_sys_path(self):
        offenders = [m.name for m in _test_modules() if _touches_sys_path(_parse(m))]
        self.assertEqual(
            [],
            offenders,
            "test modules must rely on _ctx.load(), never on sys.path: "
            + ", ".join(offenders),
        )

    def test_ctx_shim_is_not_collected_as_a_test_module(self):
        # `discover`'s default pattern is test*.py; _ctx.py must stay out of it.
        self.assertTrue((_ctx.TESTS_DIR / "_ctx.py").is_file())
        self.assertNotIn("_ctx.py", [m.name for m in _test_modules()])


class NoSalvagePathsTest(unittest.TestCase):
    """(d): shipped scripts never reference the two disappearing sources."""

    def test_no_script_references_a_salvage_path(self):
        offenders = []
        for path in sorted(_ctx.SCRIPTS_DIR.iterdir()):
            if not path.is_file() or path.name.startswith("."):
                continue
            text = path.read_text(encoding="utf-8", errors="replace")
            for pattern in SALVAGE_PATTERNS:
                if pattern in text:
                    offenders.append(f"{path.name}: {pattern}")
        self.assertEqual(
            [],
            offenders,
            "salvage paths must not survive in shipped scripts: "
            + ", ".join(offenders),
        )


class BinaryResolutionTest(unittest.TestCase):
    """(e): binaries come from the env overrides, with a documented fallback."""

    def _resolving_scripts(self):
        for script in _scripts():
            tree = _parse(script)
            if _shells_out(tree) or _defines_resolver(tree):
                yield script, tree

    def test_at_least_the_known_resolvers_are_detected(self):
        found = {script.stem for script, _ in self._resolving_scripts()}
        for expected in ("doctor", "prep_audio", "transcribe", "diarize"):
            self.assertIn(
                expected,
                found,
                f"{expected}.py resolves an external binary; the check below must see it",
            )

    def test_resolvers_use_only_the_sanctioned_env_overrides(self):
        for script, tree in self._resolving_scripts():
            with self.subTest(script=script.name):
                acta_vars = {
                    name for name in _env_get_names(tree) if name.startswith("ACTA_")
                }
                self.assertTrue(
                    acta_vars & BINARY_ENV_VARS,
                    f"{script.name} shells out but reads no ACTA_* binary override",
                )
                sanctioned = BINARY_ENV_VARS | LOCATION_ENV_VARS
                self.assertTrue(
                    acta_vars <= sanctioned,
                    f"{script.name} reads unknown overrides: "
                    f"{sorted(acta_vars - sanctioned)}",
                )

    def test_each_resolved_tool_has_its_own_override(self):
        for script, tree in self._resolving_scripts():
            source = script.read_text(encoding="utf-8")
            env_names = _env_get_names(tree)
            for tool, env_var in TOOL_ENV_VAR.items():
                if tool not in source:
                    continue
                with self.subTest(script=script.name, tool=tool):
                    self.assertIn(
                        env_var,
                        env_names,
                        f"{script.name} resolves {tool} but never reads {env_var}",
                    )

    def test_every_resolver_has_a_fallback_when_the_override_is_unset(self):
        for script, _tree in self._resolving_scripts():
            with self.subTest(script=script.name):
                source = script.read_text(encoding="utf-8")
                self.assertTrue(
                    any(marker in source for marker in FALLBACK_MARKERS),
                    f"{script.name} must fall back to the bootstrap cache path or "
                    f"a PATH lookup; none of {FALLBACK_MARKERS} found",
                )

    def test_no_script_hardcodes_an_absolute_binary_path(self):
        pattern = re.compile(r"/(usr|opt|bin|sbin)/\S*(ffmpeg|fluidaudiocli)")
        offenders = []
        for script in _scripts():
            for match in pattern.finditer(script.read_text(encoding="utf-8")):
                offenders.append(f"{script.name}: {match.group(0)}")
        self.assertEqual(
            [],
            offenders,
            "binary paths belong behind the env overrides: " + ", ".join(offenders),
        )


class ManifestRegistrationTest(unittest.TestCase):
    """The plugin is registered as skills-only, and says the same thing twice.

    ``plugin.json`` and the marketplace entry are edited by hand in two places;
    nothing else notices when they drift apart, and the Makefile lists are the
    only mechanical statement of "``go build`` never touches this tool".
    """

    @property
    def plugin_manifest(self) -> dict:
        path = _ctx.SKILL_DIR.parent.parent / ".claude-plugin" / "plugin.json"
        return json.loads(path.read_text(encoding="utf-8"))

    @property
    def marketplace_entry(self) -> dict:
        path = _ctx.REPO_ROOT / ".claude-plugin" / "marketplace.json"
        entries = json.loads(path.read_text(encoding="utf-8"))["plugins"]
        matching = [e for e in entries if e.get("name") == "acta-notes"]
        self.assertEqual(
            1,
            len(matching),
            "marketplace.json must register acta-notes exactly once",
        )
        return matching[0]

    def test_marketplace_source_points_at_the_plugin_directory(self):
        source = self.marketplace_entry["source"]
        self.assertEqual("./tools/acta-notes/plugin", source)
        self.assertTrue(
            (_ctx.REPO_ROOT / source.lstrip("./")).is_dir(),
            f"marketplace source {source} does not resolve to a directory",
        )

    def test_plugin_version_is_a_released_semver(self):
        version = self.plugin_manifest["version"]
        self.assertRegex(version, _SEMVER, "version must be plain X.Y.Z")
        self.assertNotEqual(
            "0.0.0",
            version,
            "0.0.0 is the pre-release placeholder; a shipped plugin needs a real version",
        )

    def test_both_manifests_make_the_same_claims(self):
        plugin_desc = self.plugin_manifest["description"]
        market_desc = self.marketplace_entry["description"]
        self.assertEqual("acta-notes", self.plugin_manifest["name"])
        for claim in SHARED_DESCRIPTION_CLAIMS:
            with self.subTest(claim=claim):
                self.assertIn(claim.lower(), plugin_desc.lower(), "missing in plugin.json")
                self.assertIn(claim.lower(), market_desc.lower(), "missing in marketplace.json")

    def test_makefile_lists_acta_notes_as_skills_only(self):
        makefile = (_ctx.REPO_ROOT / "Makefile").read_text(encoding="utf-8")
        lists = {}
        for name in ("TOOLS", "CLI_TOOLS", "SKILL_PLUGINS"):
            match = re.search(rf"^{name}\s*:?=\s*(.*)$", makefile, re.MULTILINE)
            self.assertIsNotNone(match, f"Makefile has no {name} list")
            lists[name] = match.group(1).split()
        self.assertIn("acta-notes", lists["SKILL_PLUGINS"])
        self.assertNotIn("acta-notes", lists["TOOLS"])
        self.assertNotIn("acta-notes", lists["CLI_TOOLS"])


class CrossModuleAgreementTest(unittest.TestCase):
    """Constants two scripts must agree on, asserted where they can be seen.

    Each script is otherwise tested in isolation against its own idea of the
    layout, so a divergence here fails nothing: ``pipeline.py`` looking for
    ``diarization.json`` in the wrong directory does not raise — it silently
    mis-computes freshness and skips a stage that should have re-run.
    """

    #: The artifact each stage script writes, and the driver reads back.
    MEETING = Path("/meeting")

    def test_pipeline_agrees_on_where_diarization_json_lives(self):
        pipeline = _ctx.load("pipeline")
        diarize = _ctx.load("diarize")
        merge = _ctx.load("merge")
        verify = _ctx.load("verify")

        written = diarize.stage_json_path(self.MEETING)
        self.assertEqual(written, pipeline.diarization_json_path(self.MEETING))
        self.assertEqual(written, merge.diarization_json_path(self.MEETING))
        self.assertEqual(
            written, self.MEETING / verify.DIARIZATION_JSON_NAME
        )
        self.assertIn(written, pipeline.stage_outputs(self.MEETING, "diarize"))
        self.assertIn(written, pipeline.stage_inputs(self.MEETING, "merge"))

    def test_pipeline_agrees_on_where_speakers_json_lives(self):
        pipeline = _ctx.load("pipeline")
        speakers = _ctx.load("speakers")
        verify = _ctx.load("verify")

        written = speakers.speakers_json_path(self.MEETING)
        self.assertEqual(written, pipeline.speakers_json_path(self.MEETING))
        self.assertEqual(written, self.MEETING / verify.SPEAKERS_JSON_NAME)
        self.assertIn(written, pipeline.stage_outputs(self.MEETING, "speakers"))

    def test_pipeline_agrees_on_where_the_transcripts_live(self):
        pipeline = _ctx.load("pipeline")
        merge = _ctx.load("merge")
        speakers = _ctx.load("speakers")

        raw = merge.transcript_path(self.MEETING)
        self.assertEqual(raw, pipeline.raw_transcript_path(self.MEETING))
        self.assertIn(raw, pipeline.stage_outputs(self.MEETING, "merge"))
        self.assertIn(raw, pipeline.stage_inputs(self.MEETING, "speakers"))

        labeled = speakers.labeled_transcript_path(self.MEETING)
        self.assertEqual(labeled, self.MEETING / pipeline.LABELED_TRANSCRIPT_NAME)
        self.assertIn(labeled, pipeline.stage_outputs(self.MEETING, "speakers"))

    def test_the_fluidaudio_binary_relpath_is_the_same_everywhere(self):
        # transcribe.py and diarize.py both document this as "kept in sync with
        # doctor.py by test_layout.py" — this is that assertion.
        doctor = _ctx.load("doctor")
        home = Path("/fake/home")
        expected = doctor.Env(home=home).cache_dir / doctor.FLUIDAUDIO_BIN_RELPATH
        for stem in ("transcribe", "diarize"):
            with self.subTest(script=stem):
                self.assertEqual(
                    expected,
                    home / _ctx.load(stem).CACHE_BIN_RELPATH,
                    f"{stem}.py's cache default is not where doctor.py looks",
                )

    def test_the_fluidaudio_tag_pin_matches_bootstrap(self):
        doctor = _ctx.load("doctor")
        text = (_ctx.SCRIPTS_DIR / "bootstrap.sh").read_text(encoding="utf-8")
        match = re.search(r'^FLUIDAUDIO_TAG="([^"]+)"', text, re.MULTILINE)
        self.assertIsNotNone(match, "bootstrap.sh must pin FLUIDAUDIO_TAG")
        self.assertEqual(
            doctor.FLUIDAUDIO_TAG,
            match.group(1),
            "doctor.py compares the stamp against a tag bootstrap.sh never builds",
        )


class RepoDocsTest(unittest.TestCase):
    """CLAUDE.md is the contract new skill scripts are written against."""

    def test_claude_md_documents_the_skill_script_conventions(self):
        text = (_ctx.REPO_ROOT / "CLAUDE.md").read_text(encoding="utf-8")
        for token in (
            "acta-notes",
            "make test-skills",
            "tests/_ctx.py",
            "stdlib only",
            "One test module per script",
        ):
            with self.subTest(token=token):
                self.assertIn(token.lower(), text.lower())


if __name__ == "__main__":
    unittest.main()
