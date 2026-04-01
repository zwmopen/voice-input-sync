from pathlib import Path

from PIL import Image, ImageDraw


SIZE = 256
BG_START = (63, 134, 255)
BG_END = (31, 77, 201)
WHITE = (255, 255, 255, 255)


def mix_color(left, right, ratio):
    return tuple(int(left[i] + (right[i] - left[i]) * ratio) for i in range(3))


def build_gradient(size):
    gradient = Image.new("RGBA", (size, size))
    pixels = gradient.load()
    for y in range(size):
        for x in range(size):
            ratio = (x + y) / (2 * (size - 1))
            pixels[x, y] = mix_color(BG_START, BG_END, ratio) + (255,)
    return gradient


def main():
    output_dir = Path(__file__).resolve().parent / "assets"
    output_dir.mkdir(parents=True, exist_ok=True)

    canvas = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    mask = Image.new("L", (SIZE, SIZE), 0)
    mask_draw = ImageDraw.Draw(mask)
    mask_draw.rounded_rectangle((12, 12, SIZE - 12, SIZE - 12), radius=56, fill=255)

    gradient = build_gradient(SIZE)
    canvas = Image.composite(gradient, canvas, mask)
    draw = ImageDraw.Draw(canvas)

    # Add a soft highlight so the Windows icon feels less flat.
    draw.ellipse((34, 26, 196, 138), fill=(255, 255, 255, 28))
    draw.ellipse((146, 148, 224, 226), fill=(255, 255, 255, 20))

    draw.ellipse((92, 54, 164, 126), fill=WHITE)
    draw.rounded_rectangle((96, 120, 160, 178), radius=30, fill=WHITE)
    draw.arc((80, 84, 176, 180), start=0, end=180, fill=WHITE, width=14)
    draw.line((128, 178, 128, 204), fill=WHITE, width=14)
    draw.rounded_rectangle((94, 202, 162, 216), radius=7, fill=WHITE)

    png_path = output_dir / "voice-sync-icon.png"
    ico_path = output_dir / "voice-sync-icon.ico"

    canvas.save(png_path, format="PNG")
    canvas.save(
        ico_path,
        format="ICO",
        sizes=[(256, 256), (128, 128), (64, 64), (48, 48), (32, 32), (16, 16)],
    )

    print(f"Generated icon: {ico_path}")


if __name__ == "__main__":
    main()
