#!/usr/bin/env python3
from pathlib import Path
from PIL import Image, ImageDraw
import sys

source = Path(sys.argv[1])
destination = Path(sys.argv[2])
destination.mkdir(parents=True, exist_ok=True)
pages = sorted(source.glob("page-*.png"))
per_sheet = 12
thumb_width = 360

for sheet_index in range(0, len(pages), per_sheet):
    selected = pages[sheet_index:sheet_index + per_sheet]
    thumbs = []
    for page in selected:
        image = Image.open(page).convert("RGB")
        height = round(image.height * thumb_width / image.width)
        image.thumbnail((thumb_width, height), Image.Resampling.LANCZOS)
        thumbs.append((page.name, image.copy()))
    cell_height = max(image.height for _, image in thumbs) + 34
    sheet = Image.new("RGB", (thumb_width * 3, cell_height * 4), "#b9c0c8")
    draw = ImageDraw.Draw(sheet)
    for index, (name, image) in enumerate(thumbs):
        x = (index % 3) * thumb_width
        y = (index // 3) * cell_height
        sheet.paste(image, (x, y + 24))
        draw.text((x + 6, y + 5), name, fill="black")
    output = destination / f"contact-{sheet_index // per_sheet + 1:02d}.jpg"
    sheet.save(output, quality=90)
