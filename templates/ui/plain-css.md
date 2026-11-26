## UI kit rules: plain CSS (custom properties, cascade layers)

### Tokens
- One `tokens.css` defines every colour, space step, radius, shadow, font size, line height and z-index as a custom property (`--space-2`, `--text-sm`, `--color-danger`). Component CSS uses only `var(--...)`; hex colours and raw `px` values outside `tokens.css` fail the tokens gate. [ci: tokens]
- Semantic names over palette names: `--color-surface`, `--color-text-muted`, `--color-danger`, `--color-pending`; dark mode redefines the semantic tokens, never the components. [review]
- `@layer reset, tokens, base, components, utilities;` declared once; component styles never use `!important`. [review]

### Components
- One component = one template/partial + one CSS file (or one `@scope` block) named after it; class names are BEM-like (`.card`, `.card__title`, `.card--compact`) or scoped. Variants are modifier classes listed in CATALOG.md, not one-off overrides on a page. [review]
- A page's own CSS only places components (grid areas, gaps, widths); restyling a component from page CSS is a finding: add a modifier. [review]
- Use logical properties (`margin-inline`, `padding-block`, `inset-inline-start`) so a right-to-left locale works without a second stylesheet. [review]

### Known traps
- `white-space: nowrap` inherits: put it on the element that must not wrap (a number, a code), never on a row or cell container that can hold prose. [review] [ux]
- `line-height: 1` on a label collides wrapped lines in long locales; labels use the body line height. [review] [ux]
- A bare `display: grid` with `grid-template-columns: repeat(auto-fit, minmax(300px, 1fr))` overflows at 320 px: use `minmax(min(100%, 300px), 1fr)`. [review] [ux]
- Flex children with text need `min-width: 0`; long unbroken strings (emails, ids) need `overflow-wrap: anywhere`. [review]
- `100vh` on phones hides content behind browser chrome: use `100dvh`. [review]

### Layout
- Mobile first: the base rules are the 375 px layout; `@media (width >= 48rem)` adds columns. [review]
- Rows that live inside cards and sidebars use container queries (`container-type: inline-size` + `@container (width > 30rem)`). [review]
