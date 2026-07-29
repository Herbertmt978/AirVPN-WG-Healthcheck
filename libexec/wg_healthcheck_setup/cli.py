"""Command-line parsing, guided prompts, and Task 9 dry-run orchestration."""

from __future__ import annotations

import argparse
from contextlib import nullcontext
from dataclasses import replace
import os
import sys
from typing import Callable, Sequence, TextIO

from . import application, clients, private_io
from .model import (
    COUNTRY_CODE_PATTERN,
    DEVICE_PATTERN,
    INTERFACE_PATTERN,
    Country,
    SetupError,
    SetupRequest,
    normalize_country_selection,
)


_SECRET_OPTIONS = frozenset(
    {
        "--api-key",
        "--apikey",
        "--secret",
        "--token",
        "--credential-value",
    }
)


class _SafeArgumentParser(argparse.ArgumentParser):
    def error(self, _message: str) -> None:
        raise SetupError("invalid command line; use --help for the supported options")


def _deny_secret_inputs(argv: Sequence[str]) -> None:
    if "AIRVPN_API_KEY" in os.environ:
        raise SetupError(
            "AIRVPN_API_KEY environment input is not accepted; use a hidden TTY prompt "
            "or --credential-file"
        )
    for argument in argv:
        option = argument.split("=", 1)[0]
        if option in _SECRET_OPTIONS:
            raise SetupError(
                "secret values are not accepted in arguments; use a hidden TTY prompt "
                "or --credential-file"
            )


def build_parser() -> argparse.ArgumentParser:
    parser = _SafeArgumentParser(
        prog="wg-healthcheck-setup",
        description="Choose static or AirVPN API-managed WireGuard profile handling.",
        allow_abbrev=False,
    )
    parser.add_argument("--mode", choices=("static", "api"))
    action = parser.add_mutually_exclusive_group()
    action.add_argument(
        "--dry-run", dest="action", action="store_const", const="dry-run"
    )
    action.add_argument("--apply", dest="action", action="store_const", const="apply")
    timer = parser.add_mutually_exclusive_group()
    timer.add_argument(
        "--enable-timer", dest="timer", action="store_const", const="enable"
    )
    timer.add_argument(
        "--leave-timer-disabled",
        dest="timer",
        action="store_const",
        const="disabled",
    )
    parser.add_argument("--device")
    parser.add_argument("--countries")
    parser.add_argument("--credential-file")
    parser.add_argument("--non-interactive", action="store_true")
    parser.add_argument("--restore-pre-managed", action="store_true")
    parser.add_argument("--replace-credential", action="store_true")
    parser.add_argument("--remove-credential", action="store_true")
    parser.add_argument("--reset-api-state", action="store_true")
    parser.add_argument("iface")
    return parser


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    arguments = list(argv)
    _deny_secret_inputs(arguments)
    return build_parser().parse_args(arguments)


def _validate_noninteractive_country_text(value: str) -> None:
    tokens = value.split()
    if not tokens:
        raise SetupError("non-interactive API setup requires --countries codes or ALL")
    upper = [token.upper() for token in tokens]
    if "ALL" in upper:
        if upper != ["ALL"]:
            raise SetupError("ALL must be the only non-interactive country selection")
        return
    if any(not COUNTRY_CODE_PATTERN.fullmatch(token) for token in upper):
        raise SetupError(
            "non-interactive --countries must contain whitespace-separated two-letter "
            "codes or the single token ALL"
        )


def resolve_request(args: argparse.Namespace) -> SetupRequest:
    iface = args.iface
    if not INTERFACE_PATTERN.fullmatch(iface):
        raise SetupError("interface name is invalid")

    if args.non_interactive:
        if args.mode is None:
            raise SetupError("non-interactive setup requires an explicit --mode")
        if args.action is None:
            raise SetupError("non-interactive setup requires --dry-run or --apply")
        if args.timer is None:
            raise SetupError(
                "non-interactive setup requires an explicit timer decision: "
                "--enable-timer or --leave-timer-disabled"
            )

    if args.reset_api_state and args.action is None:
        raise SetupError(
            "--reset-api-state requires the safety flag --dry-run or --apply"
        )
    if args.reset_api_state and args.timer == "enable":
        raise SetupError("--reset-api-state cannot enable the timer")

    if args.mode == "api":
        if args.device is not None and not DEVICE_PATTERN.fullmatch(args.device):
            raise SetupError("AirVPN device name is invalid")
        if args.non_interactive:
            if args.device is None:
                raise SetupError("non-interactive API setup requires --device")
            if args.countries is None:
                raise SetupError(
                    "non-interactive API setup requires --countries codes or ALL"
                )
            _validate_noninteractive_country_text(args.countries)
            if args.replace_credential and args.credential_file is None:
                raise SetupError(
                    "non-interactive credential replacement requires --credential-file"
                )
        if args.remove_credential:
            raise SetupError("--remove-credential requires static mode")
        if args.restore_pre_managed:
            raise SetupError("--restore-pre-managed requires static mode")
    elif args.mode == "static":
        if args.device is not None or args.countries is not None:
            raise SetupError("--device and --countries are only valid in API mode")
        if args.credential_file is not None or args.replace_credential:
            raise SetupError(
                "--credential-file and --replace-credential are only valid in API mode"
            )
    elif args.mode is not None:
        raise SetupError("mode must be static or api")

    if args.replace_credential and args.mode != "api":
        raise SetupError("--replace-credential requires API mode")
    if args.remove_credential and args.mode != "static":
        raise SetupError("--remove-credential requires static mode")
    if args.restore_pre_managed and args.mode != "static":
        raise SetupError("--restore-pre-managed requires static mode")

    return SetupRequest(
        iface=iface,
        mode=args.mode,
        action=args.action,
        timer=args.timer,
        device=args.device,
        countries_text=args.countries,
        credential_file=args.credential_file,
        non_interactive=args.non_interactive,
        restore_pre_managed=args.restore_pre_managed,
        replace_credential=args.replace_credential,
        remove_credential=args.remove_credential,
        reset_api_state=args.reset_api_state,
    )


def choose_interactive_mode(input_fn: Callable[[str], str], output: TextIO) -> str:
    output.write(
        "Choose a profile mode:\n"
        "  1. Existing/static WireGuard profile\n"
        "  2. AirVPN API-managed profile\n"
    )
    while True:
        answer = input_fn("Mode [1/2]: ").strip().lower()
        if answer in {"1", "static"}:
            return "static"
        if answer in {"2", "api"}:
            return "api"
        output.write("Select 1 for static or 2 for API-managed mode.\n")


def _choose_action(input_fn: Callable[[str], str], output: TextIO) -> str:
    output.write("Choose an action:\n  1. Dry run only\n  2. Apply after validation\n")
    while True:
        answer = input_fn("Action [1/2]: ").strip().lower()
        if answer in {"1", "dry-run", "dry"}:
            return "dry-run"
        if answer in {"2", "apply"}:
            return "apply"
        output.write("Select 1 for dry run or 2 to apply.\n")


def _choose_timer(input_fn: Callable[[str], str], output: TextIO) -> str:
    output.write(
        "Choose the timer outcome:\n"
        "  1. Leave the timer disabled\n"
        "  2. Enable only after a successful health check\n"
    )
    while True:
        answer = input_fn("Timer [1/2]: ").strip().lower()
        if answer in {"1", "disabled", "leave"}:
            return "disabled"
        if answer in {"2", "enable"}:
            return "enable"
        output.write("Select 1 to leave disabled or 2 to enable after verification.\n")


def _complete_interactive_request(
    args: argparse.Namespace,
    input_fn: Callable[[str], str],
    output: TextIO,
) -> argparse.Namespace:
    if args.non_interactive:
        return args
    if args.mode is None:
        args.mode = choose_interactive_mode(input_fn, output)
    if args.action is None:
        args.action = _choose_action(input_fn, output)
    if args.timer is None:
        if args.reset_api_state:
            args.timer = "disabled"
        else:
            args.timer = _choose_timer(input_fn, output)
    if args.mode == "api" and args.device is None:
        proposed = input_fn("AirVPN device name [default]: ").strip()
        args.device = proposed or "default"
    return args


def render_country_menu(countries: Sequence[Country], output: TextIO) -> None:
    output.write("Eligible countries with healthy AirVPN WireGuard servers:\n")
    for number, country in enumerate(countries, 1):
        suffix = "server" if country.healthy_servers == 1 else "servers"
        output.write(
            f"  {number}. {country.code}  {country.name} "
            f"({country.healthy_servers} healthy {suffix})\n"
        )
    output.write(
        "Select numbers/codes in preference order, or explicitly select ALL.\n"
        "One country is strict. Multiple countries form a hard allowlist; order is a "
        "soft preference inside that allowlist.\n"
    )


def _profile_operation(iface: str) -> str:
    return "adopt" if os.path.exists(f"/etc/wireguard/{iface}.conf") else "provision"


def render_summary(request: SetupRequest) -> str:
    lines = [
        f"interface: {request.iface}",
        f"mode: {request.mode or 'not selected'}",
        f"action: {request.action or 'not selected'}",
        f"timer: {request.timer or 'not selected'}",
    ]
    if request.mode == "api":
        lines.append(f"device: {request.device or 'not selected'}")
        if request.country_selection is None:
            country_text = request.countries_text or "not selected"
        elif request.country_selection.all_countries:
            country_text = "ALL (explicit)"
        else:
            country_text = " ".join(request.country_selection.codes)
        lines.extend(
            [
                f"countries: {country_text}",
                "country policy: hard allowlist; order is a soft preference",
                "credential: private descriptor (value redacted)",
            ]
        )
    lines.extend(
        [
            f"remove credential: {'yes' if request.remove_credential else 'no'}",
            f"reset API state: {'yes' if request.reset_api_state else 'no'}",
            "pre-managed snapshot: preserved",
        ]
    )
    return "\n".join(lines) + "\n"


def execute_request(
    request: SetupRequest,
    *,
    input_fn: Callable[[str], str] = input,
    output: TextIO | None = None,
) -> SetupRequest:
    output = output or sys.stdout
    if request.mode != "api":
        output.write(render_summary(request))
        output.write("Static setup plan validated; no API credential was opened.\n")
        if request.action == "apply":
            application.apply_setup_request(request, None)
            output.write("Static setup applied and freshly verified.\n")
        elif request.restore_pre_managed or request.reset_api_state:
            application.preview_maintenance(request)
            output.write("Maintenance dry run succeeded; no state was changed.\n")
        return request

    countries = clients.fetch_public_countries()
    if not request.non_interactive:
        render_country_menu(countries, output)
    selection_text = request.countries_text
    if selection_text is None:
        selection_text = input_fn("Countries (numbers/codes in order, or ALL): ")
    selection = normalize_country_selection(selection_text, countries)
    request = replace(request, country_selection=selection)
    output.write(render_summary(request))

    needs_proposal = application.api_requires_proposed_credential(request)
    if needs_proposal and request.non_interactive and request.credential_file is None:
        raise SetupError(
            "initial API setup and credential replacement require --credential-file"
        )
    if not needs_proposal and request.credential_file is not None:
        raise SetupError(
            "an installed credential is reused; add --replace-credential to replace it"
        )
    if needs_proposal:
        credential_context = (
            private_io.open_credential_file(request.credential_file)
            if request.credential_file is not None
            else private_io.read_hidden_credential()
        )
    else:
        credential_context = nullcontext(None)
    with credential_context as credential:
        if request.action == "apply":
            application.apply_setup_request(request, credential)
        else:
            application.preview_api_request(request, credential)
    if request.action == "apply":
        output.write("API setup applied and freshly verified.\n")
    else:
        output.write(
            "Authenticated dry-run validation succeeded (manifest redacted).\n"
        )
        if request.reset_api_state:
            output.write("API-state reset dry run succeeded; no state was removed.\n")
    return request


def main(argv: Sequence[str] | None = None) -> int:
    try:
        private_io.disable_core_dumps()
        arguments = list(sys.argv[1:] if argv is None else argv)
        _deny_secret_inputs(arguments)
        args = parse_args(arguments)
        if os.geteuid() != 0:
            raise SetupError("setup must run as root")
        args = _complete_interactive_request(args, input, sys.stdout)
        request = resolve_request(args)
        execute_request(request)
        return 0
    except SetupError as error:
        print(f"wg-healthcheck-setup: {error}", file=sys.stderr)
        return 64
    except (EOFError, KeyboardInterrupt):
        print("wg-healthcheck-setup: setup was cancelled", file=sys.stderr)
        return 130
