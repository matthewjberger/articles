# Articles

Technical writing on Rust, embedded systems, robotics, and software engineering. Deployed at [matthewberger.dev/articles](https://matthewberger.dev/articles), built with [bamboo](https://github.com/matthewjberger/bamboo).

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

New posts go in `content/posts/` with a date-prefixed filename and TOML frontmatter:

```markdown
+++
title = "My Post"
date = "2024-05-01"
tags = ["rust"]
categories = ["engineering"]
excerpt = "One-line summary shown in cards."
+++

Markdown body here.
```

## License

MIT.
