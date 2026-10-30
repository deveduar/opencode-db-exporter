"""Split oversized transcripts at complete rendered-message boundaries."""
import os
import shutil
import tempfile
from pathlib import Path


def chunk_markdown_file(
    path: Path,
    chunk_mb: int,
    title: str,
    session_id: str,
    message_sizes: list[int],
) -> list[dict]:
    """Split a transcript between messages, keeping each message intact.

    The requested size is a target: a single message larger than the target is
    kept whole in its own part. The source Markdown already contains the exact
    rendered messages, and ``message_sizes`` records their UTF-8 byte lengths.
    """
    limit = int(chunk_mb) * 1_000_000
    file_size = path.stat().st_size
    if limit <= 0 or file_size <= limit or not message_sizes:
        return []

    message_bytes = sum(message_sizes)
    if message_bytes > file_size:
        raise ValueError("rendered message sizes exceed transcript size")
    preamble_size = file_size - message_bytes
    tmp = Path(tempfile.mkdtemp(prefix=f".{path.stem}.parts-", dir=path.parent))
    target = path.with_name(f"{path.stem}.parts")
    target_created = False
    landing = None
    parts: list[dict] = []
    out = None
    size = 0
    part_start = ""
    part_end = ""
    has_message = False
    source = None

    def start_part() -> None:
        nonlocal out, size, part_start, part_end, has_message
        number = len(parts) + 1
        out = (tmp / f"{path.stem}-part-{number:03d}.md").open("wb")
        size = 0
        part_start = ""
        part_end = ""
        has_message = False
        if number > 1:
            heading = f"# {title} — part {number:03d}\n\n"
            session = f"- **Session ID:** `{session_id}`\n\n"
            continuation = (heading + session).encode("utf-8")
            out.write(continuation)
            size += len(continuation)

    def finish_part() -> None:
        nonlocal out, size
        if out is None:
            return
        out.close()
        part_path = tmp / f"{path.stem}-part-{len(parts) + 1:03d}.md"
        parts.append({
            "name": part_path.name,
            "bytes": size,
            "start": part_start,
            "end": part_end,
        })
        out = None

    try:
        if target.exists():
            raise FileExistsError(f"chunk directory already exists: {target}")

        source = path.open("rb")
        start_part()
        preamble = source.read(preamble_size)
        out.write(preamble)
        size += len(preamble)

        for message_size in message_sizes:
            message = source.read(message_size)
            if len(message) != message_size:
                raise ValueError("transcript ended while reading a rendered message")
            if has_message and size + message_size > limit:
                finish_part()
                start_part()
            out.write(message)
            size += message_size
            has_message = True
            message_heading = next(
                (line.decode("utf-8", errors="replace")
                 for line in message.splitlines() if line.startswith(b"## ")),
                "",
            )
            if "  ·  " in message_heading:
                date = message_heading.rsplit("  ·  ", 1)[-1].strip()
                if not part_start:
                    part_start = date
                part_end = date

        if source.read(1):
            raise ValueError("rendered message sizes do not cover the transcript")
        finish_part()
        source.close()
        source = None

        index_lines = [
            f"# {title} — transcript parts",
            "",
            f"- **Session ID:** `{session_id}`",
            f"- **Target size:** {chunk_mb} MB per file; individual messages stay whole",
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
            f"- **Chunks:** {len(parts)} · target {chunk_mb} MB; messages stay whole\n\n"
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
        if source is not None:
            source.close()
        if target_created:
            shutil.rmtree(target, ignore_errors=True)
        if landing is not None:
            landing.unlink(missing_ok=True)
        shutil.rmtree(tmp, ignore_errors=True)
        raise
