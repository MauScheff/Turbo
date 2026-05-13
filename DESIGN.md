# Design

This file captures the current BeepBeep UI direction so new screens stay coherent.

## Thesis

BeepBeep should feel:

- simple
- reliable
- integrated
- calm

This is not a decorative product. It should feel closer to Apple setup flows and utility apps than to a polished marketing app.

## Apple-Native Direction

BeepBeep should feel native to Apple platforms, not merely Apple-inspired.

Use Apple's Human Interface Guidelines as the baseline for interaction, layout, typography, motion, and accessibility. When designing or changing UI, the local rule is:

- adopt platform conventions before inventing custom ones
- use native SwiftUI controls before custom controls
- use system typography, semantic colors, SF Symbols, and Dynamic Type
- use native navigation patterns: tab bars, navigation stacks, sheets, sidebars, split views, and standard gestures
- use platform materials where they help hierarchy, but do not build fake glass effects

The app should feel integrated with the phone itself: light, tactile, responsive, and unobtrusive.

## Liquid Glass

Treat Liquid Glass as a native material and interaction direction, not a visual effect to imitate.

The intent is:

- content-first composition
- minimal chrome
- adaptive materials
- spatial layering
- fluid motion
- restrained visual design
- platform-native interaction patterns

Use translucency sparingly for surfaces that naturally float above content: navigation bars, contextual overlays, compact controls, sheets, and modal layers. Avoid using glass for dense text, settings groups, long reading surfaces, full-page backgrounds, or decorative cards.

Do not fake Apple UI with hardcoded blur stacks, random opacity overlays, neon glassmorphism, or custom reflection effects. Prefer native SwiftUI `Material`, semantic colors, native controls, and system behavior so the UI adapts to light/dark mode, contrast, accessibility, motion settings, and future OS updates.

Readability wins over translucency. If material treatment makes text or state harder to understand, simplify the surface.

## Floating Controls

Use native material for controls that float above the content layer, such as top icon controls, contextual overlays, and bottom primary actions. This matches Apple's Liquid Glass direction: controls and navigation can form a distinct functional layer over content, while the content itself should stay readable and structurally quiet.

For BeepBeep, floating controls should share one family:

- native SwiftUI `Material`, usually `.regularMaterial` for visible floating controls and `.thinMaterial` only when the control already has enough contrast
- native SwiftUI Liquid Glass APIs, such as `glassEffect`, for custom controls that truly float above content
- continuous circles or capsules
- neutral material edges and subtle depth, not colored outlines
- accent color in the symbol or text only when it communicates action
- at least a 44 pt tap target on iOS

Primary conversation actions, such as `Ask to Talk`, `Ask Again`, and `Accept`, should remain solid so their priority is unmistakable. Use Liquid Glass for floating controls and quiet inactive action states, not for the main action that starts or accepts a conversation.

In SwiftUI, render the main conversation action as a native large capsule button. Prefer `.buttonStyle(.borderedProminent)`, `.controlSize(.large)`, and `.buttonBorderShape(.capsule)` for enabled `Ask to Talk` and `Accept` actions. Use a quieter native bordered style for disabled, cooldown, or muted states. Do not custom-paint these buttons with manual fills, outlines, blur stacks, or shadows unless the native style fails a concrete product need.

Do not apply this treatment to every row or content group. Contact rows, settings content, and text-heavy surfaces should generally use spacing, dividers, semantic system backgrounds, or standard materials instead of glassy decoration.

## Product Tone

- Brand first, but quietly.
- Utility over ornament.
- One obvious action per screen.
- Sparse copy.
- Stable layouts.
- No visual cleverness that competes with the task.

## Visual Rules

- Prefer integrated layouts over floating cards.
- Use whitespace and alignment before adding chrome.
- Keep content in a narrow readable column.
- Keep primary actions narrower than full screen when possible.
- Use muted secondary text and a single prominent button style.
- Prefer dividers and section rhythm over boxed panels.
- Keep iconography simple and functional.

## Visual Economy

Start by removing what does not help the user act. Use spacing, alignment, type scale, weight, color, opacity, and motion to manage attention before adding boxes, borders, badges, dividers, icons, or containers.

Add visible structure only when it clarifies behavior, grouping, or state. Avoid decorative structure: a card, outline, pill, chevron, or background shape should earn its place.

Reduce before emphasizing. If a screen feels busy, first remove competing signifiers, then strengthen the remaining primary action.

## Affordances And Signifiers

Affordances should be real, and signifiers should be intentional.

Only signify real actions. If something looks tappable, expandable, draggable, dismissible, or navigable, it should be. If something is only status or metadata, avoid interactive signifiers.

Match signifier strength to importance. Primary actions can use strong shape, color, and size. Secondary actions should preserve expected hit targets and accessibility while using quieter visual treatment.

Prefer familiar platform signifiers for familiar actions, but do not copy platform styling blindly. Borrow interaction patterns, not skins.

## User Goal First

Design around the user's goal. Every visual choice should help the user understand where they are, what matters now, and what they can do next.

Lead with the object of attention: the person, place, object, document, task, or decision the user is acting on. Avoid restating the feature or mode when the screen already provides that context.

Keep the interface task-shaped. A focused surface should reduce choices, quiet unrelated controls, and make the intended workflow feel natural and low-effort.

## Hierarchy And Attention

Use hierarchy to express importance. Make the primary thing obvious, make secondary things calm, and hide or soften everything that does not help the current task.

Let empty space do work. Use spacing to group, separate, and pace the interface before adding visible separators.

Preserve physical affordance even when visual weight is low. A quiet control can still have a large tap target, clear placement, and an accessibility label.

Prefer depth over decoration. Use spacing, elevation, material, scale, focus, and continuity to express hierarchy before reaching for gradients, outlines, shadows, or saturated backgrounds.

## Progressive Disclosure

Show the minimum useful truth. The primary UI should expose only the state the user needs right now.

Escalate detail only when it changes user action. Internal phases, retries, transport choices, and implementation states belong in diagnostics, logs, settings, or developer surfaces unless they materially affect what the user should do next.

Keep expert detail available, not ambient. Developers and power users need observability, but end users should not live inside the machinery.

## State And Transience

Prefer stable perception over maximal state fidelity. Logs need fidelity; product UI needs understandable continuity.

Suppress harmless transients. Very short-lived states should usually be smoothed, delayed, or absorbed unless showing them prevents confusion or confirms meaningful progress.

Use motion to explain continuity, not to decorate. Transitions should help users understand that a surface opened, collapsed, connected, changed state, or completed an action.

Motion should feel physical and purposeful. Prefer transitions that preserve context and spatial continuity. Avoid random springiness, flashy animation, or abrupt modal jumps that do not explain structure.

Respect reduced-motion settings. Motion is part of meaning, not a required path to comprehension.

## Native Interaction Patterns

Native feeling comes more from behavior than appearance.

Prefer:

- standard navigation stacks and large-title rhythm on iPhone
- bottom tab bars when the app has durable top-level modes
- bottom sheets for focused, temporary decisions
- sidebars, split views, and resizable panels on iPad and macOS
- segmented controls, toggles, pickers, menus, lists, and swipe actions where the platform expects them

Avoid reinventing navigation, basic controls, gestures, scrolling, or selection behavior unless the product need is specific and defensible.

Use SF Symbols for familiar actions. Do not use text labels where a standard icon plus accessibility label is clearer and more native.

## Density

Modern Apple-native screens are calm because they hide complexity until it matters.

Prefer:

- fewer simultaneous actions
- progressive disclosure
- contextual controls
- large readable type
- clear alignment
- generous rhythm

Avoid dense dashboards, always-visible toolbars, compressed labels, and text-heavy control clusters in the primary product UI.

## Current Layout System

The app currently uses these shared values in `Turbo/TurboDesign.swift`:

- horizontal padding: `24`
- content max width: `360`
- primary button max width: `320`
- field corner radius: `18`

These values should be reused before introducing new ones.

When adding new shared values, prefer semantic tokens over one-off constants. Values should support native rhythm and accessibility rather than recreate a custom visual skin.

## SwiftUI Implementation Guidance

SwiftUI is the preferred UI implementation surface.

Use:

- native SwiftUI materials for layered surfaces
- semantic colors instead of hardcoded light/dark values
- system typography and Dynamic Type
- native controls and navigation APIs
- accessibility labels, traits, and hit targets from the start
- native transitions where they preserve continuity

Avoid:

- custom fake-glass modifiers
- hardcoded blur/opacity systems
- custom controls that duplicate platform controls
- fixed-size text that breaks Dynamic Type
- decorative backgrounds that compete with content

## Screen Guidance

### Entry Screens

- The wordmark is the visual anchor.
- The primary button lives near the bottom safe area.
- Use negative space intentionally.
- Avoid extra labels, helper text, or stacked controls unless needed.

### Setup Screens

- Reuse the same content width and spacing rhythm as the splash.
- Left-align the copy column.
- Keep the action area compact and obvious.
- Inputs should feel native and quiet.

### Main Product Screens

- Favor layout over card collections.
- Empty states should feel calm, not promotional.
- Section headers should explain what the user can do, not sell the feature.

### Contact Rows

Contact rows are content, not floating controls. Keep them lightweight and list-like:

- use spacing, alignment, and text hierarchy before borders or card chrome
- align row content with the section label edge; avoid double-insetting avatars or primary text
- prefer vertical rhythm between rows over hard divider lines when the list is sparse
- put the person object on the left, using an avatar or initials placeholder until real profile images exist
- show the display name first, then the handle or local subtitle
- show availability as a quiet dot and label, not a loud colored badge
- use a chevron when tapping opens a focused contact surface
- do not show durable selected state in the list; list rows are navigation entries, not the selected peer itself

The focused contact surface owns the strong action and becomes the selected peer for app-side prewarm. In the current prototype, tapping an idle row opens a person surface with `Ask to Talk` / `Hold To Talk`; tapping an active conversation row goes directly to the call screen; long-pressing a row can request directly. This keeps the contact list lightweight while preserving a fast expert path.

On the focused contact surface, lead with the person and one clear action. Show identity once: avatar, display name, then a single quiet metadata row for handle and user-visible status. Avoid repeating the handle or placing connection state as a separate competing line.

System-owned session state should stay secondary. If iOS PushToTalk needs an escape hatch, present it as quiet status with a compact `End` control, not as a large card or primary row. Transport path labels are diagnostics-adjacent; keep them small and subdued on product surfaces.

### Sheets

- Use a narrow column with section dividers.
- Do not default to card stacks.
- Keep destructive actions clearly separated from routine actions.

## Copy Guidance

- Prefer direct labels: `Add Contact`, `Continue`, `Scan`, `Share`.
- Avoid marketing phrases or emotional copy.
- Supporting text should explain behavior in one sentence.

## Things To Avoid

- full-screen card mosaics
- decorative gradients
- decorative glass effects
- multiple accent colors
- over-explaining helper text
- dense toolbars
- visually loud empty states
- controls stretched edge-to-edge without a reason
- text on noisy translucent surfaces
- full-page blur
- custom navigation or gesture systems without a strong reason

## AI UX Workflow

When using the `ux-design` skill or asking an AI agent to design, review, or change UI, this file is the project source of truth.

Apply the UX skill through this lens:

1. Start with the user's goal and the main object of attention.
2. Choose the native Apple interaction pattern for that goal.
3. Remove chrome before adding structure.
4. Use native SwiftUI controls, materials, typography, colors, and motion.
5. Keep implementation states and transport details out of the primary UI unless they change user action.
6. Check that anything visually interactive is actually interactive.
7. Prefer the calmer, simpler, more platform-native version.

## Decision Rule

If a screen looks more “designed” but less calm, less clear, or less native, simplify it.
