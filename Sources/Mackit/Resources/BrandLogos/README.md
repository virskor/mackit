# Brand logos

Single-color SVG marks for the developer-tool categories (see
`Sources/Mackit/Models/BrandLogo.swift`), shown in the sidebar, the item list,
and per-item rows.

- **Source** — vendored verbatim from [simple-icons](https://simpleicons.org)
  (v16.35.0, fetched 2026-10-25). File names are the upstream slugs
  (`nodedotjs.svg`, `cocoapods.svg`, ...), so refreshing a mark is a
  byte-for-byte file replacement and diffing against upstream stays trivial.
- **License** — simple-icons' repository is CC0-licensed (the code, i.e. the
  path data). Each mark remains a trademark of its respective owner and is
  used here nominatively: labeling a cache category with the logo of the very
  toolchain it cleans up.
- **Updating** — overwrite the file with the new upstream SVG and rebuild.
  The SVGs are loaded and parsed at runtime (viewBox + every `<path>` `d`
  attribute, via `SVGPath.parse(document:)`); there is no codegen step and no
  duplicated copy of the data anywhere.
- **Adding a logo** — drop the SVG here under its upstream slug, add a case
  to `BrandLogo` (with a `resourceSlug` mapping when the slug differs from
  the case name), and map the category to it in `JunkCategory.brandLogo`.
  The mark must be a single-color, path-only 24×24-style SVG; non-path shapes
  (`rect`, `circle`, ...) are not parsed.
