#!/usr/bin/env python3
"""Convert Standard Ebooks epubs to markdown for Azure AI Search ingestion.

One markdown file per work, with each chapter as an h2 heading:

    # The Iliad
    ## Book IX: The Embassy to Achilles
    ...

The blob indexer parses those h2 headings (markdownHeaderDepth: h2, oneToMany) to
produce one enriched document per chapter, so the heading text becomes queryable
`chapter` metadata on every chunk. Work-level metadata — title, author, translator,
year — is not in the file: it is attached to the blob at upload time and picked up by
the indexer, so it stays editable without re-converting.

Stdlib only. Standard Ebooks ships well-formed XHTML, so ElementTree is enough and the
script needs no environment of its own.

    python3 tools/epub2md.py content/*.epub --out content/markdown
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import zipfile
from pathlib import Path
from xml.etree import ElementTree

OPF_NS = {"opf": "http://www.idpf.org/2007/opf", "dc": "http://purl.org/dc/elements/1.1/"}
XHTML = "{http://www.w3.org/1999/xhtml}"
EPUB = "{http://www.idpf.org/2007/ops}"

# Spine items that are front or back matter rather than the text itself.
CHAPTER_RE = re.compile(r"(^|/)(book|chapter)-\d+\.xhtml$")


def _opf_path(zf: zipfile.ZipFile) -> str:
    container = ElementTree.fromstring(zf.read("META-INF/container.xml"))
    rootfile = container.find(".//{urn:oasis:names:tc:opendocument:xmlns:container}rootfile")
    if rootfile is None:
        raise SystemExit("epub has no rootfile in META-INF/container.xml")
    return rootfile.attrib["full-path"]


def _metadata(opf: ElementTree.Element) -> dict[str, str]:
    """Work-level metadata, for attaching to the blob at upload time."""

    def dc(tag: str) -> str:
        el = opf.find(f".//dc:{tag}", OPF_NS)
        return (el.text or "").strip() if el is not None else ""

    # Contributors are distinguished by a role refinement (marc relator codes): trl is
    # translator, art illustrator, and so on. Without this you get the cover artist.
    translator = ""
    for meta in opf.findall(".//opf:meta[@property='role']", OPF_NS):
        if (meta.text or "").strip() == "trl":
            refines = meta.attrib.get("refines", "").lstrip("#")
            el = opf.find(f".//dc:contributor[@id='{refines}']", OPF_NS)
            if el is not None and el.text:
                translator = el.text.strip()
                break

    return {
        "title": dc("title"),
        "author": dc("creator"),
        "translator": translator,
        "year": dc("date")[:4],
        "language": dc("language"),
    }


def _spine(opf: ElementTree.Element, base: str) -> list[str]:
    """Chapter hrefs, in reading order."""
    manifest = {
        item.attrib["id"]: item.attrib["href"]
        for item in opf.findall(".//opf:manifest/opf:item", OPF_NS)
    }
    hrefs = [
        manifest[ref.attrib["idref"]]
        for ref in opf.findall(".//opf:spine/opf:itemref", OPF_NS)
        if ref.attrib["idref"] in manifest
    ]
    return [f"{base}{h}" for h in hrefs if CHAPTER_RE.search(h)]


def _text(el: ElementTree.Element) -> str:
    return re.sub(r"\s+", " ", "".join(el.itertext())).strip()


def _chapter(zf: zipfile.ZipFile, path: str) -> tuple[str, str]:
    """Return (heading, body) for one chapter file."""
    root = ElementTree.fromstring(zf.read(path))

    title_el = root.find(f".//{XHTML}head/{XHTML}title")
    heading = _text(title_el) if title_el is not None else Path(path).stem

    blocks: list[str] = []
    for p in root.iter(f"{XHTML}p"):
        # <p epub:type="title"> repeats the chapter title, which is already the heading.
        # The bridgehead paragraph in the same header is the chapter argument and is
        # worth keeping, so filter on the type rather than skipping the header wholesale.
        if "title" in p.attrib.get(f"{EPUB}type", "").split():
            continue

        # Verse: one <span> per line, separated by <br/>. Joining the spans with
        # newlines keeps the line structure, which matters for poetry and for
        # recognising quotations.
        spans = p.findall(f"{XHTML}span")
        if spans:
            lines = [_text(s) for s in spans]
            blocks.append("\n".join(line for line in lines if line))
        else:
            body = _text(p)
            if body:
                blocks.append(body)

    return heading, "\n\n".join(blocks)


def convert(epub: Path, out_dir: Path) -> dict[str, str]:
    with zipfile.ZipFile(epub) as zf:
        opf_path = _opf_path(zf)
        opf = ElementTree.fromstring(zf.read(opf_path))
        base = opf_path.rsplit("/", 1)[0] + "/" if "/" in opf_path else ""

        meta = _metadata(opf)
        chapters = _spine(opf, base)
        if not chapters:
            raise SystemExit(f"{epub}: no chapter files found in the spine")

        parts = [f"# {meta['title']}", ""]
        for path in chapters:
            heading, body = _chapter(zf, path)
            parts += [f"## {heading}", "", body, ""]

    slug = re.sub(r"[^a-z0-9]+", "-", meta["title"].lower()).strip("-")
    out = out_dir / f"{slug}.md"
    out.write_text("\n".join(parts), encoding="utf-8")

    meta["chapters"] = str(len(chapters))
    meta["file"] = out.name
    print(f"{epub.name} -> {out}  ({len(chapters)} chapters, {out.stat().st_size // 1024} KB)")
    return meta


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("epubs", nargs="+", type=Path)
    ap.add_argument("--out", type=Path, default=Path("content/markdown"))
    args = ap.parse_args()

    args.out.mkdir(parents=True, exist_ok=True)
    manifest = [convert(e, args.out) for e in args.epubs]

    # Consumed by the upload step: these become blob metadata, and every field must have
    # a matching field in the search index or the indexer discards it silently.
    (args.out / "metadata.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    print(f"\nwrote {args.out / 'metadata.json'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
