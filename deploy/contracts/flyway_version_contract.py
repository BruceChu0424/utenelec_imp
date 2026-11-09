"""Pure Flyway identity contract, embedded deterministically into trusted tools.

Do not add runtime imports to the embedded block. Runtime tools retain their
existing immutable-source loading and pin boundaries. Canonical wire identities
are deliberately stricter than Flyway's alias-tolerant semantic comparison.
"""

_FLYWAY_CONTRACT_ERROR = ValueError

# These immutable, already-applied basenames predate canonical wire versions.
# This is not permission to add another leading-zero source or accept an alias
# in a manifest/API field. Script name and CRC/source hashes remain exact.
_FLYWAY_LEGACY_INTEGER_SCRIPTS = {
    "V01__enable_pgcrypto.sql": "01",
    "V02__departments_positions.sql": "02",
    "V03__employees.sql": "03",
    "V04__auth_rbac.sql": "04",
    "V05__audit.sql": "05",
    "V06__seed_rbac.sql": "06",
    "V07__seed_org.sql": "07",
    "V08__seed_admin.sql": "08",
    "V09__audit_redact_password.sql": "09",
}

_FLYWAY_SEMANTIC_RE = __import__("re").compile(r"[0-9]+(?:[._][0-9]+)*")
_FLYWAY_SCRIPT_RE = __import__("re").compile(
    r"V(?P<version>[0-9]+(?:[._][0-9]+)*)__"
    r"(?P<description>[^\x00-\x1f\x7f-\x9f/\\]{1,200})\.sql"
)


def _flyway_semantic_key(value: object) -> tuple[int, ...]:
    """Match MigrationVersion numeric ordering without float or integer limits."""
    if type(value) is not str or len(value) > 50 or not _FLYWAY_SEMANTIC_RE.fullmatch(value):
        raise _FLYWAY_CONTRACT_ERROR("Flyway version must contain bounded ASCII integer components")
    parts = tuple(int(part) for part in value.replace("_", ".").split("."))
    while len(parts) > 1 and parts[-1] == 0:
        parts = parts[:-1]
    return parts


def _flyway_version_key(value: object) -> tuple[int, ...]:
    """Require a positive, unique dotted representation for signed/live rows."""
    parts = _flyway_semantic_key(value)
    if parts <= (0,) or value != ".".join(str(part) for part in parts):
        raise _FLYWAY_CONTRACT_ERROR("Flyway version is not a canonical positive dotted identity")
    return parts


def _flyway_script_parts(filename: object) -> tuple[tuple[int, ...], str, str]:
    """Bind the exact basename to its version and both description spellings."""
    if type(filename) is not str:
        raise _FLYWAY_CONTRACT_ERROR("Flyway script must be a bounded exact basename")
    try:
        encoded = filename.encode("utf-8")
    except UnicodeError:
        raise _FLYWAY_CONTRACT_ERROR("Flyway script basename is not valid UTF-8") from None
    if len(encoded) > 255:
        raise _FLYWAY_CONTRACT_ERROR("Flyway script must be a bounded exact basename")
    match = _FLYWAY_SCRIPT_RE.fullmatch(filename)
    if match is None:
        raise _FLYWAY_CONTRACT_ERROR("Flyway script basename is not canonical")
    token = match.group("version")
    if "." in token and "_" in token:
        raise _FLYWAY_CONTRACT_ERROR("Flyway script version mixes component separators")
    key = (_flyway_semantic_key(token) if filename in _FLYWAY_LEGACY_INTEGER_SCRIPTS
           else _flyway_version_key(token.replace("_", ".")))
    raw_description = match.group("description")
    return key, raw_description, raw_description.replace("_", " ")


def _flyway_history_version_key(value: object, script: object) -> tuple[int, ...]:
    """Read an original history identity without silently accepting new aliases."""
    script_key, _, _ = _flyway_script_parts(script)
    if script in _FLYWAY_LEGACY_INTEGER_SCRIPTS and value == _FLYWAY_LEGACY_INTEGER_SCRIPTS[script]:
        key = _flyway_semantic_key(value)
    else:
        key = _flyway_version_key(value)
    if key != script_key:
        raise _FLYWAY_CONTRACT_ERROR("Flyway history version differs from its exact script")
    return key


def _flyway_history_order_frontier(
    version_key: tuple[int, ...], seen: set, prior_integer: tuple[int, ...]
) -> tuple[int, ...]:
    """Enforce the one live-history rank-order rule shared by every owner.

    Integer history must strictly increase by installed rank. Backfilled dotted
    versions (for example 990.1 applied after 999; see the migration README
    dotted-version note) legally rank after larger integers and around sibling
    dotted rows, so they join uniqueness and exact script binding but not the
    order check - the same scope ForwardMigrationSequenceContractTest gives
    dotted versions. Returns the integer frontier for the next row.
    """
    if version_key in seen:
        raise _FLYWAY_CONTRACT_ERROR("Flyway history versions are duplicated")
    if len(version_key) == 1:
        if version_key <= prior_integer:
            raise _FLYWAY_CONTRACT_ERROR(
                "Flyway integer history versions are not strictly increasing"
            )
        return version_key
    return prior_integer


def _flyway_wire_version(value: object, script: object) -> str:
    """Project a checked history row to the canonical signed TSV identity."""
    return ".".join(str(part) for part in _flyway_history_version_key(value, script))


def _flyway_head_identity(version: object) -> int | str:
    """Keep existing integer health/receipt bytes; dotted heads remain strings."""
    key = _flyway_version_key(version)
    return key[0] if len(key) == 1 else str(version)


def _flyway_history_head(history: object) -> int | str:
    """Return the head of installed_rank-ordered (version, script) history rows.

    The head is the semantic maximum, never the row applied last: a dotted
    backfill installed after a larger integer stays below that integer. Each
    row binds its observed version to its exact script, and the rows obey the
    shared rank rule (unique versions, integers strictly increasing by rank).
    """
    if type(history) not in (list, tuple) or not history:
        raise _FLYWAY_CONTRACT_ERROR("Flyway history must be a non-empty row sequence")
    seen: set = set()
    prior_integer = (0,)
    for row in history:
        if type(row) not in (list, tuple) or len(row) != 2:
            raise _FLYWAY_CONTRACT_ERROR("Flyway history row must be an exact version/script pair")
        version_key = _flyway_history_version_key(row[0], row[1])
        prior_integer = _flyway_history_order_frontier(version_key, seen, prior_integer)
        seen.add(version_key)
    return _flyway_head_identity(".".join(str(part) for part in max(seen)))


def _flyway_head_key(value: object) -> tuple[int, ...]:
    """Read the existing integer head or the explicit new dotted-string form."""
    if type(value) is int and value > 0 and len(str(value)) <= 50:
        return (value,)
    if type(value) is str and "." in value:
        return _flyway_version_key(value)
    raise _FLYWAY_CONTRACT_ERROR("Flyway database head must be an integer or canonical dotted string")
