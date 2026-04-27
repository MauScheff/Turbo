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
