+++
title = "Why nightshade ships dozens of small shaders instead of one big one"
tags = ["rust", "graphics", "wgsl", "wgpu", "shaders", "nightshade"]
categories = ["nightshade"]
excerpt = "A pass-based renderer's shaders look very different from a forward renderer's übershader. Here's the shape of nightshade's pipeline and why it's structured this way."
draft = true
+++

Most engines I've worked with bundle their rendering into a small number of mega-shaders riddled with `#ifdef` switches, or use a build-time permutation system that compiles thousands of variants. Both approaches are reasonable, but neither is what nightshade does.

Nightshade's pipeline is built from many small, focused WGSL shaders, each doing one job. The frame graph stitches them together. The cost is more shader files. The benefit is that any individual shader is short enough to read in one sitting, and the boundary between shaders matches the boundary between conceptual rendering passes.

What follows is a tour of the catalog by purpose. A map, not a tutorial.

## Lighting is clustered and GPU-driven

`cluster_bounds.wgsl` computes the world-space AABB of every cluster in the view frustum. `cluster_light_assign.wgsl` tests every active light against each cluster and writes the indices of the ones that touch it. The mesh shader then samples that per-cluster light list per pixel.

Forward+ rendering, basically. Pixels don't iterate over every light in the scene; the trade-off relative to deferred is that material variation costs more.

## Depth feeds GPU-driven culling

The depth prepass writes z-only before any color work. Then `hiz_spd.wgsl` builds the entire HiZ pyramid in one dispatch using subgroup operations (with a fallback `hiz_downsample.wgsl` for mobile and web where subgroup ops aren't reliably available).

HiZ exists for one reason: `mesh_culling.wgsl` samples it to throw away meshes whose AABBs are entirely behind something else. Without GPU-driven culling, frame time tracks scene complexity. With it, frame time tracks visible scene complexity.

`line_culling_gpu.wgsl` does the same for debug lines, since debug overlays in production builds can dump tens of thousands of segments. `instanced_transform_compute.wgsl` keeps per-instance world matrices on the GPU instead of uploading them from CPU each frame.

## Order-independent transparency without sorting

`mesh_oit.wgsl` handles transparency without depth sorting on the CPU. The trade-off is approximation versus correctness: it's good enough for most cases that aren't glass-against-glass, and transparent objects can be instanced and drawn alongside opaque geometry without per-frame CPU cost.

## Image-based lighting is four shaders that run once

The IBL setup at startup: `equirect_to_cube.wgsl` projects an equirectangular HDR into a cubemap. `cubemap_mipgen.wgsl` generates the mip chain. `filter_envmap.wgsl` pre-filters the mips with importance sampling so each mip corresponds to a different surface roughness. `brdf_lut.wgsl` precomputes a 256x256 BRDF integration LUT using Hammersley sequences.

After startup, the PBR mesh shader samples these resources for the IBL specular and diffuse contributions.

## Grass is its own subsystem

Five shaders share state to render an animated grass field at scale: `grass_placement.wgsl` populates an instance buffer from terrain density maps. `grass_culling.wgsl` does frustum and distance LOD on the GPU. `grass_interaction.wgsl` bends blades around dynamic objects. `grass_shadow_depth.wgsl` handles shadow casting. `grass_render.wgsl` is the color render with wind animation and per-blade variation.

This subsystem is heavy enough to be feature-flagged. Most games don't need it.

## The mesh shader is the workhorse

`mesh.wgsl` is the largest single file in the rendering pipeline. It handles PBR shading with GGX-based specular, IBL specular and diffuse from the filtered env-map, clustered light evaluation, PCF shadow filtering, optional emissive and normal mapping, transparency when used as the OIT input, and morph-target displacement for shape-key animation.

Skeletal animation lives in a separate set of shaders (`skinned_mesh.wgsl`, `skinning_compute.wgsl`, and the skinned variants of OIT and shadow-depth). Splitting it out lets static meshes skip the skinning machinery entirely.

Most of the runtime lighting cost lives in `mesh.wgsl`. Branches are kept compile-time where possible, runtime only where features genuinely need to vary per-material.

## Post-processing

Bloom is split: `bloom_downsample.wgsl` builds a mip pyramid of bright pixels, `bloom_upsample.wgsl` blends them back together, and the threshold pass in `effects.wgsl` keeps bloom from blowing out everything by gating on a brightness floor.

`fxaa.wgsl` is post-process antialiasing. `depth_of_field.wgsl` is bokeh DoF with a circle-of-confusion calculation that respects focal distance and aperture.

## Smaller systems worth naming

`decal.wgsl` projects a 2D texture along a frustum onto whatever opaque surface lies underneath. Cheap, additive blend, works over deferred or forward.

`interior_mapping.wgsl` fakes building interiors by intersecting the view ray against an axis-aligned box per fragment. Used for distant city geometry. Looks expensive, costs almost nothing.

`water_mesh.wgsl` handles the water surface with wave displacement and Fresnel-based color blending. The water-specific work is the surface plus refraction sampling against a copy of the scene color.

`line_gpu.wgsl` does GPU line rendering using instanced quads, with each instance reading start/end/color from a structured buffer. `bounding_volume_lines.wgsl` handles debug AABBs and frustums.

## The argument

Splitting rendering into small shaders is more files to keep track of. The payoff is that when something is wrong with bloom, you read the bloom shaders. When something is wrong with culling, you read the culling shaders. The frame graph already encodes which shader feeds which, so the conceptual map matches the file map.

The whole pipeline is at [`crates/nightshade/src/render/wgpu/shaders/`](https://github.com/matthewjberger/nightshade/tree/main/crates/nightshade/src/render/wgpu/shaders). Each shader has a header comment describing its inputs, outputs, and place in the pipeline. The corresponding pass code is at [`passes/`](https://github.com/matthewjberger/nightshade/tree/main/crates/nightshade/src/render/wgpu/passes).
