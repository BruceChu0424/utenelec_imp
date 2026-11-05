"""Pure Flyway identity contract, embedded deterministically into trusted tools.

Do not add runtime imports to the embedded block. Runtime tools retain their
existing immutable-source loading and pin boundaries. Canonical wire identities
are deliberately stricter than Flyway's alias-tolerant semantic comparison.
"""

_FLYWAY_SEMANTIC_RE = __import__("re").compile(r"[0-9]+(?:[._][0-9]+)*")
_FLYWAY_SCRIPT_RE = __import__("re").compile(
    r"V(?P<version>[0-9]+(?:[._][0-9]+)*)__"
    r"(?P<description>[^\x00-\x1f\x7f-\x9f/\\]{1,200})\.sql"
)


def _flyway_semantic_key(value: object) -> tuple[int, ...]:
    """Match MigrationVersion numeric ordering without float or integer limits."""
    if type(value) is not str or len(value) > 50 or not _FLYWAY_SEMANTIC_RE.fullmatch(value):
        raise ValueError("Flyway version must contain bounded ASCII integer components")
    parts = tuple(int(part) for part in value.replace("_", ".").split("."))
    while len(parts) > 1 and parts[-1] == 0:
        parts = parts[:-1]
    return parts


def _flyway_version_key(value: object) -> tuple[int, ...]:
    """Require a positive, unique dotted representation for signed/live rows."""
    parts = _flyway_semantic_key(value)
    if parts <= (0,) or value != ".".join(str(part) for part in parts):
        raise ValueError("Flyway version is not a canonical positive dotted identity")
    return parts


def _flyway_script_parts(filename: object) -> tuple[tuple[int, ...], str, str]:
    """Bind the exact basename to its version and both description spellings."""
    if type(filename) is not str or len(filename.encode("utf-8")) > 255:
        raise ValueError("Flyway script must be a bounded exact basename")
    match = _FLYWAY_SCRIPT_RE.fullmatch(filename)
    if match is None:
        raise ValueError("Flyway script basename is not canonical")
    token = match.group("version")
    if "." in token and "_" in token:
        raise ValueError("Flyway script version mixes component separators")
    key = _flyway_version_key(token.replace("_", "."))
    raw_description = match.group("description")
    return key, raw_description, raw_description.replace("_", " ")


def _flyway_head_identity(version: object) -> int | str:
    """Keep existing integer health/receipt bytes; dotted heads remain strings."""
    key = _flyway_version_key(version)
    return key[0] if len(key) == 1 else str(version)


def _flyway_head_key(value: object) -> tuple[int, ...]:
    """Read the existing integer head or the explicit new dotted-string form."""
    if type(value) is int and value > 0 and len(str(value)) <= 50:
        return (value,)
    if type(value) is str and "." in value:
        return _flyway_version_key(value)
    raise ValueError("Flyway database head must be an integer or canonical dotted string")
