# Secret redaction (--sanitize). Redaction only rewrites export output, never
# the DB. Patterns are HIGH CONFIDENCE ONLY (specific prefixes + lengths).
# The key=value pattern and bare env-var names are EXCLUDED to avoid false
# positives on example code/config/tutorials. Use with care; review output.
import re

_SANITIZE_PATTERNS = [
    (re.compile(r"-----BEGIN [A-Z ]+PRIVATE KEY-----.*?-----END [A-Z ]+PRIVATE KEY-----", re.S),
     "-----BEGIN PRIVATE KEY-----[REDACTED]-----END PRIVATE KEY-----"),
    (re.compile(r"\bBearer\s+[A-Za-z0-9._~+/=\-]{12,}\b", re.I), "Bearer [REDACTED]"),
    (re.compile(r"\b(sk-[A-Za-z0-9]{16,})\b"), "sk-[REDACTED]"),
    (re.compile(r"\b(ghp_[A-Za-z0-9]{20,})\b"), "ghp_[REDACTED]"),
    (re.compile(r"\b(gho_[A-Za-z0-9]{20,})\b"), "gho_[REDACTED]"),
    (re.compile(r"\b(github_pat_[A-Za-z0-9_]{20,})\b"), "github_pat_[REDACTED]"),
    (re.compile(r"\b(xox[baprs]-[A-Za-z0-9-]{8,})\b"), "xox-[REDACTED]"),
    (re.compile(r"\b(AIza[0-9A-Za-z_\-]{20,})\b"), "AIza[REDACTED]"),
    (re.compile(r"\b(AKIA[0-9A-Z]{16})\b"), "AKIA[REDACTED]"),
    (re.compile(r"\b(eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,})\b"), "eyJ[REDACTED]"),
    (re.compile(r"\b(sk-ant-[A-Za-z0-9_\-]{20,})\b"), "sk-ant-[REDACTED]"),
]


def sanitize(text: str) -> str:
    text = str(text)
    for rx, rep in _SANITIZE_PATTERNS:
        text = rx.sub(rep, text)
    return text


def sanitize_json(obj):
    if isinstance(obj, dict):
        return {k: sanitize_json(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [sanitize_json(v) for v in obj]
    if isinstance(obj, str):
        return sanitize(obj)
    return obj