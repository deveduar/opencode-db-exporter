# Markdown renderer: turns messages/parts into the transcript/digest text.
import json

from exportlib.sanitize import sanitize
from exportlib.util import ts_iso, truncate

ROLE_HEADER = {"user": "## User", "assistant": "## Assistant"}


class Renderer:
    def __init__(self, args):
        self.profile = args.profile
        self.sub = args.sub
        self.tool_output = args.tool_output
        self.tool_out_limit = args.tool_output_limit
        self.tool_in_limit = args.tool_input_limit
        self.patch_mode = args.patch
        self.mark_compactions = args.mark_compactions
        self.diffs = args.summary_diffs
        self.filter = args.filter
        self.role = args.role
        self.reasoning = not args.no_reasoning
        self.json_mode = args.json
        self.sanitize = args.sanitize

    def w(self, s: str) -> str:
        return sanitize(s) if self.sanitize else s

    # ---- message inclusion (role filter) ----
    def include_message(self, mdata: dict) -> bool:
        return self.role == "all" or mdata.get("role") == self.role

    # ---- part inclusion ----
    def include_part(self, ptype: str) -> bool:
        if self.profile == "digest":
            return ptype == "text"
        # transcript
        if ptype == "tool":
            return self.tool_output != "omit"
        if ptype == "patch":
            return self.patch_mode == "full"
        if ptype == "reasoning":
            return self.reasoning
        if ptype == "compaction":
            return self.mark_compactions
        return True

    def render_part(self, p: dict, out: list) -> None:
        t = p.get("type")
        if not self.include_part(t):
            return
        if t == "text":
            txt = (p.get("text") or "").rstrip()
            if txt.strip():
                out.append(self.w(txt))
        elif t == "reasoning":
            txt = (p.get("text") or p.get("reasoning") or "").rstrip()
            if txt.strip():
                txt = self.w(txt.strip().replace("\n", "\n> "))
                out.append("> _Reasoning:_\n>\n> " + txt)
        elif t == "tool":
            tool = p.get("tool", "?")
            state = p.get("state") or {}
            status = state.get("status", "")
            inp = state.get("input", {})
            outp = state.get("output", "")
            title = state.get("title") or ""
            line = f"**Tool:** `{tool}` ({status})"
            if title:
                line += f" — {title}"
            out.append(line)
            if inp not in (None, {}):
                block = json.dumps(inp, indent=2, ensure_ascii=False)
                if self.sanitize:
                    block = sanitize(block)
                if self.tool_output == "truncated":
                    block = truncate(block, self.tool_in_limit)
                out.append("```json\n" + block.rstrip() + "\n```")
            if outp:
                if self.sanitize:
                    outp = sanitize(str(outp))
                if self.tool_output == "truncated":
                    outp = truncate(outp, self.tool_out_limit)
                out.append("**Output:**\n\n```\n" + str(outp).rstrip() + "\n```")
        elif t == "patch":
            patch = p.get("patch") or json.dumps(p, ensure_ascii=False)
            if self.sanitize:
                patch = sanitize(patch)
            out.append("**Patch:**\n\n```diff\n" + patch.rstrip() + "\n```")
        elif t == "file":
            block = json.dumps(p, indent=2, ensure_ascii=False)
            if self.sanitize:
                block = sanitize(block)
            out.append("```json\n" + block.rstrip() + "\n```")
        elif t in ("step-start", "step-finish"):
            out.append(f"<!-- {t} -->")
        elif t == "compaction":
            tail = p.get("tail_start_id", "")
            auto = p.get("auto", True)
            extra = " (auto)" if auto else ""
            out.append(
                "---\n\n> **Context compaction**" + extra
                + (f" — new queue from `{tail}`" if tail else "")
                + "\n"
            )

    def summary_diffs(self, mdata: dict) -> str:
        summary = mdata.get("summary")
        diffs = (summary.get("diffs") if isinstance(summary, dict) else None) or []
        if not diffs:
            return ""
        lines = ["**Summary of changes:**\n"]
        for d in diffs:
            f = d.get("file", "?")
            add = d.get("additions", 0)
            dele = d.get("deletions", 0)
            status = d.get("status", "")
            lines.append(self.w(f"- `{f}`  (+{add} −{dele})  {status}"))
        return "\n".join(lines)

    def render_message(self, mdata: dict, parts: list[dict], diffs_html: str) -> str:
        role = mdata.get("role", "unknown")
        header = ROLE_HEADER.get(role, f"## {role}")
        created = (mdata.get("time") or {}).get("created")
        if created:
            header += f"  ·  {ts_iso(created)}"

        body: list[str] = []
        for p in parts:
            self.render_part(p, body)

        if self.diffs and diffs_html:
            body.append(diffs_html)

        if not body:
            return ""
        rendered = "\n\n".join(x.rstrip() for x in body if x.rstrip())
        if not rendered.strip():
            return ""
        return header + "\n\n" + rendered + "\n"