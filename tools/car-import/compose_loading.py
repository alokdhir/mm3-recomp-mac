"""Lay a rendered car over MM3's loading screen, in its blue night style.

    python compose_loading.py hero.png Default_Koenigsegg.tga out.tga

hero.png: render_hero.py's transparent render. The second file is a retail
640x480 loading screen (Data_dvd.zip LoadingScreens/Default_*.tga): its top
band and logo are kept, the donor car below fades into navy, and the new car
is graded blue to match. The output is the same 24-bit TGA the game reads,
for a package's LoadingScreens/Default_<alias>.tga.
"""
import sys
from PIL import Image, ImageChops, ImageEnhance, ImageFilter

hero_path, screen_path, out_path = sys.argv[1:4]
screen = Image.open(screen_path).convert("RGB")
car = Image.open(hero_path).convert("RGBA")
car = car.crop(car.getbbox())

navy = Image.new("RGB", (640, 480))
px = navy.load()
for y in range(480):
    t = y / 479
    for x in range(640):
        px[x, y] = (int(22 - 10 * t), int(30 - 12 * t), int(72 - 30 * t))
city = ImageEnhance.Brightness(screen.filter(ImageFilter.GaussianBlur(6))).enhance(0.7)
fade = Image.new("L", (640, 480))
fp = fade.load()
for y in range(480):
    for x in range(640):
        fp[x, y] = 0 if y < 175 else min(255, (y - 175) * 5)
frame = Image.composite(navy, Image.composite(city, screen, fade.point(lambda v: min(255, v * 3))), fade)

r, g, b, a = car.split()
rgb = Image.merge("RGB", (r, g, b))
grey = rgb.convert("L")
blue = Image.merge("RGB", (grey.point(lambda v: int(v * 0.80)), grey.point(lambda v: int(v * 0.88)),
                           grey.point(lambda v: min(255, int(v * 1.08 + 12)))))
car = Image.merge("RGBA", (*Image.blend(rgb, blue, 0.55).split(), a))
width = 600
height = int(car.height * width / car.width)
if height > 300:
    width, height = int(width * 300 / height), 300
car = car.resize((width, height), Image.LANCZOS)
frame.paste(car, ((640 - width) // 2 + 10, 480 - height - 14), car)

# The logo back on top: its bright and saturated pixels from the original.
logo = screen.crop((40, 40, 600, 200))
_, sat, val = logo.convert("HSV").split()
mask = ImageChops.lighter(ImageChops.multiply(sat, val).point(lambda v: 255 if v > 60 else 0),
                          val.point(lambda v: 255 if v > 200 else 0))
frame.paste(logo, (40, 40), mask.filter(ImageFilter.MaxFilter(3)).filter(ImageFilter.GaussianBlur(1)))
frame.save(out_path)
