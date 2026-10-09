#!/usr/bin/env python3
"""Prepend one release to NotchGram's Sparkle appcast.

    appcast.py APPCAST --version 0.1.0 --build 2 --url URL --length N \\
        --signature SIG --notes-html FILE [--min-system 26.0] [--release-page URL]

APPCAST is created with an empty channel when it does not exist yet (the
first release has no feed to download). The new <item> goes first, so the
newest release leads. Refuses a version that is already in the feed, and
re-parses the result so a malformed feed never reaches the `feed` release.
"""

import argparse
import email.utils
import os
import sys
import xml.etree.ElementTree as ET
from xml.sax.saxutils import escape, quoteattr

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"

SKELETON = f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="{SPARKLE_NS}" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>NotchGram</title>
    <link>https://github.com/f1lcry/notchgram</link>
    <description>Updates for NotchGram, the Telegram client in the MacBook notch.</description>
    <language>en</language>
  </channel>
</rss>
"""

MARKER = "<language>en</language>\n"


def item(args: argparse.Namespace, notes_html: str) -> str:
    release_page = (
        f"      <sparkle:fullReleaseNotesLink>{escape(args.release_page)}"
        f"</sparkle:fullReleaseNotesLink>\n"
        if args.release_page
        else ""
    )
    return f"""    <item>
      <title>NotchGram {escape(args.version)}</title>
      <pubDate>{email.utils.formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{escape(args.build)}</sparkle:version>
      <sparkle:shortVersionString>{escape(args.version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{escape(args.min_system)}</sparkle:minimumSystemVersion>
{release_page}      <description><![CDATA[
{notes_html}
      ]]></description>
      <enclosure url={quoteattr(args.url)}
                 length={quoteattr(args.length)}
                 type="application/octet-stream"
                 sparkle:edSignature={quoteattr(args.signature)}/>
    </item>
"""


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("appcast")
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--url", required=True)
    parser.add_argument("--length", required=True)
    parser.add_argument("--signature", required=True)
    parser.add_argument("--notes-html", required=True)
    parser.add_argument("--min-system", default="26.0")
    parser.add_argument("--release-page")
    args = parser.parse_args()

    if os.path.exists(args.appcast):
        with open(args.appcast, encoding="utf-8") as f:
            content = f.read()
    else:
        content = SKELETON

    # Already rendered and CDATA-safe by scripts/release_notes.py --html.
    with open(args.notes_html, encoding="utf-8") as f:
        notes = f.read().rstrip("\n")

    if f"<sparkle:shortVersionString>{args.version}<" in content:
        sys.exit(f"appcast: {args.version} is already in {args.appcast}")
    if MARKER not in content:
        sys.exit("appcast: the <language>en</language> marker is missing — not our feed?")
    content = content.replace(MARKER, MARKER + item(args, notes), 1)

    # Well-formedness, and the facts Sparkle reads, before anything is written.
    root = ET.fromstring(content.encode("utf-8"))
    first = root.find("channel/item")
    assert first is not None, "no <item> after insertion"
    ns = {"sparkle": SPARKLE_NS}
    assert first.findtext("sparkle:shortVersionString", namespaces=ns) == args.version
    enclosure = first.find("enclosure")
    assert enclosure is not None and enclosure.get(f"{{{SPARKLE_NS}}}edSignature") == args.signature

    with open(args.appcast, "w", encoding="utf-8") as f:
        f.write(content)
    count = len(root.findall("channel/item"))
    print(f"appcast: {args.version} (build {args.build}) prepended; {count} item(s) in feed")


if __name__ == "__main__":
    main()
