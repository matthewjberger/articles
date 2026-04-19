+++
title = "wgpu without eframe: a cross-platform Rust starting point"
tags = ["rust", "wgpu", "egui", "wasm", "android", "openxr", "cross-platform"]
categories = ["rust"]
excerpt = "A small reference project for cross-platform Rust apps that need wgpu directly, without eframe in the way."
draft = true
+++

If your app is "egui plus a window," `eframe` is the right tool. It bundles a winit window, the wgpu integration, and a simple application loop, and you don't think about any of it.

If your app does anything else with wgpu, eframe gets in the way. A custom 3D scene, a non-egui rendering pipeline, embedded use inside something that owns its own window, or an OpenXR target that needs a different render-loop model: in all those cases you end up wiring `wgpu`, `winit`, and `egui` together yourself. There's nothing complicated about doing it, but the wiring is fiddly enough that I keep a reference implementation around.

That reference is [`wgpu-example`](https://github.com/matthewjberger/wgpu-example). It runs the same triangle on Windows, Linux, macOS, the web (WebGPU), Android, and OpenXR (Quest 3) from one source tree.

## What's in it

Two files do the work:

- [`src/lib.rs`](https://github.com/matthewjberger/wgpu-example/blob/main/src/lib.rs) covers the desktop, web, and Android entry points, the renderer, and the egui integration
- [`src/xr.rs`](https://github.com/matthewjberger/wgpu-example/blob/main/src/xr.rs) is the OpenXR variant (gated behind a feature)

A `main.rs` that's basically nothing dispatches to the desktop entry point.

The renderer draws a single triangle. The example is about platform setup, not graphics; once the triangle renders on every target, replace it with whatever you actually want to draw.

## The egui integration without eframe

The wiring uses three crates from the egui ecosystem:

- `egui-winit` translates winit events into egui events
- `egui-wgpu` handles wgpu render-pass setup for egui
- `egui` itself is the immediate-mode UI

The setup boils down to creating a wgpu surface from the winit window, an `egui::Context`, an `egui_winit::State` to translate input, and an `egui_wgpu::Renderer` to draw. Each frame: pull input from the State, run the UI in the Context, upload mesh data through the Renderer, then issue the egui draw commands inside whatever wgpu render pass you've set up. The exact constructor signatures change across egui versions, so the canonical reference is the actual `lib.rs` in the repo.

This is roughly what `eframe` does internally. Doing it yourself gives you control over the render-pass structure, which is the reason to skip eframe.

## What changes per platform

The renderer is identical everywhere. The platform pieces are surface creation (HWND on Windows, NSView on macOS, X11/Wayland on Linux, ANativeWindow on Android, canvas on web), init being async on web because WebGPU adapter selection is async, resize coming from winit on native and Android but from DOM events on web, and asset loading switching between `std::fs`, `AssetManager`, and `fetch()`.

Each platform-specific block is gated with `cfg`. Reading the source you can see exactly what runs where.

## OpenXR

The OpenXR render loop is fundamentally different from a winit-driven loop. Instead of "winit gives you events, you draw, you present," OpenXR is:

```text
xrWaitFrame    wait for the compositor to be ready
xrBeginFrame   begin recording
  for each view (one per eye):
    record rendering commands
xrEndFrame     submit
```

Two views per frame, one per eye, into per-eye render targets. The compositor handles presentation. The view configuration provides per-eye projection and view matrices. wgpu has to use Vulkan as its backend; mainstream OpenXR runtimes don't support DX12 or Metal.

## Try it

```bash
cargo run                                   # native
trunk serve                                 # web
cargo apk run --release                     # Android (with NDK)
cargo run --features openxr --bin xr-example
```

Permissively licensed (MIT/Apache). It's an example, not a framework. Copy what you need.
