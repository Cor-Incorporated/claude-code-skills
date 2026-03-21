---
name: ui-design-system
description: "Design system toolkit: generate design tokens (colors, typography, spacing), document components, calculate responsive layouts, and produce developer handoff assets. Use when creating a design system, generating tokens from brand colors, ensuring visual consistency, or preparing dev handoff. Triggers: 'generate design tokens', 'create color palette', 'design system setup', 'typography scale'. Do NOT use for UX research, user testing, or backend architecture."
allowed-tools: [Bash, Read]
---

# UI Design System

Generate and maintain scalable design system artifacts.

## Core Capabilities

- Design token generation (colors, typography, spacing, shadows, animation).
- Component system architecture and documentation.
- Responsive design calculations (breakpoints, fluid scales).
- Accessibility compliance checks (contrast ratios, focus states).
- Developer handoff in multiple formats.

## Token Generator

Run: `python scripts/design_token_generator.py [brand_color] [style] [format]`

| Argument | Values | Default |
|----------|--------|---------|
| `brand_color` | Any hex color (e.g., `#3B82F6`) | Required |
| `style` | `modern`, `classic`, `playful` | `modern` |
| `format` | `json`, `css`, `scss` | `json` |

### Generated Tokens

- **Color palette**: Primary, secondary, neutral, semantic (success/warning/error/info) with 50-950 shades.
- **Typography scale**: Modular scale (1.25 ratio for modern, 1.333 for classic, 1.2 for playful).
- **Spacing**: 8pt grid system (4, 8, 12, 16, 24, 32, 48, 64, 96).
- **Shadows**: 5-level elevation scale.
- **Breakpoints**: sm (640), md (768), lg (1024), xl (1280), 2xl (1536).

## Error Handling

- If `brand_color` is not a valid hex, reject with an example of correct format.
- If contrast ratio between generated text/background pairs falls below WCAG AA (4.5:1), auto-adjust and warn.
- If the requested format is unsupported, list supported formats and ask the user to choose.
