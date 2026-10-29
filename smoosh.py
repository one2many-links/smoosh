#!/usr/bin/env python3
"""Smoosh: perkecil ukuran file di macOS tanpa menurunkan kualitas.

Pakai: python3 smoosh.py [--pdf lossless|high|small] [--video] [-o FOLDER] file_atau_folder ...
Tampilan: Smoosh.app (SwiftUI) memanggil file ini dengan --json.

File asli tidak pernah diubah. Hasil disimpan ke folder baru, dan hanya
disimpan kalau memang lebih kecil dari aslinya.
"""
import argparse
import json
import os
import shutil
import struct
import subprocess
import tempfile
import zlib
from pathlib import Path

PNG_SIG = b"\x89PNG\r\n\x1a\n"
JPEG_EXT = {".jpg", ".jpeg"}
VIDEO_EXT = {".mp4", ".mov", ".m4v"}
SUPPORTED = {".png", ".pdf"} | JPEG_EXT | VIDEO_EXT

PDF_MODES = {
    "lossless": "Lossless: isi PDF identik, hemat sedikit",
    "high": "Kualitas tinggi: gambar maks 300 dpi, hemat lebih banyak",
    "small": "Hemat: gambar maks 150 dpi, ukuran paling kecil",
}


def which(name):
    return shutil.which(name) or next(
        (f"{d}/{name}" for d in ("/opt/homebrew/bin", "/usr/local/bin") if os.access(f"{d}/{name}", os.X_OK)),
        None,
    )


def need(name):
    path = which(name)
    if not path:
        raise RuntimeError(f"butuh {name} (brew install {name})")
    return path


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True)


# ---------- PNG: susun ulang data piksel dengan deflate terbaik (lossless) ----------

def png_chunks(data):
    pos = 8
    while pos < len(data):
        (length,) = struct.unpack(">I", data[pos:pos + 4])
        yield data[pos + 4:pos + 8], data[pos + 8:pos + 8 + length]
        pos += 12 + length


def png_chunk(ctype, body):
    crc = zlib.crc32(ctype + body) & 0xFFFFFFFF
    return struct.pack(">I", len(body)) + ctype + body + struct.pack(">I", crc)


def compress_png(src, dst, **_):
    oxipng = which("oxipng")
    if oxipng:
        return run([oxipng, "-o", "max", "--strip", "safe", "--out", str(dst), str(src)]).returncode == 0
    data = Path(src).read_bytes()
    if not data.startswith(PNG_SIG):
        return False
    chunks = list(png_chunks(data))
    raw = zlib.decompress(b"".join(b for t, b in chunks if t == b"IDAT"))
    best = None
    for strategy in (zlib.Z_DEFAULT_STRATEGY, zlib.Z_FILTERED):
        c = zlib.compressobj(9, zlib.DEFLATED, 15, 9, strategy)
        out = c.compress(raw) + c.flush()
        if best is None or len(out) < len(best):
            best = out
    result, wrote = [PNG_SIG], False
    for t, b in chunks:
        if t == b"IDAT":
            if not wrote:
                result.append(png_chunk(b"IDAT", best))
                wrote = True
        else:
            result.append(png_chunk(t, b))
    Path(dst).write_bytes(b"".join(result))
    return True


# ---------- JPEG: jpegtran, hasil piksel identik ----------

def compress_jpeg(src, dst, **_):
    tool = need("jpegtran")
    return run([tool, "-copy", "all", "-optimize", "-progressive", "-outfile", str(dst), str(src)]).returncode == 0


# ---------- PDF (pikepdf = qpdf + pengolah gambar) ----------

PDF_TARGET = {"high": (300, 90), "small": (150, 75)}  # (dpi maks, kualitas JPEG)


def downsample_images(pdf, max_dpi, quality):
    """Kecilkan gambar yang resolusinya di atas max_dpi. Gambar yang sudah di bawahnya tidak disentuh."""
    import io

    from pikepdf import Name, PdfImage
    from PIL import Image

    seen = set()
    for page in pdf.pages:
        w, h = (float(page.mediabox[2] - page.mediabox[0]), float(page.mediabox[3] - page.mediabox[1]))
        long_side_in = max(w, h) / 72  # perkiraan aman: tidak pernah menurunkan resolusi lebih dari yang perlu
        for raw in page.get_images().values():
            if raw.objgen in seen:
                continue
            seen.add(raw.objgen)
            try:
                if raw.get("/ImageMask") or "/Mask" in raw:
                    continue
                img = PdfImage(raw)
                dpi = max(img.width, img.height) / long_side_in
                if dpi <= max_dpi * 1.05:
                    continue
                pil = img.as_pil_image()
                if pil.mode not in ("RGB", "L"):
                    continue
                scale = max_dpi / dpi
                small = pil.resize((max(1, round(pil.width * scale)), max(1, round(pil.height * scale))), Image.LANCZOS)
                buf = io.BytesIO()
                small.save(buf, "JPEG", quality=quality, optimize=True)
                if len(buf.getvalue()) >= len(raw.read_raw_bytes()):
                    continue
                raw.write(buf.getvalue(), filter=Name.DCTDecode, decode_parms=None)
                raw.Width, raw.Height = small.size
                raw.ColorSpace = Name.DeviceGray if small.mode == "L" else Name.DeviceRGB
                raw.BitsPerComponent = 8
                if "/Decode" in raw:
                    del raw["/Decode"]
            except Exception:
                continue


def compress_pdf(src, dst, pdf_mode="lossless", **_):
    try:
        import pikepdf
    except ImportError:
        raise RuntimeError("butuh pikepdf (pip3 install pikepdf)")
    pikepdf.settings.set_flate_compression_level(9)
    with pikepdf.open(src) as pdf:
        if pdf_mode != "lossless":
            downsample_images(pdf, *PDF_TARGET[pdf_mode])
        pdf.save(dst, compress_streams=True, recompress_flate=True,
                 object_stream_mode=pikepdf.ObjectStreamMode.generate)
    return True


# ---------- Video: HEVC CRF rendah (hampir tanpa kehilangan, bukan lossless murni) ----------

def compress_video(src, dst, **_):
    r = run([need("ffmpeg"), "-y", "-v", "error", "-i", str(src), "-map", "0:v:0", "-map", "0:a?",
             "-c:v", "libx265", "-crf", "18", "-preset", "medium", "-tag:v", "hvc1",
             "-c:a", "copy", "-movflags", "+faststart", "-f", "mp4", str(dst)])
    return r.returncode == 0


def compress_one(src, dst_dir, pdf_mode="lossless", use_video=False):
    """Return (status, sebelum, sesudah, catatan). Status: ok / optimal / lewati / gagal."""
    src = Path(src)
    ext = src.suffix.lower()
    if ext == ".png":
        fn = compress_png
    elif ext in JPEG_EXT:
        fn = compress_jpeg
    elif ext == ".pdf":
        fn = compress_pdf
    elif ext in VIDEO_EXT and use_video:
        fn = compress_video
    else:
        return "lewati", 0, 0, "dilewati" if ext in SUPPORTED else "tidak didukung"
    before = src.stat().st_size
    out_ext = ".mp4" if ext in VIDEO_EXT else ext
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td) / ("out" + out_ext)
        try:
            ok = fn(src, tmp, pdf_mode=pdf_mode)
        except RuntimeError as e:
            return "gagal", before, 0, str(e)
        except Exception as e:
            return "gagal", before, 0, f"error: {e}"
        if not ok or not tmp.exists():
            return "gagal", before, 0, "gagal diproses"
        after = tmp.stat().st_size
        if after >= before:
            return "optimal", before, after, "sudah optimal"
        dst_dir.mkdir(parents=True, exist_ok=True)
        shutil.move(str(tmp), dst_dir / (src.stem + out_ext))
    return "ok", before, after, ""


def result_root(f, base, out):
    """Folder hasil teratas: folder dipetakan ke <nama>_terkompres, file tunggal ke 'Terkompres'."""
    if base:
        return Path(out) / base.name if out else base.parent / (base.name + "_terkompres")
    return Path(out) if out else f.parent / "Terkompres"


def dest_dir(f, base, out):
    root = result_root(f, base, out)
    return root / f.parent.relative_to(base) if base else root


def expand(paths):
    """Yield (file, base) untuk file yang didukung; base = folder induk yang dipilih, atau None."""
    for p in map(Path, paths):
        if p.is_dir():
            for f in sorted(p.rglob("*")):
                hidden = any(part.startswith(".") for part in f.relative_to(p).parts)
                if f.is_file() and not hidden and f.suffix.lower() in SUPPORTED and "_terkompres" not in f.parts[len(p.parts):]:
                    yield f, p
        elif p.is_file() and p.suffix.lower() in SUPPORTED:
            yield p, None


def human(n):
    for u in ("B", "KB", "MB", "GB"):
        if n < 1024:
            return f"{n:.0f} {u}" if u == "B" else f"{n:.1f} {u}"
        n /= 1024
    return f"{n:.1f} TB"


def describe(status, before, after, note):
    if status == "ok":
        return f"{human(before)} → {human(after)}   −{100 * (before - after) / before:.1f}%"
    return note


def main():
    ap = argparse.ArgumentParser(description="Kompres file tanpa menurunkan kualitas.")
    ap.add_argument("paths", nargs="+")
    ap.add_argument("-o", "--output", help="folder tujuan")
    ap.add_argument("--pdf", choices=list(PDF_MODES), default="lossless", help="mode kualitas PDF")
    ap.add_argument("--video", action="store_true", help="sertakan video (HEVC CRF 18)")
    ap.add_argument("--json", action="store_true", help="satu baris JSON per file (dipakai aplikasi)")
    ap.add_argument("--list", action="store_true", help="daftar file yang didukung, tanpa mengompres")
    ap.add_argument("--base", help="folder induk, agar struktur folder ikut dipetakan")
    a = ap.parse_args()

    if a.base:
        items = [(Path(p), Path(a.base)) for p in a.paths]
    else:
        items = list(expand(a.paths))

    if a.list:
        for f, base in items:
            print(json.dumps({"path": str(f), "base": str(base) if base else None, "size": f.stat().st_size}), flush=True)
        return

    tb = ta = 0
    for f, base in items:
        status, b, af, note = compress_one(f, dest_dir(f, base, a.output), a.pdf, a.video)
        if status == "ok":
            tb, ta = tb + b, ta + af
        if a.json:
            print(json.dumps({"path": str(f), "status": status, "before": b, "after": af, "note": note,
                              "out": str(result_root(f, base, a.output))}), flush=True)
        else:
            print(f"{f.name}: {describe(status, b, af, note)}")
    if tb and not a.json:
        print(f"\nTotal hemat {human(tb - ta)} ({100 * (tb - ta) / tb:.1f}%)")


if __name__ == "__main__":
    main()
