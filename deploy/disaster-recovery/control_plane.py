#!/usr/bin/env python3
"""Independent recovery identity and durable drill queue. No shell/SQL executor.

Only a local ERP step-up broker can issue enrollment. Backup agents have narrowly
scoped tokens and cannot enroll admins, register targets or promote a write master.
The current commissioning phase deliberately has no promotion executor.
"""
from __future__ import annotations

import argparse
import base64
import contextlib
import datetime as dt
import hashlib
import hmac
import importlib.util
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import secrets
import sqlite3
import stat
import struct
import time
import uuid
from urllib.parse import urlsplit

ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}\Z")
SHA = re.compile(r"[a-f0-9]{64}\Z")
MAX_BODY = 131072
EVIDENCE = ("databaseRestored", "attachmentsVerified", "keysVerified", "isolated", "sideEffectsDisabled")
TLS_STATUS = Path("/var/lib/uten-remote-status/tls.json")


def digest(value):
    return hashlib.sha256(value.encode()).hexdigest()


def utc(value=None):
    return dt.datetime.fromtimestamp(value if value is not None else time.time(), dt.timezone.utc).isoformat()


def timestamp(value):
    if not isinstance(value, str):
        raise ValueError("timestamp string required")
    parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("timezone required")
    return parsed.timestamp()


def tls_status(now, path=TLS_STATUS):
    result = {name: {"domain": domain, "state": "UNKNOWN", "publicChainVerified": False}
              for name, domain in (("employee", "justplayit.cn"), ("dr", "admin.justplayit.cn"))}
    try:
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or stat.S_IMODE(info.st_mode) & 0o022 or info.st_size > 16384:
            return result
        document = json.loads(path.read_text(encoding="utf-8"))
        if document.get("schemaVersion") != 1:
            return result
        for name, item in result.items():
            record = document.get(name, {})
            if record.get("domain") != item["domain"]:
                continue
            for key in ("expiresAt", "lastSuccessAt", "lastFailureAt"):
                value = record.get(key)
                if value:
                    item[key] = utc(timestamp(value))
            item["lastOutcome"] = record.get("lastOutcome") if record.get("lastOutcome") in ("SUCCESS", "FAILED", "NOT_ISSUED", "UNKNOWN") else "UNKNOWN"
            code = record.get("errorCode", "")
            item["errorCode"] = code if isinstance(code, str) and re.fullmatch(r"[A-Z0-9_]{1,64}", code) else "UNKNOWN"
            item["publicChainVerified"] = record.get("publicChainVerified") is True
            if "expiresAt" in item and timestamp(item["expiresAt"]) <= now:
                item["state"] = "EXPIRED"
            elif item["lastOutcome"] == "NOT_ISSUED":
                item["state"] = "NOT_ISSUED"
            elif item["lastOutcome"] == "FAILED":
                item["state"] = "RENEWAL_FAILED"
            elif item["publicChainVerified"] and "expiresAt" in item and item["lastOutcome"] == "SUCCESS":
                item["state"] = "VALID_AT_LAST_VERIFICATION"
    except (OSError, ValueError, TypeError, KeyError, AttributeError):
        pass
    return result


def password_hash(password, salt=None):
    salt = salt or secrets.token_hex(16)
    value = hashlib.scrypt(password.encode(), salt=bytes.fromhex(salt), n=32768, r=8, p=1, maxmem=67108864)
    return salt + ":" + value.hex()


def password_valid(password):
    if not isinstance(password, str) or not 20 <= len(password) <= 256 or len(set(password)) < 10 \
            or any(ord(c) < 32 for c in password):
        return False
    normalized = re.sub(r"[-_\s]", "", password.lower())
    return not any(marker in normalized for marker in ("changeme", "placeholder", "replacewith", "yourpassword")) \
        and not any(all(password[i] == password[i % period] for i in range(period, len(password)))
                    for period in range(1, min(16, len(password) // 2) + 1))


def read_master_credential(path):
    path = Path(path)
    info = path.lstat()
    mode = stat.S_IMODE(info.st_mode)
    if not stat.S_ISREG(info.st_mode) or info.st_uid not in (0, os.geteuid()) or info.st_size > 128:
        raise ValueError("private TOTP master credential required")
    private_file = mode in (0o400, 0o600)
    systemd_acl_credential = False
    # systemd255 credentials may have a 0440 ACL mask while allowing only the
    # unit's named UID. This exception is confined to its exact, root-owned,
    # non-writable read-only credential mount, never an ordinary group-readable file.
    declared = os.environ.get("CREDENTIALS_DIRECTORY", "")
    if mode == 0o440 and info.st_uid == 0 and path.name == "totp-master" and declared \
            and path.parent == Path(declared) and not path.parent.is_symlink():
        parent = path.parent.lstat()
        systemd_acl_credential = stat.S_ISDIR(parent.st_mode) and parent.st_uid == 0 \
            and stat.S_IMODE(parent.st_mode) & 0o227 == 0 \
            and os.path.ismount(path.parent) \
            and bool(os.statvfs(path.parent).f_flag & os.ST_RDONLY)
    if not private_file and not systemd_acl_credential:
        raise ValueError("private TOTP master systemd credential required")
    master = path.read_text(encoding="ascii").strip()
    if not SHA.fullmatch(master):
        raise ValueError("256-bit TOTP master required")
    return bytes.fromhex(master)


def totp(secret, counter):
    key = base64.b32decode(secret, casefold=True)
    mac = hmac.new(key, struct.pack(">Q", counter), hashlib.sha1).digest()
    offset = mac[-1] & 15
    number = struct.unpack(">I", mac[offset:offset + 4])[0] & 0x7fffffff
    return f"{number % 1000000:06d}"


class Refused(Exception):
    def __init__(self, code, status=409):
        self.code, self.status = code, status


def identifier(value):
    if not isinstance(value, str) or not ID.fullmatch(value):
        raise Refused("INVALID_IDENTIFIER", 400)
    return value


def validate_config(config):
    if set(config) - {"allowedOrigins", "enrollmentBrokerSha256", "enrollmentEnabledUntil", "agents", "promotion"}:
        raise ValueError("unknown control configuration")
    if not SHA.fullmatch(config.get("enrollmentBrokerSha256", "")):
        raise ValueError("enrollment broker hash required")
    origins = config.get("allowedOrigins", [])
    if not isinstance(origins, list) or not 1 <= len(origins) <= 8:
        raise ValueError("trusted control origins required")
    for origin in origins:
        uri = urlsplit(origin)
        if not uri.hostname or uri.username or uri.password or uri.query or uri.fragment or uri.path \
                or "*" in origin or not (uri.scheme == "https" or (uri.scheme == "http" and uri.hostname == "127.0.0.1")):
            raise ValueError("fixed HTTPS origin or loopback enrollment origin required")
    if not isinstance(config.get("enrollmentEnabledUntil", 0), (int, float)):
        raise ValueError("numeric enrollment expiry required")
    agents = config.get("agents", {})
    if not isinstance(agents, dict) or len(agents) > 32:
        raise ValueError("invalid agents")
    for name, value in agents.items():
        identifier(name)
        if set(value) - {"tokenSha256", "targetIds", "canDrill", "canPromote"} \
                or not {"tokenSha256", "targetIds", "canDrill"}.issubset(value) or not SHA.fullmatch(value["tokenSha256"]) \
                or type(value["canDrill"]) is not bool or not isinstance(value["targetIds"], list) \
                or type(value.get("canPromote", False)) is not bool or not 1 <= len(value["targetIds"]) <= 32:
            raise ValueError("fixed agent hash, targets and capability required; URLs and commands forbidden")
        for target in value["targetIds"]:
            identifier(target)
    tokens = [config["enrollmentBrokerSha256"]] + [agent["tokenSha256"] for agent in agents.values()]
    if len(tokens) != len(set(tokens)):
        raise ValueError("broker and each agent require distinct credentials")
    return config


class ControlPlane:
    def __init__(self, database, config, clock=time.time, master_key=None):
        if not isinstance(master_key, bytes) or len(master_key) != 32:
            raise ValueError("independent 256-bit TOTP derivation master required")
        self.database, self.config, self.clock, self.master_key = str(database), config, clock, master_key
        Path(database).parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        with self.connect() as db:
            db.executescript("""
                PRAGMA journal_mode=WAL;
                CREATE TABLE IF NOT EXISTS meta(id INTEGER PRIMARY KEY CHECK(id=1),revision INTEGER NOT NULL);
                INSERT OR IGNORE INTO meta(id,revision) VALUES(1,0);
                CREATE TABLE IF NOT EXISTS users(subject TEXT PRIMARY KEY,account TEXT UNIQUE NOT NULL,
                    password_hash TEXT NOT NULL,totp_secret TEXT NOT NULL,last_counter INTEGER NOT NULL,
                    revoked INTEGER NOT NULL DEFAULT 0);
                CREATE TABLE IF NOT EXISTS enrollments(token TEXT PRIMARY KEY,subject TEXT NOT NULL,account TEXT NOT NULL,
                    expires REAL NOT NULL,secret TEXT,claimed INTEGER NOT NULL DEFAULT 0,used INTEGER NOT NULL DEFAULT 0);
                CREATE TABLE IF NOT EXISTS sessions(token TEXT PRIMARY KEY,subject TEXT NOT NULL,csrf TEXT NOT NULL,
                    issued REAL NOT NULL,expires REAL NOT NULL,last_seen REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS attempts(account TEXT NOT NULL,peer TEXT NOT NULL,at REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS targets(id TEXT PRIMARY KEY,label TEXT NOT NULL,agent TEXT NOT NULL,kind TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS snapshots(agent TEXT PRIMARY KEY,sequence INTEGER NOT NULL,observed REAL NOT NULL,
                    received REAL NOT NULL,health TEXT NOT NULL,payload TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS points(id TEXT PRIMARY KEY,storage_target TEXT NOT NULL,agent TEXT NOT NULL,
                    payload TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS jobs(id TEXT PRIMARY KEY,subject TEXT NOT NULL,request_hash TEXT NOT NULL,
                    target TEXT NOT NULL,point TEXT NOT NULL,agent TEXT NOT NULL,state TEXT NOT NULL,
                    created REAL NOT NULL,updated REAL NOT NULL,lease TEXT,lease_expires REAL,evidence TEXT);
                CREATE UNIQUE INDEX IF NOT EXISTS one_active_job ON jobs((1)) WHERE state IN ('QUEUED','RUNNING','UNKNOWN');
                CREATE TABLE IF NOT EXISTS audit(id INTEGER PRIMARY KEY,at REAL NOT NULL,actor TEXT NOT NULL,
                    action TEXT NOT NULL,object_id TEXT NOT NULL);
            """)
            meta_columns = {row[1] for row in db.execute("PRAGMA table_info(meta)")}
            if "master_fingerprint" not in meta_columns:
                db.execute("ALTER TABLE meta ADD COLUMN master_fingerprint TEXT")
            fingerprint = hashlib.sha256(master_key).hexdigest()
            recorded = db.execute("SELECT master_fingerprint FROM meta WHERE id=1").fetchone()[0]
            if recorded is not None and not hmac.compare_digest(recorded, fingerprint):
                raise ValueError("TOTP master does not match the independent identity store")
            db.execute("UPDATE meta SET master_fingerprint=? WHERE id=1", (fingerprint,))
            # Jobs survive service restarts; authentication capabilities do not.
            # Restoring an old control database must never revive an old session.
            db.execute("DELETE FROM sessions")
        os.chmod(database, 0o600)
        module_path = Path(__file__).with_name("promotion_receipts.py")
        self.promotions = None
        if module_path.is_file():
            spec = importlib.util.spec_from_file_location("uten_dr_promotion_receipts", module_path)
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            self.promotions = module.Coordinator(self, Refused)

    @contextlib.contextmanager
    def connect(self):
        db = sqlite3.connect(self.database, timeout=5, isolation_level=None)
        db.row_factory = sqlite3.Row
        db.execute("PRAGMA busy_timeout=5000")
        try:
            yield db
        finally:
            db.close()

    @contextlib.contextmanager
    def transaction(self):
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            try:
                yield db
                db.commit()
            except Exception:
                db.rollback()
                raise

    def audit(self, db, actor, action, object_id=""):
        db.execute("INSERT INTO audit(at,actor,action,object_id) VALUES(?,?,?,?)",
                   (self.clock(), actor, action, object_id))

    def revision(self, db):
        return db.execute("SELECT revision FROM meta WHERE id=1").fetchone()[0]

    def advance(self, db):
        db.execute("UPDATE meta SET revision=revision+1 WHERE id=1")

    def cas(self, db, body):
        if type(body.get("expectedRevision")) is not int or body["expectedRevision"] != self.revision(db):
            raise Refused("STATE_CHANGED")

    def broker(self, token):
        expected = self.config.get("enrollmentBrokerSha256", "")
        if not SHA.fullmatch(expected) or not hmac.compare_digest(digest(token), expected):
            raise Refused("UNAUTHORIZED", 401)

    def totp_key(self, subject, reference):
        if not reference.startswith("hmac-sha256-v1:") or not SHA.fullmatch(reference.split(":", 1)[1]):
            raise Refused("AUTHENTICATOR_STORAGE_UNAVAILABLE", 503)
        # HMAC is used as a standard PRF, not as an encryption construction.
        # The independent master is a systemd credential, never stored in SQLite.
        material = b"uten-dr:totp:v1\x00" + subject.encode() + b"\x00" + bytes.fromhex(reference.split(":", 1)[1])
        return base64.b32encode(hmac.new(self.master_key, material, hashlib.sha256).digest()[:20]).decode()

    def issue_enrollment(self, token, body):
        self.broker(token)
        if not self.clock() < self.config.get("enrollmentEnabledUntil", 0) <= self.clock() + 900:
            raise Refused("ENROLLMENT_WINDOW_CLOSED", 403)
        subject, account = identifier(body.get("subject")), body.get("account")
        if not isinstance(account, str) or not 1 <= len(account) <= 128 or account != account.strip() or any(ord(c) < 32 for c in account):
            raise Refused("INVALID_ACCOUNT", 400)
        proof = body.get("stepUpVerified") is True and body.get("localSuperAdmin") is True
        if not proof:
            raise Refused("LOCAL_STEP_UP_REQUIRED", 403)
        raw = secrets.token_urlsafe(48)
        with self.transaction() as db:
            if db.execute("SELECT 1 FROM users WHERE subject=?", (subject,)).fetchone():
                raise Refused("ALREADY_ENROLLED")
            db.execute("UPDATE enrollments SET used=1 WHERE subject=?", (subject,))
            db.execute("INSERT INTO enrollments(token,subject,account,expires) VALUES(?,?,?,?)",
                       (digest(raw), subject, account, self.clock() + 300))
            self.audit(db, subject, "ENROLLMENT_ISSUED")
        return {"enrollmentToken": raw, "expiresAt": utc(self.clock() + 300)}

    def claim_enrollment(self, body):
        with self.transaction() as db:
            row = db.execute("SELECT * FROM enrollments WHERE token=?", (digest(str(body.get("token", ""))),)).fetchone()
            if row is None or row["used"] or row["claimed"] or row["expires"] <= self.clock():
                raise Refused("ENROLLMENT_EXPIRED", 403)
            reference = "hmac-sha256-v1:" + secrets.token_hex(32)
            db.execute("UPDATE enrollments SET claimed=1,secret=? WHERE token=?", (reference, row["token"]))
            return {"account": row["account"], "totpSecret": self.totp_key(row["subject"], reference), "expiresAt": utc(row["expires"])}

    def finish_enrollment(self, body):
        password = body.get("password")
        if not password_valid(password):
            raise Refused("PASSWORD_STRENGTH_REQUIRED", 400)
        with self.transaction() as db:
            row = db.execute("SELECT * FROM enrollments WHERE token=?", (digest(str(body.get("token", ""))),)).fetchone()
            if row is None or row["used"] or not row["claimed"] or row["expires"] <= self.clock():
                raise Refused("ENROLLMENT_EXPIRED", 403)
            counter = self.counter(self.totp_key(row["subject"], row["secret"]), body.get("otp", ""), -1)
            if counter is None:
                raise Refused("AUTHENTICATION_FAILED", 403)
            db.execute("INSERT INTO users(subject,account,password_hash,totp_secret,last_counter) VALUES(?,?,?,?,?)",
                       (row["subject"], row["account"], password_hash(password), row["secret"], counter))
            db.execute("UPDATE enrollments SET used=1,secret=NULL WHERE token=?", (row["token"],))
            self.audit(db, row["subject"], "ENROLLMENT_COMPLETED")
        return {"enrolled": True, "message": "救援身份已绑定，请使用独立口令与动态验证码登录"}

    def counter(self, secret, otp, last):
        if not isinstance(otp, str) or not re.fullmatch(r"[0-9]{6}", otp):
            return None
        current = int(self.clock() // 30)
        return next((n for n in (current - 1, current, current + 1)
                     if n > last and hmac.compare_digest(totp(secret, n), otp)), None)

    def login(self, body, peer):
        account, password = str(body.get("account", ""))[:128], body.get("password", "")
        if not isinstance(password, str) or len(password) > 256:
            raise Refused("AUTHENTICATION_FAILED", 401)
        # Reserve a rate-limit attempt before expensive hashing and commit failed
        # TOTP attempts. There is no password-only session or replayable OTP token.
        with self.transaction() as db:
            db.execute("DELETE FROM attempts WHERE at<?", (self.clock() - 900,))
            count = db.execute("SELECT count(*) FROM attempts WHERE account=? OR (peer=? AND at>?)",
                               (account, peer, self.clock() - 60)).fetchone()[0]
            if count >= 8:
                raise Refused("AUTHENTICATION_RATE_LIMITED", 429)
            db.execute("INSERT INTO attempts VALUES(?,?,?)", (account, peer, self.clock()))
        with self.transaction() as db:
            user = db.execute("SELECT * FROM users WHERE account=? AND revoked=0", (account,)).fetchone()
            stored = user["password_hash"] if user else "00" * 16 + ":" + "00" * 64
            calculated = password_hash(password, stored.split(":")[0])
            matches = hmac.compare_digest(calculated, stored)
            counter = self.counter(self.totp_key(user["subject"], user["totp_secret"]), body.get("otp", ""), user["last_counter"]) if user and matches else None
            if counter is None:
                raise Refused("AUTHENTICATION_FAILED", 401)
            token, csrf = secrets.token_urlsafe(48), secrets.token_urlsafe(32)
            db.execute("UPDATE users SET last_counter=? WHERE subject=?", (counter, user["subject"]))
            db.execute("DELETE FROM sessions WHERE subject=?", (user["subject"],))
            db.execute("INSERT INTO sessions VALUES(?,?,?,?,?,?)",
                       (digest(token), user["subject"], digest(csrf), self.clock(), self.clock() + 1800, self.clock()))
            db.execute("DELETE FROM attempts WHERE account=?", (account,))
            self.audit(db, user["subject"], "LOGIN")
            return {"accessToken": token, "csrfToken": csrf, "expiresAt": utc(self.clock() + 1800), "account": account}

    def session(self, token, csrf=None, fresh=False):
        with self.transaction() as db:
            row = db.execute("SELECT s.*,u.account FROM sessions s JOIN users u ON u.subject=s.subject "
                             "WHERE s.token=? AND u.revoked=0", (digest(token),)).fetchone()
            if row is None or row["expires"] <= self.clock() or row["last_seen"] < self.clock() - 600:
                raise Refused("UNAUTHORIZED", 401)
            if csrf is not None and not hmac.compare_digest(row["csrf"], digest(csrf)):
                raise Refused("CSRF_REQUIRED", 403)
            if fresh and row["issued"] < self.clock() - 300:
                raise Refused("FRESH_MFA_REQUIRED", 403)
            db.execute("UPDATE sessions SET last_seen=? WHERE token=?", (self.clock(), row["token"]))
            return dict(row)

    def agent(self, token, claimed=None):
        found = next(((name, value) for name, value in self.config.get("agents", {}).items()
                      if hmac.compare_digest(digest(token), value.get("tokenSha256", ""))), None)
        if found is None or (claimed is not None and claimed != found[0]):
            raise Refused("AGENT_UNAUTHORIZED", 401)
        return found

    def state(self, user):
        with self.transaction() as db:
            # Lease expiry is UNKNOWN, never retried or declared rolled back.
            expired = db.execute("UPDATE jobs SET state='UNKNOWN',updated=? WHERE state='RUNNING' AND lease_expires<?",
                                 (self.clock(), self.clock())).rowcount
            if expired:
                self.advance(db)
                self.audit(db, "control", "DRILL_OUTCOME_UNKNOWN")
            snapshots = {r["agent"]: r for r in db.execute("SELECT * FROM snapshots")}
            agents = [{"id": name, "targetIds": value.get("targetIds", []), "canDrill": value.get("canDrill", False),
                       "canPromote": value.get("canPromote", False),
                       "online": name in snapshots and snapshots[name]["received"] > self.clock() - 300}
                      for name, value in self.config.get("agents", {}).items()]
            authority = db.execute("SELECT * FROM authority WHERE id=1").fetchone() if self.promotions else None
            reasons = self.promotions.reasons() if self.promotions else ["SIGNED_RECEIPT_VERIFIER_NOT_INSTALLED"]
            return {"revision": self.revision(db), "account": user["account"], "observedAt": utc(self.clock()),
                    "businessLocation": authority["primary_id"] if authority and authority["mode"] == "ACTIVE" else "UNKNOWN",
                    "authorityEpoch": authority["epoch"] if authority else None,
                    "authorityMode": authority["mode"] if authority else "UNVERIFIED",
                    "promotionAllowed": False, "promotionPreparationAllowed": not reasons,
                    "promotionReasons": reasons or ["SIGNED_OPERATION_FENCING_AND_RESTORE_RECEIPTS_REQUIRED"],
                    "tls": tls_status(self.clock()),
                    "agents": agents, "targets": [dict(r) for r in db.execute("SELECT * FROM targets ORDER BY id")],
                    "recoveryPoints": [{**json.loads(r["payload"]), "available": self.point_available(db, r["id"], r["agent"])}
                                       for r in db.execute("SELECT id,agent,payload FROM points ORDER BY id DESC LIMIT 100")],
                    "jobs": [self.job_public(r) for r in db.execute("SELECT * FROM jobs ORDER BY created DESC LIMIT 20")]}

    def put_target(self, user, target_id, body):
        if set(body) != {"label", "agentId", "kind", "expectedRevision"}:
            raise Refused("INVALID_TARGET_REGISTRATION", 400)
        identifier(target_id)
        agent_id, kind = identifier(body.get("agentId")), body.get("kind")
        agent = self.config.get("agents", {}).get(agent_id, {})
        if target_id not in agent.get("targetIds", []) or kind not in ("ARCHIVE", "DRILL", "BUSINESS"):
            raise Refused("TARGET_NOT_COMMISSIONED", 403)
        if kind == "DRILL" and agent.get("canDrill") is not True:
            raise Refused("DRILL_EXECUTOR_NOT_COMMISSIONED", 403)
        if kind == "BUSINESS" and agent.get("canPromote") is not True:
            raise Refused("BUSINESS_TARGET_NOT_COMMISSIONED", 403)
        label = body.get("label")
        if not isinstance(label, str) or not 1 <= len(label) <= 80 or any(ord(c) < 32 for c in label):
            raise Refused("INVALID_LABEL", 400)
        with self.transaction() as db:
            self.cas(db, body)
            if db.execute("SELECT 1 FROM jobs WHERE target=? AND state IN ('PREPARING','QUEUED','RUNNING','UNKNOWN')", (target_id,)).fetchone():
                raise Refused("JOB_ALREADY_ACTIVE")
            db.execute("INSERT INTO targets VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET label=excluded.label,agent=excluded.agent,kind=excluded.kind",
                       (target_id, label, agent_id, kind))
            self.advance(db)
            self.audit(db, user["subject"], "TARGET_REGISTERED", target_id)
        return {"registered": True}

    def snapshot(self, token, body):
        name, agent = self.agent(token, body.get("agentId"))
        if type(body.get("sequence")) is not int or body["sequence"] < 0 or body.get("health") not in ("HEALTHY", "DEGRADED"):
            raise Refused("INVALID_SNAPSHOT", 400)
        try:
            observed = timestamp(body["observedAt"])
        except (ValueError, TypeError, KeyError):
            raise Refused("INVALID_SNAPSHOT_TIME", 400)
        if abs(self.clock() - observed) > 300:
            raise Refused("STALE_SNAPSHOT", 409)
        points = body.get("recoveryPoints", [])
        if not isinstance(points, list) or len(points) > 100:
            raise Refused("INVALID_SNAPSHOT", 400)
        clean = []
        for point in points:
            identifier(point.get("id"))
            if point.get("storageTargetId") not in agent.get("targetIds", []):
                raise Refused("TARGET_SCOPE_DENIED", 403)
            for key in ("manifestSha256", "cipherSha256"):
                if not SHA.fullmatch(str(point.get(key, ""))):
                    raise Refused("INVALID_MANIFEST", 400)
            if any(type(point.get(key)) is not bool for key in ("complete", "keysCovered", "verified")):
                raise Refused("INVALID_RECOVERY_POINT", 400)
            try:
                if timestamp(point["recoverableUntil"]) > observed + 60:
                    raise ValueError()
            except (KeyError, ValueError, TypeError):
                raise Refused("INVALID_RECOVERY_TIME", 400)
            if type(point.get("cipherVerified", False)) is not bool:
                raise Refused("INVALID_RECOVERY_POINT", 400)
            cleaned = {k: point[k] for k in ("id", "storageTargetId", "recoverableUntil", "manifestSha256", "cipherSha256", "complete", "keysCovered", "verified")}
            if agent.get("canDrill") is not True:
                # An archive publisher can attest ciphertext receipt only. It
                # cannot turn source-side booleans into restored key/data proof.
                cleaned["keysCovered"] = False
                cleaned["verified"] = False
            cleaned["cipherVerified"] = point.get("cipherVerified", False)
            clean.append(cleaned)
        with self.transaction() as db:
            old = db.execute("SELECT sequence FROM snapshots WHERE agent=?", (name,)).fetchone()
            if old and old[0] >= body["sequence"]:
                raise Refused("SNAPSHOT_REPLAY")
            db.execute("INSERT INTO snapshots VALUES(?,?,?,?,?,?) ON CONFLICT(agent) DO UPDATE SET sequence=excluded.sequence,observed=excluded.observed,received=excluded.received,health=excluded.health,payload=excluded.payload",
                       (name, body["sequence"], observed, self.clock(), body["health"], json.dumps({"pointIds": [p["id"] for p in clean]})))
            for point in clean:
                old_point = db.execute("SELECT payload,agent FROM points WHERE id=?", (point["id"],)).fetchone()
                encoded = json.dumps(point, sort_keys=True)
                if old_point and (old_point["agent"] != name or old_point["payload"] != encoded):
                    raise Refused("RECOVERY_POINT_IMMUTABLE")
                db.execute("INSERT OR IGNORE INTO points VALUES(?,?,?,?)", (point["id"], point["storageTargetId"], name, encoded))
            self.advance(db)
        return {"accepted": True}

    def point_available(self, db, point_id, agent):
        row = db.execute("SELECT received,payload FROM snapshots WHERE agent=?", (agent,)).fetchone()
        return row is not None and row["received"] > self.clock() - 300 \
            and point_id in json.loads(row["payload"]).get("pointIds", [])

    def create_job(self, user, body):
        if set(body) != {"requestId", "kind", "targetId", "recoveryPointId", "expectedRevision"}:
            raise Refused("INVALID_JOB_REQUEST", 400)
        try:
            job_id = str(uuid.UUID(body.get("requestId", "")))
        except (ValueError, TypeError, AttributeError):
            raise Refused("INVALID_REQUEST_ID", 400)
        if body.get("kind") != "DRILL":
            raise Refused("ONLY_ISOLATED_DRILL_SUPPORTED", 403)
        request_hash = digest(json.dumps({k: body.get(k) for k in ("kind", "targetId", "recoveryPointId")}, sort_keys=True))
        with self.transaction() as db:
            previous = db.execute("SELECT * FROM jobs WHERE id=?", (job_id,)).fetchone()
            if previous:
                if previous["subject"] != user["subject"] or previous["request_hash"] != request_hash:
                    raise Refused("IDEMPOTENCY_CONFLICT")
                return self.job_public(previous)
            self.cas(db, body)
            target = db.execute("SELECT * FROM targets WHERE id=?", (body.get("targetId"),)).fetchone()
            point = db.execute("SELECT payload,agent FROM points WHERE id=?", (body.get("recoveryPointId"),)).fetchone()
            if not target or target["kind"] != "DRILL" or not point:
                raise Refused("DRILL_NOT_READY")
            if not self.point_available(db, body["recoveryPointId"], point["agent"]):
                raise Refused("RECOVERY_POINT_AVAILABILITY_UNCONFIRMED")
            snapshot = db.execute("SELECT * FROM snapshots WHERE agent=?", (target["agent"],)).fetchone()
            if not snapshot or snapshot["received"] < self.clock() - 300 or snapshot["health"] != "HEALTHY":
                raise Refused("DRILL_EXECUTOR_OFFLINE")
            point = json.loads(point[0])
            # A verification drill is how unknown restore/key coverage becomes
            # measured evidence. Cipher integrity is required before queuing;
            # unknown keys must never be reported as a successful restoration.
            if not point["complete"] or not point.get("cipherVerified", False):
                raise Refused("RECOVERY_POINT_CIPHERTEXT_NOT_VERIFIED")
            try:
                db.execute("INSERT INTO jobs(id,subject,request_hash,target,point,agent,state,created,updated) VALUES(?,?,?,?,?,?,'QUEUED',?,?)",
                           (job_id, user["subject"], request_hash, target["id"], point["id"], target["agent"], self.clock(), self.clock()))
            except sqlite3.IntegrityError:
                raise Refused("JOB_ALREADY_ACTIVE")
            self.advance(db)
            self.audit(db, user["subject"], "DRILL_QUEUED", job_id)
            return self.job_public(db.execute("SELECT * FROM jobs WHERE id=?", (job_id,)).fetchone())

    def claim(self, token, body):
        name, agent = self.agent(token, body.get("agentId"))
        if agent.get("canDrill") is not True and agent.get("canPromote") is not True:
            raise Refused("DRILL_EXECUTOR_NOT_COMMISSIONED", 403)
        with self.transaction() as db:
            row = db.execute("SELECT * FROM jobs WHERE agent=? AND state='QUEUED' ORDER BY created LIMIT 1", (name,)).fetchone()
            if row is None:
                return {"job": None}
            kind = row["kind"] if "kind" in row.keys() else "DRILL"
            if row["target"] not in agent.get("targetIds", []):
                raise Refused("TARGET_SCOPE_DENIED", 403)
            if kind == "DRILL" and agent.get("canDrill") is not True:
                raise Refused("DRILL_EXECUTOR_NOT_COMMISSIONED", 403)
            point_row = db.execute("SELECT agent FROM points WHERE id=?", (row["point"],)).fetchone()
            if point_row is None or not self.point_available(db, row["point"], point_row["agent"]):
                raise Refused("RECOVERY_POINT_AVAILABILITY_UNCONFIRMED")
            lease = secrets.token_urlsafe(48)
            expires = self.promotions.claim(db, row, agent) if kind == "PROMOTE" else self.clock() + 3600
            db.execute("UPDATE jobs SET state='RUNNING',lease=?,lease_expires=?,updated=? WHERE id=? AND state='QUEUED'",
                       (digest(lease), expires, self.clock(), row["id"]))
            point = json.loads(db.execute("SELECT payload FROM points WHERE id=?", (row["point"],)).fetchone()[0])
            self.advance(db)
            self.audit(db, name, "DRILL_CLAIMED", row["id"])
            job = {"id": row["id"], "kind": kind, "targetId": row["target"], "recoveryPointId": row["point"],
                   "manifestSha256": point["manifestSha256"]}
            if kind == "PROMOTE":
                job.update({"desiredEpoch": row["desired_epoch"], "sourceId": row["source_id"],
                            "signedReceipts": json.loads(row["proofs"])})
            return {"job": job, "leaseToken": lease, "leaseExpiresAt": utc(expires)}

    def complete(self, token, job_id, body):
        name, agent = self.agent(token)
        if agent.get("canDrill") is not True and agent.get("canPromote") is not True:
            raise Refused("DRILL_EXECUTOR_NOT_COMMISSIONED", 403)
        with self.transaction() as db:
            row = db.execute("SELECT * FROM jobs WHERE id=? AND agent=?", (job_id, name)).fetchone()
            if row is None or row["state"] != "RUNNING" or row["lease_expires"] <= self.clock() or not hmac.compare_digest(row["lease"], digest(str(body.get("leaseToken", "")))):
                raise Refused("LEASE_INVALID")
            if row["target"] not in agent.get("targetIds", []):
                raise Refused("TARGET_SCOPE_DENIED", 403)
            if "kind" in row.keys() and row["kind"] == "PROMOTE":
                if not self.promotions or agent.get("canPromote") is not True:
                    raise Refused("PROMOTION_EXECUTOR_NOT_COMMISSIONED", 403)
                return self.promotions.complete(db, row, body)
            if agent.get("canDrill") is not True:
                raise Refused("DRILL_EXECUTOR_NOT_COMMISSIONED", 403)
            evidence = body.get("evidence", {})
            success = body.get("success") is True
            verified = isinstance(evidence, dict) and all(evidence.get(k) is True for k in EVIDENCE) and SHA.fullmatch(str(evidence.get("reportSha256", "")))
            if success and not verified:
                raise Refused("RESTORE_EVIDENCE_INCOMPLETE")
            clean = {k: evidence.get(k) is True for k in EVIDENCE}
            clean["reportSha256"] = evidence.get("reportSha256", "") if SHA.fullmatch(str(evidence.get("reportSha256", ""))) else ""
            db.execute("UPDATE jobs SET state=?,evidence=?,updated=? WHERE id=?",
                       ("SUCCEEDED" if success else "FAILED", json.dumps(clean), self.clock(), job_id))
            self.advance(db)
            self.audit(db, name, "DRILL_SUCCEEDED" if success else "DRILL_FAILED", job_id)
            return self.job_public(db.execute("SELECT * FROM jobs WHERE id=?", (job_id,)).fetchone())

    def job_public(self, row):
        return {"id": row["id"], "kind": row["kind"] if "kind" in row.keys() else "DRILL",
                "desiredEpoch": row["desired_epoch"] if "desired_epoch" in row.keys() else None,
                "sourceId": row["source_id"] if "source_id" in row.keys() else None,
                "targetId": row["target"], "recoveryPointId": row["point"],
                "state": row["state"], "createdAt": utc(row["created"]), "updatedAt": utc(row["updated"]),
                "evidence": json.loads(row["evidence"]) if row["evidence"] else None}

    def dispatch(self, method, path, body, token, csrf, peer):
        if method == "POST" and path == "/v1/broker/enrollments":
            return self.issue_enrollment(token, body)
        if method == "POST" and path == "/v1/enrollments/claim":
            return self.claim_enrollment(body)
        if method == "POST" and path == "/v1/enrollments/complete":
            return self.finish_enrollment(body)
        if method == "POST" and path == "/v1/auth/login":
            return self.login(body, peer)
        if method == "POST" and path == "/v1/agent/snapshot":
            return self.snapshot(token, body)
        if method == "POST" and path == "/v1/agent/jobs/claim":
            return self.claim(token, body)
        match = re.fullmatch(r"/v1/agent/jobs/([a-f0-9-]{36})/complete", path)
        if method == "POST" and match:
            return self.complete(token, match[1], body)
        user = self.session(token, csrf if method != "GET" else None,
                            fresh=method != "GET" and path != "/v1/auth/logout")
        if method == "GET" and path == "/v1/state":
            return self.state(user)
        if method == "POST" and path == "/v1/auth/logout":
            with self.transaction() as db:
                db.execute("DELETE FROM sessions WHERE token=?", (digest(token),))
            return {"loggedOut": True}
        if method == "PUT" and path.startswith("/v1/targets/"):
            return self.put_target(user, path.removeprefix("/v1/targets/"), body)
        if method == "POST" and path == "/v1/jobs":
            return self.create_job(user, body)
        if method == "GET" and re.fullmatch(r"/v1/jobs/[a-f0-9-]{36}", path):
            with self.connect() as db:
                row = db.execute("SELECT * FROM jobs WHERE id=?", (path.rsplit("/", 1)[-1],)).fetchone()
                if not row:
                    raise Refused("JOB_NOT_FOUND", 404)
                return self.job_public(row)
        if method == "POST" and path in ("/v1/promotions", "/v1/promotions/prepare"):
            if not self.promotions:
                raise Refused("SIGNED_RECEIPT_VERIFIER_NOT_INSTALLED", 409)
            return self.promotions.prepare(user, body) if path.endswith("/prepare") else self.promotions.authorize(user, body)
        match = re.fullmatch(r"/v1/promotions/([a-f0-9-]{36})/(refresh-proofs|reconcile|cancel)", path)
        if method == "POST" and match:
            if not self.promotions:
                raise Refused("SIGNED_RECEIPT_VERIFIER_NOT_INSTALLED", 409)
            return {"refresh-proofs": self.promotions.refresh, "reconcile": self.promotions.reconcile,
                    "cancel": self.promotions.cancel}[match[2]](user, match[1], body)
        raise Refused("NOT_FOUND", 404)


class Handler(BaseHTTPRequestHandler):
    server_version = "uten-dr"
    sys_version = ""
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        # Never log enrollment tokens, passwords, OTPs, URLs, request bodies or headers.
        pass

    def send(self, status, data, mime="application/json; charset=utf-8", nonce=None):
        raw = data if isinstance(data, bytes) else json.dumps(data, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.close_connection = True
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Content-Security-Policy", "default-src 'none'; base-uri 'none'; frame-ancestors 'none'; connect-src 'self'; "
                         + (f"script-src 'nonce-{nonce}'; style-src 'nonce-{nonce}'" if nonce else "script-src 'none'"))
        origin = self.headers.get("Origin")
        if origin in self.server.control.config.get("allowedOrigins", []):
            self.send_header("Access-Control-Allow-Origin", origin)
            self.send_header("Vary", "Origin")
        self.end_headers()
        self.wfile.write(raw)

    def do_OPTIONS(self):
        if self.headers.get("Origin") not in self.server.control.config.get("allowedOrigins", []):
            return self.send(403, {"code": "ORIGIN_DENIED"})
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", self.headers["Origin"])
        self.send_header("Access-Control-Allow-Methods", "GET, POST, PUT")
        self.send_header("Access-Control-Allow-Headers", "Authorization, Content-Type, X-CSRF-Token")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def handle_request(self):
        self.connection.settimeout(15)
        try:
            parts = urlsplit(self.path)
            if parts.query or parts.fragment:
                raise Refused("QUERY_NOT_ALLOWED", 400)
            origin = self.headers.get("Origin")
            if origin and origin not in self.server.control.config.get("allowedOrigins", []):
                raise Refused("ORIGIN_DENIED", 403)
            if self.command == "GET" and parts.path == "/healthz":
                with self.server.control.connect() as db:
                    setup_required = db.execute("SELECT 1 FROM users WHERE revoked=0 LIMIT 1").fetchone() is None
                return self.send(200, {"status": "ok", "service": "disaster-control", "businessReady": False,
                                       "setupRequired": setup_required})
            if self.command == "GET" and parts.path in ("/", "/enroll"):
                nonce = secrets.token_urlsafe(24)
                page = Path(__file__).with_name("rescue.html").read_text(encoding="utf-8").replace("{{NONCE}}", nonce)
                return self.send(200, page.encode(), "text/html; charset=utf-8", nonce)
            body = {}
            if self.command != "GET":
                lengths = self.headers.get_all("Content-Length", [])
                if len(lengths) != 1 or not lengths[0].isdigit() or self.headers.get("Transfer-Encoding"):
                    raise Refused("CONTENT_LENGTH_REQUIRED", 411)
                length = int(lengths[0])
                if length > MAX_BODY:
                    raise Refused("BODY_TOO_LARGE", 413)
                if self.headers.get("Content-Type", "").split(";")[0] != "application/json":
                    raise Refused("JSON_REQUIRED", 415)
                body = json.loads(self.rfile.read(length))
                if not isinstance(body, dict):
                    raise Refused("JSON_OBJECT_REQUIRED", 400)
            authorization = self.headers.get("Authorization", "")
            token = authorization.removeprefix("Bearer ") if authorization.startswith("Bearer ") else ""
            result = self.server.control.dispatch(self.command, parts.path, body, token,
                                                  self.headers.get("X-CSRF-Token", ""), self.client_address[0])
            self.send(200, result)
        except Refused as error:
            self.send(error.status, {"code": error.code})
        except (ValueError, TypeError, KeyError, UnicodeError):
            self.send(400, {"code": "INVALID_REQUEST"})
        except Exception:
            self.send(503, {"code": "CONTROL_STATE_UNAVAILABLE"})

    do_GET = do_POST = do_PUT = handle_request


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    parser.add_argument("--database", required=True)
    parser.add_argument("--master-key-file", required=True)
    parser.add_argument("--port", type=int, default=9087)
    args = parser.parse_args()
    config_path = Path(args.config)
    mode = config_path.stat()
    if config_path.is_symlink() or mode.st_uid not in (0, os.geteuid()) or stat.S_IMODE(mode.st_mode) & 0o027:
        raise SystemExit("protected control configuration required (0640 or stricter)")
    config = validate_config(json.loads(config_path.read_text(encoding="utf-8")))
    os.umask(0o077)
    try:
        master = read_master_credential(Path(args.master_key_file))
    except (OSError, ValueError):
        raise SystemExit("private TOTP master systemd credential required") from None
    control = ControlPlane(Path(args.database), config, master_key=master)
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.daemon_threads = True
    server.control = control
    server.serve_forever()


if __name__ == "__main__":
    main()
