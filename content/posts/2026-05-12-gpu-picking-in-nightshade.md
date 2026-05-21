+++
title = "GPU picking in nightshade"
tags = ["rust", "wgpu", "rendering", "game-engine"]
categories = ["rust"]
excerpt = "How nightshade answers \"what is under the cursor, where in the world is it, and what is the surface normal there\" using a multiple-render-target mesh pass, a compute shader that samples a 5x5 window of the depth and entity-id textures, and an async readback."
+++

Picking is the rendering problem of answering two questions every time the mouse moves. Which entity is under the cursor, and what is the 3D point on that entity's surface where the cursor is hitting. The first one alone is enough to do selection. Both together let you drop a decal at exactly the spot you clicked, paint terrain at the cursor, or anchor a tooltip at a world-space point that sits on the model instead of floating in front of it.

You can answer both on the CPU by raycasting through your scene. Build a ray from the camera through the cursor pixel, intersect it against every entity's bounding volume to get candidates, then against every triangle of every candidate to find the closest hit. The math is well understood. The cost scales with scene size and goes up if your models have a lot of triangles. It also requires the CPU to know about every renderable thing in the scene with enough detail to intersect rays. Animated skinned meshes, instanced meshes, lines, decals, terrain LODs. The renderer already knows about all of that, because it just drew them. Picking on the GPU reuses that work.

This post walks through how [nightshade](https://github.com/matthewjberger/nightshade) does it. End state is a 5x5 sample around the cursor that resolves to a world position, a world-space surface normal, and the entity id of whatever drew that pixel. The CPU work is bounded (under a hundred lines of arithmetic) and the GPU work is the same depth and entity-id textures the renderer was already producing. No raycasts.

The runnable example is the `apps/picking` demo in the nightshade repo. It has both modes side by side. CPU hover uses the bounding-volume raycast path. GPU hover uses what is described below.

## Two render targets that already exist

The mesh pass in nightshade is a multiple-render-target pass. It writes to three color attachments plus a depth attachment. The fragment shader output looks like this:

```wgsl
struct FragmentOutput {
    @location(0) color: vec4<f32>,
    @location(1) entity_id: f32,
    @location(2) view_normal: vec4<f32>,
};
```

Color goes to the scene HDR texture. Entity id goes to a single-channel float texture. View normal goes to a vec4 texture used by SSAO and SSR. Depth is whatever depth target the depth-stencil attachment is bound to. All four of these are written in the same fragment invocation, so adding picking does not cost an extra geometry pass.

The entity id is a `u32` that lives in a per-object uniform alongside the model matrix and material parameters. Each fragment outputs the id of the object that drew it. The trick is the storage format. The entity-id texture is `Rgba16Float` (or whatever single-channel float format the pipeline uses), and `u32` ids cannot be stored as floats above 2^24 without precision loss. So instead of converting, the shader reinterprets the bits:

```wgsl
output.entity_id = bitcast<f32>(in.entity_id);
```

`bitcast<f32>` writes the raw 32 bits of the `u32` into the float slot. The texture stores garbage as a float (`NaN`, denormals, whatever the bit pattern works out to), but the bits round-trip exactly. The picking shader reads the same texel with `textureLoad`, bitcasts back to `u32`, and gets the original id. This is the standard pattern for shipping ids through a float-only pipeline, and it is the reason the texture's filter mode is `Nearest` everywhere. Any kind of interpolation would corrupt the bit pattern.

The depth texture is the regular depth target written by the geometry pass. After the pass finishes, every visible pixel has a real depth value in `[0, 1]` and a real entity id encoded in its bits. The picking shader needs nothing else.

## Why a compute pass instead of a buffer copy

The simplest readback is `copy_texture_to_buffer`. Copy one texel of the entity-id texture into a staging buffer, map the buffer, read the `u32`. That gives you the entity. It does not give you world position or surface normal.

World position comes from depth. To convert a screen pixel and its depth into a world-space point, you multiply the clip-space coordinate by the inverse of the view-projection matrix. You need the depth value to do that, and that value lives in the depth texture, a separate resource from the entity-id texture. You could issue two copies, one per texture, and reconcile the buffers on the CPU. Doable. Awkward.

Surface normal is the bigger problem. The view-normal texture exists, but for picking you actually want the *world*-space normal, derived from the geometry under the cursor rather than the shaded view-normal output. The standard trick is to take three points on the surface (the pixel under the cursor and two of its neighbors), convert all three to world space, take the cross product of the edge vectors, and you have a normal that follows the actual geometry. That needs multiple depth samples, not one.

A compute shader can read both textures with `textureLoad`, sample a small window around the cursor, write the result into a single storage buffer, and let the CPU read a strided list of `(depth, entity_id)` pairs. One readback, one dispatch, all the data you need.

The dispatch size is one workgroup per sample. The sample window is a 5x5 square centered on the cursor. Five is enough for a finite-difference normal (the center plus four neighbors) with extra slack for noisy depth.

## The compute shader

```wgsl
struct PickOutput {
    depth: f32,
    entity_id: u32,
};

struct PickParams {
    center_x: u32,
    center_y: u32,
    sample_size: u32,
    _padding: u32,
}

@group(0) @binding(0) var depth_texture: texture_depth_2d;
@group(0) @binding(1) var<storage, read_write> output: array<PickOutput>;
@group(0) @binding(2) var<uniform> params: PickParams;
@group(0) @binding(3) var entity_id_texture: texture_2d<f32>;

@compute @workgroup_size(1, 1, 1)
fn main(@builtin(global_invocation_id) global_id: vec3<u32>) {
    let half_size = i32(params.sample_size / 2u);
    let px = i32(params.center_x) + i32(global_id.x) - half_size;
    let py = i32(params.center_y) + i32(global_id.y) - half_size;

    let dims = vec2<i32>(textureDimensions(depth_texture));

    var depth_value: f32 = 0.0;
    var entity_id_value: u32 = 0u;
    if px >= 0 && py >= 0 && px < dims.x && py < dims.y {
        let coord = vec2<u32>(u32(px), u32(py));
        depth_value = textureLoad(depth_texture, coord, 0);
        let entity_id_float = textureLoad(entity_id_texture, coord, 0).r;
        entity_id_value = bitcast<u32>(entity_id_float);
    }

    let index = global_id.y * params.sample_size + global_id.x;
    output[index].depth = depth_value;
    output[index].entity_id = entity_id_value;
}
```

Each invocation handles one texel of the sample window. The window is `sample_size x sample_size` centered on `(center_x, center_y)`, which the host writes into the params uniform every frame. The dispatch is `dispatch_workgroups(sample_size, sample_size, 1)`, so 25 invocations total when `sample_size = 5`. Each invocation reads one depth value, one entity-id float (which is really a `u32` in disguise), and writes them as a `PickOutput` into the storage buffer at the index matching its position in the 5x5 grid.

The depth texture binding is `texture_depth_2d` rather than `texture_2d`. `textureLoad` returns the raw depth as a single `f32` in `[0, 1]`. The entity-id binding is `texture_2d<f32>` because the underlying format is single-channel float, and the `.r` channel holds the bit-cast id. The `_padding` field on `PickParams` is there because std140 layout for a uniform buffer needs a 16-byte stride; the host writes a `[u32; 4]` regardless.

Each `PickOutput` is two `u32`s of payload (`f32` and `u32` are both four bytes), so the storage buffer is `sample_size * sample_size * 8` bytes. For a 5x5 sample that is 200 bytes.

## The dispatch and the async readback

On the host side, picking is initiated by the application setting a pending request on a `GpuPicking` resource:

```rust
world
    .resources
    .gpu_picking
    .request_pick(current_mouse_pos.0, current_mouse_pos.1);
```

That is the only API the application sees. Internally, before the renderer submits the main viewport's command buffer, it checks whether a pick is pending and dispatches the compute shader if so:

```rust
fn dispatch_pick_compute_if_pending(&mut self, world: &mut World) {
    if self.depth_pick_pending {
        return;
    }
    let Some(request) = world.resources.gpu_picking.take_pending_request() else {
        return;
    };
    let Some(depth_texture_view) = render_graph_get_texture_view(&self.graph, self.depth_id)
    else {
        return;
    };
    let Some(entity_id_texture_view) =
        render_graph_get_texture_view(&self.graph, self.entity_id_id)
    else {
        return;
    };

    let uniform_data: [u32; 4] = [
        request.screen_x,
        request.screen_y,
        DEPTH_PICK_SAMPLE_SIZE,
        0,
    ];
    self.queue.write_buffer(
        &self.depth_pick_uniform_buffer,
        0,
        bytemuck::cast_slice(&uniform_data),
    );

    let bind_group = self.device.create_bind_group(&wgpu::BindGroupDescriptor {
        label: Some("Depth Pick Bind Group"),
        layout: &self.depth_pick_bind_group_layout,
        entries: &[
            wgpu::BindGroupEntry { binding: 0, resource: wgpu::BindingResource::TextureView(depth_texture_view) },
            wgpu::BindGroupEntry { binding: 1, resource: self.depth_pick_storage_buffer.as_entire_binding() },
            wgpu::BindGroupEntry { binding: 2, resource: self.depth_pick_uniform_buffer.as_entire_binding() },
            wgpu::BindGroupEntry { binding: 3, resource: wgpu::BindingResource::TextureView(entity_id_texture_view) },
        ],
    });

    let mut encoder = self.device.create_command_encoder(&Default::default());
    {
        let mut compute_pass = encoder.begin_compute_pass(&Default::default());
        compute_pass.set_pipeline(&self.depth_pick_compute_pipeline);
        compute_pass.set_bind_group(0, &bind_group, &[]);
        compute_pass.dispatch_workgroups(DEPTH_PICK_SAMPLE_SIZE, DEPTH_PICK_SAMPLE_SIZE, 1);
    }
    encoder.copy_buffer_to_buffer(
        &self.depth_pick_storage_buffer,
        0,
        &self.depth_pick_staging_buffer,
        0,
        (DEPTH_PICK_SAMPLE_SIZE * DEPTH_PICK_SAMPLE_SIZE * 8) as u64,
    );

    self.queue.submit(std::iter::once(encoder.finish()));
    self.depth_pick_pending = true;
    self.depth_pick_center = (request.screen_x, request.screen_y);
    self.depth_pick_texture_size = self.render_buffer_size;
    self.depth_pick_camera = world.resources.active_camera;

    let map_complete = self.depth_pick_map_complete.clone();
    self.depth_pick_staging_buffer
        .slice(..)
        .map_async(wgpu::MapMode::Read, move |_| {
            map_complete.store(true, std::sync::atomic::Ordering::Relaxed);
        });
}
```

Four things to flag here.

The dispatch writes into `depth_pick_storage_buffer`, which is `BufferUsages::STORAGE | BufferUsages::COPY_SRC`. Compute shaders write to storage buffers; the CPU cannot directly map a storage buffer. The `encoder.copy_buffer_to_buffer` call moves the bytes into `depth_pick_staging_buffer`, which is `BufferUsages::COPY_DST | BufferUsages::MAP_READ`. The staging buffer is the one the CPU eventually reads. This double-buffer dance is wgpu-mandated because of how GPU memory is exposed.

`map_async` is the asynchronous part. It schedules a callback that fires *after the GPU has finished* writing the staging buffer. The callback stores `true` into an `Arc<AtomicBool>` that the host polls each frame. There is no blocking on the calling thread. The frame where you request a pick is not the frame where you get the answer.

The renderer also stashes `depth_pick_camera`. Picking needs the inverse view-projection of the camera that was active when the pick was issued. The camera moves between frames, so storing it at dispatch time avoids using a different camera's matrix during the conversion step.

There is one more subtlety. nightshade does not render every frame unconditionally; cameras can have an update mode that only re-renders when something dirty changed. A pick request forces a render of the main viewport on the frame it is issued:

```rust
let pick_forces_render =
    is_main_viewport_camera && world.resources.gpu_picking.has_pending_request();
```

Without this, a pick issued during an idle frame would dispatch against a stale depth texture, or worse, against a texture that had been freed by a resource lifetime change. Forcing the render guarantees the textures are fresh and live when the compute pass runs.

## Reading the readback

The next frame, before submitting any work, the renderer checks whether the staging buffer has been mapped:

```rust
if self.depth_pick_pending {
    let _ = self.device.poll(wgpu::PollType::Poll);

    if self.depth_pick_map_complete.load(std::sync::atomic::Ordering::Relaxed) {
        let buffer_slice = self.depth_pick_staging_buffer.slice(..);
        let data = buffer_slice.get_mapped_range();
        let mut depth_values = Vec::new();
        let mut entity_id_values = Vec::new();
        for chunk in data.chunks_exact(8) {
            let depth = f32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]);
            let entity_id = u32::from_le_bytes([chunk[4], chunk[5], chunk[6], chunk[7]]);
            depth_values.push(depth);
            entity_id_values.push(entity_id);
        }
        drop(data);
        self.depth_pick_staging_buffer.unmap();

        world.resources.gpu_picking.set_depth_samples(
            depth_values,
            entity_id_values,
            DEPTH_PICK_SAMPLE_SIZE,
            DEPTH_PICK_SAMPLE_SIZE,
            self.depth_pick_center.0,
            self.depth_pick_center.1,
        );

        if let Some(camera_entity) = self.depth_pick_camera
            && let Some(matrices) = query_camera_matrices(world, camera_entity)
        {
            let (texture_width, texture_height) = self.depth_pick_texture_size;
            let inverse_view_proj = (matrices.projection * matrices.view)
                .try_inverse()
                .unwrap_or_else(nalgebra_glm::Mat4::identity);

            world.resources.gpu_picking.compute_result(
                &inverse_view_proj,
                texture_width as f32,
                texture_height as f32,
            );
        }

        self.depth_pick_pending = false;
        self.depth_pick_map_complete.store(false, std::sync::atomic::Ordering::Relaxed);
    }
}
```

`device.poll` is the wgpu equivalent of "advance the callback queue." On native backends this is what actually triggers the `map_async` callback when the GPU is done. On wasm the browser runs the queue on its own schedule, so `poll` becomes a no-op but the structure still works.

The mapped range is `sample_size * sample_size` chunks of eight bytes each, matching the `PickOutput` struct layout. Each chunk decodes to a `(depth, entity_id)` pair. The two flat `Vec`s are passed into the picking resource alongside the sample center and dimensions.

Then the inverse view-projection is computed from the camera that was active when the pick was issued. The viewport size used here is the texture size at dispatch time, not the current texture size, since a resize between dispatch and readback would invalidate the conversion.

Both vectors land on the `GpuPicking` resource. The interesting math is in `compute_result`.

## Depth to world position

The depth value in the buffer is a normalized device-coordinate Z in `[0, 1]`. To get a world-space point you assemble the full clip-space coordinate and multiply by the inverse view-projection.

```rust
let ndc_x = (2.0 * self.sample_center_x as f32) / viewport_width - 1.0;
let ndc_y = 1.0 - (2.0 * self.sample_center_y as f32) / viewport_height;

let clip_pos = nalgebra_glm::Vec4::new(ndc_x, ndc_y, center_depth, 1.0);
let world_pos = inverse_view_proj * clip_pos;
let world_position = world_pos.xyz() / world_pos.w;
```

`sample_center_x` and `sample_center_y` are the screen pixel under the cursor. The first two lines convert them to normalized device coordinates. NDC x runs from -1 on the left to +1 on the right. NDC y runs from +1 on the top to -1 on the bottom, which is why the y formula inverts the ratio. (Different APIs disagree on Y direction; wgpu/Vulkan-style is what nightshade uses.)

`center_depth` is the depth at the cursor pixel, already in NDC space because the depth texture stores post-projection depth. The four-component clip-space point is `(ndc_x, ndc_y, depth, 1)`. Multiplying by the inverse view-projection gives a world-space homogeneous point. The perspective divide by `w` produces the actual world-space `Vec3`.

Before any of this, there is a quick rejection:

```rust
if center_depth <= 0.0 {
    self.result = Some(GpuPickResult {
        world_position: nalgebra_glm::Vec3::zeros(),
        world_normal: nalgebra_glm::Vec3::new(0.0, 1.0, 0.0),
        depth: 0.0,
        entity_id: None,
    });
    return;
}
```

A depth of exactly zero means no geometry was rasterized at that pixel. The cursor is over the cleared depth buffer (the sky, or pure background). nightshade uses a reversed-Z depth buffer where 0 is far and 1 is near, and the clear value is 0, so `depth <= 0` is the "no hit" case. The result still gets published but with `entity_id: None`, so callers can distinguish "we did the pick, nothing was there" from "we have not picked yet."

## Normal from finite differences

The world-space normal of the surface under the cursor is the cross product of two edge vectors lying on the surface. The two edges come from the four pixels immediately adjacent to the cursor: left, right, up, down. Each of those four pixels has its own depth and converts to its own world position the same way.

```rust
let get_world_pos = |dx: i32, dy: i32| -> Option<nalgebra_glm::Vec3> {
    let sx = (self.sample_width as i32 / 2 + dx) as usize;
    let sy = (self.sample_height as i32 / 2 + dy) as usize;
    let idx = sy * self.sample_width as usize + sx;
    if idx >= self.depth_sample_buffer.len() {
        return None;
    }
    let d = self.depth_sample_buffer[idx];
    if d <= 0.0 {
        return None;
    }

    let px = self.sample_center_x as i32 + dx;
    let py = self.sample_center_y as i32 + dy;
    let nx = (2.0 * px as f32) / viewport_width - 1.0;
    let ny = 1.0 - (2.0 * py as f32) / viewport_height;
    let clip = nalgebra_glm::Vec4::new(nx, ny, d, 1.0);
    let wp = inverse_view_proj * clip;
    Some(wp.xyz() / wp.w)
};

if let (Some(left), Some(right), Some(up), Some(down)) = (
    get_world_pos(-1, 0),
    get_world_pos(1, 0),
    get_world_pos(0, -1),
    get_world_pos(0, 1),
) {
    let dx = right - left;
    let dy = down - up;
    let n = nalgebra_glm::cross(&dx, &dy);
    let len = nalgebra_glm::length(&n);
    if len > 1e-6 {
        normal = n / len;
    }
}
```

The closure reads a sample at `(dx, dy)` offset from the center of the 5x5 grid and converts it to a world position, returning `None` if the sample missed (depth zero) or if the index is out of range. With left/right/up/down all valid, `dx = right - left` is the world-space step along the +X screen direction across two pixels, and `dy = down - up` is the world-space step along the +Y screen direction across two pixels. Both vectors lie in the surface's tangent plane (approximately; they are chords across a discretized surface, not true tangent vectors). The cross product gives the normal.

Length-check before normalizing covers the degenerate case where left, right, up, and down all landed on the same point. For example, sampling a near-flat surface viewed at a steep grazing angle where two-pixel offsets in screen space barely move in world space. Better to fall back to a default normal than divide by zero.

This is why the sample window is 5x5 rather than 3x3, even though only the center plus four neighbors are read for the normal. Extra slack. If a future change wants a smoother normal, for example averaging multiple finite-difference samples from different offsets, the data is already on hand.

There is one quiet failure mode. Two-pixel finite differences lie at silhouette edges, where one neighbor is on a different object. For decal placement that is fine. You do not usually want a decal straddling an edge anyway. A stricter implementation would reject sample windows where the four neighboring entity ids disagree and fall back to a vertex normal or a smaller radius. nightshade has not needed to.

## Temporal smoothing

The cursor jitters by a pixel every frame. Two-pixel finite differences on a noisy depth buffer produce a normal that flickers visibly even when the cursor is "stationary." A small exponential moving average across frames cleans it up at the cost of one frame of latency on rapid changes.

```rust
let smoothing_factor = 0.3;

let smoothed_position = if let Some(prev_pos) = self.previous_position {
    let distance = nalgebra_glm::distance(&prev_pos, &world_position);
    if distance < 2.0 {
        nalgebra_glm::lerp(&prev_pos, &world_position, smoothing_factor)
    } else {
        world_position
    }
} else {
    world_position
};

let smoothed_normal = if let Some(prev_normal) = self.previous_normal {
    let dot = nalgebra_glm::dot(&prev_normal, &normal);
    if dot > 0.0 {
        let lerped = nalgebra_glm::lerp(&prev_normal, &normal, smoothing_factor);
        nalgebra_glm::normalize(&lerped)
    } else {
        normal
    }
} else {
    normal
};

self.previous_position = Some(smoothed_position);
self.previous_normal = Some(smoothed_normal);
```

The position lerp is gated on distance. When the cursor moves smoothly across a surface, consecutive samples are within a couple of world units of each other, and a 30% lerp blends out the per-frame noise. When the cursor jumps from one object to another, or off the geometry entirely, the distance threshold trips and the new sample is used directly without smoothing. This avoids a visible glide as the marker drags from the old position to the new one.

The normal lerp uses the dot product as its discontinuity guard. If the previous normal and the new normal point in roughly the same direction (`dot > 0`), they belong to the same surface and we blend. If the dot product is negative, meaning the new normal points the opposite way, which happens at object boundaries, we adopt the new normal without lerping. Lerping between opposing normals would produce zero-length vectors halfway through.

Smoothing only kicks in after the first sample, when `previous_position` is `Some`. The very first pick after startup uses the raw values directly, so there is no warm-up phase visible in the demo.

## Reading the result on the application side

The application asks for results the same way it asked for picks, through the `GpuPicking` resource.

```rust
if let Some(result) = world.resources.gpu_picking.take_result() {
    self.last_pick_result = Some(result);
}
```

`take_result` consumes the result if one is available. The renderer publishes the result by calling `compute_result` after each successful readback, and the application drains it the next frame. If there is no result waiting, `take_result` returns `None` and the application keeps using whatever it had cached.

The `GpuPickResult` struct is what falls out of the whole process:

```rust
pub struct GpuPickResult {
    pub world_position: nalgebra_glm::Vec3,
    pub world_normal: nalgebra_glm::Vec3,
    pub depth: f32,
    pub entity_id: Option<u32>,
}
```

World position is the smoothed point on the surface. World normal is the smoothed surface normal at that point. Depth is the raw NDC depth, useful as a "did we hit anything" signal (zero means no hit). Entity id is the id read from the entity-id texture at the center pixel, `None` when the texel held zero.

In the picking demo, the application uses these for two things. The selection outline tracks the entity id under the cursor. The renderer's selection-mask pass paints an outline around whatever entity matches `bounding_volume_selected_entity`, which the demo sets to the entity id from the pick. The world position drives a small cross-and-normal preview marker drawn with the lines system, anchored at the pick point and oriented to the surface normal. CPU raycasts can drive either feature on their own. The GPU path drives both from the same readback.

## What this gives you and what it does not

The cost of the system is fixed. One compute dispatch of 25 invocations, one buffer-to-buffer copy of 200 bytes, one `map_async` callback per pick, one inverse-matrix multiply on the CPU per pick. None of that scales with the number of objects in the scene. A scene with one hundred thousand triangles costs the same to pick as a scene with one cube.

What it does not give you is a result on the same frame the pick is issued. Asynchronous readback is the price of not stalling the GPU pipeline. For a hover-with-outline workflow this is invisible. One frame of latency on a 60 Hz hover is sixteen milliseconds, well under human perception. For a click that needs to commit a selection immediately, the application has to buffer the click and apply it when the next pick result arrives. The demo does this by latching the highlighted entity on left-mouse-just-pressed.

It also relies on the renderer producing the entity-id and depth textures every frame, which means the picking-friendly fragment shaders have to be the ones drawing the things you want to pick. Lines, decals, and skybox quads are not written through the mesh shader, so they are not pickable. nightshade's skinned-mesh shader writes its entity id the same way the static mesh shader does, so skinned characters work without special-casing. Particles, line meshes, and post-process effects do not.

The CPU raycast path stays around for cases where the GPU path is not appropriate. Picking against an object that has not yet been rendered, picking against bounding volumes rather than geometry (which is what the `apps/picking` demo uses for its bounding-sphere hover mode), and any picking that needs to happen on a worker thread without going through the renderer. The two modes coexist on the same selection state in the demo, so you can toggle between them and see the difference.

The full picking flow is fewer than three hundred lines split between the compute shader, the renderer's dispatch and readback, and the `GpuPicking` resource. The compute shader and the `GpuPicking` resource sit alongside the rest of the renderer at `crates/nightshade/src/render/wgpu/` and `crates/nightshade/src/ecs/gpu_picking.rs` if you want to read the production version.
