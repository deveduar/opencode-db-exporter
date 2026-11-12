"""Small terminal-only progress display for Python exports."""
import atexit
import sys


class Progress:
    def __init__(
        self,
        label: str,
        total: int,
        *,
        disabled: bool = False,
        stream=None,
    ) -> None:
        self.label = label
        self.total = total
        self.stream = stream or sys.stderr
        self.enabled = not disabled and self.stream.isatty()
        self.completed = 0
        self.active = False

    def start(self) -> None:
        if self.enabled and self.total > 0:
            self.active = True
            self._render()
            atexit.register(self.finish)

    def advance(self, count: int = 1) -> None:
        self.completed = min(self.total, self.completed + count)
        if self.enabled and self.active:
            self._render()

    def _render(self) -> None:
        width = 24
        ratio = self.completed / self.total
        filled = round(width * ratio)
        bar = "=" * filled + " " * (width - filled)
        self.stream.write(
            f"\r{self.label}: [{bar}] {self.completed}/{self.total} sessions"
        )
        if self.completed >= self.total:
            self.stream.write("\n")
            self.active = False
        self.stream.flush()

    def finish(self) -> None:
        if self.active:
            self.stream.write("\n")
            self.stream.flush()
            self.active = False

    def __enter__(self):
        self.start()
        return self

    def __exit__(self, _exc_type, _exc, _traceback) -> None:
        self.finish()
