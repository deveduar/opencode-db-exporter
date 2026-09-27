| `product` | string | `transcript` \| `memory` \| `compactions` | single only (`full` is a CLI alias, **not** a preset product) |
| `products` | object | keys restricted to the 3 products | bundle only (exclusive with `product`) |
| Product flags (top level for single, per product for bundle): | | | |
| `filter` / `sessions` | string / string[] | — | selection (shared; exclusive, `not` both) |
| `no_subagents` | bool | — | any |
| `no_orphan_subagents` | bool | — | any |
| `sub` | string | `separate` \| `inline` \| `omit` | transcript |
| `tool_output` | string | `full` \| `truncated` \| `omit` | transcript |
| `tool_input_limit` | int | ≥ 0 | transcript |
| `tool_output_limit` | int | ≥ 0 | transcript |
| `patch` | string | `full` \| `omit` | transcript |
| `no_reasoning` | bool | — | transcript, compactions |
| `mark_compactions` | bool | — | transcript, compactions |
| `summary_diffs` | bool | — | transcript, compactions |
| `role` | string | `all` \| `user` \| `assistant` | transcript, compactions |
| `json` | bool | — | transcript/compactions (faithful archive) |
| `sanitize` | bool | — | any |
| `snapshot` | string | `fresh` | any |
| `cap` | int | 0 = unlimited (≥ 0) | memory |
| `files` | bool | — | memory (touched files) |
| `out` | string | — | any — CLI-only (never a preset key: output root) |
| `last` | int ≥ 1 | — | any — CLI-only (never a preset key: a recency rule, recomputed at run time) |
| `since` | date YYYY-MM-DD | — | any — CLI-only (never a preset key: a recency rule, recomputed at run time) |
