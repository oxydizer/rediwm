# Proposal: compositor-owned scene graph

Status: unimplemented, retained from the September 2026 proposal. RediWM still
uses `wlr_scene`, projection and the glass implementation. This is an optional
architecture project, not a prerequisite for desktop readiness.

## Motivation and scope

Evaluate whether an owned scene graph would improve fractional positioning,
subtree transforms, backdrop effects and clipping of client corners. Those needs
currently span `src/projection.c`, `src/glass.c` and the two-band window chrome.
The old line counts, mechanical conversion checklist and delivery estimates no
longer describe the current tree and have been removed.

Retain wlroots backends, input/session handling, renderers, allocators, Xwayland
and protocol implementations. Prefer retaining its surface/subsurface commit
semantics behind an adapter over reimplementing them. Static linking and binary
portability are separate packaging decisions, not necessary first steps.

## Possible stages

1. Measure current projection, glass, scene commit and scanout behavior on a
   fixed workload. Identify an actual benefit before replacing infrastructure.
2. Prototype typed nodes with continuous logical coordinates, transforms,
   clipping and optional effects, initially presented through wlroots nodes.
3. Evaluate an owned output-state/render pass only if the prototype justifies
   taking responsibility for damage, buffer age, presentation and scanout.
4. Move backdrop effects and rounded clipping onto that path, then remove
   obsolete projection/chrome workarounds once equivalent behavior is proven.

Every stage must leave a working compositor. Do not let a temporary second
scene representation become a permanent new source of geometry truth.

## Acceptance requirements

Preserve surface commit ordering, explicit-sync fences, frame callbacks,
presentation feedback, damage, hit-testing, color transforms, capture isolation,
output hotplug, and lock coverage. Include popups, IME candidates, subsurfaces,
fractional/mixed scale and close snapshots.

Compare CPU/GPU frame costs and scanout/plane use against the existing renderer;
do not assume glass makes scanout irrelevant. Require equivalent pixels and
capture behavior under isolated tests before migration. The current render
invariants are in [AGENTS.md](../../AGENTS.md), with test commands in
[TESTING.md](../../TESTING.md).
