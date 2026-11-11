"""Create the sample files used by the DJ tests.

Run:  python tests/make_sample_files.py
Creates tests/sample_files/ with a mix of file types, including one
file about travel and tourism (the Virun pitch) and one PDF.
"""

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
SAMPLE_DIR = HERE / "sample_files"


def _pdf_escape(text: str) -> str:
    return text.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)")


def make_pdf(path: Path, lines: list) -> None:
    """Write a minimal valid PDF with the given text lines."""
    content = []
    y = 720
    for i, line in enumerate(lines):
        size = 18 if i == 0 else 12
        content.append(
            f"BT /F1 {size} Tf 72 {y} Td ({_pdf_escape(line)}) Tj ET")
        y -= 30
    stream = "\n".join(content).encode("latin-1")
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] "
        b"/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
        b"<< /Length %d >>\nstream\n" % len(stream) + stream + b"\nendstream",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    ]
    out = bytearray(b"%PDF-1.4\n")
    offsets = []
    for i, obj in enumerate(objects, start=1):
        offsets.append(len(out))
        out += f"{i} 0 obj\n".encode() + obj + b"\nendobj\n"
    xref_pos = len(out)
    out += f"xref\n0 {len(objects) + 1}\n".encode()
    out += b"0000000000 65535 f \n"
    for off in offsets:
        out += f"{off:010d} 00000 n \n".encode()
    out += (f"trailer\n<< /Size {len(objects) + 1} /Root 1 0 R >>\n"
            f"startxref\n{xref_pos}\n%%EOF").encode()
    path.write_bytes(bytes(out))


def main():
    SAMPLE_DIR.mkdir(parents=True, exist_ok=True)
    (SAMPLE_DIR / "Virun pitch - Travel Titans.md").write_text(
        "# Virun — Travel Titans\n\n"
        "Virun is a travel and tourism app for tourists visiting a new "
        "city. It shows local guides, hidden places, food spots and "
        "transport. A tourist opens the app, picks a place, and a local "
        "guide takes them there. Built for the SAMARTHA hackathon.\n",
        encoding="utf-8")
    (SAMPLE_DIR / "Kerala trip notes.txt").write_text(
        "Kerala trip notes\n"
        "Travel and tourism in Kerala: backwaters of Alleppey, Munnar tea "
        "gardens, Kochi fort. Best time to visit is December. Tourist "
        "places to cover in three days.\n",
        encoding="utf-8")
    (SAMPLE_DIR / "cricket score tracker.py").write_text(
        "# A small script that tracks a cricket score.\n"
        "def show_score(runs, wickets):\n"
        "    print(f'Score: {runs}/{wickets}')\n",
        encoding="utf-8")
    make_pdf(SAMPLE_DIR / "SAPSS smart sanitation.pdf", [
        "SAPSS Smart Sanitation Project",
        "IoT auto-cleaning for public toilets in Visakhapatnam.",
        "Sensors detect usage and start cleaning after every use.",
        "Built for the Vishwakarma Awards, Stage 2.",
    ])
    from docx import Document
    doc = Document()
    doc.add_heading("Operating Systems Lab Assignment", level=1)
    doc.add_paragraph(
        "COA and OS lab: write a program for CPU scheduling, "
        "first come first served, and explain process states.")
    doc.save(str(SAMPLE_DIR / "College OS lab assignment.docx"))
    print(f"Sample files created in {SAMPLE_DIR}")


if __name__ == "__main__":
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
    main()
