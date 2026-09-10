import _ctx

import contextlib
import io
import json
import unittest
from pathlib import Path

doctor = _ctx.load("doctor")

HOME = Path("/fake/home")
CACHE_DIR = HOME / ".cache" / "acta-notes" / "fluidaudio"
STAMP_PATH = CACHE_DIR / ".acta-bootstrap.json"
BINARY = CACHE_DIR / ".build" / "release" / "fluidaudiocli"
MODELS_DIR = HOME / "Library" / "Application Support" / "FluidAudio" / "Models"

GB = 1024**3

GOOD_STAMP = {
    "fluidaudio_tag": "v0.15.5",
    "commit": "0123456789abcdef0123456789abcdef01234567",
    "binary_path": str(BINARY),
    "built_at": "2026-07-29T10:00:00Z",
    "swift_version": "swift-driver version: 1.90.11",
}


class FakeEnv(doctor.Env):
    """An Env backed by in-memory dicts — no real filesystem, no real PATH."""

    def __init__(self, files=None, dirs=(), executables=(), progs=None,
                 free=20 * GB, environ=None):
        super().__init__(home=HOME, environ=environ or {})
        self.files = {str(k): v for k, v in (files or {}).items()}
        self.dirs = {str(d) for d in dirs}
        self.executables = {str(e) for e in executables}
        self.progs = {k: str(v) for k, v in (progs or {}).items()}
        self.free = free

    def which(self, prog):
        return self.progs.get(prog)

    def is_file(self, path):
        return str(path) in self.files or str(path) in self.executables

    def is_dir(self, path):
        return str(path) in self.dirs

    def is_executable(self, path):
        return str(path) in self.executables

    def read_text(self, path):
        try:
            return self.files[str(path)]
        except KeyError:
            raise OSError(f"no such fake file: {path}")

    def free_bytes(self, path):
        if self.free is None:
            raise OSError("statvfs failed")
        return self.free


def healthy_env(**overrides) -> FakeEnv:
    """A machine that must come out green, holding ONLY the required models."""
    kwargs = {
        "files": {STAMP_PATH: json.dumps(GOOD_STAMP)},
        "dirs": [MODELS_DIR / name for name in doctor.REQUIRED_MODELS],
        "executables": [BINARY, "/opt/homebrew/bin/ffmpeg"],
        "progs": {"ffmpeg": "/opt/homebrew/bin/ffmpeg", "swift": "/usr/bin/swift"},
        "free": 20 * GB,
    }
    kwargs.update(overrides)
    return FakeEnv(**kwargs)


def check_named(report, name):
    for check in report["checks"]:
        if check["name"] == name:
            return check
    raise AssertionError(f"no check named {name!r} in {[c['name'] for c in report['checks']]}")


class TestHealthyMachine(unittest.TestCase):
    def test_only_required_models_is_green(self):
        report = doctor.run_checks(healthy_env())
        self.assertEqual(report["status"], doctor.GREEN)
        self.assertEqual(doctor.exit_code(report), 0)

    def test_optional_models_absent_are_reported_present_false_and_stay_green(self):
        report = doctor.run_checks(healthy_env())
        self.assertEqual(report["status"], doctor.GREEN)
        for name in doctor.OPTIONAL_MODELS:
            check = check_named(report, f"model:{name}")
            self.assertIs(check["present"], False, name)
            self.assertEqual(check["tier"], "optional")
            self.assertEqual(check["status"], doctor.GREEN, name)

    def test_all_optional_models_present_is_also_green(self):
        env = healthy_env(
            dirs=[MODELS_DIR / n for n in doctor.REQUIRED_MODELS + doctor.OPTIONAL_MODELS]
        )
        report = doctor.run_checks(env)
        self.assertEqual(report["status"], doctor.GREEN)
        for name in doctor.OPTIONAL_MODELS:
            self.assertIs(check_named(report, f"model:{name}")["present"], True)


class TestModelTiering(unittest.TestCase):
    def test_missing_required_model_is_red(self):
        for missing in doctor.REQUIRED_MODELS:
            with self.subTest(missing=missing):
                kept = [n for n in doctor.REQUIRED_MODELS if n != missing]
                env = healthy_env(dirs=[MODELS_DIR / n for n in kept])
                report = doctor.run_checks(env)
                self.assertEqual(report["status"], doctor.RED)
                self.assertEqual(check_named(report, f"model:{missing}")["status"], doctor.RED)
                self.assertEqual(doctor.exit_code(report), 1)

    def test_required_models_are_exactly_the_two_v1_loads(self):
        self.assertEqual(
            set(doctor.REQUIRED_MODELS), {"parakeet-tdt-0.6b-v3", "speaker-diarization"}
        )
        self.assertEqual(
            set(doctor.OPTIONAL_MODELS),
            {"sortformer", "ls-eend", "parakeet-ctc-110m-coreml"},
        )

    def test_optional_model_missing_never_warns(self):
        env = healthy_env()
        report = doctor.run_checks(env)
        statuses = {
            check_named(report, f"model:{n}")["status"] for n in doctor.OPTIONAL_MODELS
        }
        self.assertEqual(statuses, {doctor.GREEN})
        self.assertNotIn(doctor.WARN, [c["status"] for c in report["checks"]])


class TestBootstrapStamp(unittest.TestCase):
    def test_missing_stamp_is_red(self):
        env = healthy_env(files={})
        check = doctor.check_bootstrap(env)
        self.assertEqual(check["status"], doctor.RED)
        self.assertIn("bootstrap.sh", check["detail"])
        self.assertIsNone(check["found_tag"])

    def test_tag_mismatch_is_red(self):
        stamp = dict(GOOD_STAMP, fluidaudio_tag="v0.14.0")
        env = healthy_env(files={STAMP_PATH: json.dumps(stamp)})
        check = doctor.check_bootstrap(env)
        self.assertEqual(check["status"], doctor.RED)
        self.assertEqual(check["found_tag"], "v0.14.0")
        self.assertEqual(check["expected_tag"], doctor.FLUIDAUDIO_TAG)

    def test_dead_binary_path_is_red(self):
        env = healthy_env(executables=["/opt/homebrew/bin/ffmpeg"])  # binary gone
        check = doctor.check_bootstrap(env)
        self.assertEqual(check["status"], doctor.RED)
        self.assertIn("not executable", check["detail"])

    def test_corrupt_stamp_is_red(self):
        env = healthy_env(files={STAMP_PATH: "{not json"})
        self.assertIsNone(doctor.read_stamp(env))
        self.assertEqual(doctor.check_bootstrap(env)["status"], doctor.RED)

    def test_matching_stamp_is_green_and_reports_provenance(self):
        check = doctor.check_bootstrap(healthy_env())
        self.assertEqual(check["status"], doctor.GREEN)
        self.assertEqual(check["found_tag"], "v0.15.5")
        self.assertEqual(check["commit"], GOOD_STAMP["commit"])
        self.assertEqual(check["built_at"], GOOD_STAMP["built_at"])
        self.assertEqual(check["binary_path"], str(BINARY))

    def test_a_stamp_pointing_away_from_the_run_path_is_red(self):
        # doctor consults the stamp; transcribe.py and diarize.py do not — absent
        # ACTA_FLUIDAUDIO_BIN they resolve the cache default and nothing else. A
        # green verdict over a binary no stage will invoke is the exact
        # halfway-through-a-meeting failure this check exists to prevent.
        elsewhere = "/opt/hand-built/fluidaudiocli"
        stamp = dict(GOOD_STAMP, binary_path=elsewhere)
        env = healthy_env(
            files={STAMP_PATH: json.dumps(stamp)},
            executables=[elsewhere, "/opt/homebrew/bin/ffmpeg"],  # BINARY absent
        )
        check = doctor.check_bootstrap(env)
        self.assertEqual(check["status"], doctor.RED)
        self.assertIn("ACTA_FLUIDAUDIO_BIN", check["detail"])
        self.assertEqual(check["run_binary_path"], str(BINARY))

    def test_a_stamp_pointing_elsewhere_is_fine_when_the_run_path_also_works(self):
        elsewhere = "/opt/hand-built/fluidaudiocli"
        stamp = dict(GOOD_STAMP, binary_path=elsewhere)
        env = healthy_env(
            files={STAMP_PATH: json.dumps(stamp)},
            executables=[elsewhere, BINARY, "/opt/homebrew/bin/ffmpeg"],
        )
        self.assertEqual(doctor.check_bootstrap(env)["status"], doctor.GREEN)

    def test_an_env_override_is_not_second_guessed(self):
        # ACTA_FLUIDAUDIO_BIN points *every* stage at the same binary, so there
        # is no divergence to warn about.
        elsewhere = "/opt/hand-built/fluidaudiocli"
        env = healthy_env(
            executables=[elsewhere, "/opt/homebrew/bin/ffmpeg"],
            environ={"ACTA_FLUIDAUDIO_BIN": elsewhere},
        )
        check = doctor.check_bootstrap(env)
        self.assertEqual(check["status"], doctor.GREEN)
        self.assertEqual(check["binary_source"], "env:ACTA_FLUIDAUDIO_BIN")

    def test_pin_is_a_module_constant_not_derived_from_git(self):
        self.assertEqual(doctor.FLUIDAUDIO_TAG, "v0.15.5")
        source = _ctx.script_path("doctor").read_text(encoding="utf-8")
        self.assertNotIn("git describe", source)
        self.assertNotIn("rev-parse", source)


class TestBinaryResolution(unittest.TestCase):
    def test_env_override_wins_over_stamp(self):
        env = healthy_env(
            environ={"ACTA_FLUIDAUDIO_BIN": "/tmp/stub/fluidaudiocli"},
            executables=[BINARY, "/tmp/stub/fluidaudiocli", "/opt/homebrew/bin/ffmpeg"],
        )
        path, source = doctor.resolve_fluidaudio_bin(env, doctor.read_stamp(env))
        self.assertEqual(str(path), "/tmp/stub/fluidaudiocli")
        self.assertEqual(source, "env:ACTA_FLUIDAUDIO_BIN")

    def test_stamp_path_used_when_no_override(self):
        env = healthy_env()
        path, source = doctor.resolve_fluidaudio_bin(env, doctor.read_stamp(env))
        self.assertEqual(str(path), str(BINARY))
        self.assertEqual(source, "stamp")

    def test_cache_default_when_no_stamp_and_no_override(self):
        env = healthy_env(files={})
        path, source = doctor.resolve_fluidaudio_bin(env, None)
        self.assertEqual(str(path), str(BINARY))
        self.assertEqual(source, "cache-default")

    def test_ffmpeg_env_override(self):
        env = healthy_env(
            environ={"ACTA_FFMPEG_BIN": "/tmp/stub/ffmpeg"},
            executables=[BINARY, "/tmp/stub/ffmpeg"],
            progs={"swift": "/usr/bin/swift"},
        )
        check = doctor.check_ffmpeg(env)
        self.assertEqual(check["status"], doctor.GREEN)
        self.assertEqual(check["source"], "env:ACTA_FFMPEG_BIN")
        self.assertEqual(check["path"], "/tmp/stub/ffmpeg")


class TestToolChecks(unittest.TestCase):
    def test_missing_ffmpeg_is_red(self):
        env = healthy_env(progs={"swift": "/usr/bin/swift"}, executables=[BINARY])
        report = doctor.run_checks(env)
        self.assertEqual(check_named(report, "ffmpeg")["status"], doctor.RED)
        self.assertEqual(report["status"], doctor.RED)

    def test_missing_swift_only_warns_when_the_binary_is_already_built(self):
        # Swift is bootstrap.sh's dependency, not the run's: a machine with a
        # working fluidaudiocli must still be allowed to process meetings.
        env = healthy_env(progs={"ffmpeg": "/opt/homebrew/bin/ffmpeg"})
        report = doctor.run_checks(env)
        self.assertEqual(check_named(report, "fluidaudio")["status"], doctor.GREEN)
        self.assertEqual(check_named(report, "swift")["status"], doctor.WARN)
        self.assertNotEqual(report["status"], doctor.RED)
        self.assertEqual(doctor.exit_code(report), 0)

    def test_missing_swift_is_red_when_the_binary_still_has_to_be_built(self):
        env = healthy_env(
            progs={"ffmpeg": "/opt/homebrew/bin/ffmpeg"},
            files={},  # no stamp: bootstrap.sh has to run, and it needs swift
        )
        report = doctor.run_checks(env)
        self.assertEqual(check_named(report, "swift")["status"], doctor.RED)
        self.assertEqual(report["status"], doctor.RED)

    def test_non_executable_ffmpeg_is_red(self):
        env = healthy_env(executables=[BINARY])  # on PATH, but not executable
        self.assertEqual(doctor.check_ffmpeg(env)["status"], doctor.RED)


class TestDiskThresholds(unittest.TestCase):
    def test_thresholds_are_two_and_five_gb(self):
        self.assertEqual(doctor.DISK_FAIL_BYTES, 2 * GB)
        self.assertEqual(doctor.DISK_WARN_BYTES, 5 * GB)

    def test_boundaries(self):
        cases = [
            (0, doctor.RED),
            (2 * GB - 1, doctor.RED),
            (2 * GB, doctor.WARN),
            (5 * GB - 1, doctor.WARN),
            (5 * GB, doctor.GREEN),
            (17 * GB, doctor.GREEN),
        ]
        for free, expected in cases:
            with self.subTest(free=free):
                self.assertEqual(doctor.check_disk(healthy_env(free=free))["status"], expected)

    def test_seventeen_gb_machine_is_not_warned(self):
        report = doctor.run_checks(healthy_env(free=17 * GB))
        self.assertEqual(report["status"], doctor.GREEN)

    def test_warn_does_not_change_exit_code(self):
        report = doctor.run_checks(healthy_env(free=3 * GB))
        self.assertEqual(report["status"], doctor.WARN)
        self.assertEqual(doctor.exit_code(report), 0)

    def test_low_disk_is_red_and_exits_one(self):
        report = doctor.run_checks(healthy_env(free=1 * GB))
        self.assertEqual(report["status"], doctor.RED)
        self.assertEqual(doctor.exit_code(report), 1)

    def test_statvfs_failure_is_red(self):
        self.assertEqual(doctor.check_disk(healthy_env(free=None))["status"], doctor.RED)


class TestAggregation(unittest.TestCase):
    def test_red_beats_warn_beats_green(self):
        mk = lambda s: {"name": "x", "status": s, "detail": ""}
        self.assertEqual(doctor.aggregate([mk("green"), mk("green")]), doctor.GREEN)
        self.assertEqual(doctor.aggregate([mk("green"), mk("warn")]), doctor.WARN)
        self.assertEqual(doctor.aggregate([mk("warn"), mk("red"), mk("green")]), doctor.RED)
        self.assertEqual(doctor.aggregate([]), doctor.GREEN)


class TestOutput(unittest.TestCase):
    def _run(self, argv, env):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            code = doctor.main(argv, env=env)
        return code, buf.getvalue()

    def test_json_shape(self):
        code, out = self._run(["--json"], healthy_env())
        self.assertEqual(code, 0)
        report = json.loads(out)
        self.assertEqual(report["status"], "green")
        self.assertEqual(report["fluidaudio_tag_pin"], "v0.15.5")
        self.assertEqual(report["models_dir"], str(MODELS_DIR))
        self.assertEqual(report["cache_dir"], str(CACHE_DIR))
        names = [c["name"] for c in report["checks"]]
        expected = (
            ["ffmpeg", "swift", "fluidaudio"]
            + [f"model:{n}" for n in doctor.REQUIRED_MODELS + doctor.OPTIONAL_MODELS]
            + ["disk"]
        )
        self.assertEqual(names, expected)
        for check in report["checks"]:
            self.assertIn(check["status"], {"green", "warn", "red"})
            self.assertIsInstance(check["detail"], str)

    def test_json_carries_present_false_for_absent_optional_models(self):
        _, out = self._run(["--json"], healthy_env())
        report = json.loads(out)
        absent = {
            c["model"]: c["present"] for c in report["checks"] if c.get("tier") == "optional"
        }
        self.assertEqual(absent, {n: False for n in doctor.OPTIONAL_MODELS})

    def test_human_output_lists_every_check(self):
        code, out = self._run([], healthy_env())
        self.assertEqual(code, 0)
        self.assertIn("status: GREEN", out)
        for name in ("ffmpeg", "swift", "fluidaudio", "disk"):
            self.assertIn(name, out)
        for name in doctor.OPTIONAL_MODELS:
            self.assertIn(f"model:{name}", out)
        self.assertIn("absent (optional", out)

    def test_human_output_on_red_explains_the_refusal(self):
        code, out = self._run([], healthy_env(files={}))
        self.assertEqual(code, 1)
        self.assertIn("status: RED", out)
        self.assertIn("FAIL", out)
        self.assertIn("Refusing to run", out)

    def test_exit_code_is_nonzero_only_on_red(self):
        self.assertEqual(self._run(["--json"], healthy_env())[0], 0)
        self.assertEqual(self._run(["--json"], healthy_env(free=3 * GB))[0], 0)
        self.assertEqual(self._run(["--json"], healthy_env(free=1 * GB))[0], 1)


class CacheDirOverrideTests(unittest.TestCase):
    """``ACTA_CACHE_DIR`` moves the stamp, so doctor has to look for it there.

    bootstrap.sh writes the stamp under ``ACTA_CACHE_DIR``, and the "no usable
    bootstrap stamp" branch fires before any binary check — so a doctor blind to
    the override is RED with no escape, and pipeline.py aborts at stage 0.
    """

    ALT = Path("/elsewhere/fluidaudio")

    def _alt_env(self, *, export_bin=True, **overrides):
        stamp_path = self.ALT / ".acta-bootstrap.json"
        binary = self.ALT / ".build" / "release" / "fluidaudiocli"
        stamp = dict(GOOD_STAMP, binary_path=str(binary))
        environ = {"ACTA_CACHE_DIR": str(self.ALT)}
        if export_bin:
            environ["ACTA_FLUIDAUDIO_BIN"] = str(binary)
        kwargs = {
            "files": {stamp_path: json.dumps(stamp)},
            "dirs": [MODELS_DIR / name for name in doctor.REQUIRED_MODELS],
            "executables": [binary, "/opt/homebrew/bin/ffmpeg"],
            "progs": {"ffmpeg": "/opt/homebrew/bin/ffmpeg", "swift": "/usr/bin/swift"},
            "environ": environ,
        }
        kwargs.update(overrides)
        return FakeEnv(**kwargs)

    def test_the_stamp_is_looked_for_under_the_override(self):
        env = self._alt_env()
        self.assertEqual(env.stamp_path, self.ALT / ".acta-bootstrap.json")
        self.assertIsNotNone(doctor.read_stamp(env))

    def test_the_documented_escape_actually_clears_the_check(self):
        # ACTA_CACHE_DIR to find the stamp + ACTA_FLUIDAUDIO_BIN so the stages
        # reach the same binary — exactly what bootstrap.sh --help prescribes.
        check = doctor.check_bootstrap(self._alt_env())
        self.assertEqual(check["status"], doctor.GREEN, check["detail"])

    def test_without_the_override_the_relocated_stamp_is_invisible(self):
        # The stamp is genuinely unreadable here — but ACTA_FLUIDAUDIO_BIN still
        # points at an executable binary, and that is the binary the stages will
        # invoke. So this is a warning, not a refusal: the run can proceed, only
        # the tag behind those bytes is unverified.
        env = self._alt_env()
        env.environ.pop("ACTA_CACHE_DIR")
        self.assertEqual(env.stamp_path, STAMP_PATH)
        self.assertIsNone(doctor.read_stamp(env))
        check = doctor.check_bootstrap(env)
        self.assertEqual(check["status"], doctor.WARN, check["detail"])
        self.assertIn("unverified", check["detail"])

    def test_no_stamp_and_no_override_is_still_red(self):
        # The warning above is bought by the override alone. Take it away and a
        # missing stamp is a refusal again, because nothing has established that
        # the path the stages resolve holds a working binary.
        env = self._alt_env(export_bin=False)
        env.environ.pop("ACTA_CACHE_DIR")
        check = doctor.check_bootstrap(env)
        self.assertEqual(check["status"], doctor.RED, check["detail"])
        self.assertIn("run bootstrap.sh", check["detail"])

    def test_an_unusable_override_is_red_not_warned(self):
        # A warning says "usable but unverified". An override that cannot be
        # executed is neither, and must not be softened into one.
        env = self._alt_env(executables=["/opt/homebrew/bin/ffmpeg"])
        env.environ.pop("ACTA_CACHE_DIR")
        check = doctor.check_bootstrap(env)
        self.assertEqual(check["status"], doctor.RED, check["detail"])
        self.assertIn("not executable", check["detail"])

    def test_an_off_pin_stamp_under_a_working_override_warns(self):
        # Same rule for a stamp that is readable but records the wrong tag: the
        # override still carries the run, the tag is still unverified.
        stamp_path = self.ALT / ".acta-bootstrap.json"
        binary = self.ALT / ".build" / "release" / "fluidaudiocli"
        env = self._alt_env(
            files={
                stamp_path: json.dumps(
                    dict(GOOD_STAMP, binary_path=str(binary), fluidaudio_tag="v0.0.1")
                )
            }
        )
        check = doctor.check_bootstrap(env)
        self.assertEqual(check["status"], doctor.WARN, check["detail"])
        self.assertIn("v0.0.1", check["detail"])

    def test_a_warned_bootstrap_does_not_turn_swift_red(self):
        # check_swift's own rule is "red only when the machine would have to
        # build". A warned bootstrap means a usable binary exists, so there is
        # nothing to build and no reason to demand a toolchain.
        env = self._alt_env(
            progs={"ffmpeg": "/opt/homebrew/bin/ffmpeg"},  # no swift
        )
        env.environ.pop("ACTA_CACHE_DIR")
        report = doctor.run_checks(env)
        by_name = {check["name"]: check for check in report["checks"]}
        self.assertEqual(by_name["fluidaudio"]["status"], doctor.WARN)
        self.assertEqual(by_name["swift"]["status"], doctor.WARN, by_name["swift"])

    def test_the_run_path_is_not_moved_by_the_override(self):
        # transcribe.py/diarize.py resolve the default cache path and nothing
        # else, so cache_dir must keep describing where the run will look —
        # otherwise the stamp-points-elsewhere guard compares the wrong paths.
        env = self._alt_env()
        self.assertEqual(env.cache_dir, CACHE_DIR)

    def test_a_relocated_stamp_without_the_bin_export_stays_red(self):
        # The stamp is found, but nothing the stages invoke is executable: the
        # guard has to catch it rather than go green over an unreachable binary.
        check = doctor.check_bootstrap(self._alt_env(export_bin=False))
        self.assertEqual(check["status"], doctor.RED)
        self.assertIn("ACTA_FLUIDAUDIO_BIN", check["detail"])

    def test_the_json_report_names_both_directories(self):
        report = doctor.run_checks(self._alt_env())
        self.assertEqual(report["cache_dir"], str(CACHE_DIR))
        self.assertEqual(report["stamp_dir"], str(self.ALT))


if __name__ == "__main__":
    unittest.main()
