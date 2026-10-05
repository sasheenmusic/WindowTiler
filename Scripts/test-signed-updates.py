#!/usr/bin/env python3
"""Exercise the real Sparkle updater on isolated, signed fixture apps.

Requires a built app, macOS GUI session, and the release signing key in Keychain.
No Window Tiler process, settings, or user windows are changed.
"""
import functools
import http.server
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import threading
import time
import uuid
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
TEST = ROOT / "dist" / ("signed-update-tests-" + uuid.uuid4().hex[:8])
SPARKLE = ROOT / ".build/artifacts/sparkle/Sparkle"
FRAMEWORK = SPARKLE / "Sparkle.xcframework/macos-arm64_x86_64"
SIGN = SPARKLE / "bin/sign_update"
PUBLIC_KEY = plistlib.loads((ROOT / "Resources/Info.plist").read_bytes())["SUPublicEDKey"]


def run(*args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, **kwargs).stdout.strip()


class Server(http.server.SimpleHTTPRequestHandler):
    requests = []

    def log_message(self, *_):
        pass

    def do_GET(self):
        self.requests.append(self.path)
        super().do_GET()


def sign(path):
    return run(SIGN, "--account", "windowtiler", "-p", path)


def make_app(destination, identifier, version, feed, receipt):
    source = ROOT / "dist/Window Tiler.app"
    run("ditto", source, destination)
    shutil.copy2(TEST / "fixture", destination / "Contents/MacOS/WindowTiler")
    info_path = destination / "Contents/Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    info.update(CFBundleIdentifier=identifier, CFBundleName="Update Fixture",
                CFBundleVersion=str(version), CFBundleShortVersionString=f"0.0.{version}",
                SUFeedURL=feed, SUPublicEDKey=PUBLIC_KEY, SUEnableAutomaticChecks=True,
                SUAutomaticallyUpdate=True, SURequireSignedFeed=True,
                SUVerifyUpdateBeforeExtraction=True, FixtureReceipt=str(receipt),
                NSAppTransportSecurity={"NSAllowsLocalNetworking": True})
    info_path.write_bytes(plistlib.dumps(info))
    # Match the public release's signature, including the embedded installer helpers.
    run(ROOT / "Scripts/sign-app.sh", destination, "-")
    run("codesign", "--verify", "--deep", "--strict", destination)


def exercise(case, port):
    directory = TEST / case
    directory.mkdir()
    identifier = "com.windowtiler.updater-fixture." + uuid.uuid4().hex
    receipt = directory / "launches.txt"
    app = directory / "installed/Update Fixture.app"
    payload = directory / "payload/Update Fixture.app"
    app.parent.mkdir()
    payload.parent.mkdir()
    feed_url = f"http://127.0.0.1:{port}/{case}/appcast.xml"
    make_app(app, identifier, 1, feed_url, receipt)
    make_app(payload, identifier, 2, feed_url, receipt)
    archive = directory / "update.zip"
    run("ditto", "-c", "-k", "--norsrc", "--keepParent", payload, archive)
    signature = sign(archive)
    if case == "bad-archive":
        signature = ("A" if signature[0] != "A" else "B") + signature[1:]
    ns = "http://www.andymatuschak.org/xml-namespaces/sparkle"
    ET.register_namespace("sparkle", ns)
    rss = ET.Element("rss", version="2.0")
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "Window Tiler Update Test"
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = "Fixture update"
    ET.SubElement(item, "{" + ns + "}version").text = "1" if case == "current" else "2"
    ET.SubElement(item, "{" + ns + "}shortVersionString").text = "0.0.2"
    ET.SubElement(item, "enclosure", url=f"http://127.0.0.1:{port}/{case}/update.zip",
                  length=str(archive.stat().st_size), type="application/octet-stream",
                  **{"{" + ns + "}edSignature": signature})
    feed = directory / "appcast.xml"
    ET.ElementTree(rss).write(feed, encoding="utf-8", xml_declaration=True)
    sign(feed)
    if case == "bad-feed":
        feed.write_bytes(feed.read_bytes().replace(b"Fixture update", b"Changed update"))
    output = open(directory / "process.log", "w")
    proc = subprocess.Popen([str(app / "Contents/MacOS/WindowTiler")], stdout=output, stderr=output)
    try:
        deadline = time.monotonic() + (45 if case == "upgrade" else 14)
        while time.monotonic() < deadline:
            launches = receipt.read_text() if receipt.exists() else ""
            if "launched 2 " in launches:
                break
            time.sleep(0.2)
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        requests = [p for p in Server.requests if p.startswith(f"/{case}/")]
        assert f"/{case}/appcast.xml" in requests, f"{case}: updater never fetched feed"
        if case == "upgrade":
            assert info["CFBundleVersion"] == "2", "Signed update was not installed"
            assert "launched 2 " in launches, "Updated app was not relaunched automatically"
        else:
            assert info["CFBundleVersion"] == "1", f"{case}: app unexpectedly replaced"
            assert "launched 2 " not in launches, f"{case}: app unexpectedly relaunched"
            if case == "bad-archive":
                assert f"/{case}/update.zip" in requests, "Bad-archive test never downloaded its archive"
            if case in ("bad-feed", "current"):
                assert f"/{case}/update.zip" not in requests, f"{case}: archive fetched unnecessarily"
        print(f"PASS: {case}", flush=True)
    finally:
        if proc.poll() is None:
            proc.terminate()
        proc.wait(timeout=10)
        output.close()
        subprocess.run(["defaults", "delete", identifier], capture_output=True)


def main():
    TEST.mkdir(parents=True)
    run("swiftc", "-F", FRAMEWORK, "-framework", "Sparkle",
        "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
        ROOT / "Sources/WindowTilerApp/AppUpdater.swift",
        ROOT / "Scripts/UpdateFixtures/main.swift", "-o", TEST / "fixture")
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(Server, directory=str(TEST)))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        for case in ("upgrade", "bad-archive", "bad-feed", "current"):
            exercise(case, server.server_port)
    finally:
        server.shutdown()
        print(f"Receipts: {TEST}", flush=True)


if __name__ == "__main__":
    main()
