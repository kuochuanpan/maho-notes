---
title: 6. Images & Assets
tags: [tutorial]
created: 2026-03-14T00:00:00-05:00
updated: 2026-03-14T00:00:00-05:00
public: false
---

# 6. Images & Assets

Maho Notes stores images alongside your notes in an `_assets/` folder within each collection.

## Adding Images

Drag and drop an image into the editor, or paste from your clipboard. Maho Notes automatically:

1. Saves the image to the collection's `_assets/` folder
2. Inserts the markdown reference for you

## Image Syntax

Standard markdown images work as expected:

```markdown
![A beautiful sunset](_assets/sunset.png)
```

Here's what that looks like rendered:

![A beautiful sunset](_assets/sunset.png)

Maho Notes also supports **alignment** and **width** controls:

```markdown
![Photo|center|80%](_assets/desk-plant.png)
![Diagram|right|50%](_assets/diagram.png)
```

![A cozy desk scene|center|80%](_assets/desk-plant.png)

![Knowledge graph|right|50%](_assets/diagram.png)

- **Alignment**: `left`, `center`, or `right`
- **Width**: `25%` to `100%` of the content area

## Asset Management

When you move or copy a note to another collection, its referenced assets are moved or copied along with it. Your images always stay with your notes.

## Supported Formats

Maho Notes supports common image formats: PNG, JPEG, GIF, WebP, and SVG.
