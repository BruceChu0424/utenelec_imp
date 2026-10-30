"""Strict conservation of current staff data during a database rebuild/restore.

This is not a deployment hook. Normal application upgrades do not rebuild HR or
account data and must not run a full inventory scan. Tokens are custody digests,
never source password hashes, phone/identity hashes, ciphertext or plaintext.
"""
import json
import re
import uuid
from datetime import datetime, timezone

KIND = "staff-account-preservation-v1"
CURRENT = {"active", "probation", "onLeave"}
FIXED_TABLES = {
    "departments", "positions", "permissions", "permission_templates",
    "permission_surfaces", "permission_surface_permissions",
    "department_permissions", "manager_permission_delegations", "notices",
    "notice_user_states", "refresh_tokens", "employment_history",
    "organization_permission_leader_assignments", "emergency_contacts", "password_history",
}
REQUIRED = {
    "employees", "users", "employee_sensitive", "employee_compensation",
    "employee_contracts", "employee_education", "employee_credentials",
    "employment_history", "user_permission_overrides", "user_data_scopes",
    "user_preferences", "auth_sessions", "refresh_tokens", *FIXED_TABLES,
}
IDENTIFIER = re.compile(r"[a-z_][a-z0-9_]*\Z")
TOKEN = re.compile(r"[0-9a-f]{64}\Z")
VOLATILE = {"updated_at", "updated_by", "version", "auth_version",
            "permission_delegation_generation", "last_login_at"}
ROW_METADATA = {"updated_at", "updated_by", "version"}
SESSION_VOLATILE = {
    "updated_at", "last_seen_at", "revoked_at", "revoked_reason",
    "step_up_token_hash", "step_up_expires_at",
}


class PreservationError(ValueError):
    pass


def require(ok, reason):
    if not ok:
        raise PreservationError(reason)


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True)


def quoted(value):
    require(isinstance(value, str) and IDENTIFIER.fullmatch(value), "Invalid schema identifier")
    return '"' + value + '"'


def literal(value):
    return "'" + value.replace("'", "''") + "'"


def schema_sql():
    names = ",".join(literal(name) for name in sorted(FIXED_TABLES | {"employees", "users"}))
    return """SELECT jsonb_build_object('tables',COALESCE(jsonb_agg(jsonb_build_object(
        'name',t.table_name,'columns',(SELECT jsonb_agg(jsonb_build_object('name',c.column_name,
          'type',c.udt_name,'nullable',c.is_nullable) ORDER BY c.ordinal_position)
          FROM information_schema.columns c WHERE c.table_schema='public' AND c.table_name=t.table_name),
        'primary_key',(SELECT jsonb_agg(a.attname ORDER BY k.ordinality)
          FROM pg_constraint p CROSS JOIN LATERAL unnest(p.conkey) WITH ORDINALITY k(attnum,ordinality)
          JOIN pg_attribute a ON a.attrelid=p.conrelid AND a.attnum=k.attnum
          WHERE p.conrelid=to_regclass('public.'||t.table_name) AND p.contype='p'))
        ORDER BY t.table_name),'[]'::jsonb))
        FROM information_schema.tables t WHERE t.table_schema='public' AND t.table_type='BASE TABLE'
        AND (t.table_name IN (""" + names + """) OR t.table_name LIKE 'employee\\_%' ESCAPE '\\'
          OR t.table_name LIKE 'user\\_%' ESCAPE '\\' OR t.table_name LIKE 'auth\\_%' ESCAPE '\\'
          OR t.table_name LIKE 'notice\\_%' ESCAPE '\\')"""


def reviewed_specs(metadata):
    require(isinstance(metadata, dict) and isinstance(metadata.get("tables"), list), "Missing staff schema inventory")
    specs = metadata["tables"]
    names = [item.get("name") for item in specs]
    require(len(names) == len(set(names)) and REQUIRED <= set(names), "Incomplete or duplicate staff schema inventory")
    for item in specs:
        quoted(item["name"])
        require(isinstance(item.get("columns"), list) and item["columns"], "Missing staff column inventory")
        cols = [column.get("name") for column in item["columns"]]
        require(len(cols) == len(set(cols)), "Duplicate staff column inventory")
        require(isinstance(item.get("primary_key"), list) and item["primary_key"], "Staff table has no stable primary key")
        for col in cols:
            quoted(col)
        require(set(item["primary_key"]) <= set(cols), "Staff primary key is not in its schema")
    return sorted(specs, key=lambda item: item["name"])


def snapshot_sql(metadata, audit_highwater=None):
    specs = reviewed_specs(metadata)
    if audit_highwater is not None:
        require(type(audit_highwater) is int and audit_highwater >= 0, "Invalid native audit boundary")
    tables = []
    for item in specs:
        table = item["name"]
        key = "jsonb_build_array(" + ",".join("to_jsonb(r)->" + literal(col) for col in item["primary_key"]) + ")"
        excluded = (SESSION_VOLATILE if table == "auth_sessions" else {"revoked_at"}
                    if table == "refresh_tokens" else VOLATILE if table in {"employees", "users"} else ROW_METADATA)
        minus = "ARRAY[" + ",".join(literal(col) for col in sorted(excluded)) + "]::text[]"
        # A stable, protected admin credential is used only inside this read-only
        # statement as an opaque custody key. No key, source hash or separately
        # guessable phone/identity digest is exported.
        token = "encode(hmac((to_jsonb(r)-" + minus + ")::text,(SELECT secret FROM custody_key),'sha256'),'hex')"
        state = "jsonb_build_object('version',to_jsonb(r)->'version')"
        if table == "employees":
            state = "jsonb_build_object('id',r.id,'code',r.code,'status',r.status,'deleted',r.is_deleted,'generation',r.permission_delegation_generation,'version',r.version)"
        elif table == "users":
            state = "jsonb_build_object('id',r.id,'employee_id',r.employee_id,'status',r.status,'deleted',r.is_deleted,'auth_version',r.auth_version,'generation',r.permission_delegation_generation,'version',r.version,'credential_present',length(r.password_hash)>20)"
        elif table in {"auth_sessions", "refresh_tokens"}:
            state = "jsonb_build_object('revoked_at',r.revoked_at)"
            if table == "auth_sessions":
                state = "jsonb_build_object('revoked_at',r.revoked_at,'revoked_reason',r.revoked_reason,'step_up_cleared',r.step_up_token_hash IS NULL AND r.step_up_expires_at IS NULL)"
        rows = "(SELECT COALESCE(jsonb_agg(jsonb_build_object('key'," + key + ",'token'," + token + ",'state'," + state + ") ORDER BY " + key + "::text),'[]'::jsonb) FROM public." + quoted(table) + " r)"
        tables.append("(" + literal(table) + "," + rows + ")")
    bound = str(audit_highwater) if audit_highwater is not None else "NULL::bigint"
    return """SELECT (WITH custody_key AS (SELECT u.id,u.password_hash AS secret FROM users u
      JOIN employees e ON e.id=u.employee_id WHERE u.is_super_admin AND NOT u.is_deleted AND u.status='active'
      AND NOT e.is_deleted AND e.status IN('active','probation','onLeave') AND length(u.password_hash)>20 ORDER BY u.id LIMIT 1)
      SELECT jsonb_build_object('formatVersion',1,'kind','""" + KIND + """',
      'captured_at',clock_timestamp(),'read_only',current_setting('transaction_read_only'),
      'custody_key_user_id',(SELECT id::text FROM custody_key),
      'custody_key_fingerprint',(SELECT encode(digest(secret,'sha256'),'hex') FROM custody_key),
      'identity',jsonb_build_object('database',current_database(),'system_identifier',(SELECT system_identifier::text FROM pg_control_system()),
        'database_oid',(SELECT oid::bigint FROM pg_database WHERE datname=current_database()),
        'dataset_id',(SELECT to_jsonb(a)->>'business_dataset_id' FROM authorization_state a WHERE singleton_id=1),
        'generation',(SELECT business_reset_generation FROM authorization_state WHERE singleton_id=1),
        'authorization_epoch',(SELECT epoch FROM authorization_state WHERE singleton_id=1)),
      'schema',""" + literal(canonical(specs)) + """::jsonb,
      'schema_in_snapshot',(""" + schema_sql() + """),'tables',
        (SELECT jsonb_object_agg(k,v) FROM (VALUES """ + ",".join(tables) + """) inventory(k,v)),
      'audit',(WITH evidence AS (SELECT to_jsonb(a) body,a.id,a.created_at FROM audit_log a
        UNION ALL SELECT to_jsonb(a),a.id,a.created_at FROM audit_log_archive a),
       boundary AS (SELECT COALESCE(""" + bound + """,max(id),0) AS highwater FROM evidence)
       SELECT jsonb_build_object('highwater',b.highwater,'rows',count(e.id),
         'token',encode(hmac(COALESCE(string_agg(encode(hmac(e.body::text,(SELECT secret FROM custody_key),'sha256'),'hex'),'' ORDER BY e.id,e.created_at,e.body::text),''),(SELECT secret FROM custody_key),'sha256'),'hex'))
       FROM boundary b LEFT JOIN evidence e ON e.id<=b.highwater GROUP BY b.highwater)))"""


def validate_snapshot(value):
    require(isinstance(value, dict) and value.get("kind") == KIND and value.get("formatVersion") == 1, "Wrong staff snapshot protocol")
    require(value.get("read_only") == "on", "Staff evidence was not captured read-only")
    try:
        captured = datetime.fromisoformat(value["captured_at"].replace("Z", "+00:00"))
        require(captured.tzinfo is not None, "Staff capture time has no timezone")
    except (KeyError, ValueError, TypeError, AttributeError):
        raise PreservationError("Missing timezone-aware staff capture time") from None
    require(isinstance(value.get("custody_key_fingerprint"), str) and TOKEN.fullmatch(value["custody_key_fingerprint"]),
            "Missing protected credential custody context")
    try:
        uuid.UUID(value["custody_key_user_id"])
    except (KeyError, TypeError, ValueError, AttributeError):
        raise PreservationError("Missing protected credential custody identity") from None
    identity = value.get("identity", {})
    require(isinstance(identity.get("database"), str) and identity["database"], "Missing staff database name")
    require(type(identity.get("database_oid")) is int and identity["database_oid"] > 0, "Missing physical staff database identity")
    require(isinstance(identity.get("system_identifier"), str) and re.fullmatch(r"[0-9]{1,20}", identity["system_identifier"]), "Missing staff cluster identity")
    try:
        uuid.UUID(identity["dataset_id"])
    except (KeyError, TypeError, ValueError, AttributeError):
        raise PreservationError("Missing business dataset identity; a local old test database is not company evidence") from None
    require(type(identity.get("generation")) is int and identity["generation"] >= 0, "Missing business generation")
    require(type(identity.get("authorization_epoch")) is int and identity["authorization_epoch"] >= 0, "Missing current authorization epoch")
    schema = reviewed_specs({"tables": value.get("schema")})
    require(schema == reviewed_specs(value.get("schema_in_snapshot")), "Staff schema changed between inventory and its read-only snapshot")
    tables = value.get("tables")
    require(isinstance(tables, dict) and set(tables) == {item["name"] for item in schema}, "Staff snapshot omitted a registered table")
    indices = {}
    for name, rows in tables.items():
        require(isinstance(rows, list), "Malformed staff rows")
        index = {}
        for row in rows:
            require(isinstance(row, dict) and isinstance(row.get("key"), list) and row["key"] and all(v is not None for v in row["key"]), "Missing staff row identity")
            key = canonical(row["key"])
            require(key not in index, "Duplicate staff row identity in " + name)
            require(isinstance(row.get("token"), str) and TOKEN.fullmatch(row["token"]), "Invalid staff custody token")
            require(isinstance(row.get("state"), dict), "Missing staff state")
            state = row["state"]
            if name in {"employees", "users"}:
                require(len(row["key"]) == 1 and state.get("id") == row["key"][0], "Staff state differs from its stable row identity")
                try:
                    uuid.UUID(state["id"])
                    if name == "users":
                        uuid.UUID(state["employee_id"])
                except (KeyError, TypeError, ValueError, AttributeError):
                    raise PreservationError("Invalid native staff identity") from None
                require(type(state.get("deleted")) is bool and isinstance(state.get("status"), str), "Missing native staff lifecycle state")
                for field in ("version", "generation", *(["auth_version"] if name == "users" else [])):
                    require(type(state.get(field)) is int and state[field] >= 0, "Missing native staff security generation")
                if name == "users":
                    require(type(state.get("credential_present")) is bool, "Missing credential custody state")
            index[key] = row
        indices[name] = index
    audit = value.get("audit", {})
    require(type(audit.get("highwater")) is int and audit["highwater"] >= 0 and type(audit.get("rows")) is int and audit["rows"] >= 0
            and isinstance(audit.get("token"), str) and TOKEN.fullmatch(audit["token"]), "Missing native audit evidence")
    return indices


def compare_staff(source, candidate, *, allow_same_database_restore=False, now=None, max_source_age_seconds=3600):
    before, after = validate_snapshot(source), validate_snapshot(candidate)
    require(source["schema"] == candidate["schema"], "Staff schemas differ: upgrade both under their normal migration policy before a same-version data rebuild")
    source_id, target_id = source["identity"], candidate["identity"]
    now = now or datetime.now(timezone.utc)
    for evidence in (source, candidate):
        captured = datetime.fromisoformat(evidence["captured_at"].replace("Z", "+00:00"))
        age = (now-captured).total_seconds()
        require(-300 <= age <= max_source_age_seconds, "Staff evidence is stale or future-dated: recapture the current source and candidate before handoff")
    require(source["custody_key_user_id"] == candidate["custody_key_user_id"]
            and source["custody_key_fingerprint"] == candidate["custody_key_fingerprint"], "Protected administrator credential changed; capture a fresh verified baseline")
    physical = lambda value: (value["system_identifier"], value["database_oid"])
    require(allow_same_database_restore or physical(source_id) != physical(target_id), "Source cannot verify itself as a replacement candidate")
    require(source_id["dataset_id"] == target_id["dataset_id"] and source_id["generation"] == target_id["generation"], "Staff source/candidate business identities differ")
    require(target_id["authorization_epoch"] >= source_id["authorization_epoch"], "Authorization epoch regressed")
    require(source["audit"] == candidate["audit"], "Native audit history or completion markers were lost or rewritten")
    issues = []
    for name, rows in before.items():
        target = after[name]
        if set(rows) != set(target):
            issues.append({"table": name, "kind": "ROW_IDENTITIES_DIFFER", "missing": len(set(rows)-set(target)), "extra": len(set(target)-set(rows))})
            continue
        for key, row in rows.items():
            current = target[key]
            if row["token"] != current["token"]:
                issues.append({"table": name, "kind": "STAFF_FACTS_CHANGED", "key": row["key"]})
            if row["state"].get("version") is not None and (type(current["state"].get("version")) is not int
                    or current["state"]["version"] < row["state"]["version"]):
                issues.append({"table": name, "kind": "ROW_VERSION_REGRESSED", "key": row["key"]})
            if name in {"employees", "users"}:
                state, updated = row["state"], current["state"]
                if updated["generation"] != state["generation"]:
                    # Delegations snapshot these counters: advancing them while
                    # retaining the same rows would silently revoke real grants.
                    issues.append({"table": name, "kind": "DELEGATION_GENERATION_CHANGED", "key": row["key"]})
                for field in ("auth_version",):
                    if field in state and (type(updated.get(field)) is not int or updated[field] < state[field]):
                        issues.append({"table": name, "kind": "SECURITY_GENERATION_REGRESSED", "key": row["key"]})
            elif name in {"auth_sessions", "refresh_tokens"}:
                state, updated = row["state"], current["state"]
                if updated.get("revoked_at") is None or (name == "auth_sessions" and updated.get("step_up_cleared") is not True):
                    issues.append({"table": name, "kind": "CANDIDATE_SESSION_STILL_USABLE", "key": row["key"]})
                if state.get("revoked_at") is not None and (state["revoked_at"] != updated.get("revoked_at")
                    or name == "auth_sessions" and state.get("revoked_reason") != updated.get("revoked_reason")):
                    issues.append({"table": name, "kind": "REVOKED_HISTORY_CHANGED", "key": row["key"]})
    employees = {row["state"].get("id"): row["state"] for row in after["employees"].values()}
    for row in after["users"].values():
        user = row["state"]
        employee = employees.get(user.get("employee_id"))
        if not user.get("deleted") and user.get("status") == "active" and (not employee or employee.get("deleted") is not False or employee.get("status") not in CURRENT or user.get("credential_present") is not True):
            issues.append({"table": "users", "kind": "ACTIVE_ACCOUNT_WITHOUT_CURRENT_IDENTITY", "key": row["key"]})
    return {"status": "FAILED" if issues else "PASSED", "scope": "CURRENT_STAFF_DATA_CONSERVATION_ONLY",
            "source_identity": source_id, "candidate_identity": target_id, "registered_tables": len(before),
            "employees": len(before["employees"]), "accounts": len(before["users"]), "issue_count": len(issues),
            "issues": issues[:40], "issues_truncated": len(issues) > 40, "production_acceptance": False,
            "actual_password_login_tested": False, "business_writes": 0}
