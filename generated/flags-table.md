| `product` | string | `transcript` \| `memory` \| `digest` \| `faithful` | single only (`full` is a CLI alias, **not** a preset product) |
| `products` | object | keys restricted to the products above | bundle only (exclusive with `product`) |
| `description` | string | — | optional human one-liner (picker row / `--list-presets` / legend); it travels with the recipe |
| Product flags (top level for single, per product for bundle): | | | |
| `filter` / `sessions` | string / string[] | — | selection (shared; exclusive, `not` both) |
| `no_subagents` | bool | — | any |
| `no_orphan_subagents` | bool | — | any |
| `sub` | string | `separate` \| `inline` \| `omit` | transcript |
| `tool_output` | string | `full` \| `truncated` \| `omit` | transcript |
| `tool_input_limit` | int | ≥ 0 | transcript |
| `tool_output_limit` | int | ≥ 0 | transcript |
| `patch` | string | `full` \| `omit` | transcript |
| `no_reasoning` | bool | — | transcript, digest |
| `mark_compactions` | bool | — | transcript, digest |
| `summary_diffs` | bool | — | transcript, digest |
| `role` | string | `all` \| `user` \| `assistant` | transcript, digest |
| `sanitize` | bool | — | any |
| `snapshot` | string | `fresh` | any |
| `cap` | int | 0 = unlimited (≥ 0) | memory |
| `files` | bool | — | memory (touched files) |
| `out` | string | — | any — CLI-only (never a preset key: output root) |
| `last` | int ≥ 1 | — | any — CLI-only (never a preset key: a recency rule, recomputed at run time) |
| `since` | date YYYY-MM-DD | — | any — CLI-only (never a preset key: a recency rule, recomputed at run time) |
