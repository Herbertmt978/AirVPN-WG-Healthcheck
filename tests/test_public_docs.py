"""Public documentation contract for the dual-mode release surface.

The v1.0 release note is immutable historical material, so these assertions cover
only the current operator-facing documents and examples.
"""

from __future__ import annotations

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]
README = ROOT / "README.md"
OPERATIONS = ROOT / "docs" / "operations.md"
LICENSE = ROOT / "LICENSE"
SECURITY = ROOT / "SECURITY.md"
CONTRIBUTING = ROOT / "CONTRIBUTING.md"
EXAMPLE_CONFIG = ROOT / "config" / "wg0.conf.example"


def read_text(path: Path) -> str:
    if not path.is_file():
        return ""
    return path.read_text(encoding="utf-8")


class PublicDocumentationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.readme = read_text(README)
        self.readme_opening = "\n".join(self.readme.splitlines()[:100])

    def current_public_text(self) -> str:
        """Return current documentation only; v1.0 notes remain immutable history."""
        return "\n".join(
            read_text(path)
            for path in (README, OPERATIONS, SECURITY, CONTRIBUTING, EXAMPLE_CONFIG, LICENSE)
        )

    def test_readme_opening_has_a_two_mode_choice_table(self) -> None:
        self.assertRegex(
            self.readme_opening,
            r"(?im)^\|[^\n]*static[^\n]*\|[^\n]*api[^\n]*\|\s*$\n^\|[ :|-]+\|",
            "the first 100 README lines must contain a Markdown static/API choice table",
        )
        self.assertIn("credential-free", self.readme_opening.lower())
        self.assertIn("api key required", self.readme_opening.lower())

    def test_readme_opening_has_both_exact_two_command_setup_paths(self) -> None:
        self.assertIn(
            "sudo ./install.sh wg0\nsudo wg-healthcheck-setup --mode static wg0",
            self.readme_opening,
        )
        self.assertIn(
            "sudo ./install.sh wg0\nsudo wg-healthcheck-setup --mode api wg0",
            self.readme_opening,
        )

    def test_readme_links_to_the_operator_guide(self) -> None:
        self.assertTrue(OPERATIONS.is_file(), "docs/operations.md must be published")
        self.assertRegex(self.readme, r"\[[^\]]+\]\(docs/operations\.md(?:#[^)]+)?\)")

    def test_api_quick_start_links_key_source_and_states_the_service_scope(self) -> None:
        self.assertIn(
            "[AirVPN API settings](https://airvpn.org/apisettings/)",
            self.readme_opening,
        )
        for service in ("`status`", "`generator`", "`whatismyip`"):
            with self.subTest(service=service):
                self.assertIn(service, self.readme)
        for excluded in (
            "`userinfo`",
            "`devices`",
            "`disconnect`",
            "`notification`",
            "`dns_lists`",
        ):
            with self.subTest(excluded=excluded):
                self.assertRegex(
                    self.readme,
                    rf"(?is)(does not|never).{{0,240}}{re.escape(excluded)}",
                )
        self.assertIn("600 API requests per\n10 minutes", self.readme)
        for service in (
            "`status`",
            "`generator`",
            "`whatismyip`",
            "`devices`",
            "`userinfo`",
            "`disconnect`",
            "`notification`",
            "`dns_lists`",
        ):
            with self.subTest(policy_row=service):
                self.assertRegex(
                    self.readme,
                    rf"(?m)^\| {re.escape(service)} \| .+ \| .+ \|$",
                )
        self.assertRegex(
            self.readme,
            r"(?is)devices.{0,220}list/add/renew/delete/modify.{0,220}blue/green",
        )

    def test_operations_cover_status_manual_health_and_timer_decision(self) -> None:
        text = read_text(OPERATIONS)
        self.assertIn("wg-healthcheck status wg0", text)
        self.assertIn("systemctl start wg-healthcheck@wg0.service", text)
        self.assertIn("systemctl enable --now wg-healthcheck@wg0.timer", text)
        self.assertRegex(text, r"(?is)(leave|keep).{0,120}timer.{0,120}disabled")

    def test_operations_explain_country_selection_rules(self) -> None:
        text = read_text(OPERATIONS)
        self.assertRegex(
            text,
            r"(?is)(?:(?:single|one).{0,100}countr.{0,100}(strict|only)|(strict|only).{0,100}(?:single|one).{0,100}countr)",
        )
        self.assertRegex(text, r"(?is)(multiple|several|more than one).{0,120}allowlist")
        self.assertRegex(text, r"(?is)(order|first).{0,100}soft.{0,100}preference")
        self.assertRegex(text, r"(?is)\bALL\b.{0,120}(eligible|every).{0,120}countr")

    def test_docs_explain_the_trusted_installed_hook_boundary(self) -> None:
        text = self.readme + "\n" + read_text(OPERATIONS)
        self.assertIn("`PostUp`", text)
        self.assertIn("`PostDown`", text)
        self.assertIn("`PreUp`", text)
        self.assertIn("`PreDown`", text)
        self.assertIn("`SaveConfig`", text)
        self.assertRegex(text, r"(?is)(provider|generated).{0,180}reject.{0,100}hook")
        self.assertRegex(text, r"(?is)(root|installed).{0,180}(retain|preserv).{0,100}PostUp")

    def test_docs_state_exact_api_managed_profile_directory_permissions(self) -> None:
        text = self.readme + "\n" + read_text(OPERATIONS)
        self.assertRegex(
            text,
            r"(?is)immediate directory.{0,180}root-owned.{0,180}(?:exact mode|mode)[- `]*0700",
        )
        self.assertRegex(text, r"(?is)immediate directory.{0,180}non-symlinked")

    def test_operations_explain_safe_authenticated_failure_phases(self) -> None:
        text = read_text(OPERATIONS)
        for phase in ("transport", "response", "profile", "internal"):
            with self.subTest(phase=phase):
                self.assertIn(f"`phase={phase}`", text)
        for reason in ("status", "encoding", "media", "read", "size", "json", "protocol"):
            with self.subTest(reason=reason):
                self.assertIn(f"`reason={reason}`", text)
        self.assertRegex(text, r"(?is)(wait|honou?r|respect).{0,100}backoff")
        self.assertRegex(text, r"(?is)phase.{0,160}(never|does not).{0,100}(key|profile|provider text)")
        self.assertIn('`result: "ok"`', text)
        self.assertRegex(text, r"(?is)top-level.{0,100}`error`")
        self.assertNotRegex(text, r"(?i)curl\s+(?:-[^\s]*v|--verbose)")

    def test_credential_lifecycle_is_documented_without_secret_cli_or_environment_input(self) -> None:
        text = self.current_public_text()
        self.assertIn("/etc/wireguard/healthcheck.d/<iface>.api-key", text)
        self.assertIn("--replace-credential", text)
        self.assertIn("--remove-credential", text)
        self.assertRegex(text, r"(?is)never.{0,100}(argument|command line).{0,100}(environment|env)")
        self.assertNotRegex(text, r"(?i)--(?:airvpn-)?api[-_]?key(?:=|\s+\S)")
        self.assertNotRegex(text, r"(?im)^\s*(?:AIRVPN_)?API[_-]?KEY\s*=")

    def test_docs_state_kill_switch_and_fixed_device_limits(self) -> None:
        text = self.current_public_text().lower()
        self.assertIn("not a firewall kill switch", text)
        self.assertIn("fixed device", text)
        self.assertRegex(text, r"does not (create|renew|delete).{0,80}device")

    def test_standard_mit_license_and_readme_declaration_are_present(self) -> None:
        license_text = read_text(LICENSE)
        self.assertIn("MIT License", license_text)
        self.assertIn("Copyright (c) 2026 Herbertmt978", license_text)
        self.assertIn("Permission is hereby granted, free of charge", license_text)
        self.assertIn("THE SOFTWARE IS PROVIDED \"AS IS\"", license_text)
        self.assertRegex(self.readme, r"(?i)\bMIT\b.{0,80}\blicen[cs]e\b")

    def test_security_and_contributing_prohibit_secret_submission(self) -> None:
        for path in (SECURITY, CONTRIBUTING):
            text = read_text(path).lower()
            with self.subTest(path=path.name):
                self.assertRegex(text, r"(never|do not).{0,140}(api key|credential|private key|token)")
                self.assertRegex(text, r"(redact|unredacted|secret)")

    def test_current_public_docs_do_not_contain_private_hosts_home_paths_or_key_values(self) -> None:
        text = self.current_public_text()
        forbidden = {
            "RFC1918 IPv4": r"(?<![\d.])(?:10(?:\.\d{1,3}){3}|192\.168(?:\.\d{1,3}){2}|172\.(?:1[6-9]|2\d|3[0-1])(?:\.\d{1,3}){2})(?![\d.])",
            "IPv6 unique-local address": r"(?i)(?<![0-9a-f:])[fd][0-9a-f]{1,3}:[0-9a-f:]+",
            "Unix home path": r"(?m)(?:^|[\s`'\"])/home/[^/\s`'\"]+",
            "Windows user profile": r"(?i)[A-Z]:\\Users\\[^\\\s`'\"]+",
            "credential-like assignment": r"(?im)^\s*(?:api[_-]?key|credential|token|password)\s*=\s*[^\s#]",
        }
        for label, pattern in forbidden.items():
            with self.subTest(label=label):
                self.assertNotRegex(text, pattern)

    def test_current_docs_do_not_make_stale_no_license_or_no_key_only_claims(self) -> None:
        text = self.current_public_text()
        self.assertNotRegex(text, r"(?i)(intentionally )?contains no licen[cs]e")
        self.assertNotRegex(text, r"(?i)no airvpn (?:credential|api key) (?:is )?used")
        self.assertNotRegex(text, r"(?i)never reads an airvpn api key")

    def test_configuration_example_documents_both_profile_sources_and_country_input(self) -> None:
        text = read_text(EXAMPLE_CONFIG)
        self.assertIn("AIRVPN_PROFILE_SOURCE=static", text)
        self.assertIn("AIRVPN_DEVICE=", text)
        self.assertIn("AIRVPN_COUNTRIES=", text)
        self.assertRegex(text, r"(?is)AIRVPN_COUNTRIES.{0,200}\bALL\b")


if __name__ == "__main__":
    unittest.main()
