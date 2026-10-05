#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Stage the public app separately, preserving the local app's signature.
python3 - "$@" <<'PY'
import argparse, base64, datetime, hashlib, os, pathlib, plistlib, re, subprocess, tempfile, xml.etree.ElementTree as ET

p = argparse.ArgumentParser(description='Stage a signed Sparkle release; never publishes or installs.')
p.add_argument('--app', default='dist/Window Tiler.app')
p.add_argument('--output', help='New output directory (default: dist/releases/vVERSION-buildBUILD)')
p.add_argument('--download-url', help='HTTPS ZIP URL (default: GitHub vVERSION release asset)')
a = p.parse_args()
app = pathlib.Path(a.app).resolve()
tools = pathlib.Path('.build/artifacts/sparkle/Sparkle/bin').resolve()
def run(*args, capture=False):
    return subprocess.run([str(x) for x in args], check=True, text=True,
                          stdout=subprocess.PIPE if capture else None).stdout
def require(condition, message):
    if not condition: raise SystemExit(message)
require(app.name == 'Window Tiler.app', 'Release app must be named Window Tiler.app.')
require((app / 'Contents/Resources/Sparkle-LICENSE.txt').is_file(), 'App is missing the bundled Sparkle license; rebuild it first.')
with (app / 'Contents/Info.plist').open('rb') as f: info = plistlib.load(f)
version, build = info['CFBundleShortVersionString'], info['CFBundleVersion']
require(re.fullmatch(r'[0-9]+(?:\.[0-9]+)*', version) and re.fullmatch(r'[0-9]+', build), 'Invalid release version/build.')
require(info.get('CFBundleIdentifier') == 'com.windowtiler.app', 'Wrong application bundle.')
require(info.get('SURequireSignedFeed') is True and info.get('SUVerifyUpdateBeforeExtraction') is True, 'Release must require signed feeds and pre-extraction verification.')
key = info.get('SUPublicEDKey', '')
require(len(base64.b64decode(key, validate=True)) == 32, 'Missing or invalid public EdDSA key.')
require(run(tools / 'generate_keys', '--account', 'windowtiler', '-p', capture=True).strip() == key, 'Keychain account windowtiler does not match the app public key.')
require(info.get('SUFeedURL') == 'https://raw.githubusercontent.com/sasheenmusic/WindowTiler/main/appcast.xml', 'Unexpected appcast URL.')
output = pathlib.Path(a.output or f'dist/releases/v{version}-build{build}').resolve()
require(not output.exists(), 'Output already exists; choose a new --output directory.')
filename = f'Window-Tiler-{version}.zip'
url = a.download_url or f'https://github.com/sasheenmusic/WindowTiler/releases/download/v{version}/{filename}'
require(url.startswith('https://') and url.endswith('/' + filename), 'Download URL must be HTTPS and end in the archive filename.')
output.parent.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='.windowtiler-release-', dir=output.parent) as temp:
    stage = pathlib.Path(temp)
    public = stage / app.name
    run('/usr/bin/ditto', app, public)
    run('Scripts/sign-app.sh', public, '-')
    archive = stage / filename
    run('/usr/bin/ditto', '-c', '-k', '--norsrc', '--keepParent', public, archive)
    extracted = stage / 'verify'
    run('/usr/bin/ditto', '-x', '-k', archive, extracted)
    check = extracted / app.name
    require((check / 'Contents/Frameworks/Sparkle.framework/Versions/Current').is_symlink(), 'ZIP lost framework symlinks.')
    run('/usr/bin/codesign', '--verify', '--deep', '--strict', check)
    with (check / 'Contents/Info.plist').open('rb') as f: require(plistlib.load(f) == info, 'Archive metadata changed.')
    signature = run(tools / 'sign_update', '--account', 'windowtiler', '-p', archive, capture=True).strip()
    require(len(base64.b64decode(signature, validate=True)) == 64, 'Invalid archive signature.')
    run(tools / 'sign_update', '--account', 'windowtiler', '--verify', archive, signature)
    ns = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
    ET.register_namespace('sparkle', ns)
    tag = lambda name: '{' + ns + '}' + name
    rss = ET.Element('rss', {'version': '2.0'})
    channel = ET.SubElement(rss, 'channel')
    ET.SubElement(channel, 'title').text = 'Window Tiler Updates'
    ET.SubElement(channel, 'link').text = info['SUFeedURL']
    item = ET.SubElement(channel, 'item')
    ET.SubElement(item, 'title').text = f'Window Tiler {version}'
    ET.SubElement(item, 'pubDate').text = datetime.datetime.now(datetime.timezone.utc).strftime('%a, %d %b %Y %H:%M:%S +0000')
    ET.SubElement(item, tag('version')).text = build
    ET.SubElement(item, tag('shortVersionString')).text = version
    ET.SubElement(item, tag('minimumSystemVersion')).text = info['LSMinimumSystemVersion']
    architectures = run('/usr/bin/lipo', '-archs', public / 'Contents/MacOS' / info['CFBundleExecutable'], capture=True).split()
    require(architectures and set(architectures) <= {'arm64', 'x86_64'}, 'Unknown release architecture.')
    if len(architectures) == 1: ET.SubElement(item, tag('hardwareRequirements')).text = architectures[0]
    ET.SubElement(item, 'enclosure', {'url': url, 'length': str(archive.stat().st_size), 'type': 'application/octet-stream', tag('edSignature'): signature})
    feed = stage / 'appcast.xml'
    ET.indent(rss)
    ET.ElementTree(rss).write(feed, encoding='utf-8', xml_declaration=True)
    run(tools / 'sign_update', '--account', 'windowtiler', feed)
    run(tools / 'sign_update', '--account', 'windowtiler', '--verify', feed)
    parsed = ET.parse(feed).find('channel/item')
    require(parsed.find(tag('version')).text == build and parsed.find('enclosure').get('length') == str(archive.stat().st_size), 'Feed validation failed.')
    checksum = stage / (filename + '.sha256')
    checksum.write_text(hashlib.sha256(archive.read_bytes()).hexdigest() + '  ' + filename + '\n')
    output.mkdir()
    for artifact in (archive, checksum, feed): os.replace(artifact, output / artifact.name)
print(output)
PY
