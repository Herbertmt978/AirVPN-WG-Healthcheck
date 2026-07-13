"""Strict durable setup-journal grammar shared by recovery paths."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import re

from .apply_system import ApplyPathSet
from .model import SetupError
from .store import secure_read


MAX_JOURNAL_BYTES = 512
MAX_CANONICAL_UINT = 10**20 - 1
OPERATIONS = frozenset({"provision", "adopt", "api-update", "static", "static-restore"})
_LEGACY_PHASES = frozenset(
    {"prepared", "config", "credential", "activating", "activated", "verified"}
)
PHASES = _LEGACY_PHASES | {"verifying", "rolled-back"}
_OPERATION_PHASES = {
    "provision": frozenset(
        {
            "prepared",
            "config",
            "credential",
            "activated",
            "verifying",
            "verified",
            "rolled-back",
        }
    ),
    "adopt": frozenset(
        {
            "prepared",
            "config",
            "credential",
            "activated",
            "verifying",
            "verified",
            "rolled-back",
        }
    ),
    "api-update": frozenset(
        {
            "prepared",
            "config",
            "credential",
            "activated",
            "verifying",
            "verified",
            "rolled-back",
        }
    ),
    "static": frozenset(
        {"prepared", "activated", "verifying", "verified", "rolled-back"}
    ),
    "static-restore": frozenset(
        {
            "prepared",
            "activating",
            "activated",
            "verifying",
            "verified",
            "rolled-back",
        }
    ),
}
_FIELD_ORDER = {
    "1": ("version", "operation", "phase", "had_key", "had_pre_managed"),
    "2": (
        "version",
        "operation",
        "phase",
        "had_key",
        "had_pre_managed",
        "key_changed",
    ),
    "3": (
        "version",
        "operation",
        "phase",
        "had_key",
        "had_pre_managed",
        "key_changed",
        "verify_started",
        "status_before_dev",
        "status_before_ino",
    ),
}


@dataclass(frozen=True)
class SetupJournal:
    operation: str
    phase: str
    had_key: bool
    had_pre_managed: bool
    key_changed: bool
    verify_started: int = 0
    status_before_dev: int = 0
    status_before_ino: int = 0


def _validate_semantics(version: str, journal: SetupJournal) -> None:
    version_phases = PHASES if version == "3" else _LEGACY_PHASES
    static_operation = journal.operation in {"static", "static-restore"}
    api_operation = journal.operation in {"provision", "adopt", "api-update"}
    if (
        journal.operation not in OPERATIONS
        or journal.phase not in version_phases
        or journal.phase not in _OPERATION_PHASES[journal.operation]
        or not isinstance(journal.had_key, bool)
        or not isinstance(journal.had_pre_managed, bool)
        or not isinstance(journal.key_changed, bool)
        or (static_operation and journal.key_changed)
        or (api_operation and not journal.had_key and not journal.key_changed)
    ):
        raise SetupError("the previous setup transaction record is invalid")
    proof_values = (
        journal.verify_started,
        journal.status_before_dev,
        journal.status_before_ino,
    )
    if any(
        isinstance(value, bool) or not isinstance(value, int) or value < 0
        for value in proof_values
    ):
        raise SetupError("the previous setup transaction record is invalid")
    if (journal.status_before_dev == 0) != (journal.status_before_ino == 0):
        raise SetupError("the previous setup transaction record is invalid")
    proof_phase = version == "3" and journal.phase in {"verifying", "verified"}
    if proof_phase != (journal.verify_started > 0):
        raise SetupError("the previous setup transaction record is invalid")
    if not proof_phase and (
        journal.status_before_dev != 0 or journal.status_before_ino != 0
    ):
        raise SetupError("the previous setup transaction record is invalid")


def render_journal(journal: SetupJournal) -> bytes:
    """Render a canonical current-version journal after semantic validation."""

    _validate_semantics("3", journal)
    if any(
        value > MAX_CANONICAL_UINT
        for value in (
            journal.verify_started,
            journal.status_before_dev,
            journal.status_before_ino,
        )
    ):
        raise SetupError("the setup transaction record is invalid")
    return (
        "version=3\n"
        f"operation={journal.operation}\n"
        f"phase={journal.phase}\n"
        f"had_key={int(journal.had_key)}\n"
        f"had_pre_managed={int(journal.had_pre_managed)}\n"
        f"key_changed={int(journal.key_changed)}\n"
        f"verify_started={journal.verify_started}\n"
        f"status_before_dev={journal.status_before_dev}\n"
        f"status_before_ino={journal.status_before_ino}\n"
    ).encode("ascii")


def extra_path(paths: ApplyPathSet, kind: str) -> Path:
    if kind == "journal":
        return paths.health_dir / f"{paths.iface}.setup-transaction"
    if kind == "config-previous":
        return paths.health_dir / f".{paths.iface}.conf.setup-previous"
    if kind == "credential-previous":
        return paths.health_dir / f".{paths.iface}.api-key.setup-previous"
    raise AssertionError(kind)


def path_exists(path: Path) -> bool:
    return path.exists() or path.is_symlink()


def read_journal(paths: ApplyPathSet) -> SetupJournal:
    payload = secure_read(
        extra_path(paths, "journal"),
        paths.trusted_uid,
        maximum=MAX_JOURNAL_BYTES,
        required=True,
    )
    if (
        payload is None
        or not payload.endswith(b"\n")
        or payload == b"\n"
        or any(value != 0x0A and not 0x20 <= value <= 0x7E for value in payload)
    ):
        raise SetupError("the previous setup transaction record is invalid")
    try:
        lines = [line.decode("ascii", "strict") for line in payload[:-1].split(b"\n")]
    except UnicodeError as error:
        raise SetupError("the previous setup transaction record is invalid") from error
    if not lines or lines[0] not in {"version=1", "version=2", "version=3"}:
        raise SetupError("the previous setup transaction record is invalid")
    version = lines[0].removeprefix("version=")
    order = _FIELD_ORDER[version]
    if len(lines) != len(order):
        raise SetupError("the previous setup transaction record is invalid")
    fields: dict[str, str] = {}
    for expected_key, line in zip(order, lines, strict=True):
        if line.count("=") != 1:
            raise SetupError("the previous setup transaction record is invalid")
        key, value = line.split("=", 1)
        if key != expected_key:
            raise SetupError("the previous setup transaction record is invalid")
        fields[key] = value
    operation = fields["operation"]
    phase = fields["phase"]
    if fields["had_key"] not in {"0", "1"} or fields["had_pre_managed"] not in {
        "0",
        "1",
    }:
        raise SetupError("the previous setup transaction record is invalid")
    key_changed = fields.get("key_changed", "1")
    if key_changed not in {"0", "1"}:
        raise SetupError("the previous setup transaction record is invalid")
    proof_values = [
        fields.get("verify_started", "0"),
        fields.get("status_before_dev", "0"),
        fields.get("status_before_ino", "0"),
    ]
    if any(not re.fullmatch(r"0|[1-9][0-9]{0,19}", value) for value in proof_values):
        raise SetupError("the previous setup transaction record is invalid")
    verify_started, status_before_dev, status_before_ino = map(int, proof_values)
    journal = SetupJournal(
        operation,
        phase,
        fields["had_key"] == "1",
        fields["had_pre_managed"] == "1",
        key_changed == "1",
        verify_started,
        status_before_dev,
        status_before_ino,
    )
    _validate_semantics(version, journal)
    return journal
