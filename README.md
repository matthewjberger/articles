# Articles

Long-form notes on the systems I write in my own time. Game engines, graphics, language design, derive macros, cross-platform Rust, and the libraries that fall out of all of it. Deployed at [matthewberger.dev/articles](https://matthewberger.dev/articles), built with [bamboo](https://github.com/matthewjberger/bamboo).

## Prerequisites

```sh
cargo install bamboo-cli
cargo install just
```

## Development

```sh
just serve   # live-reload server at http://localhost:3000
just build   # one-shot build to dist/
```

## Structure

```
.
├── bamboo.toml              # Site config + [extra.author_profile]
├── content/
│   ├── _index.md            # Home (landing blurb)
│   ├── about.md
│   ├── archive.md           # Posts-by-year archive
│   ├── categories.md        # Posts-by-category archive
│   ├── tags.md              # Posts-by-tag archive
│   └── posts/               # Blog posts (YYYY-MM-DD-title.md)
└── static/                  # Copied verbatim to the output root
    └── bio-photo.jpg
```

New posts go in `content/posts/` with a date-prefixed filename and TOML frontmatter. Set `draft = true` to keep a post in source control without publishing it; remove the line (or set to `false`) when it's ready.

```markdown
+++
title = "My Post"
tags = ["rust"]
categories = ["engineering"]
excerpt = "One-line summary shown in cards."
draft = true
+++

Markdown body here.
```

## License

Dual-licensed under [Apache 2.0](LICENSE-APACHE) and [MIT](LICENSE-MIT) at your option.
