## UI kit rules: Mantine

### Tokens
- The theme (`createTheme`) is the only place for colours, radius, spacing, font sizes and breakpoints; components use theme keys (`c="dimmed"`, `p="md"`, `radius="sm"`, `var(--mantine-color-...)`), never hex or raw px. [ci: tokens] for hex, [review] for raw px
- Status colours are theme colours named by meaning (`success`, `warning`, `danger`, `pending`) with AA contrast for both filled and light variants in both colour schemes. [review] [ux]
- No `style={{ ... }}` props for visual styling; `styles`/`classNames` API only in the catalogued wrapper, never on a page. [ci: tokens] [review]

### Components
- Product components in `components/app/` wrap Mantine components and expose typed `variant`/`tone`/`size` props; pages use the wrappers, not raw Mantine components with ad-hoc props, for anything catalogued. [review]
- A page passes only placement props (`mt`, `w`, `maw`, grid span); appearance belongs in the wrapper's variants. [review]
- Forms with `@mantine/form` + a zod resolver; a refused submit keeps values and shows the server's reason on the field. [review] [ux]
- Every icon-only `ActionIcon` has an `aria-label` from an i18n key. [not yet: i18n check]

### Known traps
- `Table` cells do not wrap long localized words by default inside `Table.ScrollContainer`: set `style` via the catalog wrapper to `overflow-wrap: anywhere` for prose columns, and check in the widest locale. [ux]
- `Group` has `wrap="nowrap"` in many examples: that pushes buttons off a 375 px screen. Default to wrapping. [review] [ux]
- `SimpleGrid cols={3}` without a responsive object overflows on phones: always `cols={{ base: 1, sm: 2, lg: 3 }}`. [review]
- `Modal` on phones: use `fullScreen` below `sm` so the primary action stays reachable. [ux]
- `Select`/`Combobox` dropdowns are portalled: width and max height come from their own props. [review]

### Layout
- Mobile first with the responsive object syntax (`{ base, sm, md }`); `AppShell` navbar collapses below `sm`. [review]
- Container queries (`@container`) for rows inside cards, via the catalog wrapper's CSS module. [review]
