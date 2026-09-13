import _ctx

import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path

speakers = _ctx.load("speakers")


HEADER = [
    "# 2026-07-29 Weekly — транскрипт",
    "",
    "_Источник: локальный ASR. Дословно, без правок._",
    "",
]


def transcript(*rows):
    """``(time, label, text)`` tuples → a ``transcript.raw.md`` body."""
    lines = list(HEADER)
    for time, label, text in rows:
        lines.append(f"**[{time}] {label}:** {text}")
        lines.append("")
    return "\n".join(lines)


@contextlib.contextmanager
def meeting(raw=None, artifact=None, name="2026-07-29 Weekly"):
    """A meeting folder holding whatever this stage is supposed to read."""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp) / name
        (root / ".acta-notes").mkdir(parents=True)
        if raw is not None:
            speakers.raw_transcript_path(root).write_text(raw, encoding="utf-8")
        if artifact is not None:
            speakers.speakers_json_path(root).write_text(
                json.dumps(artifact, ensure_ascii=False), encoding="utf-8"
            )
        yield root


def artifact_of(root):
    return json.loads(speakers.speakers_json_path(root).read_text(encoding="utf-8"))


def entry_for(root, label):
    return artifact_of(root)["speakers"][label]


def labeled_lines(text):
    return [line for line in text.splitlines() if line.startswith("**[")]


def run_main(argv):
    """``main()`` with stdout captured — returns ``(exit_code, stdout)``."""
    buffer = io.StringIO()
    with contextlib.redirect_stdout(buffer):
        code = speakers.main(argv)
    return code, buffer.getvalue()


# --- anchor extraction -------------------------------------------------------


class SelfIntroTests(unittest.TestCase):
    def test_меня_зовут_names_the_speaker_of_that_line(self):
        raw = transcript(
            ("00:00:01", "Я", "Привет, начнём."),
            ("00:00:05", "SPK_01", "Всем привет, меня зовут Дмитрий."),
        )
        with meeting(raw) as root:
            speakers.run_build(root)
            entry = entry_for(root, "SPK_01")
            self.assertEqual(entry["name"], "Дмитрий")
            self.assertEqual(entry["anchor_type"], "self_intro")
            self.assertTrue(entry["anchored"])
            self.assertEqual(entry["status"], "anchored")

    def test_the_matched_span_is_kept_as_evidence(self):
        raw = transcript(("00:00:05", "SPK_01", "Меня зовут Дмитрий, я из платформы."))
        with meeting(raw) as root:
            speakers.run_build(root)
            evidence = entry_for(root, "SPK_01")["evidence"]
            self.assertEqual(len(evidence), 1)
            self.assertEqual(evidence[0]["span"], "Меня зовут Дмитрий")
            self.assertEqual(evidence[0]["timecode"], "00:00:05")
            self.assertEqual(evidence[0]["source_speaker"], "SPK_01")

    def test_bare_я_needs_a_capitalized_name(self):
        self.assertEqual(
            [a["surface"] for a in speakers.find_self_intros("Я Дмитрий, привет")],
            ["Дмитрий"],
        )
        self.assertEqual(speakers.find_self_intros("я думаю, что надо"), [])

    def test_a_self_intro_on_the_mic_track_names_nobody(self):
        raw = transcript(
            ("00:00:01", "Я", "Меня зовут Александр."),
            ("00:00:05", "SPK_01", "Угу."),
        )
        with meeting(raw) as root:
            report = speakers.run_build(root)
            self.assertIsNone(entry_for(root, "SPK_01")["name"])
            reasons = [a["reason"] for a in report["unattached_anchors"]]
            self.assertTrue(any("mic" in r or "Я" in r for r in reasons))


class VocativeTests(unittest.TestCase):
    def test_leading_short_form_names_whoever_answers(self):
        raw = transcript(
            ("00:00:10", "Я", "Дим, посмотри второй пункт."),
            ("00:00:14", "SPK_01", "Да, закроем на этой неделе."),
            ("00:04:00", "Я", "Дим, а по тестам?"),
            ("00:04:03", "SPK_01", "Тесты зелёные."),
        )
        with meeting(raw) as root:
            speakers.run_build(root)
            entry = entry_for(root, "SPK_01")
            self.assertEqual(entry["name"], "Дим")
            self.assertEqual(entry["anchor_type"], "vocative")
            self.assertEqual(entry["evidence"][0]["span"], "Дим,")

    def test_trailing_vocative_is_also_an_anchor(self):
        raw = transcript(
            ("00:01:00", "SPK_01", "Ты фиксируешь, Люб?"),
            ("00:01:03", "SPK_02", "Фиксирую."),
            ("00:02:00", "SPK_01", "Ты записала, Люб?"),
            ("00:02:04", "SPK_02", "Записала."),
        )
        with meeting(raw) as root:
            speakers.run_build(root)
            self.assertEqual(entry_for(root, "SPK_02")["name"], "Люб")
            self.assertIsNone(entry_for(root, "SPK_01")["name"])

    def test_the_speaker_who_said_it_is_never_the_addressee(self):
        raw = transcript(
            ("00:00:10", "SPK_01", "Дим, глянешь?"),
            ("00:00:12", "SPK_01", "Ну то есть когда сможешь."),
            ("00:00:20", "SPK_02", "Гляну."),
            ("00:03:00", "SPK_01", "Дим, ещё по логам вопрос."),
            ("00:03:05", "SPK_02", "Смотрю логи."),
        )
        with meeting(raw) as root:
            speakers.run_build(root)
            self.assertIsNone(entry_for(root, "SPK_01")["name"])
            self.assertEqual(entry_for(root, "SPK_02")["name"], "Дим")

    def test_an_address_answered_on_the_mic_track_names_nobody(self):
        """D8: the mic track is the user, so his name must not land on a SPK.

        `_vocative_target` used to *skip* non-diarized rows, so "Саш, посмотри"
        answered by the user on the mic handed "Саш" to whichever SPK_NN spoke
        next inside the look-ahead window — marked anchored, at 0.6+.
        """
        raw = transcript(
            ("00:00:10", "SPK_01", "Саш, посмотри на график."),
            ("00:00:13", "Я", "Смотрю, сейчас скажу."),
            ("00:00:18", "SPK_02", "А я пока по бэклогу пройдусь."),
            ("00:04:00", "SPK_01", "Саш, а по бюджету?"),
            ("00:04:04", "Я", "Бюджет согласован."),
            ("00:04:09", "SPK_02", "Отлично."),
        )
        with meeting(raw, ) as root:
            report = speakers.run_build(root, attendees=("Александр",))
            for label in ("SPK_01", "SPK_02"):
                self.assertIsNone(entry_for(root, label)["name"], label)
            reasons = [a["reason"] for a in report["unattached_anchors"]]
            self.assertTrue(
                any("non-diarized" in r for r in reasons), reasons
            )

    def test_a_single_vocative_alone_does_not_mint_a_name(self):
        """Anchor-only mode has nothing to check a surface against.

        `ADDRESS_STOPWORDS` is a blacklist, so a sentence-initial word it does
        not know — here a product name — used to be written out as a speaker's
        name with `status: anchored`. One occurrence is no longer enough.
        """
        raw = transcript(
            ("00:00:10", "SPK_01", "Мы это уже задеплоили, Кубер."),
            ("00:00:14", "SPK_02", "Ага, видел."),
        )
        with meeting(raw) as root:
            report = speakers.run_build(root)
            entry = entry_for(root, "SPK_02")
            self.assertIsNone(entry["name"])
            self.assertEqual(entry["status"], "inferred")
            self.assertEqual(entry["uncorroborated"], "Кубер")
            self.assertEqual(report["anchored_count"], 0)
            # …and the anchor is still on the record for a human to read.
            self.assertTrue(entry["evidence"])

    def test_an_attendee_list_corroborates_a_single_vocative(self):
        raw = transcript(
            ("00:00:10", "Я", "Дим, глянешь?"),
            ("00:00:12", "SPK_01", "Гляну."),
        )
        with meeting(raw) as root:
            speakers.run_build(root, attendees=("Дмитрий",))
            self.assertEqual(entry_for(root, "SPK_01")["name"], "Дмитрий")

    def test_common_openers_are_not_addresses(self):
        for opener in ("Отлично", "Внимание", "Здравствуйте", "Супер"):
            with self.subTest(opener=opener):
                self.assertEqual(
                    speakers.find_vocatives(f"{opener}, поехали дальше."), []
                )

    def test_an_unanswered_vocative_is_recorded_but_attaches_to_nobody(self):
        raw = transcript(
            ("00:00:10", "SPK_01", "Всем привет."),
            ("00:09:00", "Я", "Дим, ты тут?"),
        )
        with meeting(raw) as root:
            report = speakers.run_build(root)
            self.assertIsNone(entry_for(root, "SPK_01")["name"])
            self.assertEqual(
                [a["surface"] for a in report["unattached_anchors"]], ["Дим"]
            )

    def test_sentence_openers_are_not_names(self):
        for text in ("Так, поехали дальше.", "Ладно, давайте.", "Коллеги, начинаем."):
            with self.subTest(text=text):
                self.assertEqual(speakers.find_vocatives(text), [])


class GivenNameShapeTests(unittest.TestCase):
    """The allowlist that replaced the blacklist.

    Measured regression on a 57-minute recording: `ADDRESS_STOPWORDS` plus the
    corroboration count let «Соответственно» and «Единственное» be written out as
    speaker names, and 123 transcript lines were relabelled with them. Repetition
    was no defence — «Соответственно» recurred three times.
    """

    #: Surfaces a run harvested as a "vocative" that are not names. Kept as language
    #: coverage: these are ordinary Russian words, and the matcher must reject them.
    OBSERVED_NON_NAMES = (
        "Соответственно", "Единственное", "Допустим", "Стенциально", "Информацию",
        "принципе", "клиенты", "решения", "вопросы", "конфигов", "Пустышками",
        "Устройства", "Прошлого", "Этого", "Предложение", "Казалось", "Учитывая",
        "Возможно", "Непонятно", "Никаких", "Первое", "того", "Хотим", "Сказать",
        "Определяем", "Видите", "Скорее", "URL", "Origin", "фронта", "наоборот",
    )

    #: Address forms that must keep working, including the irregular hypocorisms
    #: `is_short_form_of` cannot derive from a full name. Language coverage, not a
    #: roster: nothing here says who was in any recording.
    OBSERVED_NAMES = (
        "Дим", "Саш", "Саша", "Люб", "Люба", "Илья", "Ваня", "Антон",
        "Айрат", "Алмаз",
    )

    def test_observed_non_names_are_rejected(self):
        for token in self.OBSERVED_NON_NAMES:
            with self.subTest(token=token):
                self.assertFalse(speakers.looks_like_given_name(token))

    def test_observed_names_are_accepted(self):
        for token in self.OBSERVED_NAMES:
            with self.subTest(token=token):
                self.assertTrue(speakers.looks_like_given_name(token))

    def test_a_repeated_non_name_still_mints_nothing(self):
        """The exact shape of the measured failure, at the count that beat it."""
        raw = transcript(
            ("00:03:53", "SPK_02", "Ну вот. Соответственно, тут нужен транспорт."),
            ("00:03:58", "SPK_04", "Да, согласен."),
            ("00:09:13", "SPK_05", "Origin проверяем. Соответственно, дальше."),
            ("00:09:20", "SPK_04", "Проверим."),
            ("00:09:41", "SPK_05", "Соответственно, мы это выключаем."),
            ("00:09:45", "SPK_04", "Хорошо."),
        )
        with meeting(raw) as root:
            report = speakers.run_build(root)
            entry = entry_for(root, "SPK_04")
            self.assertIsNone(entry["name"])
            self.assertEqual(entry["status"], "inferred")
            self.assertEqual(entry["uncorroborated"], "Соответственно")
            self.assertEqual(entry["rejected_reason"], "not-a-known-given-name")
            self.assertEqual(report["anchored_count"], 0)
            # The evidence a human reviews is still on the record.
            self.assertTrue(entry["evidence"])

    def test_an_attendee_list_still_overrides_the_lexicon(self):
        """A name the lexicon has never heard of is fine once attendees say so.

        The allowlist gates the *anchor-only* path; `--attendees` remains
        authoritative, so an unusual given name is not locked out.
        """
        raw = transcript(
            ("00:00:10", "SPK_01", "Ниязбек, глянешь конфиг?"),
            ("00:00:14", "SPK_02", "Гляну."),
        )
        self.assertFalse(speakers.looks_like_given_name("Ниязбек"))
        with meeting(raw) as root:
            speakers.run_build(root, attendees=("Ниязбек Сатыбалдиев",))
            self.assertEqual(entry_for(root, "SPK_02")["name"], "Ниязбек Сатыбалдиев")


class NoAnchorTests(unittest.TestCase):
    def test_a_speaker_nobody_names_keeps_its_label_and_is_inferred(self):
        raw = transcript(
            ("00:00:01", "SPK_01", "Давайте начнём с метрик."),
            ("00:00:20", "SPK_02", "Метрики выросли на десять процентов."),
        )
        with meeting(raw) as root:
            report = speakers.run_build(root)
            for label in ("SPK_01", "SPK_02"):
                entry = entry_for(root, label)
                self.assertIsNone(entry["name"])
                self.assertFalse(entry["anchored"])
                self.assertEqual(entry["status"], "inferred")
                self.assertEqual(entry["evidence"], [])
                self.assertEqual(entry["confidence"], 0.0)
            self.assertEqual(report["anchored_count"], 0)
            self.assertEqual(report["inferred_count"], 2)

    def test_an_attendee_list_alone_never_names_anybody(self):
        # The single other attendee is the classic "obvious" guess. D8 forbids it.
        raw = transcript(("00:00:01", "SPK_01", "Погнали по задачам."))
        with meeting(raw) as root:
            speakers.run_build(root, attendees=["Дмитрий Иванов"])
            self.assertIsNone(entry_for(root, "SPK_01")["name"])

    def test_two_names_of_equal_weight_resolve_to_no_name(self):
        raw = transcript(
            ("00:00:10", "Я", "Дим, глянешь?"),
            ("00:00:12", "SPK_01", "Ага."),
            ("00:00:20", "Я", "Люб, а ты?"),
            ("00:00:22", "SPK_01", "Тоже."),
        )
        with meeting(raw) as root:
            speakers.run_build(root)
            entry = entry_for(root, "SPK_01")
            self.assertIsNone(entry["name"])
            self.assertEqual(sorted(entry["conflict"]), ["Дим", "Люб"])
            self.assertEqual(len(entry["evidence"]), 2)


class NameCollisionTests(unittest.TestCase):
    """D8 one level up: one name must never label two diarized speakers.

    Two voices rendered as the same person is invisible downstream — the
    labeled transcript shows one name and the provenance counts both as
    anchored — so it is exactly the confident wrong attribution D8 forbids.
    """

    def test_a_tie_between_two_speakers_leaves_both_unnamed(self):
        # Two vocatives, same name, different speakers answering: nothing
        # distinguishes them, so naming either one would be a coin flip.
        raw = transcript(
            ("00:00:10", "Я", "Дим, глянешь?"),
            ("00:00:12", "SPK_01", "Гляну."),
            ("00:05:00", "Я", "Дим, а по релизу?"),
            ("00:05:02", "SPK_02", "Закрыли."),
        )
        with meeting(raw) as root:
            report = speakers.run_build(root, attendees=("Дим",))
            for label in ("SPK_01", "SPK_02"):
                entry = entry_for(root, label)
                self.assertIsNone(entry["name"], label)
                self.assertEqual(entry["status"], "inferred")
                self.assertFalse(entry["anchored"])
                self.assertEqual(entry["confidence"], 0.0)
                self.assertEqual(entry["name_conflict"]["name"], "Дим")
                self.assertEqual(
                    entry["name_conflict"]["also_claimed_by"],
                    [other for other in ("SPK_01", "SPK_02") if other != label],
                )
            self.assertEqual(report["anchored_count"], 0)

    def test_a_self_intro_outranks_a_vocative_for_the_same_name(self):
        raw = transcript(
            ("00:00:10", "SPK_01", "Меня зовут Дмитрий, я веду релиз."),
            ("00:05:00", "Я", "Дмитрий, глянешь?"),
            ("00:05:02", "SPK_02", "Гляну."),
        )
        with meeting(raw) as root:
            speakers.run_build(root, attendees=("Дмитрий",))
            winner = entry_for(root, "SPK_01")
            loser = entry_for(root, "SPK_02")

            self.assertEqual(winner["name"], "Дмитрий")
            self.assertEqual(winner["status"], "anchored")
            self.assertNotIn("name_conflict", winner)

            self.assertIsNone(loser["name"])
            self.assertEqual(loser["status"], "inferred")
            self.assertEqual(loser["name_conflict"]["name"], "Дмитрий")
            self.assertEqual(loser["name_conflict"]["also_claimed_by"], ["SPK_01"])

    def test_a_demoted_speaker_keeps_its_label_in_the_transcript(self):
        raw = transcript(
            ("00:00:10", "SPK_01", "Меня зовут Дмитрий, я веду релиз."),
            ("00:05:00", "Я", "Дмитрий, глянешь?"),
            ("00:05:02", "SPK_02", "Гляну."),
        )
        with meeting(raw) as root:
            speakers.run_build(root, attendees=("Дмитрий",))
            speakers.run_apply(root)
            text = speakers.labeled_transcript_path(root).read_text(encoding="utf-8")

            self.assertIn("SPK_02", text)
            self.assertEqual(text.count("Дмитрий:"), 1)

    def test_distinct_names_are_left_alone(self):
        raw = transcript(
            ("00:00:10", "Я", "Дим, глянешь?"),
            ("00:00:12", "SPK_01", "Гляну."),
            ("00:05:00", "Я", "Люб, а ты?"),
            ("00:05:02", "SPK_02", "Тоже."),
            ("00:07:00", "Я", "Дим, и по релизу тоже."),
            ("00:07:03", "SPK_01", "Понял."),
            ("00:08:00", "Я", "Люб, зафиксируешь?"),
            ("00:08:02", "SPK_02", "Зафиксирую."),
        )
        with meeting(raw) as root:
            speakers.run_build(root)
            self.assertEqual(entry_for(root, "SPK_01")["name"], "Дим")
            self.assertEqual(entry_for(root, "SPK_02")["name"], "Люб")
            for label in ("SPK_01", "SPK_02"):
                self.assertNotIn("name_conflict", entry_for(root, label))


# --- attendee matching -------------------------------------------------------


class AttendeeMatchingTests(unittest.TestCase):
    def test_russian_short_forms_resolve_to_the_full_attendee(self):
        self.assertTrue(speakers.is_short_form_of("Дим", "Дмитрий"))
        self.assertTrue(speakers.is_short_form_of("Люб", "Любовь"))
        self.assertTrue(speakers.is_short_form_of("Саш", "Саша"))
        self.assertTrue(speakers.is_short_form_of("Дмитрий", "Дмитрий"))

    def test_a_near_miss_must_not_match(self):
        # Same first letter, same consonant skeleton opening — and a different
        # person. The first-vowel guard is what stops it.
        self.assertFalse(speakers.is_short_form_of("Ром", "Римма"))
        self.assertFalse(speakers.is_short_form_of("Дим", "Денис"))
        self.assertFalse(speakers.is_short_form_of("Кать", "Мария"))

    def test_a_vocative_the_attendee_list_rejects_names_nobody(self):
        raw = transcript(
            ("00:00:10", "Я", "Ром, посмотришь дашборд?"),
            ("00:00:14", "SPK_01", "Посмотрю."),
        )
        with meeting(raw) as root:
            speakers.run_build(root, attendees=["Римма Соколова"])
            entry = entry_for(root, "SPK_01")
            self.assertIsNone(entry["name"])
            self.assertFalse(entry["anchored"])
            # The near miss is still on the record for a human to look at.
            self.assertEqual(entry["evidence"][0]["surface"], "Ром")
            self.assertEqual(entry["evidence"][0]["attendee_match"], "none")

    def test_a_matched_vocative_takes_the_full_attendee_name(self):
        raw = transcript(
            ("00:00:10", "Я", "Дим, посмотри второй пункт."),
            ("00:00:14", "SPK_01", "Закроем."),
        )
        with meeting(raw) as root:
            speakers.run_build(
                root, attendees=["Дмитрий Иванов", "Любовь Кузнецова"]
            )
            entry = entry_for(root, "SPK_01")
            self.assertEqual(entry["name"], "Дмитрий Иванов")
            self.assertEqual(entry["evidence"][0]["matched_attendee"], "Дмитрий Иванов")
            self.assertGreater(entry["confidence"], speakers.ANCHOR_CONFIDENCE["vocative"])

    def test_an_ambiguous_stem_names_nobody(self):
        raw = transcript(
            ("00:00:10", "Я", "Ань, глянешь?"),
            ("00:00:14", "SPK_01", "Гляну."),
        )
        with meeting(raw) as root:
            speakers.run_build(root, attendees=["Анна Петрова", "Аня Сидорова"])
            entry = entry_for(root, "SPK_01")
            self.assertIsNone(entry["name"])
            self.assertEqual(entry["evidence"][0]["attendee_match"], "ambiguous")

    def test_attendees_are_parsed_from_comma_lists_and_repeats(self):
        self.assertEqual(
            speakers.parse_attendees(["Дмитрий Иванов, Любовь Кузнецова", "Пётр"]),
            ["Дмитрий Иванов", "Любовь Кузнецова", "Пётр"],
        )

    def test_a_self_intro_outranks_a_conflicting_vocative(self):
        raw = transcript(
            ("00:00:05", "SPK_01", "Меня зовут Дмитрий."),
            ("00:00:20", "Я", "Люб, а ты?"),
            ("00:00:22", "SPK_01", "Я тут."),
        )
        with meeting(raw) as root:
            speakers.run_build(root)
            self.assertEqual(entry_for(root, "SPK_01")["name"], "Дмитрий")


# --- the artifact ------------------------------------------------------------


class SpeakersJsonSchemaTests(unittest.TestCase):
    def test_every_entry_carries_the_full_D8_schema(self):
        raw = transcript(
            ("00:00:05", "SPK_01", "Меня зовут Дмитрий."),
            ("00:00:20", "SPK_02", "Ок, поехали."),
        )
        with meeting(raw) as root:
            speakers.run_build(root, attendees=["Дмитрий Иванов"])
            artifact = artifact_of(root)
            self.assertEqual(artifact["schema"], "acta-notes/speakers@1")
            self.assertEqual(sorted(artifact["speakers"]), ["SPK_01", "SPK_02"])
            for entry in artifact["speakers"].values():
                for field in (
                    "speaker",
                    "name",
                    "status",
                    "anchored",
                    "anchor_type",
                    "confidence",
                    "evidence",
                    "resolved_group",
                    "utterances",
                    "words",
                ):
                    self.assertIn(field, entry)
                self.assertIn(entry["status"], ("anchored", "inferred"))

    def test_resolved_group_is_always_written_and_null_by_default(self):
        raw = transcript(("00:00:05", "SPK_01", "Привет."))
        with meeting(raw) as root:
            speakers.run_build(root)
            self.assertIsNone(entry_for(root, "SPK_01")["resolved_group"])
            speakers.run_build(root, group="work")
            self.assertEqual(entry_for(root, "SPK_01")["resolved_group"], "work")

    def test_the_mic_label_is_not_a_speaker_entry(self):
        raw = transcript(
            ("00:00:01", "Я", "Начнём."),
            ("00:00:05", "SPK_01", "Давай."),
        )
        with meeting(raw) as root:
            speakers.run_build(root)
            self.assertEqual(list(artifact_of(root)["speakers"]), ["SPK_01"])

    def test_a_missing_raw_transcript_fails_loudly(self):
        with meeting() as root:
            report = speakers.run_build(root)
            self.assertEqual(report["status"], speakers.STATUS_MISSING)
            self.assertEqual(speakers.exit_code(report), speakers.EXIT_FAILED)
            self.assertFalse(speakers.speakers_json_path(root).exists())


# --- apply -------------------------------------------------------------------


@contextlib.contextmanager
def built_meeting(raw, **kwargs):
    """A folder that has already been through ``build``."""
    with meeting(raw) as root:
        speakers.run_build(root, **kwargs)
        yield root


class ApplyTests(unittest.TestCase):
    RAW = transcript(
        ("00:00:01", "Я", "Дим, посмотри второй пункт."),
        ("00:00:05", "SPK_01", "Закроем на этой неделе."),
        ("00:00:20", "SPK_02", "У меня вопрос по метрикам."),
    )

    def test_it_reads_raw_and_writes_labeled(self):
        with built_meeting(self.RAW, attendees=["Дмитрий Иванов"]) as root:
            report = speakers.run_apply(root)
            self.assertEqual(report["status"], speakers.STATUS_OK)
            self.assertEqual(report["source"], str(speakers.raw_transcript_path(root)))
            self.assertEqual(
                report["output"], str(speakers.labeled_transcript_path(root))
            )
            labeled = speakers.labeled_transcript_path(root).read_text(encoding="utf-8")
            self.assertIn("**[00:00:05] Дмитрий Иванов:**", labeled)

    def test_the_raw_transcript_is_byte_identical_afterwards(self):
        with built_meeting(self.RAW) as root:
            before = speakers.raw_transcript_path(root).read_bytes()
            speakers.run_apply(root)
            self.assertEqual(speakers.raw_transcript_path(root).read_bytes(), before)

    def test_it_never_creates_transcript_md(self):
        with built_meeting(self.RAW) as root:
            speakers.run_apply(root)
            self.assertFalse((root / speakers.CLEAN_TRANSCRIPT_NAME).exists())

    def test_asked_to_write_transcript_md_it_refuses_with_exit_2(self):
        with built_meeting(self.RAW) as root:
            target = root / speakers.CLEAN_TRANSCRIPT_NAME
            report = speakers.run_apply(root, output=target)
            self.assertEqual(report["status"], speakers.STATUS_REFUSED)
            self.assertEqual(speakers.exit_code(report), speakers.EXIT_USAGE)
            self.assertFalse(target.exists())
            self.assertIn("S7", report["detail"])

    def test_it_also_refuses_to_write_over_the_raw_transcript(self):
        with built_meeting(self.RAW) as root:
            before = speakers.raw_transcript_path(root).read_bytes()
            report = speakers.run_apply(
                root, output=speakers.raw_transcript_path(root)
            )
            self.assertEqual(report["status"], speakers.STATUS_REFUSED)
            self.assertEqual(speakers.raw_transcript_path(root).read_bytes(), before)

    def test_inferred_speakers_keep_their_label(self):
        with built_meeting(self.RAW, attendees=["Дмитрий Иванов"]) as root:
            report = speakers.run_apply(root)
            labeled = speakers.labeled_transcript_path(root).read_text(encoding="utf-8")
            self.assertIn("**[00:00:20] SPK_02:**", labeled)
            self.assertEqual(report["kept_labels"], ["SPK_02"])
            self.assertEqual(report["lines_relabeled"], 1)

    def test_the_mic_track_is_left_alone(self):
        with built_meeting(self.RAW, attendees=["Дмитрий Иванов"]) as root:
            speakers.run_apply(root)
            labeled = speakers.labeled_transcript_path(root).read_text(encoding="utf-8")
            self.assertIn("**[00:00:01] Я:** Дим, посмотри второй пункт.", labeled)

    def test_only_the_label_position_is_rewritten(self):
        text = "**[00:00:05] SPK_01:** SPK_01 не слышно\n"
        out, replaced = speakers.relabel(text, {"SPK_01": "Дмитрий"})
        self.assertEqual(out, "**[00:00:05] Дмитрий:** SPK_01 не слышно\n")
        self.assertEqual(replaced, 1)

    def test_the_utterance_text_survives_verbatim(self):
        with built_meeting(self.RAW, attendees=["Дмитрий Иванов"]) as root:
            speakers.run_apply(root)
            raw_text = [
                line.split(":**", 1)[1]
                for line in labeled_lines(
                    speakers.raw_transcript_path(root).read_text(encoding="utf-8")
                )
            ]
            labeled_text = [
                line.split(":**", 1)[1]
                for line in labeled_lines(
                    speakers.labeled_transcript_path(root).read_text(encoding="utf-8")
                )
            ]
            self.assertEqual(raw_text, labeled_text)

    def test_a_provenance_note_records_what_was_substituted(self):
        with built_meeting(self.RAW, attendees=["Дмитрий Иванов"]) as root:
            speakers.run_apply(root)
            labeled = speakers.labeled_transcript_path(root).read_text(encoding="utf-8")
            note = [line for line in labeled.splitlines() if line.startswith("_Имена")]
            self.assertEqual(len(note), 1)
            self.assertIn("SPK_01 → Дмитрий Иванов", note[0])
            self.assertIn("SPK_02", note[0])

    def test_apply_is_source_agnostic(self):
        # A Teams-converted transcript has no diarization behind it at all;
        # apply must still work off transcript.raw.md alone.
        raw = transcript(
            ("00:00:01", "Дмитрий Иванов", "Официальный транскрипт из Teams."),
        )
        with built_meeting(raw) as root:
            (speakers.work_dir(root) / speakers.TEAMS_VTT_JSON_NAME).write_text(
                '{"stage": "teams-vtt", "status": "ok"}', encoding="utf-8"
            )
            report = speakers.run_apply(root)
            self.assertEqual(report["status"], speakers.STATUS_OK)
            self.assertEqual(report["lines_relabeled"], 0)
            labeled = speakers.labeled_transcript_path(root).read_text(encoding="utf-8")
            self.assertIn("**[00:00:01] Дмитрий Иванов:**", labeled)
            # The names came from the recording itself, so the note must not
            # read as "nobody was identified" — S7 works off this line.
            self.assertNotIn("ни один спикер не опознан", labeled)
            self.assertIn("имена пришли из самой записи", labeled)

    def test_a_mic_only_local_asr_run_does_not_claim_teams_provenance(self):
        # Nothing was diarized, so `speakers` is empty — but this is a local ASR
        # meeting with one track, not a Teams transcript. The Teams note would
        # claim the names came from the recording: a provenance lie in the one
        # document whose whole purpose is provenance.
        raw = transcript(
            ("00:00:01", speakers.MIC_LABEL, "Записал сам, второй дорожки нет."),
        )
        with built_meeting(raw) as root:
            (speakers.work_dir(root) / speakers.TRANSCRIBE_JSON_NAME).write_text(
                '{"stage": "transcribe", "status": "ok"}', encoding="utf-8"
            )
            report = speakers.run_apply(root)
            self.assertEqual(report["status"], speakers.STATUS_OK)
            labeled = speakers.labeled_transcript_path(root).read_text(encoding="utf-8")

        self.assertNotIn("имена пришли из самой записи", labeled)
        self.assertIn(speakers.MIC_LABEL, labeled)
        self.assertIn("D5", labeled)
        self.assertIn(speakers.RAW_TRANSCRIPT_NAME, labeled)

    def test_the_teams_note_fires_off_the_converters_own_marker(self):
        raw = transcript(("00:00:01", "Дмитрий Иванов", "Из Teams."))
        with built_meeting(raw) as root:
            (speakers.work_dir(root) / speakers.TEAMS_VTT_JSON_NAME).write_text(
                '{"stage": "teams-vtt", "status": "ok"}', encoding="utf-8"
            )
            self.assertFalse(speakers.is_local_asr(root))
            self.assertEqual(speakers.detect_source(root), speakers.SOURCE_TEAMS_VTT)
            speakers.run_apply(root)
            labeled = speakers.labeled_transcript_path(root).read_text(encoding="utf-8")
        self.assertIn("имена пришли из самой записи", labeled)

    def test_neither_marker_present_claims_neither_provenance(self):
        # `.acta-notes/` is documented as disposable, so a meeting folder with a
        # transcript and no stage JSON is reachable. Reading "Teams" out of the
        # *absence* of transcribe.json made the note claim the names came from the
        # recording about a locally transcribed meeting — a provenance lie in the
        # one line that exists to carry provenance. Neither claim is evidenced
        # here, so the note must make neither.
        raw = transcript(("00:00:01", "Дмитрий Иванов", "Источник неизвестен."))
        with built_meeting(raw) as root:
            self.assertEqual(speakers.detect_source(root), speakers.SOURCE_UNKNOWN)
            speakers.run_apply(root)
            labeled = speakers.labeled_transcript_path(root).read_text(encoding="utf-8")
        self.assertNotIn("имена пришли из самой записи", labeled)
        self.assertNotIn("D5", labeled)
        self.assertIn("источник транскрипта не определён", labeled)
        self.assertIn(speakers.RAW_TRANSCRIPT_NAME, labeled)

    def test_the_note_is_keyed_on_the_source_not_on_the_absence_of_labels(self):
        artifact = {"schema": "acta-notes/speakers@1", "speakers": {}}
        cases = (
            (speakers.SOURCE_LOCAL_ASR, "D5"),
            (speakers.SOURCE_TEAMS_VTT, "имена пришли из самой записи"),
            (speakers.SOURCE_UNKNOWN, "источник транскрипта не определён"),
        )
        for source, expected in cases:
            with self.subTest(source=source):
                note = speakers.provenance_note({}, artifact, source=source)
                self.assertIn(expected, note)

    def test_a_diarized_local_asr_run_keeps_the_anchor_note(self):
        with built_meeting(self.RAW, attendees=["Дмитрий Иванов"]) as root:
            (speakers.work_dir(root) / speakers.TRANSCRIBE_JSON_NAME).write_text(
                '{"stage": "transcribe", "status": "ok"}', encoding="utf-8"
            )
            speakers.run_apply(root)
            labeled = speakers.labeled_transcript_path(root).read_text(encoding="utf-8")
        self.assertIn("SPK_01 → Дмитрий Иванов", labeled)
        self.assertNotIn("подставлять было нечего", labeled)

    def test_apply_without_a_speakers_json_fails_loudly(self):
        with meeting(self.RAW) as root:
            report = speakers.run_apply(root)
            self.assertEqual(report["status"], speakers.STATUS_MISSING)
            self.assertEqual(speakers.exit_code(report), speakers.EXIT_FAILED)
            self.assertFalse(speakers.labeled_transcript_path(root).exists())

    def test_a_hand_edited_artifact_is_honoured(self):
        # S6: Claude reviews speakers.json and may correct a name before apply.
        artifact = {
            "schema": "acta-notes/speakers@1",
            "speakers": {
                "SPK_01": {
                    "speaker": "SPK_01",
                    "name": "Любовь Кузнецова",
                    "status": "anchored",
                    "anchored": True,
                }
            },
        }
        with meeting(self.RAW, artifact=artifact) as root:
            speakers.run_apply(root)
            self.assertIn(
                "**[00:00:05] Любовь Кузнецова:**",
                speakers.labeled_transcript_path(root).read_text(encoding="utf-8"),
            )


# --- CLI ---------------------------------------------------------------------


class CliTests(unittest.TestCase):
    def test_build_then_apply_end_to_end(self):
        raw = transcript(
            ("00:00:01", "Я", "Дим, посмотри второй пункт."),
            ("00:00:05", "SPK_01", "Закроем."),
        )
        with meeting(raw) as root:
            code, _ = run_main(
                ["build", str(root), "--attendees", "Дмитрий Иванов", "--json"]
            )
            self.assertEqual(code, speakers.EXIT_OK)
            self.assertTrue(
                speakers.stage_json_path(root, "build").is_file()
            )
            code, _ = run_main(["apply", str(root)])
            self.assertEqual(code, speakers.EXIT_OK)
            self.assertTrue(speakers.labeled_transcript_path(root).is_file())
            self.assertTrue(speakers.stage_json_path(root, "apply").is_file())

    def test_a_refusal_leaves_no_stage_json_behind(self):
        with built_meeting(ApplyTests.RAW) as root:
            code, _ = run_main(
                [
                    "apply",
                    str(root),
                    "--output",
                    str(root / speakers.CLEAN_TRANSCRIPT_NAME),
                ]
            )
            self.assertEqual(code, speakers.EXIT_USAGE)
            self.assertFalse(speakers.stage_json_path(root, "apply").exists())

    def test_a_mode_is_required(self):
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                speakers.main([])


class NameSanitationTests(unittest.TestCase):
    """``LINE_RE`` matches a speaker as ``[^:*]+?``, so a name carrying ``:`` or
    ``*`` makes every rewritten line stop parsing — and verify then reports the
    ``transcript`` hard gate, pointing the operator at ASR instead of the name."""

    def test_colons_and_stars_are_folded_out_of_attendee_names(self):
        self.assertEqual(speakers.clean_name("Иван: Петров"), "Иван Петров")
        self.assertEqual(speakers.clean_name("**Мария**"), "Мария")
        self.assertEqual(speakers.parse_attendees(["A:B"]), ["A B"])

    def test_a_relabelled_line_still_parses(self):
        artifact = {
            "speakers": {
                "SPK_01": {"name": "Иван: Петров", "anchored": True},
            }
        }
        mapping = speakers.name_map(artifact)
        text = "**[00:00:01] SPK_01:** привет\n"
        relabelled, replaced = speakers.relabel(text, mapping)

        self.assertEqual(replaced, 1)
        match = speakers.LINE_RE.match(relabelled.splitlines()[0])
        self.assertIsNotNone(match, relabelled)
        self.assertEqual(match.group("speaker").strip(), "Иван Петров")

    def test_a_name_that_cleans_to_nothing_substitutes_nothing(self):
        artifact = {"speakers": {"SPK_01": {"name": ":*:", "anchored": True}}}
        self.assertEqual(speakers.name_map(artifact), {})


class ApplyCollisionTests(unittest.TestCase):
    """``apply`` must enforce D8's no-shared-name rule on its own.

    ``build`` guards it via ``resolve_name_collisions``, but ``apply`` routinely
    runs over a ``speakers.json`` this process did not write: SKILL.md tells the
    operator to hand-correct the map and re-run ``pipeline.py --from-stage
    speakers``, which ``labeling_only_stale`` turns into apply-only — so build's
    guard is bypassed *by design* on the one path where a human just typed the
    names, and a typo rendered two diarized voices as one person with no gate
    firing (verify.speaker_tally merges them).
    """

    RAW = transcript(
        ("00:00:01", "SPK_01", "привет коллеги"),
        ("00:00:05", "SPK_02", "да согласен"),
    )

    def _artifact(self, first, second):
        return {
            "schema": "acta-notes/speakers@1",
            "speakers": {
                "SPK_01": {"name": first, "anchored": True, "status": "anchored"},
                "SPK_02": {"name": second, "anchored": True, "status": "anchored"},
            },
        }

    def test_one_name_claimed_by_two_labels_substitutes_neither(self):
        artifact = self._artifact("Дмитрий", "Дмитрий")
        self.assertEqual(speakers.name_map(artifact), {})
        self.assertEqual(
            speakers.name_collisions(artifact), {"Дмитрий": ["SPK_01", "SPK_02"]}
        )

    def test_the_labels_survive_into_the_labeled_transcript(self):
        with meeting(self.RAW, artifact=self._artifact("Дмитрий", "Дмитрий")) as root:
            report = speakers.run_apply(root)
            labeled = speakers.labeled_transcript_path(root).read_text(encoding="utf-8")

        self.assertEqual(report["status"], speakers.STATUS_OK)
        self.assertEqual(report["lines_relabeled"], 0)
        for label in ("SPK_01", "SPK_02"):
            self.assertIn(f"] {label}:**", labeled)

    def test_the_provenance_note_says_why_nothing_was_substituted(self):
        with meeting(self.RAW, artifact=self._artifact("Дмитрий", "Дмитрий")) as root:
            speakers.run_apply(root)
            labeled = speakers.labeled_transcript_path(root).read_text(encoding="utf-8")

        # Distinct from the "без якоря" wording: the anchor is there, the map is
        # what needs correcting, and saying otherwise sends the operator looking
        # for an anchor that already exists.
        self.assertIn("Дмитрий", labeled)
        self.assertIn("SPK_01, SPK_02", labeled)
        self.assertIn("несколькими голосами", labeled)

    def test_distinct_names_are_unaffected(self):
        artifact = self._artifact("Дмитрий", "Мария")
        self.assertEqual(
            speakers.name_map(artifact), {"SPK_01": "Дмитрий", "SPK_02": "Мария"}
        )
        self.assertEqual(speakers.name_collisions(artifact), {})

    def test_a_collision_only_after_cleaning_is_still_a_collision(self):
        # clean_name folds ':' and '*' out, so two different raw strings can
        # collapse onto one rendered name.
        artifact = self._artifact("Дмитрий", "**Дмитрий**")
        self.assertEqual(speakers.name_map(artifact), {})


class BareSelfIntroCorroborationTests(unittest.TestCase):
    """The bare ``я <Cap>`` shape is a guess and is gated like a vocative.

    ``меня зовут X`` cannot mean anything but a name, so one occurrence is
    proof. ``Я Zoom открыл`` is an ordinary sentence, and capitalization is the
    only thing separating it from one — so a single occurrence used to name a
    speaker "Zoom" at confidence 0.90 with status ``anchored``, which
    ``apply`` then wrote over every one of that speaker's lines. That is the
    confidently-wrong name D8 forbids. NAME_STOPWORDS cannot close it: the
    offenders are capitalized loanwords (Zoom, Slack, Teams, Excel, Docker), an
    open set, and the list is Russian.
    """

    def _resolve(self, texts, attendees=()):
        anchors = []
        for index, text in enumerate(texts):
            for found in speakers.find_self_intros(text):
                anchors.append(
                    dict(
                        found,
                        timecode=f"00:00:{index:02d}",
                        line=index,
                        source_speaker="SPK_01",
                        speaker="SPK_01",
                    )
                )
        return speakers.resolve_speaker(anchors, tuple(attendees))

    def test_a_lone_bare_intro_naming_a_loanword_is_refused(self):
        resolved = self._resolve(["Я Zoom открыл, сейчас покажу экран."])
        self.assertIsNone(resolved["name"])
        self.assertEqual(resolved["confidence"], 0.0)
        # Kept where a human can read it, exactly as an uncorroborated vocative is.
        self.assertEqual(resolved["uncorroborated"], "Zoom")

    def test_a_lone_explicit_intro_is_still_anchored(self):
        resolved = self._resolve(["Меня зовут Дмитрий."])
        self.assertEqual(resolved["name"], "Дмитрий")
        self.assertEqual(resolved["anchor_type"], speakers.ANCHOR_SELF_INTRO)

    def test_a_repeated_bare_intro_corroborates_itself(self):
        resolved = self._resolve(["Я Дмитрий.", "Я Дмитрий, ещё раз."])
        self.assertEqual(resolved["name"], "Дмитрий")

    def test_an_attendee_list_corroborates_a_lone_bare_intro(self):
        resolved = self._resolve(["Я Дмитрий."], attendees=("Дмитрий",))
        self.assertEqual(resolved["name"], "Дмитрий")

    def test_на_связи_is_bare_too(self):
        self.assertIsNone(self._resolve(["На связи Jira, шучу."])["name"])

    def test_explicitness_is_recorded_on_the_anchor(self):
        explicit = speakers.find_self_intros("Меня зовут Дмитрий")[0]
        bare = speakers.find_self_intros("Я Дмитрий")[0]
        self.assertTrue(explicit["explicit"])
        self.assertFalse(bare["explicit"])


if __name__ == "__main__":
    unittest.main()
