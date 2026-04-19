+++
title = "One Rust codebase, six platforms: how nightshade ships everywhere"
tags = ["rust", "wgpu", "wasm", "android", "openxr", "cross-platform", "nightshade"]
categories = ["nightshade"]
excerpt = "Windows, Linux, macOS, web (WebGPU), Android, and OpenXR (Quest 3) from one crate. What that takes in practice."
draft = true
+++

A `State` impl I wrote for nightshade on a Windows desktop with a Vulkan backend will, with no source changes, run in a browser tab against WebGPU, on a Quest 3 through OpenXR, and on an Android phone through the NDK. The shape of the engine code stays identical. What changes is the entry point, the surface creation, and a handful of `cfg`-gated modules that paper over differences the platforms genuinely have.

The same six targets are also covered, without an engine on top, by [`wgpu-example`](https://github.com/matthewjberger/wgpu-example) if you want a smaller reference.

The user-facing entry point is the same on every platform:

```rust
fn main() -> Result<(), Box<dyn std::error::Error>> {
    nightshade::launch(MyGame::default())
}
```

Behind that one line is a different code path per target.

## The three crates that do most of the work

`winit` handles windowing and input. It's as close as the Rust ecosystem gets to a portable window-system abstraction. `wgpu` handles graphics, backed by DX12 on Windows, Vulkan or Metal on Linux and macOS, and WebGPU on the web. `web-time` wraps `std::time` so that browser builds use `performance.now()` under the same `Instant` API the rest of the engine consumes.

Beyond those three, every target has its own pile of platform-specific work.

## Windows, Linux, macOS

The native desktop targets are the easy case. `winit` opens a window, `wgpu` initializes against the platform-native backend (DX12 on Windows, Vulkan or Metal on Linux and macOS), and the rest of the engine works without modification. The audio backend (`kira`) abstracts cpal; physics (`rapier3d`) is portable Rust; egui binds to wgpu through `egui-wgpu`.

Windows-specific touches:
- App icon embedding via `winres` (gated behind `windows-app-icon`)
- Optional Steamworks SDK (`steam` feature) for achievements and multiplayer

macOS-specific:
- Menu bar handling through winit
- Bundle identifier needs to be set for asset access

Linux-specific:
- Wayland and X11 both work (winit handles the dispatch)

## Web (WebGPU)

The web target is where the cross-platform story stops being free.

```toml
[target.'cfg(target_arch = "wasm32")'.dependencies]
console_error_panic_hook = "0.1"
console_log = "1.0"
wasm-bindgen = "0.2"
wasm-bindgen-futures = "0.4"
```

The complications:

1. **Async initialization.** `wgpu::Instance::new()` on the web is async because WebGPU adapter selection is async. The native code path can use `pollster::block_on()`; the web path has to thread async through the entry point.
2. **No file system.** Asset loading switches to `fetch()`-based HTTP requests or drag-and-drop. The `assets` feature is mostly disabled on web.
3. **Audio gating.** Browsers refuse to start audio contexts until the user has interacted with the page. Nightshade auto-initializes audio on the first input event rather than on app start.
4. **No WASI plugins.** The plugin runtime is gated to native targets.
5. **Some wgpu features unavailable.** `MULTI_DRAW_INDIRECT_COUNT` doesn't work on WebGPU yet, so the GPU mesh culling path uses indirect-without-count on web.
6. **Texture sample functions differ.** Some shaders need `textureSampleLevel` instead of `textureSample` on web because the latter is restricted to certain shader stages in WGSL spec on browsers.

The build is a normal `wasm-pack` or `trunk` flow. The site at [matthewberger.dev/nightshade](https://matthewberger.dev/nightshade) runs nightshade-built demos in the browser this way.

## Android

Android adds an extra entry point. Native libraries on Android don't have a `main`; they have a JNI-callable activity. Nightshade exposes:

```rust
#[cfg(target_os = "android")]
#[unsafe(no_mangle)]
fn android_main(app: AndroidApp) {
    android_logger::init_once(/* ... */);
    let event_loop = winit::event_loop::EventLoop::builder()
        .with_android_app(app)
        .build()
        .expect("Failed to create event loop");
    let mut application = App::default();
    event_loop.run_app(&mut application).expect("Failed to run app");
}
```

The build uses `cargo-apk` or a `cargo ndk`-based pipeline. There's a Manifest XML and the usual signing dance. Once those are sorted, the same `State` impl that runs on desktop runs on the phone.

Asset access on Android goes through `AssetManager` rather than the file system. The `filesystem` module in nightshade has Android-specific paths that read assets from the APK.

## OpenXR (Quest 3 + Virtual Desktop)

This is the most involved target. OpenXR is its own session model, render loop, and reference-frame system. Nightshade exposes a separate entry point:

```rust
#[cfg(feature = "openxr")]
fn main() -> Result<(), Box<dyn std::error::Error>> {
    nightshade::launch_xr(MyGame::default())
}
```

What changes under the hood:

- The render loop is driven by `xrWaitFrame`, `xrBeginFrame`, and `xrEndFrame` instead of winit.
- Two views (one per eye) get rendered each frame; the engine submits both to the OpenXR compositor.
- Input comes from the OpenXR action system: head pose, hand poses, triggers, A/B/X/Y buttons. Wrapped in an `XrInput` struct exposed to game code.
- Locomotion is built in (`world.resources.xr.locomotion_enabled = true`).
- The Vulkan backend is required; DX12 and Metal aren't supported by OpenXR runtimes the same way.

I tested this primarily on Meta Quest 3 connected via Virtual Desktop to a Windows machine. The standalone Quest 3 build path works the same way but uses OpenXR's Android runtime.

## Trade-offs

Some features are platform-restricted:

| Feature | Native | Web | Android | OpenXR |
|---|---|---|---|---|
| WASI plugins | yes | no | yes | yes |
| File-system asset loading | yes | no | via AssetManager | yes |
| Async audio gating | n/a | required | n/a | n/a |
| MULTI_DRAW_INDIRECT_COUNT | yes | no | depends | yes |
| Steamworks | yes | no | no | no |
| MCP server | yes | no | no | no |
| Webview (Tauri-style) | yes | no | no | no |

These aren't workarounds I'd love to remove. They're the consequence of the platforms genuinely differing. The engine surfaces them as feature flags so the user knows what they're getting.

## What I learned

The temptation when going cross-platform is to abstract everything into one common interface. The opposite has worked better. Keep platform-specific code in platform-specific modules, gate them with `cfg`, let the shared interface emerge from the parts that actually overlap. The `State` trait and the frame graph are the same on every platform. Everything below them is whatever the platform requires, and trying to hide that hurts more than it helps.

The other thing worth knowing: web is the platform that exposes lazy assumptions. If your code works on web, it almost always works on every other target. Most of the cross-platform bugs I've fixed in nightshade were caught on the web build first.

The cross-platform entry points live in [`crates/nightshade/src/run/`](https://github.com/matthewjberger/nightshade/tree/main/crates/nightshade/src/run); OpenXR support in [`crates/nightshade/src/xr/`](https://github.com/matthewjberger/nightshade/tree/main/crates/nightshade/src/xr); the Android filesystem code in [`filesystem.rs`](https://github.com/matthewjberger/nightshade/blob/main/crates/nightshade/src/filesystem.rs). A minimal cross-platform reference without nightshade on top is at [`wgpu-example`](https://github.com/matthewjberger/wgpu-example), the same six platforms with just wgpu and egui.
