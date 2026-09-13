import _ctx

import contextlib
import io
import json
import tempfile
import unittest
import wave
from pathlib import Path

index = _ctx.load("archive_index")

INFO = '---\ntitle: "Slack — 2026-07-22 15:19"\ndate: 2026-07-22T14:19:00Z\nsource: "Slack"\nduration: "00:30:00"\nstatus: done\n---\n\n# Slack\n'


def write_wav(path, seconds=1.0, rate=16000):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with contextlib.closing(wave.open(str(path), "wb")) as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(rate)
        handle.writeframes(b"\x00" * int(seconds * rate) * 2)
    return path


def make_meeting(archive, name, *, info=INFO, summary=None, files=(), audio=()):
    d = Path(archive) / name
    d.mkdir(parents=True, exist_ok=True)
    if info:
        (d / "info.md").write_text(info, encoding="utf-8")
    if summary is not None:
        (d / "summary.md").write_text(summary, encoding="utf-8")
    for fname in files:
        (d / fname).write_text("x", encoding="utf-8")
    for fname in audio:
        if fname.endswith(".wav"):
            write_wav(d / fname)
        else:
            (d / fname).write_bytes(b"\x00" * 1024)
    return d


class TestFrontMatter(unittest.TestCase):
    def test_parses_quoted_values(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / "info.md"
            p.write_text(INFO, encoding="utf-8")
            fields = index.read_front_matter(p)
            self.assertEqual(fields["source"], "Slack")
            self.assertEqual(fields["duration"], "00:30:00")
            self.assertEqual(fields["status"], "done")

    def test_missing_file_is_empty(self):
        self.assertEqual(index.read_front_matter("/nope/info.md"), {})

    def test_file_without_front_matter_is_empty(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / "info.md"
            p.write_text("# just a heading\n", encoding="utf-8")
            self.assertEqual(index.read_front_matter(p), {})

    def test_duration_seconds(self):
        self.assertEqual(index.duration_seconds("01:06:57"), 4017)
        self.assertEqual(index.duration_seconds("00:00:00"), 0)
        self.assertEqual(index.duration_seconds(None), 0)
        self.assertEqual(index.duration_seconds("nonsense"), 0)


class TestSummaryReading(unittest.TestCase):
    def test_topic_strips_trailing_date(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / "summary.md"
            p.write_text("# Утечка памяти в парсере — 2026-07-23\n\ntext\n", encoding="utf-8")
            self.assertEqual(index.summary_topic(p), "Утечка памяти в парсере")

    def test_topic_absent_when_no_heading(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / "summary.md"
            p.write_text("no heading here\n", encoding="utf-8")
            self.assertIsNone(index.summary_topic(p))

    def test_participants_strip_markup_and_truncate(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / "summary.md"
            names = ", ".join(f"Человек Номер {i}" for i in range(12))
            p.write_text(
                f"# T — 2026-07-01\n\n- **Участники (11 чел.):** {names}\n",
                encoding="utf-8",
            )
            got = index.summary_participants(p, limit=40)
            self.assertLessEqual(len(got), 40)
            self.assertTrue(got.endswith("…"))
            self.assertNotIn("**", got)

    def test_participants_absent_is_none(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / "summary.md"
            p.write_text("# T — 2026-07-01\n\nno participants line\n", encoding="utf-8")
            self.assertIsNone(index.summary_participants(p))


class TestStateDetection(unittest.TestCase):
    def test_audio_state_labels_raw_and_compressed(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = make_meeting(tmp, "2026-07-01_1000__a", audio=("system.wav",))
            label, size = index.audio_state(d)
            self.assertEqual(label, "wav")
            self.assertGreater(size, 0)

            (d / "mic.opus").write_bytes(b"\x00" * 10)
            label, _ = index.audio_state(d)
            self.assertEqual(label, "opus+wav")

    def test_audio_state_none_when_pruned(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = make_meeting(tmp, "2026-07-01_1000__a")
            self.assertEqual(index.audio_state(d), ("—", 0))

    def test_artifact_state_reports_present_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = make_meeting(
                tmp,
                "2026-07-01_1000__a",
                summary="# T — 2026-07-01\n",
                files=("transcript.raw.md", "context.md"),
            )
            self.assertEqual(index.artifact_state(d), ["raw", "sum", "ctx"])

    def test_empty_files_do_not_count_as_artifacts(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = make_meeting(tmp, "2026-07-01_1000__a")
            (d / "summary.md").write_text("", encoding="utf-8")
            self.assertNotIn("sum", index.artifact_state(d))


class TestScan(unittest.TestCase):
    def test_scan_meeting_extracts_fields(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = make_meeting(
                tmp,
                "2026-01-15_1519__slack-2026-01-15-15-19",
                summary="# Урок английского — 2026-07-22\n\n- **Участники:** А и Б\n",
                audio=("system.wav",),
            )
            entry = index.scan_meeting(d)
            self.assertEqual(entry["date"], "2026-07-22")
            self.assertEqual(entry["time"], "15:19")
            self.assertEqual(entry["month"], "2026-07")
            self.assertEqual(entry["duration"], "00:30:00")
            self.assertEqual(entry["duration_seconds"], 1800)
            self.assertEqual(entry["source"], "Slack")
            self.assertEqual(entry["topic"], "Урок английского")
            self.assertEqual(entry["participants"], "А и Б")
            self.assertTrue(entry["has_summary"])
            self.assertEqual(entry["audio"], "wav")

    def test_scan_meeting_rejects_non_meeting_dirs(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp) / "screenshots"
            d.mkdir()
            self.assertIsNone(index.scan_meeting(d))

    def test_scan_meeting_survives_missing_info(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = make_meeting(tmp, "2026-07-01_1000__a", info=None)
            entry = index.scan_meeting(d)
            self.assertEqual(entry["source"], "?")
            self.assertEqual(entry["duration"], "?")

    def test_scan_archive_is_newest_first_and_skips_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            make_meeting(tmp, "2026-07-01_1000__old")
            make_meeting(tmp, "2026-07-28_1100__new")
            (Path(tmp) / "CLAUDE.md").write_text("docs\n", encoding="utf-8")
            entries = index.scan_archive(tmp)
            self.assertEqual(
                [e["folder"] for e in entries],
                ["2026-07-28_1100__new", "2026-07-01_1000__old"],
            )


class TestRender(unittest.TestCase):
    def test_render_groups_by_month_and_totals(self):
        with tempfile.TemporaryDirectory() as tmp:
            make_meeting(
                tmp, "2026-06-30_0900__june", summary="# Июньская — 2026-06-30\n"
            )
            make_meeting(
                tmp, "2026-07-28_1100__july", summary="# Июльская — 2026-07-28\n"
            )
            text = index.render(index.scan_archive(tmp))
            self.assertIn("## 2026-07 —", text)
            self.assertIn("## 2026-06 —", text)
            self.assertIn("Встреч: **2**", text)
            self.assertIn("1 ч 00 мин", text)  # 2 x 30 min
            self.assertLess(text.index("## 2026-07"), text.index("## 2026-06"))

    def test_render_flags_meetings_without_summary(self):
        with tempfile.TemporaryDirectory() as tmp:
            make_meeting(tmp, "2026-07-28_1100__nosum")
            text = index.render(index.scan_archive(tmp))
            self.assertIn("Без `summary.md`: 1", text)
            self.assertIn("нет итогов", text)

    def test_render_says_so_when_everything_is_summarized(self):
        with tempfile.TemporaryDirectory() as tmp:
            make_meeting(tmp, "2026-07-28_1100__a", summary="# T — 2026-07-28\n")
            text = index.render(index.scan_archive(tmp))
            self.assertIn("Без `summary.md`: нет", text)

    def test_render_escapes_pipes_in_topics(self):
        """A topic with a pipe would silently split the table column."""
        with tempfile.TemporaryDirectory() as tmp:
            make_meeting(
                tmp, "2026-07-28_1100__a", summary="# A | B — 2026-07-28\n"
            )
            text = index.render(index.scan_archive(tmp))
            self.assertIn("A \\| B", text)

    def test_render_marks_file_as_generated(self):
        text = index.render([])
        self.assertIn("acta-index: generated", text)
        self.assertIn("archive_index.py", text)

    def test_render_includes_stamp_when_given(self):
        text = index.render([], generated_for="2026-07-30")
        self.assertIn("Обновлён: 2026-07-30", text)


class TestMain(unittest.TestCase):
    def test_writes_index_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            make_meeting(tmp, "2026-07-28_1100__a", summary="# T — 2026-07-28\n")
            buf = io.StringIO()
            code = index.main([tmp], stdout=buf)
            self.assertEqual(code, index.EXIT_OK)
            target = Path(tmp) / index.INDEX_NAME
            self.assertTrue(target.is_file())
            self.assertIn("Acta — индекс встреч", target.read_text(encoding="utf-8"))
            self.assertIn("1 meeting(s)", buf.getvalue())

    def test_stdout_mode_writes_no_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            make_meeting(tmp, "2026-07-28_1100__a", summary="# T — 2026-07-28\n")
            buf = io.StringIO()
            code = index.main([tmp, "--stdout"], stdout=buf)
            self.assertEqual(code, index.EXIT_OK)
            self.assertFalse((Path(tmp) / index.INDEX_NAME).exists())
            self.assertIn("Acta — индекс встреч", buf.getvalue())

    def test_regeneration_is_idempotent(self):
        with tempfile.TemporaryDirectory() as tmp:
            make_meeting(tmp, "2026-07-28_1100__a", summary="# T — 2026-07-28\n")
            buf = io.StringIO()
            index.main([tmp], stdout=buf)
            first = (Path(tmp) / index.INDEX_NAME).read_text(encoding="utf-8")
            index.main([tmp], stdout=buf)
            second = (Path(tmp) / index.INDEX_NAME).read_text(encoding="utf-8")
            self.assertEqual(first, second)

    def test_index_file_is_not_indexed_as_a_meeting(self):
        with tempfile.TemporaryDirectory() as tmp:
            make_meeting(tmp, "2026-07-28_1100__a", summary="# T — 2026-07-28\n")
            buf = io.StringIO()
            index.main([tmp], stdout=buf)
            index.main([tmp], stdout=buf)
            text = (Path(tmp) / index.INDEX_NAME).read_text(encoding="utf-8")
            self.assertIn("Встреч: **1**", text)

    def test_json_inventory(self):
        with tempfile.TemporaryDirectory() as tmp:
            make_meeting(tmp, "2026-07-28_1100__a", summary="# T — 2026-07-28\n")
            buf = io.StringIO()
            code = index.main([tmp, "--json"], stdout=buf)
            self.assertEqual(code, index.EXIT_OK)
            payload = json.loads(buf.getvalue())
            self.assertEqual(len(payload["meetings"]), 1)
            self.assertEqual(payload["meetings"][0]["topic"], "T")

    def test_missing_archive_is_usage_error(self):
        buf = io.StringIO()
        code = index.main(["/definitely/not/here"], stdout=buf)
        self.assertEqual(code, index.EXIT_USAGE)


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
