| Key | Allowed | Meaning |
|---|---|---|
| `keep` | int ≥ 1 | keep the N most recent sessions (by last update) |
| `older_than` | int ≥ 1 | keep sessions updated within the last N days |
| `since` | string | keep sessions updated on or after DATE (YYYY-MM-DD, UTC) |
| `keep_all` | true/false | keep ALL sessions (just prune orphans + vacuum) |
| `keep_sessions` | string[] | keep ONLY the listed session ids (+ their parents/subagents) |
| `discard_sessions` | string[] | keep everything EXCEPT the listed session ids (+ their subagents) |
| `strip_reasoning` | true/false | also drop the 'reasoning' parts (the bulk of the size) on the copy |

Exactly ONE keep rule (`keep` \| `older_than` \| `since` \| `keep_all` \| `keep_sessions` \| `discard_sessions`) per preset — they are mutually exclusive. `strip_reasoning` is the only optional companion.
