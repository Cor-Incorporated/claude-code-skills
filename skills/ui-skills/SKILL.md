---
name: ui-skills
description: "Opinionated UI constraints for Tailwind CSS, accessibility, animation, and layout. Use when building, reviewing, or fixing UI components. Triggers: 'review this component', 'check UI quality', 'build a form/modal/dialog', 'fix animation jank', 'accessible button'. Do NOT use for backend logic, API design, or database work."
allowed-tools: [Read, Grep]
---

# UI Skills

Apply these constraints to all UI work. When reviewing a file, output: violation (exact line), why it matters (1 sentence), concrete fix (code).

## Stack

- Use Tailwind CSS defaults unless custom values already exist or are explicitly requested.
- Use `motion/react` (formerly `framer-motion`) for JavaScript animation.
- Use `tw-animate-css` for entrance and micro-animations.
- Use `cn` utility (`clsx` + `tailwind-merge`) for class logic.

## Components

- Use accessible primitives (`Base UI`, `React Aria`, `Radix`) for keyboard/focus behavior.
- Use the project's existing component primitives first.
- NEVER mix primitive systems within the same interaction surface.
- Prefer [`Base UI`](https://base-ui.com/react/components) for new primitives if compatible.
- Add `aria-label` to icon-only buttons.
- NEVER rebuild keyboard or focus behavior by hand.

## Interaction

- Use `AlertDialog` for destructive or irreversible actions.
- Use structural skeletons for loading states.
- Use `h-dvh` instead of `h-screen`.
- Respect `safe-area-inset` for fixed elements.
- Show errors next to where the action happens.
- NEVER block paste in `input` or `textarea`.

## Animation

- NEVER add animation unless explicitly requested.
- Animate only compositor props (`transform`, `opacity`).
- NEVER animate layout properties (`width`, `height`, `top`, `left`, `margin`, `padding`).
- Avoid animating paint properties (`background`, `color`) except for small local UI.
- Use `ease-out` on entrance.
- NEVER exceed `200ms` for interaction feedback.
- Pause looping animations when off-screen.
- Respect `prefers-reduced-motion`.
- NEVER introduce custom easing curves unless explicitly requested.

## Typography

- Use `text-balance` for headings, `text-pretty` for body/paragraphs.
- Use `tabular-nums` for data.
- Use `truncate` or `line-clamp` for dense UI.
- NEVER modify `letter-spacing` unless explicitly requested.

## Layout

- Use a fixed `z-index` scale (no arbitrary `z-*`).
- Use `size-*` for square elements instead of `w-*` + `h-*`.

## Performance

- NEVER animate large `blur()` or `backdrop-filter` surfaces.
- NEVER apply `will-change` outside an active animation.
- NEVER use `useEffect` for anything expressible as render logic.

## Design

- NEVER use gradients unless explicitly requested.
- NEVER use purple or multicolor gradients.
- NEVER use glow effects as primary affordances.
- Use Tailwind default shadow scale unless explicitly requested.
- Give empty states one clear next action.
- Limit accent color to one per view.
- Use existing theme or Tailwind color tokens before introducing new ones.

## Error Handling

- If a constraint conflicts with an explicit user request, follow the user request and note the deviation.
- If a component violates multiple constraints, report all violations sorted by severity (accessibility > performance > design).
