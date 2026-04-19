+++
title = "Inside Bamboo, a Rust static site generator"
tags = ["rust", "ssg", "bamboo", "tera", "web"]
categories = ["rust"]
excerpt = "Bamboo is the static site generator powering this blog, my homepage, and the nightshade marketing site. Three sites of three different shapes from one default theme."
draft = true
+++

Three sites I run share visual language: this blog, my homepage at [matthewberger.dev](https://matthewberger.dev), and the marketing site for [nightshade](https://matthewberger.dev/nightshade). All three are built with [`bamboo`](https://github.com/matthewjberger/bamboo), a Rust SSG with a default theme that handles blog, portfolio, and product-marketing layouts from a single template tree.

The dogfooding is the whole point. The three sites cover most shapes a personal site needs to take, and using one SSG for all three forces the theme to actually generalize. When something breaks on the portfolio site that I wouldn't have caught on the blog, that's bamboo telling me where to fix it.

## The default theme

Most SSGs let you write any theme. Bamboo does too, but the part I've spent the most time on is the built-in theme that ships baked into the binary. About 19 Tera templates handle every layout shape I've wanted for the three sites: base, index, post, page, collection, slideshow, docs, portfolio, landing, changelog, book, archive, tags, categories, taxonomy, taxonomy term, pagination, 404, and search.

The templates are pulled in via `include_str!` so a fresh `bamboo new my-site` produces a working site with no theme files on disk. Override any template by dropping a file with the same name into a local `themes/` directory. No copy-the-whole-theme inheritance friction.

## Shortcodes

Markdown gets two flavors of shortcode: inline shortcodes that expand to HTML in place, and block shortcodes that wrap a section of already-marked-up content. Both render through Tera templates. Bamboo ships built-in shortcodes for `youtube`, `figure`, `gist`, `pdf`, `note`, and `details`. User shortcodes go in a `templates/shortcodes/` directory and shadow the built-ins, so overriding a built-in is a one-file change rather than a fork.

The interesting design choice is that shortcodes have access to the full site context during expansion. They can resolve internal links, look up other posts, and reference site metadata. That's what makes embedded cross-references and live demos straightforward to write.

## Search, feeds, taxonomies, redirects

Search is client-side. Bamboo generates a `search-index.json` containing every post's title, URL, tags, and excerpt; the default theme's search page consumes that index through Fuse.js. No server, no external service, no third-party tracking.

Feed generation produces RSS 2.0, Atom, and JSON Feed outputs, configurable per content section. The blog gets its own feed; the portfolio gets a different one; the marketing site doesn't generate feeds at all.

Taxonomies are configurable beyond the default tags-and-categories pair. A site can declare its own taxonomy types in `bamboo.toml` and bamboo generates index pages, term pages, and per-term feeds for each.

Redirects are handled through `redirect_from` entries in frontmatter. When a post moves, declaring its old URL keeps the link valid; bamboo writes a small HTML stub at the old path that redirects to the new one.

## Implementation notes

The render step iterates over content in parallel via Rayon. For sites with hundreds of pages this is meaningfully faster than serial rendering.

Markdown extensions (KaTeX math, syntect syntax highlighting, custom callouts, responsive image processing) are off by default and opted into per site. The image processor generates multiple resolution variants from source assets and emits `srcset` attributes so screenshots look correct on high-DPI displays.

The CLI has a `serve` command that watches the content directory, re-renders changed pages, and pushes a refresh through a small WebSocket inject in the rendered output.

The site loader is at [`crates/bamboo/src/site.rs`](https://github.com/matthewjberger/bamboo/blob/main/crates/bamboo/src/site.rs); the rendering engine at [`crates/bamboo/src/theme.rs`](https://github.com/matthewjberger/bamboo/blob/main/crates/bamboo/src/theme.rs). The starter is at [github.com/matthewjberger/bamboo-template](https://github.com/matthewjberger/bamboo-template).

## What's next

The shortcode system is currently compiled in. A WASM-based plugin model would let users write shortcodes in Rust without forking bamboo. Incremental builds would help large sites. Theme inheritance with per-block overrides would help users who want to nudge the default theme rather than replace it. None of these are blocking, which is why they're still on the list.
