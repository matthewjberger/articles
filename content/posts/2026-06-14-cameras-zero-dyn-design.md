+++
title = "Compile-time backend dispatch for a cross-platform camera library"
tags = ["rust", "cameras", "library-design", "cross-platform"]
categories = ["rust"]
excerpt = "How the cameras crate dispatches to AVFoundation, Media Foundation, and V4L2 at compile time, without a single trait object."
draft = true
+++

A cross-platform library has to do roughly the same things on every platform but reach into wildly different APIs to do them. The conventional Rust answer is a `Box<dyn Backend>` that dispatches at runtime. [`cameras`](https://github.com/matthewjberger/cameras), my Rust library for video capture, doesn't do that. It targets macOS via AVFoundation, Windows via Media Foundation and DirectShow, and Linux via V4L2, with zero trait objects anywhere in the codebase. Every platform-specific dispatch happens at compile time.

## Why dyn doesn't earn its keep here

The conventional `dyn Backend` shape looks like this:

```rust
trait Backend {
    fn devices(&self) -> Result<Vec<Device>, Error>;
    fn probe(&self, id: &DeviceId) -> Result<Capabilities, Error>;
    fn open(&self, id: &DeviceId, config: StreamConfig) -> Result<Camera, Error>;
}

fn make_backend() -> Box<dyn Backend> { /* return platform impl */ }
```

The four operations every camera library needs (enumerate devices, probe capabilities, open a stream, deliver frames) all go through that v-table. Which is fine, except the backend choice is fixed at compile time. A build of `cameras` is never going to dispatch between AVFoundation and V4L2 at runtime; the two don't even compile on the same target. You're paying for runtime polymorphism nobody will ever use.

## What cameras does instead

The crate defines a `Backend` trait with associated types:

```rust
pub trait Backend {
    type SessionHandle;
    fn devices() -> Result<Vec<Device>, Error>;
    fn probe(id: &DeviceId) -> Result<Capabilities, Error>;
    fn open(id: &DeviceId, config: StreamConfig) -> Result<Camera, Error>;
    fn monitor() -> Result<DeviceMonitor, Error>;
}
```

Every method is an associated function (no `&self`). The trait exists only so the compiler can verify that every platform implements the same surface. There's no value of `dyn Backend` anywhere in the library.

Then a single `cfg`-gated type alias selects the active backend:

```rust
#[cfg(target_os = "macos")]
pub type ActiveBackend = macos::MacosDriver;

#[cfg(target_os = "windows")]
pub type ActiveBackend = windows::WindowsDriver;

#[cfg(target_os = "linux")]
pub type ActiveBackend = linux::LinuxDriver;
```

Public free functions at the crate root dispatch through this alias:

```rust
pub fn devices() -> Result<Vec<Device>, Error> {
    ActiveBackend::devices()
}

pub fn probe(id: &DeviceId) -> Result<Capabilities, Error> {
    ActiveBackend::probe(id)
}
```

The user calls `cameras::devices()`. The compiler resolves `ActiveBackend` to the right struct for the current target. The platform impl runs directly. There is no v-table lookup. There is no boxing.

## What this buys you

Every camera call becomes a method call to a known type, fully inlinable. The hot path of `next_frame` doesn't pay for a virtual dispatch on every invocation.

A user reading `cameras::devices` in the docs sees the function signature and can trace it directly to the platform-conditional implementation. There's no abstraction layer hiding which platform path runs.

Adding a method to `Backend` forces every platform impl to provide it. If one is missing, the build breaks at the platform module, not at the call site. Every platform stays in lockstep with the contract by construction.

Backends correspond to operating system APIs, not user choice, so the set is finite and known at compile time. That's the case the design is built around.

## Companion features without breaking the model

The same pattern extends to optional capabilities. The `controls` feature adds a `BackendControls` sub-trait:

```rust
#[cfg(feature = "controls")]
pub trait BackendControls: Backend {
    fn control_capabilities(id: &DeviceId) -> Result<ControlCapabilities, Error>;
    fn read_controls(id: &DeviceId) -> Result<Controls, Error>;
    fn apply_controls(id: &DeviceId, controls: &Controls) -> Result<(), Error>;
}
```

Brightness, contrast, exposure, focus, zoom, pan, tilt, all routed through the same compile-time pattern. The free functions at the crate root that wrap controls call into the `ActiveBackend` directly. Adding a new feature flag (say, `mtp` for camera-tethered control) follows the same template: define a sub-trait, gate it on a feature, implement it per platform, expose free functions.

## The platform-specific work

Where the library doesn't try to abstract is the inside of each backend. The Windows implementation in [`crates/cameras/src/windows.rs`](https://github.com/matthewjberger/cameras/blob/main/crates/cameras/src/windows.rs) is Media Foundation and DirectShow code: COM initialization, IMFMediaSource enumeration, IMFSourceReader configuration, IAMCameraControl and IAMVideoProcAmp for runtime parameters, async sample callbacks delivering frames into a crossbeam channel. None of it is portable, and none of it tries to be.

The macOS implementation has the same shape: AVCaptureSession, AVCaptureDeviceInput, AVCaptureVideoDataOutput delegate, all bridged through `objc2`. Structured into [`src/macos/`](https://github.com/matthewjberger/cameras/tree/main/crates/cameras/src/macos) submodules (controls, delegate, enumerate, monitor, permission, session).

V4L2 on Linux is the simplest: ioctl-driven device enumeration via `/dev/video*`, format negotiation through `VIDIOC_S_FMT`, frames pulled via `VIDIOC_DQBUF`.

The user-facing API is identical across all three.

## Frame delivery and ownership

A `Camera` owns a worker thread that drives the platform's frame delivery API. Frames flow into a bounded crossbeam channel. The consumer pulls them with a timeout via `next_frame(&camera, Duration::from_secs(2))`. If the consumer falls behind, old frames are dropped rather than buffered. Real-time consumers usually want the latest frame more than they want a complete history.

When the `Camera` is dropped, the worker shuts down via an atomic flag and the platform session is torn down in the order each platform requires.

## When this pattern generalizes

The compile-time-selected type alias plus a free-function facade works for any cross-platform library where the set of backends is finite and known at compile time, each backend corresponds to a target OS rather than a user choice, and the trait surface is small enough that users mostly call free functions instead of implementing the trait themselves.

If any of those isn't true (user-supplied backends, runtime-dynamic backend choice), `dyn Backend` is the right answer. For everything else, the compile-time path is cheaper and clearer.

The trait is at [`src/backend.rs`](https://github.com/matthewjberger/cameras/blob/main/crates/cameras/src/backend.rs); platform implementations at [`src/macos/`](https://github.com/matthewjberger/cameras/tree/main/crates/cameras/src/macos), [`src/windows.rs`](https://github.com/matthewjberger/cameras/blob/main/crates/cameras/src/windows.rs), and [`src/linux.rs`](https://github.com/matthewjberger/cameras/blob/main/crates/cameras/src/linux.rs).
