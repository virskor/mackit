#!/usr/bin/env python3
"""Write per-size HTML pages for the sparkle SVG (no subprocess, no shell)."""
import pathlib

base = pathlib.Path("/Users/weizhang/Projects/Mackit/Assets/sparkle")
svg = (base / "sparkle-blue.svg").read_text()

template = """<!DOCTYPE html>
<html><head><meta charset="utf-8"><style>
html,body{{margin:0;padding:0;width:{s}px;height:{s}px;overflow:hidden;background:transparent;}}
svg{{display:block;width:{s}px;height:{s}px;}}
</style></head><body>{svg}</body></html>"""

for s in [16, 24, 32, 48, 64, 128, 256, 512, 1024]:
    page = base / ("_page-%d.html" % s)
    page.write_text(
        template.format(s=s, svg=svg.replace('width="24" height="24"', 'width="%d" height="%d"' % (s, s), 1))
    )
    print(page.name)
