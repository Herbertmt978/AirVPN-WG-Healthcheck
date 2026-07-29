"""Stable setup API shared by the entrypoint, tests, and application layer."""

from __future__ import annotations

import getpass
import os
import resource
import subprocess

from . import application, clients, model, private_io, store
from .application import (
    LiveApplyPaths,
    api_requires_proposed_credential,
    apply_setup_request,
    preview_api_request,
    preview_api_state_reset,
    preview_maintenance,
)
from .clients import (
    _run_fixed,
    fetch_public_countries,
    run_runtime_validation,
    safe_child_environment,
)
from .model import (
    AIRVPN_API_HELPER,
    CHILD_TIMEOUT_SECONDS,
    COUNTRY_CODE_PATTERN,
    COUNT_PATTERN,
    DEVICE_PATTERN,
    INTERFACE_PATTERN,
    MAX_COUNTRY_OUTPUT_BYTES,
    MAX_MANIFEST_BYTES,
    MAX_PRIVATE_FD,
    MAX_SETTINGS_BYTES,
    MIN_PRIVATE_FD,
    RUNTIME,
    SAFE_PATH,
    SERVER_PATTERN,
    Country,
    CountrySelection,
    RuntimeManifest,
    SetupError,
    SetupRequest,
    configured_country_value,
    normalize_country_selection,
    parse_country_inventory,
    parse_runtime_manifest,
)
from .private_io import (
    PrivateHandle,
    _credential_metadata,
    _open_absolute_nofollow,
    _private_temporary,
    _validate_credential_bytes,
    _validate_private_fd_range,
    credential_from_bytes,
    disable_core_dumps,
    open_controlling_tty,
    open_credential_file,
    read_hidden_credential,
    settings_from_values,
)
from . import cli
from .cli import (
    _SafeArgumentParser,
    _choose_action,
    _choose_timer,
    _complete_interactive_request,
    _deny_secret_inputs,
    _profile_operation,
    _validate_noninteractive_country_text,
    build_parser,
    choose_interactive_mode,
    execute_request,
    main,
    parse_args,
    render_country_menu,
    render_summary,
    resolve_request,
)


# Compatibility aliases for the former single-file module. New code should use the
# descriptive pattern names above or import the owning submodule directly.
_INTERFACE = INTERFACE_PATTERN
_DEVICE = DEVICE_PATTERN
_COUNTRY_CODE = COUNTRY_CODE_PATTERN
_COUNT = COUNT_PATTERN
_SERVER = SERVER_PATTERN
_SAFE_PATH = SAFE_PATH


__all__ = [
    "AIRVPN_API_HELPER",
    "CHILD_TIMEOUT_SECONDS",
    "Country",
    "CountrySelection",
    "MAX_COUNTRY_OUTPUT_BYTES",
    "MAX_MANIFEST_BYTES",
    "MAX_PRIVATE_FD",
    "MAX_SETTINGS_BYTES",
    "MIN_PRIVATE_FD",
    "PrivateHandle",
    "RUNTIME",
    "RuntimeManifest",
    "SetupError",
    "SetupRequest",
    "LiveApplyPaths",
    "_COUNT",
    "_COUNTRY_CODE",
    "_DEVICE",
    "_INTERFACE",
    "_SAFE_PATH",
    "_SERVER",
    "_SafeArgumentParser",
    "_choose_action",
    "_choose_timer",
    "_complete_interactive_request",
    "_credential_metadata",
    "_deny_secret_inputs",
    "_open_absolute_nofollow",
    "_private_temporary",
    "_profile_operation",
    "_run_fixed",
    "_validate_credential_bytes",
    "_validate_noninteractive_country_text",
    "_validate_private_fd_range",
    "build_parser",
    "api_requires_proposed_credential",
    "apply_setup_request",
    "application",
    "choose_interactive_mode",
    "cli",
    "clients",
    "configured_country_value",
    "credential_from_bytes",
    "disable_core_dumps",
    "execute_request",
    "fetch_public_countries",
    "getpass",
    "main",
    "model",
    "normalize_country_selection",
    "open_controlling_tty",
    "open_credential_file",
    "os",
    "parse_args",
    "parse_country_inventory",
    "parse_runtime_manifest",
    "private_io",
    "preview_api_state_reset",
    "preview_api_request",
    "preview_maintenance",
    "read_hidden_credential",
    "render_country_menu",
    "render_summary",
    "resolve_request",
    "resource",
    "run_runtime_validation",
    "safe_child_environment",
    "settings_from_values",
    "subprocess",
    "store",
]
