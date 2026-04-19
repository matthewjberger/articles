+++
title = "Building a frame graph in Rust"
tags = ["rust", "graphics", "wgpu", "render-graph", "nightshade"]
categories = ["nightshade"]
excerpt = "How nightshade compiles a list of declared passes into a scheduled, aliased, dead-pass-culled execution plan."
+++

Render passes have to run in some order. Their dependencies form a DAG. Nightshade's renderer is structured around exactly that: a petgraph DAG with topological scheduling, transient resource lifetime analysis, memory aliasing, and dead-pass culling. The pattern is what the literature calls a frame graph; Yuriy O'Donnell's Frostbite talk is the canonical reference. I built nightshade's from first principles and the design converged on what the talk describes, which means the trade-offs are the right ones rather than novel ones.

The implementation is at [`crates/nightshade/src/render/wgpu/rendergraph/`](https://github.com/matthewjberger/nightshade/tree/main/crates/nightshade/src/render/wgpu/rendergraph). Three files: `graph.rs` is the orchestrator, `pass.rs` defines the trait and builders, `resources.rs` is the resource registry.

## The contract

Every pass implements `PassNode<C>`:

```rust
pub trait PassNode<C = ()>: Send + Sync + std::any::Any {
    fn name(&self) -> &str;
    fn reads(&self) -> Vec<&str>;
    fn writes(&self) -> Vec<&str>;
    fn reads_writes(&self) -> Vec<&str> { Vec::new() }
    fn optional_reads(&self) -> Vec<&str> { Vec::new() }
    fn prepare(&mut self, _device: &Device, _queue: &wgpu::Queue, _configs: &C) {}
    fn invalidate_bind_groups(&mut self) {}
    fn execute<'r, 'e>(
        &mut self,
        context: PassExecutionContext<'r, 'e, C>,
    ) -> Result<Vec<SubGraphRunCommand<'r>>>;
}
```

The pass declares its slot names (reads, writes, reads-writes, optional-reads). The graph wires those slot names to actual `ResourceId`s when the pass is added. No runtime guessing. Every dependency is declared up front.

Resources come in two flavors. Transient resources are owned by the graph; their lifetimes are managed; they can share GPU memory with other transients that don't overlap. External resources are owned by the caller and provided each frame. The swapchain texture is the canonical external resource.

## What `compile()` does

Five passes, in this order:

1. **Build dependency edges.** For each pass, walk its reads and optional-reads. If a previous pass wrote that resource, add an edge from writer to reader. Result: a DAG over passes, edges labeled with the resource that connects them.
2. **Topologically sort.** petgraph's `toposort`. The result is the execution order.
3. **Compute resource lifetimes.** Walk the execution order. For each resource, record its first-use and last-use indices. This is the input to memory aliasing.
4. **Cull dead passes.** Walk backwards from the swapchain. Any pass whose outputs are never read (directly or transitively) doesn't contribute to the final image and gets dropped. The graph keeps a `culled_passes: HashSet<NodeIndex>` and skips them at execution time.
5. **Decide store ops.** If a pass writes an attachment that no subsequent pass reads, the store op becomes `Discard` instead of `Store`. Free win on tiled mobile GPUs, no cost on desktop.

## Resource aliasing

Two transient resources whose lifetimes don't overlap can share GPU memory. The graph tracks pools of compatible resource descriptors and assigns lifetimes into them like a register allocator assigns variables to registers.

```text
Pass 1: writes A
Pass 2: reads A, writes B
Pass 3: reads B, writes C   ← A's memory can be reused for C
Pass 4: reads C, writes output
```

The aliasing data lives in `ResourceAliasingInfo { pools, aliases }`, computed once per recompile. `get_texture(id)` looks up the pool slot and returns whatever physical texture is currently mapped there. The descriptor has to match (same format, dimensions, sample count, mip count) or the resources can't share a pool.

The savings compound across the pipeline. Depth prepass, shadow cascades, geometry buffer, OIT accumulation, the bloom mip chain, post-process scratch: all participate in the same pool layout, and most never need to coexist in memory.

## What I deliberately didn't build

**Async compute and multi-queue.** wgpu's API surface for multiple queues isn't where I want it for this style of orchestration yet. The graph would handle it. The underlying API doesn't make it free.

**Cross-frame transients.** Some engines use the frame graph for resources that survive into the next frame (TAA history, motion vectors). Nightshade treats those as external resources instead. The caller owns them and provides them each frame. Slightly more work for the user, much cleaner ownership semantics on the graph side.

**Subgraphs as first-class citizens.** There's a `SubGraphRunCommand` mechanism that lets a pass spawn a sub-execution. It's a footnote, not a feature. Most cases that want subgraphs are better served by feature-flagging passes in or out at compile time. Doing it at runtime would let users shoot themselves in the foot in interesting ways.

## The recompile cache was a mistake I had to find

The first version recompiled the graph every frame. Topology only changes when passes get added or removed, which during normal play is approximately never, so this was pure waste. The graph now carries `needs_recompile: bool` and rebuilds only when something actually changed. Frame-time impact dropped to zero.

The case I haven't cleanly solved is a pass mutating its own reads or writes set at runtime (a debug toggle that adds an extra output, for example). The user has to call `mark_needs_recompile()` for that to take effect. I'd like it to be automatic, but the API surface for "pass mutated its declarations" is awkward and I haven't designed something I'm happy with.

## Calling it

```rust
let mut graph = RenderGraph::new();
let depth = graph.add_depth_texture("depth").size(1920, 1080).clear_depth(0.0).transient();
let scene = graph.add_color_texture("scene_color").format(wgpu::TextureFormat::Rgba16Float).transient();
let swapchain = graph.add_color_texture("swapchain").format(wgpu::TextureFormat::Bgra8UnormSrgb).external();

graph.add_pass(Box::new(SceneDrawPass::new(device)), &[("color", scene), ("depth", depth)])?;
graph.add_pass(Box::new(BloomPass::new(device)), &[("input", scene), ("output", swapchain)])?;
graph.compile()?;

// Each frame:
graph.set_external_texture(swapchain, Some(surface_texture), surface_view, w, h);
let command_buffers = graph.execute(&device, &queue, &world)?;
queue.submit(command_buffers);
```

That's the whole user-facing API. Declare resources, declare passes, compile, run.

The interesting code is in [`graph.rs`](https://github.com/matthewjberger/nightshade/blob/main/crates/nightshade/src/render/wgpu/rendergraph/graph.rs), where compile and execute fit together. The pass implementations under [`passes/`](https://github.com/matthewjberger/nightshade/tree/main/crates/nightshade/src/render/wgpu/passes) (geometry, postprocess, setup, shadow_depth, ui) are the practical examples of how passes get written against the contract.
