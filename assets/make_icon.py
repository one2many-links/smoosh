"""Gambar logo aplikasi dan buat AppIcon.icns (python3 make_icon.py)."""
import subprocess, shutil, tempfile
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter

N = 1024
here = Path(__file__).parent

def gradient(size, c1, c2):
    g = Image.new("RGB", (1, size))
    for y in range(size):
        t = y / (size - 1)
        g.putpixel((0, y), tuple(int(c1[i] + (c2[i] - c1[i]) * t) for i in range(3)))
    return g.resize((size, size))

# latar: squircle macOS (margin 100px) bergradasi
S = 4
big = N * S
mask = Image.new("L", (big, big), 0)
ImageDraw.Draw(mask).rounded_rectangle([100 * S, 100 * S, (N - 100) * S, (N - 100) * S], radius=185 * S, fill=255)
mask = mask.resize((N, N), Image.LANCZOS)
icon = Image.new("RGBA", (N, N), (0, 0, 0, 0))
icon.paste(gradient(N, (99, 102, 241), (20, 184, 166)), (0, 0), mask)

# bayangan + gambar utama pada layer 4x agar halus
def layer():
    return Image.new("RGBA", (big, big), (0, 0, 0, 0))
def P(*pts):
    return [(x * S, y * S) for x, y in pts]

doc = layer()
d = ImageDraw.Draw(doc)
x0, y0, x1, y1, fold = 340, 300, 684, 724, 100
d.polygon(P((x0, y0), (x1 - fold, y0), (x1, y0 + fold), (x1, y1), (x0, y1)), fill=(255, 255, 255, 255))
d.polygon(P((x1 - fold, y0), (x1, y0 + fold), (x1 - fold, y0 + fold)), fill=(199, 210, 254, 255))
for i, w in enumerate((0.70, 0.70, 0.45)):
    yy = 470 + i * 66
    d.rounded_rectangle(P((x0 + 48, yy), (x0 + 48 + (x1 - x0 - 96) * w, yy + 26)), radius=13 * S, fill=(99, 102, 241, 255))

arrows = layer()
a = ImageDraw.Draw(arrows)
for sign in (1, -1):  # panah dari atas dan bawah menuju dokumen
    tip = 512 - sign * 258
    cy = tip - sign * 64
    a.line(P((440, cy), (512, tip), (584, cy)), fill=(255, 255, 255, 255), width=34 * S, joint="curve")
    for px in (440, 584):
        a.ellipse([(px - 17) * S, (cy - 17) * S, (px + 17) * S, (cy + 17) * S], fill=(255, 255, 255, 255))
    a.ellipse([(512 - 17) * S, (tip - 17) * S, (512 + 17) * S, (tip + 17) * S], fill=(255, 255, 255, 255))

art = Image.alpha_composite(doc, arrows).resize((N, N), Image.LANCZOS)
shadow = Image.new("RGBA", (N, N), (0, 0, 0, 0))
shadow.putalpha(art.getchannel("A").point(lambda v: int(v * 0.35)))
shadow = shadow.filter(ImageFilter.GaussianBlur(18))
icon = Image.alpha_composite(icon, shadow.transform((N, N), Image.AFFINE, (1, 0, 0, 0, 1, -14)))
icon = Image.alpha_composite(icon, art)
icon.save(here / "icon_1024.png")
icon.resize((128, 128), Image.LANCZOS).save(here / "logo_128.png")

with tempfile.TemporaryDirectory() as td:
    iset = Path(td) / "AppIcon.iconset"
    iset.mkdir()
    for s in (16, 32, 128, 256, 512):
        icon.resize((s, s), Image.LANCZOS).save(iset / f"icon_{s}x{s}.png")
        icon.resize((s * 2, s * 2), Image.LANCZOS).save(iset / f"icon_{s}x{s}@2x.png")
    subprocess.run(["iconutil", "-c", "icns", str(iset), "-o", str(here / "AppIcon.icns")], check=True)
print("ok")
