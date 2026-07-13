# Grocery Planner — Design System Bundle

Static HTML "design twin" of the LiveView component layer, synced to the
**Grocery Planner** design-system project on claude.ai/design via `DesignSync`.

## What this is

Each `*.html` file is a self-contained preview card mirroring one component
family from the app:

| Preview | Source of truth |
|---|---|
| `components/buttons.html` | `CoreComponents.button/1` |
| `components/inputs.html` | `CoreComponents.input/1` (+ `error/1`) |
| `components/flash.html` | `CoreComponents.flash/1` |
| `components/modal.html` | `CoreComponents.modal/1` |
| `components/table.html` | `CoreComponents.table/1` |
| `components/data-list.html` | `CoreComponents.list/1` |
| `components/empty-state.html` | `UIComponents.empty_state/1` |
| `components/stat-cards.html` | `UIComponents.stat_card/1` |
| `components/page-header.html` | `UIComponents.page_header/1` |
| `components/section.html` | `UIComponents.section/1` |
| `components/list-item.html` | `UIComponents.list_item/1` |
| `components/nav-cards.html` | `UIComponents.nav_card/1` |
| `components/item-cards.html` | `UIComponents.item_card/1` |
| `components/skeletons.html` | `Components.Skeletons` |
| `foundations/*.html` | Skillet theme tokens + type ramp |
| `styles.css` | Skillet token layer as authored in Claude Design (ported into `assets/css/app.css` as `daisyui-theme` blocks — keep both in sync) |

`assets/app.css` is the **compiled** production stylesheet (`mix assets.build`
output copied from `priv/static/assets/css/app.css`). Previews therefore render
pixel-identical to the app, across the 4 Skillet themes — fairway (default),
orchard, marble, dark (switcher top-right of every card).

## Round-trip workflow

1. Design iteration happens on these HTML files in the claude.ai/design project.
2. Approved changes are ported back into the HEEx components — class strings
   move 1:1; `phx-*` bindings, assigns, and slots never live here.
3. After changing HEEx or previews, rebuild and refresh the bundle CSS:
   ```sh
   mix assets.build
   cp priv/static/assets/css/app.css design/assets/app.css
   ```
4. Re-sync changed files with DesignSync (incremental, plan-gated).

## Rules

- **HEEx is the source of truth for behaviour; this bundle is a rendering.**
  Never port markup structure changes back without re-checking accessibility
  attributes and LiveView bindings in the real component.
- **`design/` is a Tailwind source** (`@source "../../design"` in
  `assets/css/app.css`), so classes used only in previews still compile. This
  also safelists the dynamically interpolated classes in `UIComponents`
  (`bg-#{color}/10` etc.) that Tailwind's text scanner cannot see in the `.ex`
  source.
- Every preview's first line must keep its `<!-- @dsCard ... -->` marker — the
  Design pane builds its card index from it.
