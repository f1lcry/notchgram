#!/usr/bin/env python3
"""Release notes for one version out of CHANGELOG.md.

    release_notes.py CHANGELOG.md 0.4.0          # the section as Markdown
    release_notes.py CHANGELOG.md 0.4.0 --html   # rendered for the appcast

The section runs from `## <version>` to the next `## ` heading, without its
own heading line. Exits 1 when the section is missing or its heading still
says "Unreleased" — release.sh stamps the release date into the heading
first, then runs this before building anything.

Ported from Dictate (local-voicer/scripts/release_notes.py).
"""

import html
import re
import sys


def section(changelog: str, version: str) -> str:
    lines = changelog.splitlines()
    start = None
    for i, line in enumerate(lines):
        if re.match(rf"^## {re.escape(version)}(\s|$)", line):
            start = i
            break
    if start is None:
        sys.exit(f"CHANGELOG.md has no '## {version}' section")
    heading = lines[start]
    if "unreleased" in heading.lower():
        sys.exit(f"CHANGELOG.md still says '{heading}' — stamp the date first")
    body = []
    for line in lines[start + 1 :]:
        if line.startswith("## "):
            break
        body.append(line)
    text = "\n".join(body).strip("\n")
    if not text.strip():
        sys.exit(f"CHANGELOG.md section '{heading}' is empty")
    return text + "\n"


def inline(text: str) -> str:
    """Escape for HTML, then bring back the two inline marks the changelog uses."""
    out = html.escape(text, quote=False)
    out = re.sub(r"`([^`]+)`", r"<code>\1</code>", out)
    out = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", out)
    return out


def render(markdown: str) -> str:
    """Headings, bullet lists (with wrapped continuation lines) and paragraphs.

    That is all CHANGELOG.md uses; anything fancier is passed through as text.
    """
    out: list[str] = []
    items: list[str] = []
    paragraph: list[str] = []

    def flush_list() -> None:
        if items:
            out.append("<ul>")
            out.extend(f"  <li>{inline(item)}</li>" for item in items)
            out.append("</ul>")
            items.clear()

    def flush_paragraph() -> None:
        if paragraph:
            out.append(f"<p>{inline(' '.join(paragraph))}</p>")
            paragraph.clear()

    for line in markdown.splitlines():
        stripped = line.strip()
        if not stripped:
            flush_list()
            flush_paragraph()
        elif stripped.startswith("#"):
            flush_list()
            flush_paragraph()
            level = min(len(stripped) - len(stripped.lstrip("#")), 6)
            out.append(f"<h{level}>{inline(stripped.lstrip('#').strip())}</h{level}>")
        elif re.match(r"^[-*] ", stripped):
            flush_paragraph()
            items.append(stripped[2:].strip())
        elif items and line.startswith((" ", "\t")):
            items[-1] += " " + stripped
        else:
            flush_list()
            paragraph.append(stripped)
    flush_list()
    flush_paragraph()
    return "\n".join(out) + "\n"


def cdata(text: str) -> str:
    """Safe inside <![CDATA[ … ]]>: split any ']]>' the text itself contains."""
    return text.replace("]]>", "]]]]><![CDATA[>")


def main() -> None:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    flags = {a for a in sys.argv[1:] if a.startswith("--")}
    if len(args) != 2:
        sys.exit(__doc__)
    with open(args[0], encoding="utf-8") as f:
        notes = section(f.read(), args[1])
    if "--html" in flags:
        sys.stdout.write(cdata(render(notes)))
    else:
        sys.stdout.write(notes)


if __name__ == "__main__":
    main()
