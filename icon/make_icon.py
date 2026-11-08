# icon_1024.png üretir:  python3 make_icon.py   (Pillow + numpy gerekir)
from PIL import Image, ImageDraw, ImageFilter
import numpy as np

S = 2048                      # 2x çiz, sonra küçült
def sc(v): return int(v * S / 1024)

# --- Arka plan: köşeleri yuvarlak kare + çapraz gradyan ---
m, r = sc(100), sc(185)
mask = Image.new("L", (S, S), 0)
ImageDraw.Draw(mask).rounded_rectangle([m, m, S - m, S - m], radius=r, fill=255)

y, x = np.mgrid[0:S, 0:S]
t = np.clip((x + y) / (2 * S), 0, 1)[..., None]
c1 = np.array([60, 120, 255]); c2 = np.array([140, 60, 250])
grad = (c1 * (1 - t) + c2 * t).astype(np.uint8)
bg = Image.fromarray(grad, "RGB").convert("RGBA")
bg.putalpha(mask)

img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
img.alpha_composite(bg)

# --- Üst parlama (yumuşak dikey geçiş) ---
yy = np.linspace(0, 1, S)[:, None] * np.ones((1, S))
alpha = (np.clip(1 - yy / 0.55, 0, 1) ** 2 * 55).astype(np.uint8)
gl = np.zeros((S, S, 4), np.uint8); gl[..., :3] = 255; gl[..., 3] = alpha
gloss = Image.fromarray(gl, "RGBA")
gloss.putalpha(Image.fromarray(np.minimum(np.array(gloss.getchannel("A")), np.array(mask)), "L"))
img.alpha_composite(gloss)

# --- Kumanda katmanı ---
def remote_layer():
    L = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(L)
    cx, cy = S // 2, S // 2
    w, h = sc(250), sc(580)
    d.rounded_rectangle([cx - w//2, cy - h//2, cx + w//2, cy + h//2], radius=w//2, fill=(255, 255, 255, 255))
    # D-pad halkası
    pr = sc(86); py = cy - sc(130)
    d.ellipse([cx - pr, py - pr, cx + pr, py + pr], fill=(222, 230, 255, 255))
    ir = sc(36)
    d.ellipse([cx - ir, py - ir, cx + ir, py + ir], fill=(110, 90, 250, 255))
    # yön okları (küçük üçgenler)
    a = sc(11); o = sc(62)
    for dx, dy, pts in [(0, -o, [(0,-a),( a, a),(-a, a)]), (0, o, [(0, a),( a,-a),(-a,-a)]),
                        (-o, 0, [(-a,0),( a,-a),( a, a)]), (o, 0, [(a, 0),(-a,-a),(-a, a)])]:
        d.polygon([(cx + dx + px*1, py + dy + pyy*1) for px, pyy in pts], fill=(110, 90, 250, 255))
    # alt tuşlar
    br = sc(26)
    for i, ox in enumerate([-sc(55), sc(55)]):
        d.ellipse([cx + ox - br, cy + sc(60) - br, cx + ox + br, cy + sc(60) + br], fill=(205, 212, 240, 255))
    for i in range(2):
        by = cy + sc(150) + i * sc(62)
        d.rounded_rectangle([cx - sc(70), by - sc(20), cx + sc(70), by + sc(20)], radius=sc(20), fill=(205, 212, 240, 255))
    return L

R = remote_layer()
# gölge
sh = Image.new("RGBA", (S, S), (0, 0, 0, 0))
sh.putalpha(R.getchannel("A").point(lambda v: int(v * 0.35)))
sh = sh.filter(ImageFilter.GaussianBlur(sc(26)))
sh = Image.composite(sh, Image.new("RGBA", (S, S)), Image.new("L", (S, S), 255))
shifted = Image.new("RGBA", (S, S), (0, 0, 0, 0)); shifted.paste(sh, (0, sc(24)))
tilt = -14
Rr = R.rotate(tilt, resample=Image.BICUBIC, center=(S//2, S//2))
shr = shifted.rotate(tilt, resample=Image.BICUBIC, center=(S//2, S//2))
# Kumandayı biraz sola kaydır
off = -sc(60)
canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))
canvas.alpha_composite(shr, (off, 0)); canvas.alpha_composite(Rr, (off, 0))

# --- Tuş kapağı (sağ alt) + ok ---
kd = ImageDraw.Draw(canvas)
kx, ky, ks = sc(640), sc(560), sc(210)
ksh = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(ksh).rounded_rectangle([kx, ky + sc(16), kx + ks, ky + ks + sc(16)], radius=sc(48), fill=(0, 0, 0, 90))
ksh = ksh.filter(ImageFilter.GaussianBlur(sc(14)))
canvas.alpha_composite(ksh)
kd.rounded_rectangle([kx, ky, kx + ks, ky + ks], radius=sc(48), fill=(255, 255, 255, 255))
kd.rounded_rectangle([kx + sc(14), ky + sc(14), kx + ks - sc(14), ky + ks - sc(14)], radius=sc(36), fill=(238, 241, 255, 255))
# kapak üstünde ok (→)
ax, ay = kx + ks // 2, ky + ks // 2
kd.rounded_rectangle([ax - sc(58), ay - sc(10), ax + sc(18), ay + sc(10)], radius=sc(10), fill=(110, 90, 250, 255))
kd.polygon([(ax + sc(6), ay - sc(40)), (ax + sc(58), ay), (ax + sc(6), ay + sc(40))], fill=(110, 90, 250, 255))

# Çizimi yuvarlak kare içine kırp
cm = Image.new("L", (S, S), 0); cm.paste(mask)
canvas.putalpha(Image.composite(canvas.getchannel("A"), Image.new("L", (S, S), 0), cm))
img.alpha_composite(canvas)

img.resize((1024, 1024), Image.LANCZOS).save("icon_1024.png")
print("icon_1024.png oluşturuldu")
