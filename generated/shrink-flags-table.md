## Session selection — CLI only (the menu asks you with its picker)

| Key | Allowed | Meaning |
|---|---|---|
| `keep` | int ≥ 1 | keep the N most recent sessions (by last update) |
| `older_than` | int ≥ 1 | keep sessions updated within the last N days |
| `since` | string | keep sessions updated on or after DATE (YYYY-MM-DD, UTC) |
| `keep_all` | true/false | keep ALL sessions (just prune orphans + vacuum) |
| `keep_sessions` | string[] | keep ONLY the listed session ids (+ their parents/subagents) |
| `discard_sessions` | string[] | keep everything EXCEPT the listed session ids (+ their subagents) |

Exactly ONE selection rule (`keep` \| `older_than` \| `since` \| `keep_all` \| `keep_sessions` \| `discard_sessions`) per invocation — they are mutually exclusive (`keep` = 10 is the default).

## Operations — the only keys a recipe/preset may carry

| Key | Allowed | Meaning |
|---|---|---|
| `strip_reasoning` | true/false | Drop the 'reasoning' parts on the copy (the bulk of the text) |

A recipe is a named combination of operations; the session selection never lives in a recipe (a keep rule inside a preset is rejected, pointing at the flags above).
