#!/usr/bin/env python3
"""Render and check the Ledger Atlas Mac completion specification."""

from __future__ import annotations

import argparse
import hashlib
import html
import re
import sys
from datetime import UTC, datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_MARKDOWN = ROOT / "docs/specifications/ledger-atlas-mac-completion-v2.md"
DEFAULT_HTML = ROOT / "docs/specifications/ledger-atlas-mac-completion-v2.html"
REQUIRED_HEADINGS = (
    "Product contract",
    "Assumptions",
    "Exclusions",
    "Implementation decisions",
    "User stories",
    "Test seams",
    "Delivery tickets",
    "Traceability",
)


def slug(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-")


def inline(value: str) -> str:
    escaped = html.escape(value, quote=False)
    tokens: list[str] = []

    def stash_code(match: re.Match[str]) -> str:
        tokens.append(f"<code>{match.group(1)}</code>")
        return f"\x00{len(tokens) - 1}\x00"

    escaped = re.sub(r"`([^`]+)`", stash_code, escaped)
    escaped = re.sub(
        r"\[([^]]+)]\((https?://[^)]+|#[^)]+|[^:)][^)]+)\)",
        r'<a href="\2">\1</a>',
        escaped,
    )
    escaped = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", escaped)
    escaped = re.sub(r"\*([^*]+)\*", r"<em>\1</em>", escaped)
    for index, token in enumerate(tokens):
        escaped = escaped.replace(f"\x00{index}\x00", token)
    return escaped


def render_blocks(source: str) -> tuple[str, list[tuple[int, str, str]]]:
    lines = source.splitlines()
    output: list[str] = []
    headings: list[tuple[int, str, str]] = []
    paragraph: list[str] = []
    list_kind: str | None = None
    in_code = False
    code_lines: list[str] = []
    code_language = ""
    index = 0

    def close_paragraph() -> None:
        if paragraph:
            output.append(f"<p>{inline(' '.join(paragraph))}</p>")
            paragraph.clear()

    def close_list() -> None:
        nonlocal list_kind
        if list_kind:
            output.append(f"</{list_kind}>")
            list_kind = None

    while index < len(lines):
        line = lines[index]
        if in_code:
            if line.startswith("```"):
                language = (
                    f' class="language-{html.escape(code_language)}"' if code_language else ""
                )
                output.append(
                    f"<pre><code{language}>{html.escape(chr(10).join(code_lines))}</code></pre>"
                )
                in_code = False
                code_lines.clear()
            else:
                code_lines.append(line)
            index += 1
            continue

        if line.startswith("```"):
            close_paragraph()
            close_list()
            in_code = True
            code_language = line[3:].strip()
            index += 1
            continue

        heading = re.match(r"^(#{1,4}) (.+)$", line)
        if heading:
            close_paragraph()
            close_list()
            level = len(heading.group(1))
            title = heading.group(2)
            identifier = slug(re.sub(r"[`*]", "", title))
            headings.append((level, title, identifier))
            output.append(f'<h{level} id="{identifier}">{inline(title)}</h{level}>')
            index += 1
            continue

        if (
            line.startswith("|")
            and index + 1 < len(lines)
            and re.match(r"^\|(?:\s*:?-+:?\s*\|)+$", lines[index + 1])
        ):
            close_paragraph()
            close_list()
            rows: list[list[str]] = []
            while index < len(lines) and lines[index].startswith("|"):
                rows.append([cell.strip() for cell in lines[index].strip("|").split("|")])
                index += 1
            headers = rows[0]
            body = rows[2:]
            output.append('<div class="table-scroll"><table><thead><tr>')
            output.extend(f'<th scope="col">{inline(cell)}</th>' for cell in headers)
            output.append("</tr></thead><tbody>")
            for row in body:
                output.append("<tr>")
                output.extend(f"<td>{inline(cell)}</td>" for cell in row)
                output.append("</tr>")
            output.append("</tbody></table></div>")
            continue

        item = re.match(r"^\s*([-*]|\d+\.)\s+(.+)$", line)
        if item:
            close_paragraph()
            kind = "ol" if item.group(1)[0].isdigit() else "ul"
            if list_kind != kind:
                close_list()
                output.append(f"<{kind}>")
                list_kind = kind
            content = item.group(2)
            checked = re.match(r"^\[([ xX])\]\s+(.+)$", content)
            if checked:
                state = "checked" if checked.group(1).lower() == "x" else ""
                output.append(
                    f'<li class="check"><input type="checkbox" disabled {state} '
                    f'aria-label="Checklist state"> {inline(checked.group(2))}</li>'
                )
            else:
                output.append(f"<li>{inline(content)}</li>")
            index += 1
            continue

        if line.startswith("> "):
            close_paragraph()
            close_list()
            output.append(f"<blockquote><p>{inline(line[2:])}</p></blockquote>")
            index += 1
            continue

        if not line.strip():
            close_paragraph()
            close_list()
        else:
            paragraph.append(line.strip())
        index += 1

    close_paragraph()
    close_list()
    if in_code:
        raise ValueError("unclosed code fence")
    return "\n".join(output), headings


def validate(source: str) -> None:
    missing = [heading for heading in REQUIRED_HEADINGS if f"## {heading}" not in source]
    if missing:
        raise ValueError(f"missing required headings: {', '.join(missing)}")

    stories = re.findall(r"^### (US-\d{2}) ", source, re.MULTILINE)
    expected_stories = [f"US-{number:02d}" for number in range(1, 34)]
    if stories != expected_stories:
        raise ValueError("user stories must be US-01 through US-33 in order")

    tickets = re.findall(r"^### (MACV2-\d{2}) ", source, re.MULTILINE)
    expected_tickets = [f"MACV2-{number:02d}" for number in range(1, 24)]
    if tickets != expected_tickets:
        raise ValueError("tickets must be MACV2-01 through MACV2-23 in order")

    sections = re.split(r"(?=^### MACV2-\d{2} )", source, flags=re.MULTILINE)[1:]
    for ticket, section in zip(expected_tickets, sections, strict=True):
        if "Acceptance:" not in section:
            raise ValueError(f"{ticket} has no Acceptance text")
        if not re.search(
            r"GitHub: \[#[0-9]+]\(https://github\.com/praxstack/ledger-atlas/issues/[0-9]+\)",
            section,
        ):
            raise ValueError(f"{ticket} has no canonical GitHub link")


def render(source: str, generated_at: str) -> str:
    validate(source)
    source_hash = hashlib.sha256(source.encode()).hexdigest()
    body, headings = render_blocks(source)
    toc = "\n".join(
        f'<li class="level-{level}"><a href="#{identifier}">{inline(title)}</a></li>'
        for level, title, identifier in headings
        if level in (2, 3)
    )
    return f"""<!doctype html>
<html lang="en" data-source-sha256="{source_hash}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="source-sha256" content="{source_hash}">
<meta name="generated-at" content="{generated_at}">
<title>Ledger Atlas Mac Completion v2</title>
<style>
:root {{ color-scheme: light dark; --ink:#17201d; --muted:#53635e; --paper:#f7f7f2;
  --panel:#eceee8; --rule:#c7cec8; --accent:#17695d; --code:#e2e7e1; }}
@media (prefers-color-scheme:dark) {{ :root {{ --ink:#edf2ed; --muted:#aab8b0;
  --paper:#151a17; --panel:#202722; --rule:#3d4942; --accent:#70c3b1; --code:#29332d; }} }}
* {{ box-sizing:border-box }}
html {{ scroll-behavior:smooth }}
body {{ margin:0; color:var(--ink); background:var(--paper); font:15px/1.55 -apple-system,
  BlinkMacSystemFont,"Segoe UI",sans-serif }}
a {{ color:var(--accent); text-underline-offset:3px }}
a:focus-visible {{ outline:3px solid var(--accent); outline-offset:3px }}
.skip {{ position:absolute; left:-10000px; top:auto }}
.skip:focus {{ left:1rem; top:1rem; z-index:3; padding:.6rem .8rem; background:var(--paper) }}
header {{ border-bottom:1px solid var(--rule); background:var(--panel); padding:2rem max(1rem,4vw) }}
header p {{ margin:.3rem 0; color:var(--muted) }}
.layout {{ display:grid; grid-template-columns:minmax(15rem,22rem) minmax(0,56rem); gap:3rem;
  max-width:86rem; margin:0 auto; padding:2rem max(1rem,4vw) 5rem }}
aside {{ align-self:start; position:sticky; top:1rem; max-height:calc(100vh - 2rem); overflow:auto }}
nav ul {{ list-style:none; padding:0; margin:0 }}
nav li {{ margin:.2rem 0 }} nav .level-3 {{ padding-left:1rem; font-size:.9rem }}
main {{ min-width:0 }} h1 {{ margin:0 0 .5rem; font-size:2rem }} h2 {{ margin-top:3rem }}
h3 {{ margin-top:2rem }} h2,h3,h4 {{ scroll-margin-top:1rem }}
code,pre,.meta {{ font-family:"JetBrainsMono Nerd Font","MesloLGS NF","SFMono-Regular",
  Menlo,Consolas,monospace }}
code {{ background:var(--code); padding:.1rem .25rem; border-radius:3px }}
pre {{ overflow:auto; background:var(--code); padding:1rem; border-radius:6px }}
pre code {{ padding:0 }} blockquote {{ border-left:4px solid var(--accent); margin:1rem 0;
  padding:.1rem 1rem; color:var(--muted) }}
.table-scroll {{ overflow:auto; border:1px solid var(--rule); border-radius:6px }}
table {{ border-collapse:collapse; width:100%; min-width:42rem }} th,td {{ padding:.55rem .7rem;
  border-bottom:1px solid var(--rule); text-align:left; vertical-align:top }} th {{ background:var(--panel) }}
.check input {{ margin-right:.35rem }} footer {{ border-top:1px solid var(--rule); padding:1.5rem max(1rem,4vw);
  color:var(--muted) }}
@media (max-width:900px) {{ .layout {{ grid-template-columns:1fr }} aside {{ position:static;
  max-height:none }} }}
@media print {{ :root {{ color-scheme:light; --ink:#000; --muted:#333; --paper:#fff;
  --panel:#f2f2f2; --rule:#aaa; --accent:#000; --code:#f4f4f4 }} .layout {{ display:block;
  max-width:none; padding:0 }} aside,.skip {{ display:none }} header,footer {{ padding:1rem 0 }}
  a {{ color:#000 }} h2,h3,h4 {{ break-after:avoid }} table,pre,blockquote {{ break-inside:avoid }} }}
</style>
</head>
<body>
<a class="skip" href="#main">Skip to specification</a>
<header role="banner">
<h1>Ledger Atlas Mac Completion v2</h1>
<p class="meta">Markdown SHA-256: {source_hash}</p>
<p class="meta">Generated: {generated_at}</p>
</header>
<div class="layout">
<aside><nav aria-label="Specification sections"><h2>Contents</h2><ul>{toc}</ul></nav></aside>
<main id="main" tabindex="-1">{body}</main>
</div>
<footer>Generated from ledger-atlas-mac-completion-v2.md. GitHub Issues remain the canonical work records.</footer>
</body>
</html>
"""


def existing_timestamp(path: Path) -> str:
    if not path.exists():
        raise ValueError(f"missing HTML rendering: {path}")
    match = re.search(r'<meta name="generated-at" content="([^"]+)">', path.read_text())
    if not match:
        raise ValueError("HTML has no generation timestamp")
    datetime.fromisoformat(match.group(1))
    return match.group(1)


def main() -> int:
    parser = argparse.ArgumentParser()
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--write", action="store_true")
    mode.add_argument("--check", action="store_true")
    parser.add_argument("--markdown", type=Path, default=DEFAULT_MARKDOWN)
    parser.add_argument("--html", type=Path, default=DEFAULT_HTML)
    args = parser.parse_args()

    try:
        source = args.markdown.read_text(encoding="utf-8")
        timestamp = (
            datetime.now(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")
            if args.write
            else existing_timestamp(args.html)
        )
        expected = render(source, timestamp)
        if args.write:
            args.html.write_text(expected, encoding="utf-8")
            print(f"rendered {args.html}")
            return 0
        if args.html.read_text(encoding="utf-8") != expected:
            raise ValueError("HTML differs from the Markdown source")
        print("completion specification parity: OK")
        return 0
    except (OSError, ValueError) as error:
        print(f"completion specification parity: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
