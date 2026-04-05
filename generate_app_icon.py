from pathlib import Path

from PIL import Image


SIZE = 512


def main():
    project_root = Path(__file__).resolve().parent
    assets_dir = project_root / "assets"
    source_path = assets_dir / "voice-sync-icon-source.png"
    png_path = assets_dir / "voice-sync-icon.png"
    ico_path = assets_dir / "voice-sync-icon.ico"

    if not source_path.exists():
        raise FileNotFoundError(f"Missing icon source: {source_path}")

    with Image.open(source_path) as source:
        icon = source.convert("RGBA")
        if icon.size != (SIZE, SIZE):
            icon = icon.resize((SIZE, SIZE), Image.Resampling.LANCZOS)

        icon.save(png_path, format="PNG")
        icon.save(
            ico_path,
            format="ICO",
            sizes=[(256, 256), (128, 128), (64, 64), (48, 48), (32, 32), (16, 16)],
        )

    print(f"Generated icon: {ico_path}")


if __name__ == "__main__":
    main()
