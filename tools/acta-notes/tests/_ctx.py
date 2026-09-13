"""Test context shim for the acta-notes skill scripts.

The scripts live in ``plugin/skills/acta-notes/scripts/`` and the tests in
``tools/acta-notes/tests/``. ``unittest discover`` puts the tests directory on
``sys.path`` but knows nothing about the scripts directory, and ``conftest.py``
is a pytest mechanism that would do nothing here — so this module is the one
place that bridges the two.

Convention (enforced mechanically by ``test_layout.py``): **every test module's
first import is ``import _ctx``**, and no test module manipulates ``sys.path`` on
its own.

Loading is file-based (``importlib.util.spec_from_file_location``) rather than a
``sys.path`` append plus a bare ``import``, deliberately: script stems like
``gate``, ``merge``, ``verify`` and ``pipeline`` must never shadow — or be
shadowed by — an installed module of the same name.

This is not a test module; ``discover``'s ``test*.py`` pattern never collects it.
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

TESTS_DIR = Path(__file__).resolve().parent
#: tools/acta-notes
TOOL_DIR = TESTS_DIR.parent
#: repository root
REPO_ROOT = TOOL_DIR.parent.parent
SCRIPTS_DIR = TOOL_DIR / "plugin" / "skills" / "acta-notes" / "scripts"
SKILL_DIR = SCRIPTS_DIR.parent
FIXTURES_DIR = TESTS_DIR / "fixtures"

_MODULE_CACHE: dict[str, object] = {}


def script_path(stem: str) -> Path:
    """Absolute path of ``scripts/<stem>.py``."""
    return SCRIPTS_DIR / f"{stem}.py"


def load(stem: str):
    """Import ``scripts/<stem>.py`` under a namespaced module name, cached."""
    cached = _MODULE_CACHE.get(stem)
    if cached is not None:
        return cached

    path = script_path(stem)
    if not path.is_file():
        raise FileNotFoundError(f"no such acta-notes script: {path}")

    qualname = f"acta_notes_scripts.{stem}"
    spec = importlib.util.spec_from_file_location(qualname, path)
    if spec is None or spec.loader is None:
        raise ImportError(f"cannot build an import spec for {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[qualname] = module
    spec.loader.exec_module(module)

    _MODULE_CACHE[stem] = module
    return module


def fixture(name: str) -> Path:
    """Absolute path of ``tests/fixtures/<name>``."""
    return FIXTURES_DIR / name


def read_fixture(name: str) -> str:
    return fixture(name).read_text(encoding="utf-8")
