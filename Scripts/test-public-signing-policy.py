#!/usr/bin/env python3
"""Offline policy checks; --live also signs two disposable distinct builds."""
import argparse
import importlib.util
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("policy", ROOT / "Scripts/public-signing-policy.py")
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)
FINGERPRINT = "1" * 40
OTHER_FINGERPRINT = "2" * 40
NAME = f"Developer ID Application: Fixture ({policy.TEAM})"
DISPLAY = (f"Identifier={policy.IDENTIFIER}\nTeamIdentifier={policy.TEAM}\n"
           "CodeDirectory v=20500 size=123 flags=0x10000(runtime)\nTimestamp=Fixture timestamp\n"
           f"designated => {policy.REQUIREMENT}\n")


class PolicyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="windowtiler-signing-tests-")
        self.addCleanup(self.temp.cleanup)
        self.app = Path(self.temp.name) / "Window Tiler.app"
        (self.app / "Contents").mkdir(parents=True)
        self.info = {"CFBundleIdentifier": policy.IDENTIFIER}
        self.write_info()

    def write_info(self):
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps(self.info))

    def verify_with(self, display):
        calls = []
        def command(*args):
            calls.append(args)
            return display if "--display" in args else ""
        with patch.object(policy, "command", command):
            result = policy.verify(self.app)
        return result, calls

    def test_only_one_expected_developer_id_is_selected(self):
        listing = (f'  1) {OTHER_FINGERPRINT} "Apple Development: Fixture ({policy.TEAM})"\n'
                   f'  2) {FINGERPRINT} "{NAME}"\n')
        with patch.object(policy, "command", return_value=listing):
            self.assertEqual(policy.identity(), FINGERPRINT)
            self.assertEqual(policy.identity(NAME), FINGERPRINT)
            self.assertEqual(policy.identity(FINGERPRINT), FINGERPRINT)
            for requested in ("-", OTHER_FINGERPRINT):
                with self.assertRaises(policy.PolicyError): policy.identity(requested)

    def test_missing_or_wrong_team_has_no_fallback(self):
        for listing in ("", f'  1) {FINGERPRINT} "Developer ID Application: Fixture (OTHERTEAM0)"\n',
                        f'  1) {FINGERPRINT} "Apple Development: Fixture ({policy.TEAM})"\n'):
            with patch.object(policy, "command", return_value=listing):
                with self.assertRaises(policy.PolicyError): policy.identity()

    def test_ambiguous_certificates_require_explicit_choice(self):
        listing = f'  1) {FINGERPRINT} "{NAME}"\n  2) {OTHER_FINGERPRINT} "{NAME}"\n'
        with patch.object(policy, "command", return_value=listing):
            with self.assertRaises(policy.PolicyError): policy.identity()
            self.assertEqual(policy.identity(OTHER_FINGERPRINT), OTHER_FINGERPRINT)

    def test_validation_requires_cryptographic_publisher_not_metadata(self):
        def rejected_signature(*args):
            if "--verify" in args:
                self.assertIn("=" + policy.REQUIREMENT, args)
                raise policy.PolicyError("Wrong actual signer")
            return DISPLAY
        with patch.object(policy, "command", rejected_signature):
            with self.assertRaises(policy.PolicyError): policy.verify(self.app)

    def test_expected_signature_timestamp_runtime_and_default_dr(self):
        _, calls = self.verify_with(DISPLAY)
        self.assertIn("--all-architectures", calls[0])
        self.assertIn("=" + policy.REQUIREMENT, calls[0])

    def test_wrong_bundle_rejected_before_signature_check(self):
        self.info["CFBundleIdentifier"] = "com.example.other"
        self.write_info()
        with patch.object(policy, "command") as command:
            with self.assertRaises(policy.PolicyError): policy.verify(self.app)
            command.assert_not_called()

    def test_weak_or_hash_pinned_designated_requirements_rejected(self):
        for requirement in (f'identifier "{policy.IDENTIFIER}"',
                            'cdhash H"' + "1" * 40 + '"',
                            policy.REQUIREMENT + ' or identifier "com.example.impostor"',
                            policy.REQUIREMENT + ' and certificate leaf = H"' + "2" * 40 + '"'):
            with self.subTest(requirement=requirement):
                with self.assertRaises(policy.PolicyError):
                    self.verify_with(DISPLAY.replace(policy.REQUIREMENT, requirement))

    def test_no_secure_timestamp_or_runtime_is_rejected(self):
        for display in (DISPLAY.replace("Timestamp=Fixture timestamp\n", ""),
                        DISPLAY.replace("flags=0x10000(runtime)", "flags=0x0(none)"),
                        DISPLAY.replace(f"TeamIdentifier={policy.TEAM}", "TeamIdentifier=OTHERTEAM0")):
            with self.assertRaises(policy.PolicyError): self.verify_with(display)

    def test_renewal_and_build_hash_changes_do_not_change_publisher(self):
        alternative = " and ".join(reversed(policy.REQUIREMENT.split(" and ")))
        self.verify_with(DISPLAY.replace(policy.REQUIREMENT, alternative) + "CDHash=" + "1" * 40 + "\n")
        self.verify_with(DISPLAY + "CDHash=" + "2" * 40 + "\n")
        calls = []
        def command(*args):
            calls.append(args)
            return DISPLAY if "--display" in args else ""
        with patch.object(policy, "command", command): policy.compare(self.app, self.app)
        self.assertEqual(sum("=" + policy.REQUIREMENT in call for call in calls), 4)

    def test_packaging_and_public_signing_fail_before_mutation(self):
        # No real Keychain/signing calls: an empty identity inventory must stop
        # both entrypoints before touching source code or prompting EdDSA keys.
        bin_dir = Path(self.temp.name) / "bin"
        bin_dir.mkdir()
        security = bin_dir / "security"
        security.write_text("#!/bin/bash\nprintf '0 valid identities found\\n'\n")
        security.chmod(0o755)
        codesign = bin_dir / "codesign"
        codesign.write_text("#!/bin/bash\ntouch \"$MOCK_CODESIGN_MARKER\"\nexit 1\n")
        codesign.chmod(0o755)
        self.info.update(CFBundleShortVersionString="1.2.2", CFBundleVersion="5")
        self.write_info()
        resources = self.app / "Contents/Resources"
        resources.mkdir()
        (resources / "Sparkle-LICENSE.txt").write_text("Fixture")
        import os
        marker = Path(self.temp.name) / "codesign-called"
        env = dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}", MOCK_CODESIGN_MARKER=str(marker))
        before = (self.app / "Contents/Info.plist").read_bytes()
        commands = (["bash", ROOT / "Scripts/sign-app.sh", self.app, "-", "--public"],
                    ["bash", ROOT / "Scripts/package-release.sh", "--app", self.app,
                     "--output", Path(self.temp.name) / "release"])
        for args in commands:
            result = subprocess.run([str(arg) for arg in args], cwd=ROOT, env=env, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(b"Developer ID Application", result.stderr)
            self.assertFalse(marker.exists())
            self.assertEqual((self.app / "Contents/Info.plist").read_bytes(), before)
            self.assertFalse((Path(self.temp.name) / "release").exists())

    def test_public_secure_signing_and_local_behavior(self):
        import json
        import os
        bin_dir = Path(self.temp.name) / "bin"
        bin_dir.mkdir()
        security = bin_dir / "security"
        security.write_text(f'#!/bin/bash\nprintf \'  1) {FINGERPRINT} "{NAME}"\\n\'\n')
        security.chmod(0o755)
        codesign = bin_dir / "codesign"
        codesign.write_text("#!/usr/bin/env python3\nimport json,os,sys\n"
                            "with open(os.environ['MOCK_SIGN_LOG'],'a') as f: f.write(json.dumps(sys.argv[1:])+'\\n')\n"
                            "if '--display' in sys.argv: print(os.environ['MOCK_DISPLAY'])\n")
        codesign.chmod(0o755)
        framework = self.app / "Contents/Frameworks/Sparkle.framework"
        version = framework / "Versions/B"
        for child in ("XPCServices/Downloader.xpc", "XPCServices/Installer.xpc", "Updater.app"):
            (version / child).mkdir(parents=True)
        (version / "Autoupdate").touch()
        (framework / "Versions/Current").symlink_to("B")
        log = Path(self.temp.name) / "signing.jsonl"
        env = dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}", MOCK_SIGN_LOG=str(log), MOCK_DISPLAY=DISPLAY)
        for public in (False, True):
            log.unlink(missing_ok=True)
            args = ["bash", str(ROOT / "Scripts/sign-app.sh"), str(self.app), FINGERPRINT if public else "-"]
            if public: args.append("--public")
            subprocess.run(args, cwd=ROOT, env=env, check=True, capture_output=True)
            signed = [json.loads(line) for line in log.read_text().splitlines() if "--sign" in json.loads(line)]
            self.assertEqual(len(signed), 6)
            for call in signed:
                self.assertIn("--timestamp" if public else "--timestamp=none", call)
                self.assertEqual("--options" in call, public)
                self.assertNotIn("--requirements", call)
                self.assertNotIn("-r", call)
                self.assertIn("--preserve-metadata=entitlements", call)


def live(app, requested):
    identity = policy.identity(requested)
    with tempfile.TemporaryDirectory(prefix="windowtiler-public-identity-") as temp:
        root = Path(temp)
        builds = []
        for number in (1, 2):
            destination = root / f"build{number}" / "Window Tiler.app"
            destination.parent.mkdir()
            subprocess.run(["ditto", str(app), str(destination)], check=True)
            source = root / "main.swift"
            source.write_text(f'print("Disposable identity build {number}")\n')
            subprocess.run(["swiftc", str(source), "-o", str(destination / "Contents/MacOS/WindowTiler")], check=True)
            info_path = destination / "Contents/Info.plist"
            info = plistlib.loads(info_path.read_bytes())
            info["CFBundleVersion"] = str(500000 + number)
            info_path.write_bytes(plistlib.dumps(info))
            subprocess.run([str(ROOT / "Scripts/sign-app.sh"), str(destination), identity, "--public"], check=True)
            builds.append(destination)
        policy.compare(*builds)
        hashes = [re_hash(policy.command("codesign", "--display", "--verbose=4", app)) for app in builds]
        policy.require(None not in hashes and hashes[0] != hashes[1], "Live fixtures must have different code hashes.")
        rejected = root / "ad-hoc.app"
        subprocess.run(["ditto", str(builds[0]), str(rejected)], check=True)
        subprocess.run([str(ROOT / "Scripts/sign-app.sh"), str(rejected), "-"], check=True)
        try:
            policy.verify(rejected)
        except policy.PolicyError:
            pass
        else:
            raise policy.PolicyError("Live ad-hoc signature was incorrectly accepted.")
        print("PASS: two distinct Developer ID builds mutually satisfy their stable identity; ad-hoc rejected")


def re_hash(display):
    import re
    match = re.search(r"^CDHash=([0-9a-fA-F]+)$", display, re.MULTILINE)
    return match.group(1) if match else None


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--live", action="store_true")
    parser.add_argument("--app", type=Path, default=ROOT / "dist/Window Tiler.app")
    parser.add_argument("--signing-identity")
    args = parser.parse_args()
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(PolicyTests))
    if not result.wasSuccessful(): raise SystemExit(1)
    if args.live: live(args.app, args.signing_identity)
