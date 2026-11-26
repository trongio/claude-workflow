## UI kit rules: shadcn/ui + Tailwind CSS

### Tokens
- Colours, radii, spacing and type live as CSS variables in the one theme file (`@theme` in Tailwind v4, or `:root` / `.dark` variables mapped in the Tailwind config). Components use the semantic utilities (`bg-background`, `text-muted-foreground`, `border-input`, `bg-destructive`), never palette utilities (`bg-red-500`) and never hex. [ci: tokens]
- No arbitrary values (`w-[13px]`, `text-[#333]`, `mt-[7px]`): add a token or use the scale. A CSS-variable reference to a theme token (`max-h-(--dialog-max-h)`) is a token, not an arbitrary value. [ci: tokens]
- Status colours are tokens named by meaning (`--success`, `--warning`, `--danger`, `--info`, `--pending`), each with a foreground pair that passes AA. [review] [ux]

### Components
- `components/ui/` holds the shadcn primitives as generated; product components live in `components/app/` and compose them. Edit a primitive only to add a typed `variant`/`size`/`tone` through its `cva` definition, and record the change in CATALOG.md. [review]
- A page passes `className` only to place a component (margin, width, grid/flex placement). Restyling a component from a page (colours, padding, typography) is a finding: add a variant. [review] [guard-test where feasible]
- `cn()` (clsx + tailwind-merge) for every conditional class; never string concatenation. [review]
- Icons from one set (`lucide-react` by default), sized by tokens; an icon-only button has an `aria-label` that is an i18n key. [not yet: i18n check] [review]

### Known traps (each shipped at least once)
- `whitespace-nowrap` on `TableCell` and `Button` INHERITS and beats `break-words`, `max-w-*` and `line-clamp`. Prose inside either needs `whitespace-normal`, and a Button that can wrap also needs `h-auto`. [review] [ux: look in the widest locale]
- `leading-none` on `Label` makes wrapped lines collide (ascenders hit descenders) the moment a long-locale label wraps. Use `leading-snug` on any label that can wrap. [review] [ux]
- A bare `grid` sizes its implicit column to max-content and overflows a 375 px screen. Always start with `grid-cols-1` and add columns at a breakpoint (`grid-cols-1 md:grid-cols-2`). [review] [ux]
- A flex child with long text needs `min-w-0` or it refuses to shrink and pushes siblings off-screen. [review]
- `Badge` with a long localized value overflows its row; give it `max-w-full` and truncate with a tooltip only when actually clipped. [review]
- shadcn ships `<span className="sr-only">Close</span>` in `dialog.tsx` and `sheet.tsx`: English in every dialog, invisible to visual review. Replace it with a translated key when the primitive is added. [not yet: i18n check]
- Radix `Select`/`DropdownMenu` content is portalled: container queries and parent overflow do not apply to it; size it with its own `max-w` and collision props. [review]
- `Dialog` on a phone: content taller than the viewport gets a max height from a token (a named theme utility, or `max-h-(--dialog-max-h)` in Tailwind v4 variable syntax, which reads the token and is not an arbitrary value) plus internal scroll, and the primary action must stay reachable. [ux]

### Layout
- Mobile first: base classes are the 375 px layout; `sm:`/`md:`/`lg:` add columns. [review]
- Rows inside cards or columns use container queries (`@container` + `@md:`), because the viewport does not tell a card in a sidebar how wide it is. [review]
- Tables: below `md`, a table becomes a list of cards or scrolls inside its own container with the first column sticky; the page itself never scrolls sideways. [ux]
