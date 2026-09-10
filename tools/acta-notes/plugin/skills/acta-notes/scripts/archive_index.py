#!/usr/bin/env python3
"""Generate ``~/Acta/INDEX.md`` — one scannable table over the whole archive.

The archive is deliberately flat: folder names are ``YYYY-MM-DD_HHMM__slug``, so
they sort chronologically on their own, and every tool that walks the archive —
``pipeline.py``, the skill's "newest folder in ``~/Acta``" rule, plain globs —
depends on that. Nesting by year and month would break all of it while solving
nothing that matters.

What a flat archive genuinely lacks is a way to see what is in it without opening
folders one by one. That is this script: it reads what each meeting already
contains — ``info.md`` for time and duration, the ``# `` heading of
``summary.md`` for the topic, the participants line, which artifacts exist, and
what state the audio is in — and writes a single table, newest first, grouped by
month.

The output is derived, never authored: ``INDEX.md`` is safe to delete and
regenerate at any time, and the script never modifies anything else. Meeting
folders are read-only to it, and ``CLAUDE.md`` in the archive root is left alone.

Usage::

    archive_index.py                 # write ~/Acta/INDEX.md
    archive_index.py --stdout        # print instead, change nothing
    archive_index.py --json          # machine-readable inventory
"""

from __future__ import annotations

import argparse
import datetime
import json
import re
import sys
from pathlib import Path

DEFAULT_ARCHIVE = "~/Acta"
INDEX_NAME = "INDEX.md"
WORK_DIRNAME = ".acta-notes"

MEETING_RE = re.compile(r"^(\d{4})-(\d{2})-(\d{2})_(\d{2})(\d{2})__(.*)$")
#: ``title: "…"`` / ``duration: "…"`` — the quoted YAML front-matter Acta writes.
FRONT_MATTER_RE = re.compile(r'^(\w+):\s*"?([^"\n]*)"?\s*$')
#: The summary's own H1. Trailing ``— YYYY-MM-DD`` is dropped: the date is
#: already a column, and repeating it costs width in every row.
SUMMARY_H1_RE = re.compile(r"^#\s+(.*?)\s*$", re.M)
TRAILING_DATE_RE = re.compile(r"\s*[—-]\s*\d{4}-\d{2}-\d{2}\s*$")
PARTICIPANTS_RE = re.compile(r"^-\s+\*\*Участник[^:]*:\*\*\s*(.+?)\s*$", re.M)
DURATION_RE = re.compile(r"(\d+):(\d{2}):(\d{2})")

AUDIO_SUFFIXES = (".wav", ".opus", ".flac")
#: Artifacts reported per meeting, in pipeline order, with the label used in the
#: table's compact "state" cell.
ARTIFACTS = (
    ("transcript.raw.md", "raw"),
    ("transcript.labeled.md", "lab"),
    ("transcript.md", "txt"),
    ("summary.md", "sum"),
    ("context.md", "ctx"),
    ("screenshots.md", "shots"),
)

EXIT_OK = 0
EXIT_USAGE = 2


def read_front_matter(path) -> dict:
    """Parse Acta's ``info.md`` front matter. Absent or broken -> ``{}``."""
    path = Path(path)
    if not path.is_file():
        return {}
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return {}
    if not lines or lines[0].strip() != "---":
        return {}
    fields = {}
    for line in lines[1:]:
        if line.strip() == "---":
            break
        m = FRONT_MATTER_RE.match(line)
        if m:
            fields[m.group(1)] = m.group(2).strip()
    return fields


def duration_seconds(text) -> int:
    m = DURATION_RE.search(text or "")
    if not m:
        return 0
    return int(m.group(1)) * 3600 + int(m.group(2)) * 60 + int(m.group(3))


def summary_topic(path):
    """The summary's H1 without its trailing date, or ``None``."""
    path = Path(path)
    if not path.is_file():
        return None
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None
    m = SUMMARY_H1_RE.search(text)
    if not m:
        return None
    return TRAILING_DATE_RE.sub("", m.group(1)).strip() or None


def summary_participants(path, limit=90):
    path = Path(path)
    if not path.is_file():
        return None
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None
    m = PARTICIPANTS_RE.search(text)
    if not m:
        return None
    value = re.sub(r"\*\*|`", "", m.group(1)).strip()
    value = re.sub(r"\s+", " ", value)
    if len(value) > limit:
        value = value[: limit - 1].rstrip(" ,;.") + "…"
    return value or None


def audio_state(meeting_dir):
    """``(label, bytes)`` describing what audio survives for this meeting."""
    meeting_dir = Path(meeting_dir)
    found = {}
    for suffix in AUDIO_SUFFIXES:
        files = [p for p in meeting_dir.glob(f"*{suffix}") if p.is_file()]
        if not files:
            continue
        total = 0
        for p in files:
            try:
                total += p.stat().st_size
            except OSError:
                pass
        found[suffix.lstrip(".")] = total
    if not found:
        return "—", 0
    label = "+".join(sorted(found))
    return label, sum(found.values())


def artifact_state(meeting_dir) -> list[str]:
    meeting_dir = Path(meeting_dir)
    present = []
    for name, label in ARTIFACTS:
        path = meeting_dir / name
        try:
            if path.is_file() and path.stat().st_size > 0:
                present.append(label)
        except OSError:
            pass
    return present


def scan_meeting(meeting_dir) -> dict | None:
    meeting_dir = Path(meeting_dir)
    m = MEETING_RE.match(meeting_dir.name)
    if not m:
        return None
    try:
        local = datetime.datetime(
            int(m.group(1)), int(m.group(2)), int(m.group(3)),
            int(m.group(4)), int(m.group(5)),
        )
    except ValueError:
        return None

    info = read_front_matter(meeting_dir / "info.md")
    summary = meeting_dir / "summary.md"
    audio_label, audio_bytes = audio_state(meeting_dir)
    artifacts = artifact_state(meeting_dir)
    return {
        "folder": meeting_dir.name,
        "local": local.isoformat(sep=" ", timespec="minutes"),
        "date": local.date().isoformat(),
        "time": local.strftime("%H:%M"),
        "month": local.strftime("%Y-%m"),
        "slug": m.group(6),
        "source": info.get("source") or "?",
        "duration": info.get("duration") or "?",
        "duration_seconds": duration_seconds(info.get("duration")),
        "status": info.get("status") or "?",
        "topic": summary_topic(summary),
        "participants": summary_participants(summary),
        "artifacts": artifacts,
        "has_summary": "sum" in artifacts,
        "audio": audio_label,
        "audio_bytes": audio_bytes,
    }


def scan_archive(archive) -> list[dict]:
    archive = Path(archive)
    if not archive.is_dir():
        return []
    out = []
    for path in sorted(archive.iterdir()):
        if not path.is_dir():
            continue
        entry = scan_meeting(path)
        if entry:
            out.append(entry)
    out.sort(key=lambda e: e["folder"], reverse=True)
    return out


def human_bytes(n) -> str:
    value = float(n)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if abs(value) < 1024.0 or unit == "TB":
            return f"{int(value)} B" if unit == "B" else f"{value:.1f} {unit}"
        value /= 1024.0
    return f"{value:.1f} TB"  # pragma: no cover


def _hhmm(seconds) -> str:
    hours, rem = divmod(int(seconds), 3600)
    return f"{hours} ч {rem // 60:02d} мин"


def render(entries, generated_for=None) -> str:
    total_seconds = sum(e["duration_seconds"] for e in entries)
    total_bytes = sum(e["audio_bytes"] for e in entries)
    missing = [e for e in entries if not e["has_summary"]]

    lines = [
        "<!-- acta-index: generated by archive_index.py — do not edit by hand -->",
        "# Acta — индекс встреч",
        "",
        "Файл **генерируемый**: пересоздаётся `archive_index.py`, править руками "
        "бессмысленно. Источник правды — сами папки встреч.",
        "",
        f"- Встреч: **{len(entries)}**",
        f"- Аудио суммарно: **{_hhmm(total_seconds)}**",
        f"- Занято аудиофайлами: **{human_bytes(total_bytes)}**",
    ]
    if missing:
        lines.append(f"- **Без `summary.md`: {len(missing)}** — " + ", ".join(
            e["folder"] for e in missing[:8]
        ) + ("…" if len(missing) > 8 else ""))
    else:
        lines.append("- Без `summary.md`: нет — итоги есть по всем встречам")
    if generated_for:
        lines.append(f"- Обновлён: {generated_for}")
    lines += [
        "",
        "Колонка **арт.** — какие артефакты есть: `raw` (дословный транскрипт), "
        "`lab` (с именами), `txt` (очищенный), `sum` (итоги), `ctx` (контекст), "
        "`shots` (скриншоты). Колонка **аудио** — `wav` исходник, `opus`/`flac` "
        "сжатый, `—` удалён.",
        "",
    ]

    by_month: dict[str, list[dict]] = {}
    for entry in entries:
        by_month.setdefault(entry["month"], []).append(entry)

    for month in sorted(by_month, reverse=True):
        rows = by_month[month]
        month_seconds = sum(e["duration_seconds"] for e in rows)
        lines += [
            f"## {month} — {len(rows)} встреч, {_hhmm(month_seconds)}",
            "",
            "| дата | время | длит. | источник | тема | участники | арт. | аудио |",
            "|---|---|---|---|---|---|---|---|",
        ]
        for e in rows:
            topic = e["topic"] or f"_(нет итогов)_ `{e['slug']}`"
            topic = topic.replace("|", "\\|")
            who = (e["participants"] or "—").replace("|", "\\|")
            audio = e["audio"]
            if e["audio_bytes"]:
                audio += f" {human_bytes(e['audio_bytes'])}"
            lines.append(
                f"| [{e['date']}](./{e['folder']}/) | {e['time']} | "
                f"{e['duration']} | {e['source']} | {topic} | {who} | "
                f"{'·'.join(e['artifacts']) or '—'} | {audio} |"
            )
        lines.append("")

    return "\n".join(lines).rstrip("\n") + "\n"


def build_parser():
    p = argparse.ArgumentParser(
        prog="archive_index.py", description=__doc__.split("\n")[0]
    )
    p.add_argument("archive", nargs="?", default=DEFAULT_ARCHIVE)
    p.add_argument(
        "--stdout",
        action="store_true",
        help="print the index instead of writing INDEX.md (writes nothing)",
    )
    p.add_argument("--json", action="store_true", help="machine-readable inventory")
    p.add_argument(
        "--stamp",
        metavar="TEXT",
        help="value for the 'Обновлён' line; omit to leave it out",
    )
    return p


def main(argv=None, stdout=None):
    args = build_parser().parse_args(argv)
    out = sys.stdout if stdout is None else stdout

    archive = Path(args.archive).expanduser()
    if not archive.is_dir():
        print(f"archive_index: no such archive: {archive}", file=sys.stderr)
        return EXIT_USAGE

    entries = scan_archive(archive)

    if args.json:
        print(
            json.dumps(
                {"archive": str(archive), "meetings": entries},
                ensure_ascii=False,
                indent=1,
            ),
            file=out,
        )
        return EXIT_OK

    text = render(entries, generated_for=args.stamp)

    if args.stdout:
        print(text, end="", file=out)
        return EXIT_OK

    target = archive / INDEX_NAME
    try:
        target.write_text(text, encoding="utf-8")
    except OSError as exc:
        print(f"archive_index: cannot write {target}: {exc}", file=sys.stderr)
        return EXIT_USAGE
    without = sum(1 for e in entries if not e["has_summary"])
    print(
        f"{target}: {len(entries)} meeting(s), "
        f"{_hhmm(sum(e['duration_seconds'] for e in entries))} of audio, "
        f"{without} without summary.md",
        file=out,
    )
    return EXIT_OK


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
