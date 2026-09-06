#!/usr/bin/env python3
"""make_skin_page.py -- turn an image into a server-streamable HTML skin page.

    python3 make_skin_page.py my_livery.png skins/my_livery.html [--size 512] [--quality 82]

The page is nothing but a JPEG data URI stretched over the document; fn_htmlSkin names it
(uniqueName = the file's stem) and fn_htmlSkinClient serves it into the ui2texture display
on every viewer. 512 px JPEG q82 is ~55 KB for a car livery; base64 does not deflate, so
ship it raw. Getting the image out of a .paa is your tool's job (TexView, or any PAA decoder);
this only wants a PNG/JPEG.
"""
import base64, io, sys, argparse
from PIL import Image

ap = argparse.ArgumentParser()
ap.add_argument("image"); ap.add_argument("out")
ap.add_argument("--size", type=int, default=512); ap.add_argument("--quality", type=int, default=82)
a = ap.parse_args()
img = Image.open(a.image).convert("RGB")
src = img.size
img = img.resize((a.size, a.size), Image.LANCZOS)
buf = io.BytesIO(); img.save(buf, "JPEG", quality=a.quality, optimize=True)
b64 = base64.b64encode(buf.getvalue()).decode()
name = a.out.rsplit("/", 1)[-1].rsplit(".", 1)[0]
html = ('<!doctype html><html><head><meta charset="utf-8"><title>%s</title>\n'
        '<!-- server-streamed HTML skin from %s (%dx%d) -> %dx%d JPEG q%d -->\n'
        '<style>html,body{margin:0;width:100%%;height:100%%;overflow:hidden;'
        'background:#000 url(data:image/jpeg;base64,%s) 0 0/100%% 100%% no-repeat}</style>\n'
        '</head><body></body></html>\n') % (name, a.image, src[0], src[1], a.size, a.size, a.quality, b64)
open(a.out, "w").write(html)
print("%s: jpeg %d B, page %d B" % (a.out, len(buf.getvalue()), len(html)))
