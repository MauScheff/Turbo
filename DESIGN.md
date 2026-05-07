# Design

This file captures the current BeepBeep UI direction so new screens stay coherent.

## Thesis

BeepBeep should feel:

- simple
- reliable
- integrated
- calm

This is not a decorative product. It should feel closer to Apple setup flows and utility apps than to a polished marketing app.

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

## Progressive Disclosure

Show the minimum useful truth. The primary UI should expose only the state the user needs right now.

Escalate detail only when it changes user action. Internal phases, retries, transport choices, and implementation states belong in diagnostics, logs, settings, or developer surfaces unless they materially affect what the user should do next.

Keep expert detail available, not ambient. Developers and power users need observability, but end users should not live inside the machinery.

## State And Transience

Prefer stable perception over maximal state fidelity. Logs need fidelity; product UI needs understandable continuity.

Suppress harmless transients. Very short-lived states should usually be smoothed, delayed, or absorbed unless showing them prevents confusion or confirms meaningful progress.

Use motion to explain continuity, not to decorate. Transitions should help users understand that a surface opened, collapsed, connected, changed state, or completed an action.

## Current Layout System

The app currently uses these shared values in `Turbo/TurboDesign.swift`:

- horizontal padding: `24`
- content max width: `360`
- primary button max width: `320`
- field corner radius: `18`

These values should be reused before introducing new ones.

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
- multiple accent colors
- over-explaining helper text
- dense toolbars
- visually loud empty states
- controls stretched edge-to-edge without a reason

## Decision Rule

If a screen looks more “designed” but less calm, less clear, or less native, simplify it.
