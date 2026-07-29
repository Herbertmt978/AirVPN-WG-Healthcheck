"""Strict health-configuration parsing and setup-owned rewrites."""

from __future__ import annotations

import re

from .model import SetupError, SetupRequest


MAX_CONFIG_BYTES = 65_536
DEVICE_PATTERN = re.compile(r"[A-Za-z0-9][A-Za-z0-9 ._-]{0,63}\Z", re.ASCII)
_ASSIGNMENT = re.compile(rb"([A-Z][A-Z0-9_]*)=(.*)\Z", re.ASCII)
_COUNTRIES = re.compile(r"[A-Z]{2}(?: [A-Z]{2}){0,31}\Z", re.ASCII)


def _quote_config_value(value: str) -> bytes:
    if any(character in value for character in "\\\"'`$"):
        raise SetupError("a proposed health configuration value is ambiguous")
    try:
        encoded = value.encode("ascii", "strict")
    except UnicodeError as error:
        raise SetupError("a proposed health configuration value is invalid") from error
    if not encoded or any(character in encoded for character in b" \t"):
        return b'"' + encoded + b'"'
    return encoded


def _parse_config_value(raw: bytes) -> str:
    if len(raw) >= 2 and raw[:1] in {b'"', b"'"} and raw[-1:] == raw[:1]:
        raw = raw[1:-1]
    try:
        return raw.decode("ascii", "strict")
    except UnicodeError as error:
        raise SetupError("the installed health configuration is invalid") from error


def config_value(payload: bytes, wanted: str) -> str | None:
    found: str | None = None
    for line in payload.splitlines():
        match = _ASSIGNMENT.fullmatch(line)
        if match is None or match.group(1).decode("ascii") != wanted:
            continue
        if found is not None:
            raise SetupError("the installed health configuration has duplicate keys")
        found = _parse_config_value(match.group(2))
    return found


def render_config(payload: bytes, updates: dict[str, str]) -> bytes:
    if (
        not payload.endswith(b"\n")
        or b"\x00" in payload
        or len(payload) > MAX_CONFIG_BYTES
    ):
        raise SetupError("the installed health configuration is not canonical text")
    seen: set[str] = set()
    rendered: list[bytes] = []
    for line in payload.splitlines():
        match = _ASSIGNMENT.fullmatch(line)
        if match is None:
            rendered.append(line)
            continue
        key = match.group(1).decode("ascii")
        if key not in updates:
            rendered.append(line)
            continue
        if key in seen:
            raise SetupError(
                "the installed health configuration has duplicate setup keys"
            )
        seen.add(key)
        rendered.append(key.encode("ascii") + b"=" + _quote_config_value(updates[key]))
    for key, value in updates.items():
        if key not in seen:
            rendered.append(key.encode("ascii") + b"=" + _quote_config_value(value))
    result = b"\n".join(rendered) + b"\n"
    if len(result) > MAX_CONFIG_BYTES:
        raise SetupError("the updated health configuration exceeds its size limit")
    return result


def country_values(request: SetupRequest) -> tuple[str, str]:
    selection = request.country_selection
    if selection is None:
        raise SetupError("API setup requires an explicit validated country selection")
    if selection.all_countries:
        return "ALL", ""
    configured = " ".join(selection.codes)
    if not _COUNTRIES.fullmatch(configured):
        raise SetupError("API setup countries are not canonical")
    return configured, configured
