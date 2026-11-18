"""Generate the Tavlo logo / app-icon SVGs (logo A: three alternating points).

Run: python3 design/logo/make_icons.py
The middle (light) point's apex sits 8 units lower than its neighbours: optical
balance, so the cream point doesn't read taller than the brown ones.
iOS PNGs (1024x1024, opaque) are rendered from the app-icon SVGs.
"""
from pathlib import Path

OUT = Path(__file__).parent
CARAMEL, BROWN, CREAM, ESPRESSO = "#d4a466", "#6a361a", "#fbeed1", "#2a1408"
TRIS = [((88, 416), (200, 416), (144, 104)),
        ((200, 416), (312, 416), (256, 112)),   # optically lowered
        ((312, 416), (424, 416), (368, 104))]


def svg(bg, colors, rx=0):
    corner = f' rx="{rx}"' if rx else ""
    polys = "".join('<polygon points="%s" fill="%s"/>' % (" ".join(f"{x},{y}" for x, y in t), c)
                    for t, c in zip(TRIS, colors))
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">'
            f'<rect width="512" height="512"{corner} fill="{bg}"/>{polys}</svg>\n')


FILES = {
    "tavlo-mark.svg":            svg(CARAMEL, [BROWN, CREAM, BROWN], rx=112),
    "tavlo-app-icon.svg":        svg(CARAMEL, [BROWN, CREAM, BROWN]),
    "tavlo-app-icon-dark.svg":   svg(ESPRESSO, [CARAMEL, CREAM, CARAMEL]),
    "tavlo-app-icon-tinted.svg": svg("#000000", ["#8a8a8a", "#ffffff", "#8a8a8a"]),
}

if __name__ == "__main__":
    for name, s in FILES.items():
        (OUT / name).write_text(s)
    print("wrote", ", ".join(FILES))
