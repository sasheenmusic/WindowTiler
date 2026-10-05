#!/usr/bin/env python3
"""Public releases use one Developer ID team; local builds are separate."""
import argparse
from pathlib import Path
import plistlib
import re
import subprocess
import sys

TEAM = "B697BHH54U"
IDENTIFIER = "com.windowtiler.app"
REQUIREMENT = (
    f'identifier "{IDENTIFIER}" and anchor apple generic '
    'and certificate 1[field.1.2.840.113635.100.6.2.6] '
    'and certificate leaf[field.1.2.840.113635.100.6.1.13] '
    f'and certificate leaf[subject.OU] = "{TEAM}"'
)


class PolicyError(Exception):
    pass


def require(value, message):
    if not value:
        raise PolicyError(message)


def command(*args):
    result = subprocess.run([str(arg) for arg in args], text=True, capture_output=True)
    require(result.returncode == 0, f"{Path(str(args[0])).name} failed; public signing was stopped.")
    return result.stdout + result.stderr


def identity(requested=None):
    available = command("security", "find-identity", "-v", "-p", "codesigning")
    entries = re.findall(r'^\s*\d+\)\s+([0-9A-Fa-f]{40})\s+"([^"]+)"\s*$', available, re.MULTILINE)
    matches = [(fingerprint, name) for fingerprint, name in entries
               if name.startswith("Developer ID Application: ") and name.endswith(f"({TEAM})")
               and (requested is None or requested.lower() == fingerprint.lower() or requested == name)]
    require(len(matches) == 1,
            f"Public signing requires one valid Developer ID Application identity for team {TEAM}. "
            "No ad-hoc or Apple Development fallback is allowed. "
            "If several exist, select one with --signing-identity.")
    return matches[0][0]


def clauses(requirement):
    # codesign emits a flat conjunction for a Developer ID signature. Ignore
    # whitespace, quotes and explanatory comments, never weaken its predicates.
    text = re.sub(r"/\*.*?\*/", "", requirement)
    return re.sub(r"\s+", "", text).replace('"', "").split("and")


def verify(app):
    app = Path(app)
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    require(info.get("CFBundleIdentifier") == IDENTIFIER, "Wrong public application bundle identifier.")
    command("codesign", "--verify", "--deep", "--strict", "--all-architectures", "-R", "=" + REQUIREMENT, app)
    display = command("codesign", "--display", "--verbose=4", "-r-", app)
    designated = re.search(r"^designated => (.+)$", display, re.MULTILINE)
    require(designated is not None, "Public app has no designated requirement.")
    actual = clauses(designated.group(1))
    expected = clauses(REQUIREMENT)
    require(len(actual) == len(expected) and set(actual) == set(expected),
            "Public designated requirement must identify this Developer ID team without a build hash, "
            "certificate pin, or weaker alternative.")
    require(re.search(r"^TeamIdentifier=" + TEAM + r"$", display, re.MULTILINE), "Wrong public signing team.")
    require(re.search(r"^Timestamp=.+$", display, re.MULTILINE), "Public signing requires a secure timestamp.")
    flags = re.search(r"\bflags=0x([0-9a-fA-F]+)", display)
    require(flags is not None and int(flags.group(1), 16) & 0x10000, "Public signing requires hardened runtime.")
    return designated.group(1)


def compare(previous, updated):
    old_requirement = verify(previous)
    new_requirement = verify(updated)
    command("codesign", "--verify", "-R", "=" + old_requirement, updated)
    command("codesign", "--verify", "-R", "=" + new_requirement, previous)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_subparsers(dest="action", required=True)
    select = actions.add_parser("identity")
    select.add_argument("--signing-identity")
    check = actions.add_parser("verify")
    check.add_argument("app")
    compatible = actions.add_parser("compare")
    compatible.add_argument("previous")
    compatible.add_argument("updated")
    args = parser.parse_args()
    if args.action == "identity":
        print(identity(args.signing_identity))
    elif args.action == "verify":
        verify(args.app)
    else:
        compare(args.previous, args.updated)


if __name__ == "__main__":
    try:
        main()
    except (PolicyError, OSError, ValueError) as error:
        print(f"Window Tiler: {error}", file=sys.stderr)
        sys.exit(1)
