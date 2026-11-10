"""Regenerates the README buttons in assets/ (EN and FR).

    python3 assets/make_svgs.py

Drawn like Iris's own controls: the main action is the orange tile of the home screen, the others the
ink chip with an orange outline the app uses in dark mode. Static, readable on GitHub light and dark.
"""
from pathlib import Path

OUT = Path(__file__).parent
FONT = "-apple-system,BlinkMacSystemFont,'SF Pro Display','Helvetica Neue',Arial,sans-serif"

_LOW = "abcdefghijklmnopqrstuvwxyz"
BOLD = dict(zip(_LOW, [556, 611, 556, 611, 556, 333, 611, 611, 278, 278, 556, 278, 889, 611, 611, 611, 611, 389,
                       556, 333, 611, 556, 778, 556, 556, 500]))
BOLD.update(zip(_LOW.upper(), [722, 722, 722, 722, 667, 611, 778, 722, 278, 556, 722, 611, 833, 722, 778, 667, 778,
                                722, 667, 611, 722, 667, 944, 667, 667, 611]))
BOLD.update({" ": 278, "'": 238, "é": 556, "ç": 556, "à": 556})


def button(name, label, primary=False):
    tw = sum(BOLD.get(c, 600) for c in label) / 1000 * 14
    w, h = round(tw + 40), 40
    fill, stroke = ("#FF5B1F", "#FF5B1F") if primary else ("#0A0A0A", "#FF5B1F")
    label = label.replace("&", "&amp;")
    (OUT / f"btn-{name}.svg").write_text(
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}" width="{w}" height="{h}" role="img">'
        f'<title>{label}</title>'
        f'<rect x=".5" y=".5" width="{w - 1}" height="{h - 1}" rx="12" fill="{fill}" stroke="{stroke}"/>'
        f'<text x="20" y="25" font-family="{FONT}" font-size="14" font-weight="600" textLength="{tw:.0f}" '
        f'lengthAdjust="spacing" fill="#fff">{label}</text></svg>\n')


for name, en, fr in [("download", "Download the IPA", "Télécharger l'IPA"), ("glasses", "Which glasses", "Quelles lunettes"),
                     ("build", "Build from source", "Compiler"), ("how", "How it works", "Comment ça marche")]:
    button(name, en, name == "download")
    button(f"{name}-fr", fr, name == "download")
