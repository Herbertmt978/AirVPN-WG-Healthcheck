"""Validated setup data and side-effect-free parsing rules."""

from __future__ import annotations

from dataclasses import dataclass
import ipaddress
import re
from typing import Sequence


AIRVPN_API_HELPER = "/usr/local/libexec/wg-healthcheck/airvpn-api"
RUNTIME = "/usr/local/sbin/wg-healthcheck"
MAX_COUNTRY_OUTPUT_BYTES = 64 * 1024
MAX_MANIFEST_BYTES = 256
MAX_SETTINGS_BYTES = 256
CHILD_TIMEOUT_SECONDS = 65
MIN_PRIVATE_FD = 3
MAX_PRIVATE_FD = 1023
INTERFACE_PATTERN = re.compile(r"[A-Za-z0-9][A-Za-z0-9_=+.-]{0,14}\Z", re.ASCII)
DEVICE_PATTERN = re.compile(r"[A-Za-z0-9][A-Za-z0-9 ._-]{0,63}\Z", re.ASCII)
COUNTRY_CODE_PATTERN = re.compile(r"[A-Z]{2}\Z", re.ASCII)
COUNT_PATTERN = re.compile(r"[1-9][0-9]{0,3}\Z", re.ASCII)
SERVER_PATTERN = re.compile(r"[A-Za-z0-9-]{1,64}\Z", re.ASCII)
SAFE_PATH = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"


class SetupError(Exception):
    """A concise, already-redacted setup failure."""


@dataclass(frozen=True)
class Country:
    code: str
    name: str
    healthy_servers: int


@dataclass(frozen=True)
class CountrySelection:
    codes: tuple[str, ...]
    all_countries: bool = False


@dataclass(frozen=True)
class SetupRequest:
    iface: str
    mode: str | None
    action: str | None
    timer: str | None
    device: str | None
    countries_text: str | None
    credential_file: str | None
    non_interactive: bool
    restore_pre_managed: bool
    replace_credential: bool
    remove_credential: bool
    reset_api_state: bool
    country_selection: CountrySelection | None = None


@dataclass(frozen=True)
class RuntimeManifest:
    server: str
    endpoint: str
    pinned: bool


def parse_country_inventory(payload: str) -> tuple[Country, ...]:
    try:
        encoded = payload.encode("utf-8", "strict")
    except UnicodeError as error:
        raise SetupError("country discovery returned invalid text") from error
    if (
        not encoded
        or len(encoded) > MAX_COUNTRY_OUTPUT_BYTES
        or not payload.endswith("\n")
    ):
        raise SetupError("country discovery returned an invalid bounded response")

    countries: list[Country] = []
    previous_code = ""
    for line in payload.splitlines():
        fields = line.split("\t")
        if len(fields) != 3:
            raise SetupError("country discovery returned an invalid record")
        code, name, count_text = fields
        if not COUNTRY_CODE_PATTERN.fullmatch(code) or code <= previous_code:
            raise SetupError("country discovery returned unsorted or duplicate codes")
        if (
            not name
            or len(name) > 128
            or any(not character.isprintable() for character in name)
        ):
            raise SetupError("country discovery returned an invalid country name")
        if not COUNT_PATTERN.fullmatch(count_text):
            raise SetupError(
                "country discovery returned an invalid healthy-server count"
            )
        count = int(count_text, 10)
        if count > 1000:
            raise SetupError(
                "country discovery returned an invalid healthy-server count"
            )
        countries.append(Country(code, name, count))
        previous_code = code
    if not countries or len(countries) > 676:
        raise SetupError("country discovery returned no bounded eligible choices")
    return tuple(countries)


def normalize_country_selection(
    value: str, countries: Sequence[Country]
) -> CountrySelection:
    tokens = value.split()
    if not tokens:
        raise SetupError("explicitly select one or more countries, or ALL")
    upper = [token.upper() for token in tokens]
    if "ALL" in upper:
        if upper != ["ALL"]:
            raise SetupError("ALL cannot be combined with country numbers or codes")
        return CountrySelection((), all_countries=True)

    by_code = {country.code: country for country in countries}
    selected: list[str] = []
    seen: set[str] = set()
    for token in tokens:
        if re.fullmatch(r"[1-9][0-9]*", token, re.ASCII):
            if len(token) > 3:
                raise SetupError(
                    "country selection number is outside the displayed menu"
                )
            try:
                number = int(token, 10)
            except ValueError as error:
                raise SetupError(
                    "country selection number is outside the displayed menu"
                ) from error
            if number > len(countries):
                raise SetupError(
                    "country selection number is outside the displayed menu"
                )
            code = countries[number - 1].code
        else:
            code = token.upper()
            if not COUNTRY_CODE_PATTERN.fullmatch(code) or code not in by_code:
                raise SetupError("country selection is not an eligible displayed code")
        if code not in seen:
            if len(selected) >= 32:
                raise SetupError("select at most 32 countries")
            selected.append(code)
            seen.add(code)
    if not selected:
        raise SetupError("explicitly select one or more countries, or ALL")
    return CountrySelection(tuple(selected))


def configured_country_value(selection: CountrySelection) -> str:
    return "" if selection.all_countries else " ".join(selection.codes)


def parse_runtime_manifest(payload: str, operation: str) -> RuntimeManifest:
    try:
        encoded = payload.encode("ascii", "strict")
    except UnicodeError as error:
        raise SetupError("runtime returned an invalid redacted manifest") from error
    if not encoded or len(encoded) > MAX_MANIFEST_BYTES or not payload.endswith("\n"):
        raise SetupError("runtime returned an invalid redacted manifest")
    if payload.count("\n") != 1:
        raise SetupError("runtime returned an invalid redacted manifest")
    fields = payload[:-1].split("\t")
    if (
        len(fields) != 4
        or fields[0] != "generated"
        or not SERVER_PATTERN.fullmatch(fields[1])
    ):
        raise SetupError("runtime returned an invalid redacted manifest")
    try:
        address_text, port_text = fields[2].rsplit(":", 1)
        address = ipaddress.ip_address(address_text)
        port = int(port_text, 10)
    except (ValueError, TypeError) as error:
        raise SetupError("runtime returned an invalid redacted manifest") from error
    if (
        address.version != 4
        or str(address) != address_text
        or port_text != str(port)
        or port not in {1637, 47107, 51820}
    ):
        raise SetupError("runtime returned an invalid redacted manifest")
    expected_pin = "1" if operation == "adopt" else "0"
    if fields[3] != f"pinned={expected_pin}":
        raise SetupError("runtime returned an invalid redacted manifest")
    canonical = f"generated\t{fields[1]}\t{address}:{port}\tpinned={expected_pin}\n"
    if canonical != payload:
        raise SetupError("runtime returned an invalid redacted manifest")
    return RuntimeManifest(fields[1], f"{address}:{port}", expected_pin == "1")


def parse_runtime_failure_phase(payload: str) -> str | None:
    """Return only an exact local transient phase; discard every other child byte."""

    if not isinstance(payload, str):
        return None
    try:
        payload.encode("ascii", "strict")
    except UnicodeError:
        return None
    prefix = "failure\ttransient\tphase="
    if not payload.startswith(prefix) or not payload.endswith("\n"):
        return None
    if payload.count("\n") != 1:
        return None
    phase = payload[len(prefix) : -1]
    if phase not in {"transport", "response", "profile", "internal"}:
        return None
    if payload != f"{prefix}{phase}\n":
        return None
    return phase


def runtime_validation_failure_message(payload: str) -> str:
    phase = parse_runtime_failure_phase(payload)
    if phase is None:
        return "authenticated runtime validation failed; no changes were made"
    return (
        "authenticated runtime validation failed "
        f"(phase={phase}); no changes were made"
    )
