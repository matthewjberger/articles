+++
title = "Build your own retained UI (part 3), rendering with wgpu"
tags = ["rust", "ui", "wgpu", "ecs", "game-engine", "tutorial"]
categories = ["rust"]
excerpt = "Turning a laid-out tree into pixels. Instanced rect rendering with an SDF shader for rounded corners and borders, a bitmap font atlas for text, and the render-graph pass that ties it into a wgpu application."
series = "retained-ui"
series_part = 3
+++

*This is part 3 of 3 of a series.* ← [Layout and interaction](@/posts/2026-05-02-build-your-own-retained-ui-layout-interaction.md)

[Part 2](@/posts/2026-05-02-build-your-own-retained-ui-layout-interaction.md) finished with a UI that knew where every widget was on screen and what the user was doing with the cursor. The layout system wrote `resolved` rects into every `UiNode`, the interaction system updated per-entity flags and pushed events. Buttons fired clicks. The application could route those events to its own code. The one thing the UI still could not do was *appear*. The window was blank.

This post puts the pixels on the screen. The architecture is wgpu, the same low-level GPU API nightshade uses. The render pass walks the laid-out tree once per frame, packs every visible widget into per-instance data, and submits two draws. One draw renders every rectangle as a signed-distance-field rounded rect with optional border, fill, and shadow, all from one shader. The other draw renders every glyph against a bitmap font atlas. Both are instanced. One vertex buffer (a unit quad), N instances, one `draw_indexed` call.

The retained ECS from parts one and two is what makes this efficient. The renderer does not walk a widget tree, dispatching virtual methods. It queries the ECS for entities with the components the render pass cares about, reads packed `Vec<UiNode>` and `Vec<UiColor>` storage in lockstep, writes instance bytes into a GPU buffer, and submits. The per-frame draw cost scales with the number of visible widgets, not with the depth of the tree or the number of widget *types*.

End state of this post is a working render pass that draws the panel-with-two-buttons example from part one as actual pixels, with hover and pressed states visibly tinted, text labels centered in each button, and round corners.

Start from the file at the end of part 2.

## What the GPU actually needs

A modern GPU does not want a heap of objects with `draw()` methods. It wants buffers, flat arrays of numbers, and a small number of pipeline state changes. Every state change (binding a new pipeline, swapping a bind group, changing a uniform) costs tens of microseconds of CPU and a sync barrier on the GPU side. The fast path is one buffer with all the per-rect data, one shader pipeline, one draw call that says "draw N instances of this unit quad, expand each one into a rect using the data at index `i` in the buffer."

So the renderer's job is to produce that buffer. Each frame, walk the ECS, collect every visible widget that has a `UiNode + UiColor`, pack each one's data into a fixed-size struct that matches the shader's `RectInstance` layout, write the resulting `Vec<RectInstance>` into a GPU buffer, then submit one `draw_indexed(0..6, 0, 0..rect_count)`. The text pass does the same with a different shader and a glyph atlas as a second input.

Two things make this go fast in practice. The first is that the instance buffer is on the GPU, persistent across frames, and only the slots that changed get rewritten. Same trick as nightshade's `prev_rect_instances` cache that skips `write_buffer` when the bytes are identical to last frame. The second is that the per-instance data is small (around 64 bytes for a basic rect, 128 with shadow and effect parameters), and 1024 instances fit comfortably in a single 64 KB buffer. A real UI rarely has more than a few hundred visible widgets, so the whole frame's UI submission is a handful of kilobytes of upload.

## Sizing the instance struct

The shader's view of a rect:

```wgsl
struct RectInstance {
    position_size: vec4<f32>,
    color: vec4<f32>,
    border_color: vec4<f32>,
    clip_rect: vec4<f32>,
    params: vec4<f32>,
}
```

Five `vec4<f32>` slots, 80 bytes per rect. `position_size` carries the rect's top-left corner and its width/height (`xy = position`, `zw = size`). `color` is the RGBA fill. `border_color` is the RGBA border. `clip_rect` is the scissor rectangle (`xy = min`, `zw = max`), or all zeros for no clipping. `params` packs four scalars: corner radius, border width, depth, and rotation.

Five vec4s is the bare minimum. Production retained UIs grow this to ten or more vec4s for shadows, gradient effects, and character-color overrides. The shape is the same; each additional capability is another vec4 of parameters that the fragment shader reads when relevant.

The CPU-side struct that matches the shader.

```rust
use bytemuck::{Pod, Zeroable};

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Pod, Zeroable)]
pub struct RectInstance {
    pub position_size: [f32; 4],
    pub color: [f32; 4],
    pub border_color: [f32; 4],
    pub clip_rect: [f32; 4],
    pub params: [f32; 4],
}
```

`#[repr(C)]` so the field order is what the shader expects. `Pod + Zeroable` so we can pass `&[RectInstance]` to `bytemuck::cast_slice` to get bytes for `queue.write_buffer`, and so we can call `RectInstance::zeroed()` later when sizing the prev-frame mirror. The total size is `5 * 16 = 80` bytes, which is what wgpu expects.

The `clip_rect` field is mostly zeros for non-clipped rects. We keep one slot for it rather than splitting the storage into clipped and non-clipped arrays; the per-slot cost is four bytes and the bookkeeping a split would add is not worth it.

## Walking the tree into an instance vec

The render-sync system is a single pass over the entities the layout has already produced. For each visible entity with a `UiNode + UiColor`, build a `RectInstance` and push it.

```rust
#[derive(Default)]
pub struct UiFrame {
    pub rects: Vec<RectInstance>,
    pub rect_entities: Vec<Entity>,
    pub texts: Vec<TextInstance>,
}
```

`UiFrame` is one more world resource. Extending the macro declaration from parts one and two:

```rust
ecs! {
    World {
        ui_node: UiNode => UI_NODE,
        ui_color: UiColor => UI_COLOR,
        ui_text: UiText => UI_TEXT,
        ui_parent: UiParent => UI_PARENT,
        ui_interactive: UiInteractive => UI_INTERACTIVE,
    }
    Resources {
        layout: LayoutState,
        pointer: PointerState,
        events: Vec<UiEvent>,
        viewport: Vec2,
        ui_frame: UiFrame,
    }
}
```

The render-sync system populates `world.resources.ui_frame` each frame, and the GPU upload (`UiPass::prepare`) reads it. Two systems, one resource, no cross-pollination.

```rust
pub fn ui_render_sync_system(world: &mut World) {
    let entities: Vec<Entity> = world.query_entities(UI_NODE | UI_COLOR).collect();
    let mut entries: Vec<(Entity, UiNode, UiColor, Option<UiInteractive>)> =
        Vec::with_capacity(entities.len());
    for entity in entities {
        let Some(node) = world.get_ui_node(entity).cloned() else {
            continue;
        };
        if !node.visible {
            continue;
        }
        let Some(color) = world.get_ui_color(entity).copied() else {
            continue;
        };
        let interactive = world.get_ui_interactive(entity).cloned();
        entries.push((entity, node, color, interactive));
    }

    entries.sort_by_key(|(_, node, _, _)| node.z_index);

    let frame = &mut world.resources.ui_frame;
    frame.rects.clear();
    frame.rect_entities.clear();
    frame.texts.clear();

    for (entity, node, color, interactive) in entries {
        let rgba = effective_color(color.rgba, interactive.as_ref());
        frame.rects.push(RectInstance {
            position_size: [
                node.resolved.min.x,
                node.resolved.min.y,
                node.resolved.width(),
                node.resolved.height(),
            ],
            color: [rgba.x, rgba.y, rgba.z, rgba.w],
            border_color: [0.0; 4],
            clip_rect: clip_or_zero(node.clip),
            params: [0.0, 0.0, node.z_index as f32, 0.0],
        });
        frame.rect_entities.push(entity);
    }

    sync_text_instances(world);
}

fn effective_color(base: Vec4, interactive: Option<&UiInteractive>) -> Vec4 {
    let Some(interactive) = interactive else {
        return base;
    };
    if interactive.pressed {
        return Vec4::new(base.x * 0.6, base.y * 0.6, base.z * 0.6, base.w);
    }
    if interactive.hovered {
        return Vec4::new(
            (base.x * 1.15).min(1.0),
            (base.y * 1.15).min(1.0),
            (base.z * 1.15).min(1.0),
            base.w,
        );
    }
    base
}

fn clip_or_zero(clip: Option<Rect>) -> [f32; 4] {
    match clip {
        Some(rect) => [rect.min.x, rect.min.y, rect.max.x, rect.max.y],
        None => [0.0; 4],
    }
}
```

Three phases. Collect every visible rect into an intermediate vec, releasing every read borrow on `world` before any write. Sort by `z_index` so the painter's algorithm draws lower z first. Take the mutable borrow on `world.resources.ui_frame`, clear last frame's vecs, and translate each entry into a `RectInstance`. The collect step is what keeps the borrow checker happy. `world.query_entities` and `world.get_ui_node` both want `&World`, while `frame` wants `&mut world.resources.ui_frame`, so the read pass and the write pass have to be sequential.

`effective_color` is the interaction-driven color tint. Pressed widgets darken 40%. Hovered widgets brighten 15%. The retained-UI convention is to compute the visible color at submission time, so the render pass sees the final color and the GPU does not need to know anything about hover/pressed. A renderer that wants animated transitions stores per-state colors on the entity and blends them toward a target each frame before submission; computing the tint inline here is the static version of the same idea.

`sync_text_instances` does the same job for text. We come back to it after a couple of sections on rect uploads.

## Persistent instance buffer and incremental upload

The buffer that holds `RectInstance`s lives on the GPU and persists across frames. Allocating it new every frame would be wasteful. The fast path is to size it once large enough for the expected widget count, grow it (doubling) when an upload would overflow, and only write the slots that changed.

```rust
pub struct UiPass {
    pub rect_pipeline: wgpu::RenderPipeline,
    pub rect_instance_buffer: wgpu::Buffer,
    pub rect_instance_capacity: usize,
    pub rect_instance_bind_group: wgpu::BindGroup,
    pub rect_instance_bind_group_layout: wgpu::BindGroupLayout,
    pub rect_quad_vertex_buffer: wgpu::Buffer,
    pub rect_quad_index_buffer: wgpu::Buffer,
    pub rect_count: u32,
    pub prev_rect_instances: Vec<RectInstance>,

    pub text_pipeline: wgpu::RenderPipeline,
    pub text_instance_buffer: wgpu::Buffer,
    pub text_instance_capacity: usize,
    pub text_bind_group: wgpu::BindGroup,
    pub text_bind_group_layout: wgpu::BindGroupLayout,
    pub font_atlas_view: Option<wgpu::TextureView>,
    pub glyph_count: u32,

    pub global_uniform_buffer: wgpu::Buffer,
    pub global_uniform_bind_group: wgpu::BindGroup,
}

#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
pub struct GlobalUniforms {
    pub projection: [[f32; 4]; 4],
    pub viewport: [f32; 4],
}
```

The text fields fill in later in the post. Construction of the text pipeline mirrors the rect pipeline (different shader, one bind group that combines globals + glyph instances + atlas texture + sampler), and `font_atlas_view` is filled by the `upload_font_atlas` call.

The instance buffer is a `BufferUsages::STORAGE | COPY_DST` storage buffer the vertex shader reads as `array<RectInstance>`. Storage buffers in wgpu have an effective limit of 128 MB on most desktop GPUs and 128 KB on a conservative WebGPU profile. Either limit is more than a UI needs.

The unit quad is the geometry every instance gets expanded against. Four vertices, two triangles, indices `[0, 1, 2, 0, 2, 3]`.

```rust
#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
pub struct UiPassVertex {
    pub position: [f32; 2],
}

const QUAD_VERTICES: [UiPassVertex; 4] = [
    UiPassVertex { position: [0.0, 0.0] },
    UiPassVertex { position: [1.0, 0.0] },
    UiPassVertex { position: [1.0, 1.0] },
    UiPassVertex { position: [0.0, 1.0] },
];

const QUAD_INDICES: [u16; 6] = [0, 1, 2, 0, 2, 3];
```

The vertex shader will take each vertex's `[0..1, 0..1]` position and multiply by the instance's `size`, then add the instance's `position`. One quad geometry, expanded to N rectangles by reading per-instance data via `@builtin(instance_index)`.

The `prepare` step uploads new instances to the buffer, growing if necessary, skipping slots whose data is identical to last frame.

```rust
impl UiPass {
    pub fn prepare(&mut self, device: &wgpu::Device, queue: &wgpu::Queue, world: &World) {
        let frame = &world.resources.ui_frame;

        let viewport = world.resources.viewport;
        let projection = orthographic(viewport.x, viewport.y);
        queue.write_buffer(
            &self.global_uniform_buffer,
            0,
            bytemuck::cast_slice(&[GlobalUniforms {
                projection,
                viewport: [viewport.x, viewport.y, 0.0, 0.0],
            }]),
        );

        self.ensure_rect_capacity(device, frame.rects.len());
        if self.prev_rect_instances.len() < frame.rects.len() {
            self.prev_rect_instances
                .resize(frame.rects.len(), RectInstance::zeroed());
        }

        for (slot, instance) in frame.rects.iter().enumerate() {
            if self.prev_rect_instances[slot] != *instance {
                queue.write_buffer(
                    &self.rect_instance_buffer,
                    (slot * std::mem::size_of::<RectInstance>()) as u64,
                    bytemuck::cast_slice(&[*instance]),
                );
                self.prev_rect_instances[slot] = *instance;
            }
        }
        self.rect_count = frame.rects.len() as u32;
    }

    fn ensure_rect_capacity(&mut self, device: &wgpu::Device, required: usize) {
        if required <= self.rect_instance_capacity {
            return;
        }
        let new_capacity = (required * 2).max(INITIAL_RECT_CAPACITY);
        self.rect_instance_buffer = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("UiPass Rect Instance Buffer"),
            size: (std::mem::size_of::<RectInstance>() * new_capacity) as u64,
            usage: wgpu::BufferUsages::STORAGE | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        self.rect_instance_capacity = new_capacity;
        self.prev_rect_instances.clear();
        self.rect_instance_bind_group = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("UiPass Rect Instance Bind Group"),
            layout: &self.rect_instance_bind_group_layout,
            entries: &[wgpu::BindGroupEntry {
                binding: 0,
                resource: self.rect_instance_buffer.as_entire_binding(),
            }],
        });
    }
}

const INITIAL_RECT_CAPACITY: usize = 256;
```

`prev_rect_instances` is a CPU-side mirror of the GPU buffer, by slot. The diff check `prev != *instance` skips the `queue.write_buffer` call when nothing changed. For a static UI with one button that occasionally hovers, this turns the per-frame upload into either zero bytes (no change) or a single 80-byte slot write (just the hovered button).

`ensure_rect_capacity` doubles the buffer when an upload would not fit. The `prev_rect_instances.clear()` after growing forces every slot to re-upload because the GPU buffer is fresh; we lose the cache for one frame and rebuild it. The bind group also needs to be rebuilt because it pointed at the old buffer.

The orthographic projection is window-pixel coordinates into clip space, Y-down, depth `[0, 1]`:

```rust
pub fn orthographic(width: f32, height: f32) -> [[f32; 4]; 4] {
    let left = 0.0;
    let right = width;
    let top = 0.0;
    let bottom = height;
    let near = -1.0;
    let far = 1.0;

    let inv_width = 1.0 / (right - left);
    let inv_height = 1.0 / (top - bottom);
    let inv_depth = 1.0 / (far - near);

    let mut matrix = [[0.0f32; 4]; 4];
    matrix[0][0] = 2.0 * inv_width;
    matrix[1][1] = 2.0 * inv_height;
    matrix[2][2] = inv_depth;
    matrix[3][0] = -(right + left) * inv_width;
    matrix[3][1] = -(top + bottom) * inv_height;
    matrix[3][2] = -near * inv_depth;
    matrix[3][3] = 1.0;
    matrix
}
```

`(0, 0)` is the top-left of the window. `(width, height)` is the bottom-right. The vertex shader multiplies by this matrix to land in clip space. We could pre-multiply the projection on the CPU and write fully-projected positions into the instance buffer, but writing pixel coordinates and multiplying in the shader is the cleaner split. The GPU does the matrix multiply for free.

## The rect shader

The vertex shader reads the per-instance data and expands the unit quad into a screen-space rect.

```wgsl
struct GlobalUniforms {
    projection: mat4x4<f32>,
    viewport: vec4<f32>,
}

struct RectInstance {
    position_size: vec4<f32>,
    color: vec4<f32>,
    border_color: vec4<f32>,
    clip_rect: vec4<f32>,
    params: vec4<f32>,
}

@group(0) @binding(0) var<uniform> globals: GlobalUniforms;
@group(1) @binding(0) var<storage, read> instances: array<RectInstance>;

struct VertexInput {
    @location(0) position: vec2<f32>,
    @builtin(instance_index) instance_index: u32,
}

struct VertexOutput {
    @builtin(position) position: vec4<f32>,
    @location(0) local_pos: vec2<f32>,
    @location(1) rect_size: vec2<f32>,
    @location(2) screen_pos: vec2<f32>,
    @location(3) @interpolate(flat) instance_index: u32,
}

@vertex
fn vs_main(vertex: VertexInput) -> VertexOutput {
    let inst = instances[vertex.instance_index];
    let rect_pos = inst.position_size.xy;
    let rect_size = inst.position_size.zw;

    let local = vertex.position * rect_size;
    let world_pos = rect_pos + local;

    var output: VertexOutput;
    output.position = globals.projection * vec4<f32>(world_pos, 0.0, 1.0);
    output.local_pos = local;
    output.rect_size = rect_size;
    output.screen_pos = world_pos;
    output.instance_index = vertex.instance_index;
    return output;
}
```

The unit quad's vertex position is in `[0, 1]`. Multiply by the rect's size to get a local-space position in pixels, add the rect's top-left to get a world-space pixel position, multiply by the projection to land in clip space. The varyings `local_pos`, `rect_size`, and `screen_pos` flow into the fragment shader, where the SDF lives.

The fragment shader is where rounded corners and borders happen. A signed-distance-field rounded rect.

```wgsl
fn rounded_rect_sdf(pos: vec2<f32>, size: vec2<f32>, radius: f32) -> f32 {
    let half_size = size * 0.5;
    let center_pos = pos - half_size;
    let clamped_radius = min(radius, min(half_size.x, half_size.y));
    let q = abs(center_pos) - half_size + clamped_radius;
    return length(max(q, vec2<f32>(0.0))) + min(max(q.x, q.y), 0.0) - clamped_radius;
}

@fragment
fn fs_main(input: VertexOutput) -> @location(0) vec4<f32> {
    let inst = instances[input.instance_index];

    let clip = inst.clip_rect;
    let clip_active = clip.x != 0.0 || clip.y != 0.0 || clip.z != 0.0 || clip.w != 0.0;
    if clip_active {
        if input.screen_pos.x < clip.x
            || input.screen_pos.y < clip.y
            || input.screen_pos.x > clip.z
            || input.screen_pos.y > clip.w {
            discard;
        }
    }

    let corner_radius = inst.params.x;
    let border_width = inst.params.y;
    let sdf = rounded_rect_sdf(input.local_pos, input.rect_size, corner_radius);

    let edge = fwidth(sdf);
    let outside = smoothstep(0.0, edge, sdf);
    if outside >= 0.999 {
        discard;
    }

    var color = inst.color;
    color.a *= 1.0 - outside;

    if border_width > 0.0 && inst.border_color.a > 0.0 {
        let inner_sdf = sdf + border_width;
        let border_blend = smoothstep(-edge, 0.0, inner_sdf);
        color = mix(color, inst.border_color, border_blend);
    }

    return color;
}
```

`rounded_rect_sdf` returns the signed distance from `pos` to the edge of a rounded rectangle of `size` with corner `radius`. Negative inside, zero on the edge, positive outside. The math is `q = abs(p - center) - half_size + radius`, then `length(max(q, 0)) + min(max(q.x, q.y), 0) - radius`. The standard derivation.

The fragment shader evaluates the SDF at every pixel. If the pixel is well outside (sdf > epsilon), discard. Otherwise the pixel is inside or on the edge. `smoothstep(0.0, edge, sdf)` gives a soft alpha falloff at the edge. `edge = fwidth(sdf)` is the screen-space gradient of the SDF, which produces a one-pixel antialiased edge regardless of how zoomed in or out the rect is. The rounded corners stay crisp at any resolution.

If the rect has a border, a second SDF check at `sdf + border_width` decides whether the pixel is inside the border (negative result) or inside the fill (positive). `mix(fill, border, border_blend)` blends between the two. The result is one fragment shader that draws fill, border, and rounded corners in one pass.

Production renderers extend this further. nightshade's rect shader (around 350 lines of WGSL) adds drop shadows (a second SDF pass with offset and blur), gradient fills (linear and radial mixes in OKLab space for perceptually-uniform interpolation), inset/outset bevels, glow effects, and quadrilateral mode for non-rectangular shapes like trapezoidal arrows. Every effect is a branch in the fragment shader on an `effect_kind: u32` field in the instance struct. The structural shape (one shader, one pipeline, one instanced draw) is the same.

## Building the rect pipeline

The pipeline binds two groups: globals (projection, viewport) on group 0, instances on group 1.

```rust
impl UiPass {
    pub fn new(device: &wgpu::Device, color_format: wgpu::TextureFormat) -> Self {
        let global_uniform_bind_group_layout =
            device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
                label: Some("UiPass Global Uniform Layout"),
                entries: &[wgpu::BindGroupLayoutEntry {
                    binding: 0,
                    visibility: wgpu::ShaderStages::VERTEX_FRAGMENT,
                    ty: wgpu::BindingType::Buffer {
                        ty: wgpu::BufferBindingType::Uniform,
                        has_dynamic_offset: false,
                        min_binding_size: None,
                    },
                    count: None,
                }],
            });

        let rect_instance_bind_group_layout =
            device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
                label: Some("UiPass Rect Instance Layout"),
                entries: &[wgpu::BindGroupLayoutEntry {
                    binding: 0,
                    visibility: wgpu::ShaderStages::VERTEX_FRAGMENT,
                    ty: wgpu::BindingType::Buffer {
                        ty: wgpu::BufferBindingType::Storage { read_only: true },
                        has_dynamic_offset: false,
                        min_binding_size: None,
                    },
                    count: None,
                }],
            });

        let global_uniform_buffer = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("UiPass Global Uniform Buffer"),
            size: std::mem::size_of::<GlobalUniforms>() as u64,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });

        let rect_instance_buffer = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("UiPass Rect Instance Buffer"),
            size: (std::mem::size_of::<RectInstance>() * INITIAL_RECT_CAPACITY) as u64,
            usage: wgpu::BufferUsages::STORAGE | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });

        let global_uniform_bind_group = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("UiPass Global Uniform Bind Group"),
            layout: &global_uniform_bind_group_layout,
            entries: &[wgpu::BindGroupEntry {
                binding: 0,
                resource: global_uniform_buffer.as_entire_binding(),
            }],
        });

        let rect_instance_bind_group = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("UiPass Rect Instance Bind Group"),
            layout: &rect_instance_bind_group_layout,
            entries: &[wgpu::BindGroupEntry {
                binding: 0,
                resource: rect_instance_buffer.as_entire_binding(),
            }],
        });

        let rect_shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("UiPass Rect Shader"),
            source: wgpu::ShaderSource::Wgsl(include_str!("ui_pass_rect.wgsl").into()),
        });

        let rect_pipeline_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("UiPass Rect Pipeline Layout"),
            bind_group_layouts: &[
                &global_uniform_bind_group_layout,
                &rect_instance_bind_group_layout,
            ],
            immediate_size: 0,
        });

        let rect_pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("UiPass Rect Pipeline"),
            layout: Some(&rect_pipeline_layout),
            vertex: wgpu::VertexState {
                module: &rect_shader,
                entry_point: Some("vs_main"),
                buffers: &[wgpu::VertexBufferLayout {
                    array_stride: std::mem::size_of::<UiPassVertex>() as wgpu::BufferAddress,
                    step_mode: wgpu::VertexStepMode::Vertex,
                    attributes: &[wgpu::VertexAttribute {
                        offset: 0,
                        shader_location: 0,
                        format: wgpu::VertexFormat::Float32x2,
                    }],
                }],
                compilation_options: wgpu::PipelineCompilationOptions::default(),
            },
            primitive: wgpu::PrimitiveState::default(),
            depth_stencil: None,
            multisample: wgpu::MultisampleState::default(),
            fragment: Some(wgpu::FragmentState {
                module: &rect_shader,
                entry_point: Some("fs_main"),
                targets: &[Some(wgpu::ColorTargetState {
                    format: color_format,
                    blend: Some(wgpu::BlendState::ALPHA_BLENDING),
                    write_mask: wgpu::ColorWrites::ALL,
                })],
                compilation_options: wgpu::PipelineCompilationOptions::default(),
            }),
            multiview_mask: None,
            cache: None,
        });

        let rect_quad_vertex_buffer = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("UiPass Quad Vertex Buffer"),
            contents: bytemuck::cast_slice(&QUAD_VERTICES),
            usage: wgpu::BufferUsages::VERTEX,
        });

        let rect_quad_index_buffer = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("UiPass Quad Index Buffer"),
            contents: bytemuck::cast_slice(&QUAD_INDICES),
            usage: wgpu::BufferUsages::INDEX,
        });

        Self {
            rect_pipeline,
            rect_instance_buffer,
            rect_instance_capacity: INITIAL_RECT_CAPACITY,
            rect_instance_bind_group,
            rect_instance_bind_group_layout,
            rect_quad_vertex_buffer,
            rect_quad_index_buffer,
            rect_count: 0,
            prev_rect_instances: Vec::new(),

            global_uniform_buffer,
            global_uniform_bind_group,
        }
    }
}
```

Alpha blending is `ONE_MINUS_SRC_ALPHA` standard premultiplied alpha. The depth-stencil attachment is `None` because we are using painter's algorithm via z-index sorted submission. A production renderer would attach a depth buffer and write `z_index / 10000.0` into the rect's clip-space depth, which lets the GPU early-z reject occluded fragments. nightshade's pass does this, with the small encoded depth value packed into `params.z` in the vertex shader output.

## Executing the pass

The execute phase begins the render pass and issues the draws.

```rust
impl UiPass {
    pub fn execute<'r>(
        &mut self,
        encoder: &mut wgpu::CommandEncoder,
        color_view: &wgpu::TextureView,
    ) {
        if self.rect_count == 0 {
            return;
        }

        let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
            label: Some("UI Pass"),
            color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                view: color_view,
                resolve_target: None,
                ops: wgpu::Operations {
                    load: wgpu::LoadOp::Load,
                    store: wgpu::StoreOp::Store,
                },
                depth_slice: None,
            })],
            depth_stencil_attachment: None,
            timestamp_writes: None,
            occlusion_query_set: None,
            multiview_mask: None,
        });

        pass.set_pipeline(&self.rect_pipeline);
        pass.set_bind_group(0, &self.global_uniform_bind_group, &[]);
        pass.set_bind_group(1, &self.rect_instance_bind_group, &[]);
        pass.set_vertex_buffer(0, self.rect_quad_vertex_buffer.slice(..));
        pass.set_index_buffer(self.rect_quad_index_buffer.slice(..), wgpu::IndexFormat::Uint16);
        pass.draw_indexed(0..6, 0, 0..self.rect_count);
    }
}
```

One pipeline. Two bind groups. One vertex buffer. One index buffer. One `draw_indexed` with `rect_count` instances. The GPU draws every rectangle in the UI with one call.

`load: LoadOp::Load` is the right setting. The UI is composited on top of whatever the rest of the renderer drew (the 3D scene, the sky, the previous UI from another pass). If we cleared, the UI would erase the rest of the frame. Loading preserves the previous render and adds the UI on top via alpha blend.

The submission order matters for painter's algorithm. We sorted by `z_index` ascending on the CPU, so lower z-order rectangles get written first and higher z-order rectangles draw on top. Alpha blending handles the compositing.

## The text pass: bitmap atlas

Text rendering splits into two reasonable paths. The first is a font crate (`fontdue`, `glyph_brush`, `cosmic-text`) that handles shaping, hinting, antialiasing, and atlas management, plus a wgpu integration layer that turns shaped text into glyph quads. That is the right call for production. nightshade uses this path with a custom shaped-text cache on top.

The second is to bake a bitmap font into the binary. Each glyph is a small fixed-size bitmap, the atlas is a single-channel grayscale texture with one cell per glyph, and rendering is the same instanced-quad trick we used for rects. This is what indigo does. A hand-rolled 5x7 bitmap font, no font dependency, 84 glyphs covering ASCII uppercase and digits and punctuation. The result is recognizable as text and the implementation is two hundred lines of Rust.

The bitmap font is what we will build. Every piece is small enough to read straight through, and swapping in `fontdue` later is a drop-in replacement.

### Baking the atlas

The font's glyphs are defined inline as 5-wide, 7-tall bitmaps in source code. Each glyph is a string of `'#'` and `'.'` characters.

```rust
const FONT_GLYPH_WIDTH: u32 = 5;
const FONT_GLYPH_HEIGHT: u32 = 7;
const FONT_ADVANCE: u32 = 6;

const FONT_GLYPHS: &[(char, &str)] = &[
    (' ', ".....\n.....\n.....\n.....\n.....\n.....\n....."),
    ('A', ".###.\n#...#\n#...#\n#####\n#...#\n#...#\n#...#"),
    ('B', "####.\n#...#\n#...#\n####.\n#...#\n#...#\n####."),
    ('C', ".###.\n#...#\n#....\n#....\n#....\n#...#\n.###."),
    ('K', "#...#\n#..#.\n#.#..\n##...\n#.#..\n#..#.\n#...#"),
    ('P', "####.\n#...#\n#...#\n####.\n#....\n#....\n#...."),
    ('I', ".###.\n..#..\n..#..\n..#..\n..#..\n..#..\n.###."),
    ('N', "#...#\n##..#\n#.#.#\n#..##\n#...#\n#...#\n#...#"),
    ('!', "..#..\n..#..\n..#..\n..#..\n..#..\n.....\n..#.."),
];
```

The full font has every uppercase letter, every digit, common punctuation. The full table is 80-something entries. Lowercase letters fall back to uppercase in the lookup (case-insensitive fonts are a thing in retro UIs).

Baking is one pass that lays out glyphs in a single horizontal row in a `Vec<u8>` texture:

```rust
pub struct FontAtlas {
    pub pixels: Vec<u8>,
    pub width: u32,
    pub height: u32,
    pub glyph_of: HashMap<char, u32>,
    pub glyph_count: u32,
}

pub fn build_font_atlas() -> FontAtlas {
    let glyph_count = (FONT_GLYPHS.len() as u32) + 1;
    let width = glyph_count * FONT_GLYPH_WIDTH;
    let height = FONT_GLYPH_HEIGHT;
    let mut pixels = vec![0u8; (width * height) as usize];
    let mut glyph_of = HashMap::new();

    for (index, (character, pattern)) in FONT_GLYPHS.iter().enumerate() {
        let column = (index as u32) + 1;
        glyph_of.insert(*character, column);
        write_glyph(&mut pixels, width, column, pattern);
    }

    FontAtlas {
        pixels,
        width,
        height,
        glyph_of,
        glyph_count,
    }
}

fn write_glyph(pixels: &mut [u8], atlas_width: u32, column: u32, pattern: &str) {
    let origin_x = column * FONT_GLYPH_WIDTH;
    for (row_index, row) in pattern.split('\n').enumerate() {
        if (row_index as u32) >= FONT_GLYPH_HEIGHT {
            break;
        }
        for (column_offset, character) in row.chars().enumerate() {
            if character == '#' {
                let offset = (row_index as u32) * atlas_width + origin_x + (column_offset as u32);
                if (offset as usize) < pixels.len() {
                    pixels[offset as usize] = 255;
                }
            }
        }
    }
}
```

Column 0 is reserved as a blank "missing glyph" cell so the shader can sample it for any character the lookup does not cover. Lookup uses the hashmap with an uppercase fallback for lowercase ASCII.

The atlas is uploaded to the GPU as an `R8Unorm` texture once at startup.

```rust
impl UiPass {
    pub fn upload_font_atlas(&mut self, device: &wgpu::Device, queue: &wgpu::Queue, atlas: &FontAtlas) {
        let texture = device.create_texture(&wgpu::TextureDescriptor {
            label: Some("UiPass Font Atlas Texture"),
            size: wgpu::Extent3d {
                width: atlas.width,
                height: atlas.height,
                depth_or_array_layers: 1,
            },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: wgpu::TextureFormat::R8Unorm,
            usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
            view_formats: &[],
        });
        queue.write_texture(
            wgpu::TexelCopyTextureInfo {
                texture: &texture,
                mip_level: 0,
                origin: wgpu::Origin3d::ZERO,
                aspect: wgpu::TextureAspect::All,
            },
            &atlas.pixels,
            wgpu::TexelCopyBufferLayout {
                offset: 0,
                bytes_per_row: Some(atlas.width),
                rows_per_image: Some(atlas.height),
            },
            wgpu::Extent3d {
                width: atlas.width,
                height: atlas.height,
                depth_or_array_layers: 1,
            },
        );

        self.font_atlas_view = Some(texture.create_view(&wgpu::TextureViewDescriptor::default()));
    }
}
```

The view goes into a bind group alongside a `Sampler` (linear filter, clamp-to-edge). The text shader samples the atlas with the glyph's UV.

### Per-glyph instances

A `UiText` is a string and a position. To render it, we walk the string, look up each character's atlas column, and produce one glyph instance per character.

```rust
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, bytemuck::Pod, bytemuck::Zeroable)]
pub struct GlyphInstance {
    pub rect: [f32; 4],
    pub color: [f32; 4],
    pub atlas: [f32; 4],
}

pub struct TextInstance {
    pub content: String,
    pub position: Vec2,
    pub size: f32,
    pub color: Vec4,
    pub clip: Option<Rect>,
}

fn emit_text_glyphs(
    atlas: &FontAtlas,
    text: &TextInstance,
    out: &mut Vec<GlyphInstance>,
) {
    let scale = text.size / (FONT_GLYPH_HEIGHT as f32);
    let advance = (FONT_ADVANCE as f32) * scale;
    let glyph_width = (FONT_GLYPH_WIDTH as f32) * scale;
    let glyph_height = (FONT_GLYPH_HEIGHT as f32) * scale;

    let total_width = (text.content.chars().count() as f32) * advance;
    let mut cursor = text.position.x - total_width * 0.5;
    let y = text.position.y - glyph_height * 0.5;

    for character in text.content.chars() {
        let column = atlas.glyph_of.get(&character).copied().unwrap_or(0);
        out.push(GlyphInstance {
            rect: [cursor, y, glyph_width, glyph_height],
            color: [text.color.x, text.color.y, text.color.z, text.color.w],
            atlas: [
                (column * FONT_GLYPH_WIDTH) as f32,
                FONT_GLYPH_WIDTH as f32,
                FONT_GLYPH_HEIGHT as f32,
                atlas.width as f32,
            ],
        });
        cursor += advance;
    }
}
```

For each character, push a `GlyphInstance` whose `rect` is the glyph's position in pixels, whose `color` is the text color, and whose `atlas` packs the atlas-space (column origin, glyph width, glyph height, atlas total width). The text is centered on `text.position` by computing the total width up front and starting the cursor at the left-shifted position.

The text shader is the same instanced quad trick. Each glyph is one instance. Vertex shader expands the unit quad to the glyph's rect. Fragment shader samples the atlas at the right UV and multiplies the glyph's color by the sampled coverage.

```wgsl
struct GlyphInstance {
    rect: vec4<f32>,
    color: vec4<f32>,
    atlas: vec4<f32>,
}

@group(0) @binding(0) var<uniform> globals: GlobalUniforms;
@group(0) @binding(1) var<storage, read> glyphs: array<GlyphInstance>;
@group(0) @binding(2) var atlas_tex: texture_2d<f32>;
@group(0) @binding(3) var atlas_sampler: sampler;

struct VertexOutput {
    @builtin(position) clip_position: vec4<f32>,
    @location(0) uv: vec2<f32>,
    @location(1) color: vec4<f32>,
}

@vertex
fn vs_main(@builtin(vertex_index) vi: u32, @builtin(instance_index) ii: u32) -> VertexOutput {
    let glyph = glyphs[ii];
    var corners = array<vec2<f32>, 6>(
        vec2<f32>(0.0, 0.0),
        vec2<f32>(1.0, 0.0),
        vec2<f32>(0.0, 1.0),
        vec2<f32>(1.0, 0.0),
        vec2<f32>(1.0, 1.0),
        vec2<f32>(0.0, 1.0),
    );
    let corner = corners[vi];

    let pixel_x = glyph.rect.x + corner.x * glyph.rect.z;
    let pixel_y = glyph.rect.y + corner.y * glyph.rect.w;
    let world_pos = vec2<f32>(pixel_x, pixel_y);

    let column_origin = glyph.atlas.x;
    let glyph_width = glyph.atlas.y;
    let atlas_width = glyph.atlas.w;
    let u = (column_origin + corner.x * glyph_width) / atlas_width;
    let v = corner.y;

    var output: VertexOutput;
    output.clip_position = globals.projection * vec4<f32>(world_pos, 0.0, 1.0);
    output.uv = vec2<f32>(u, v);
    output.color = glyph.color;
    return output;
}

@fragment
fn fs_main(input: VertexOutput) -> @location(0) vec4<f32> {
    let coverage = textureSample(atlas_tex, atlas_sampler, input.uv).r;
    return vec4<f32>(input.color.rgb, input.color.a * coverage);
}
```

This vertex shader sidesteps the vertex-buffer route and uses an inline `corners` array indexed by `vertex_index`. Either approach works; the inline form saves an extra vertex buffer binding. The fragment shader samples the atlas at the computed UV and multiplies the alpha by the coverage (the glyph's bitmap value, 0 in the background, 255 in the strokes). Result: the glyph's strokes appear in the text color, the rest is transparent.

### Centering text in a button's rect

Back in the render-sync step, when we walked entities into `frame.rects`, we also need to walk entities with `UiText` and produce `TextInstance`s positioned in the center of their resolved rect.

```rust
fn sync_text_instances(world: &mut World) {
    let entities: Vec<Entity> = world.query_entities(UI_NODE | UI_TEXT).collect();
    let mut instances: Vec<TextInstance> = Vec::with_capacity(entities.len());
    for entity in entities {
        let Some(node) = world.get_ui_node(entity) else {
            continue;
        };
        if !node.visible {
            continue;
        }
        let resolved = node.resolved;
        let clip = node.clip;
        let Some(text) = world.get_ui_text(entity) else {
            continue;
        };
        if text.content.is_empty() {
            continue;
        }
        instances.push(TextInstance {
            content: text.content.clone(),
            position: resolved.center(),
            size: text.size,
            color: text.color,
            clip,
        });
    }
    world.resources.ui_frame.texts.extend(instances);
}
```

Centered on `resolved.center()`. The text rendering above uses that center as the midpoint and lays the characters out around it. A production renderer would respect a per-text alignment (`TextAlignment::Left`/`Center`/`Right`) and a vertical alignment (`Top`/`Middle`/`Bottom`); the change is replacing `center()` with the appropriate corner and shifting the cursor logic. nightshade's text emission has all six combinations as direct branches.

### Ordering the text against the rects

Text needs to draw on top of its rect. The simplest approach: draw all rects first, then all text. The text pass's render-pass attachment uses `LoadOp::Load` so the rects are visible behind it. This works because no UI design ever wants a label hidden behind its own background.

A more sophisticated renderer interleaves rects and text by z-layer, switching pipelines once per layer so a tooltip's background and text both draw after a popup's background and text, instead of all text drawing after all rects globally. For most apps the simpler ordering is enough.

## The full execute, including text

```rust
impl UiPass {
    pub fn execute<'r>(
        &mut self,
        encoder: &mut wgpu::CommandEncoder,
        color_view: &wgpu::TextureView,
    ) {
        let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
            label: Some("UI Pass"),
            color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                view: color_view,
                resolve_target: None,
                ops: wgpu::Operations {
                    load: wgpu::LoadOp::Load,
                    store: wgpu::StoreOp::Store,
                },
                depth_slice: None,
            })],
            depth_stencil_attachment: None,
            timestamp_writes: None,
            occlusion_query_set: None,
            multiview_mask: None,
        });

        if self.rect_count > 0 {
            pass.set_pipeline(&self.rect_pipeline);
            pass.set_bind_group(0, &self.global_uniform_bind_group, &[]);
            pass.set_bind_group(1, &self.rect_instance_bind_group, &[]);
            pass.set_vertex_buffer(0, self.rect_quad_vertex_buffer.slice(..));
            pass.set_index_buffer(
                self.rect_quad_index_buffer.slice(..),
                wgpu::IndexFormat::Uint16,
            );
            pass.draw_indexed(0..6, 0, 0..self.rect_count);
        }

        if self.glyph_count > 0 {
            pass.set_pipeline(&self.text_pipeline);
            pass.set_bind_group(0, &self.text_bind_group, &[]);
            pass.draw(0..6, 0..self.glyph_count);
        }
    }
}
```

Two pipelines. Two bind groups. The rect pipeline draws every rect with one `draw_indexed`. The text pipeline draws every glyph with one `draw`. For the panel-with-two-buttons example from part one, that is three rects (panel, pick button, cancel button) and eight glyphs (`Pick` + `Cancel`). Eleven instances total, two draws, every frame.

## Hooking it into the main loop

The full per-frame loop now.

```rust
fn run_frame(
    world: &mut World,
    ui_pass: &mut UiPass,
    device: &wgpu::Device,
    queue: &wgpu::Queue,
    color_view: &wgpu::TextureView,
) {
    ui_layout_system(world);
    ui_interaction_system(world);
    ui_render_sync_system(world);

    ui_pass.prepare(device, queue, world);

    let mut encoder = device.create_command_encoder(&wgpu::CommandEncoderDescriptor {
        label: Some("UI Encoder"),
    });
    ui_pass.execute(&mut encoder, color_view);
    queue.submit(std::iter::once(encoder.finish()));
}
```

Three CPU systems, one GPU prepare, one GPU execute. The CPU work is bounded by the entity count. The GPU work is two instanced draws, each touching a few KB of buffer. A UI for a tool with 100 visible widgets renders in microseconds.

In practice the UI pass would be one node in a larger render graph: scene rendering, post-processing, UI overlay, present. The UI pass writes to whichever color attachment the application designates (the swapchain output for a UI-only app, an intermediate target for a 3D app that composites UI after FXAA). nightshade slots it into its render graph with `Reads: ["color"], Writes: ["color"]`, blending on top of the rest of the frame.

## What we built

```
UiPass  (the GPU pipeline + buffers)
├── rect_pipeline                 SDF rounded-rect shader + alpha blend
├── rect_instance_buffer          per-frame Vec<RectInstance>, grows on demand
├── rect_quad_vertex_buffer       shared unit quad geometry
├── rect_quad_index_buffer        shared two-triangle indices
├── text_pipeline                 atlas-sampled bitmap glyph shader
├── glyph_instance_buffer         per-frame Vec<GlyphInstance>
├── font_atlas_view               R8Unorm texture, 5x7 glyph cells
├── global_uniform_buffer         orthographic projection + viewport
└── prev_rect_instances           CPU mirror for diff-skip uploads

FontAtlas
├── pixels: Vec<u8>               flat R8 atlas
├── glyph_of: HashMap<char, u32>  rune -> column index
└── build_font_atlas()            bakes once at startup

Per-frame data
├── world.resources.ui_frame.rects: Vec<RectInstance>
├── world.resources.ui_frame.rect_entities: Vec<Entity>  (slot -> source entity)
└── world.resources.ui_frame.texts: Vec<TextInstance>
```

New systems. `ui_render_sync_system(world)` walks the laid-out tree and packs `frame.rects` and `frame.texts`. `UiPass::prepare(device, queue, world)` uploads what changed since last frame. `UiPass::execute(encoder, color_view)` records the two draws into a command encoder. Three CPU systems, two GPU calls per frame.

The full file is the snippets from this post assembled together, around 900 lines of Rust plus the two WGSL shaders shown above. It compiles standalone in a fresh Cargo project with `wgpu`, `winit`, `bytemuck`, `freecs`, and `nalgebra_glm` as the only dependencies. `cargo run` opens a window, builds the panel-with-two-buttons UI tree at startup, and runs the layout-interaction-render-sync loop every frame. Hovering over a button visibly tints it lighter. Pressing visibly tints it darker. Clicking fires `UiEvent::Clicked { entity }` to the application's event handler, which the main loop prints.

## Where this stops and where production goes

Three systems, two shaders, one render pass. Real applications can ship on top of this. A settings panel, a HUD, an inspector all fit. The list of things a production retained UI adds beyond this is long, and most of it is more components and more systems hanging off the same kernel.

nightshade's retained UI is around 30,000 lines of Rust on top of the kernel built here. The additions fall into a few buckets: animated state (per-state weights advanced toward targets each frame and blended before submission, so the GPU never sees discrete hover/pressed states), theming (colors bound to roles like `ThemeColor::Accent` that crossfade in OKLab when the theme changes), composite layouts (flex and grid, delegated to [taffy](https://crates.io/crates/taffy)), glyph-shaped text (kerning, RTL, full Unicode, SDF fonts), scroll views that finally use the `clip` field, and the full widget set (sliders, dropdowns, tabs, tree views, modals, drag-and-drop, docking). Each widget is a composition of the same four components plus an optional data component like `UiSliderData { value, min, max }` and a system that consumes its interaction events.

None of those require revisiting parts one or two. Adding a widget type means adding a component and a system. Adding a render effect means adding a branch in the fragment shader. The kernel does not change shape.

---

[nightshade](https://github.com/matthewjberger/nightshade) is the production version. Its retained UI runs every interactive surface in the engine (the editor, the in-game HUD, the widget gallery) and shares the same `World` with the rest of the game. The Go implementation at [indigo](https://github.com/matthewjberger/indigo) is around 800 lines, almost a direct translation of the same architecture, and a useful cross-check that the ideas are not Rust-specific.

The retained UI is the last system this series covers, sitting on top of the [archetype ECS](@/posts/2026-04-07-build-your-own-ecs-archetype-storage.md), the [structural change and queries](@/posts/2026-04-12-build-your-own-ecs-structural-change.md), and the [events, change detection, tags, and commands](@/posts/2026-04-17-build-your-own-ecs-events-changes-tags-commands.md). Both ship in nightshade as the foundation everything else builds on.
