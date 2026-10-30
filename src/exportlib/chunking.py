"""Split oversized transcript Markdown into ordered, size-bounded files."""
import os
import re
import shutil
import tempfile
from pathlib import Path


_FENCE = re.compile(rb"^\s*(`{3,}|~{3,})(.*?)(?:\r?\n)?$")
_MESSAGE_DATE = re.compile(r"^## .+  · (\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ)\s*$")


def _fence_token(fence: bytes) -> bytes:
    match = re.match(rb"(`+|~+)", fence)
    return match.group(1) if match else fence


def _utf8_end(data: bytes, start: int, limit: int) -> int:
    """Choose a byte boundary no larger than limit without splitting UTF-8."""
    end = min(len(data), start + limit)
    while end > start and end < len(data) and (data[end] & 0xC0) == 0x80:
        end -= 1
    return end


def chunk_markdown_file(path: Path, chunk_mb: int, title: str, session_id: str) -> list[dict]:
    """Chunk an already-rendered transcript, preserving source order and text.

    Small files keep their historical flat path. For oversized files, the
    original path becomes a small entry point and ``<stem>.parts/`` contains
    chronological chunks plus an index that links the newest chunk first.
    """
    limit = int(chunk_mb) * 1_000_000
    if limit <= 0 or path.stat().st_size <= limit:
        return []

    tmp = Path(tempfile.mkdtemp(prefix=f".{path.stem}.parts-", dir=path.parent))
    parts: list[dict] = []
    fence: bytes | None = None
    out = None
    size = 0
    part_start = ""
    part_end = ""
    active_date = ""
    target = path.with_name(f"{path.stem}.parts")
    target_created = False
    landing = None

    def start_part() -> None:
        nonlocal out, size, part_start, part_end
        number = len(parts) + 1
        out = (tmp / f"part-{number:03d}.md").open("wb")
        size = 0
        part_start = active_date
        part_end = active_date
        if number > 1:
            header = f"<!-- Continued transcript for session {session_id}; chronological order. -->\n\n".encode()
            out.write(header)
            size += len(header)
            if fence:
                opening = fence + b"\n"
                out.write(opening)
                size += len(opening)

    def finish_part() -> None:
        nonlocal out, size
        if out is None:
            return
        if fence:
            closing = b"\n" + _fence_token(fence) + b"\n"
            out.write(closing)
            size += len(closing)
        out.close()
        part_path = tmp / f"part-{len(parts) + 1:03d}.md"
        parts.append({
            "name": part_path.name,
            "bytes": size,
            "start": part_start,
            "end": part_end,
        })
        out = None

    def split_part() -> None:
        finish_part()
        start_part()

    try:
        start_part()
        with path.open("r", encoding="utf-8", newline="") as source:
            for line in source:
                match = _MESSAGE_DATE.match(line.rstrip("\r\n"))
                line_date = match.group(1) if match else ""
                if match:
                    active_date = line_date

                data = line.encode("utf-8")
                offset = 0
                while offset < len(data):
                    closing_size = len(b"\n" + _fence_token(fence) + b"\n") if fence else 0
                    available = limit - size - closing_size
                    if available <= 0:
                        split_part()
                        continue
                    end = _utf8_end(data, offset, available)
                    if end == offset:
                        split_part()
                        continue
                    piece = data[offset:end]
                    out.write(piece)
                    size += len(piece)
                    offset = end
                    if offset < len(data):
                        split_part()

                fence_match = _FENCE.match(data)
                if fence_match:
                    token = fence_match.group(1)
                    if fence is None:
                        fence = token + fence_match.group(2)
                    elif (
                        not fence_match.group(2).strip()
                        and token[:1] == fence[:1]
                        and len(token) >= len(_fence_token(fence))
                    ):
                        fence = None
                if line_date:
                    if not part_start:
                        part_start = line_date
                    part_end = line_date
        finish_part()

        if target.exists():
            raise FileExistsError(f"chunk directory already exists: {target}")
        index_lines = [
            f"# {title} — transcript parts",
            "",
            f"- **Session ID:** `{session_id}`",
            f"- **Target size:** {chunk_mb} MB per file",
            "- **Order:** files are chronological; start with the newest part below.",
            "",
            "## Newest first",
            "",
        ]
        for part in reversed(parts):
            dates = ""
            if part["start"] and part["end"]:
                dates = f" · {part['start']} – {part['end']}"
            index_lines.append(
                f"- [{part['name']}]({part['name']}){dates} · {part['bytes']:,} bytes"
            )
        (tmp / "index.md").write_text("\n".join(index_lines) + "\n", encoding="utf-8")

        latest = parts[-1]
        fd, landing_name = tempfile.mkstemp(
            prefix=f".{path.name}.chunked-", dir=path.parent
        )
        os.close(fd)
        landing = Path(landing_name)
        landing.write_text(
            f"# {title} — chunked transcript\n\n"
            f"- **Session ID:** `{session_id}`\n"
            f"- **Chunks:** {len(parts)} · target {chunk_mb} MB each\n\n"
            f"**Latest context:** [{latest['name']}]({target.name}/{latest['name']})\n\n"
            f"[All parts, newest first]({target.name}/index.md)\n",
            encoding="utf-8",
        )
        os.replace(tmp, target)
        target_created = True
        os.replace(landing, path)
        return parts
    except BaseException:
        if out is not None:
            out.close()
        if target_created:
            shutil.rmtree(target, ignore_errors=True)
        if landing is not None:
            landing.unlink(missing_ok=True)
        shutil.rmtree(tmp, ignore_errors=True)
        raise
