"""Ed25519 commissioning and promotion state machine; never executes host commands.

Private signing keys remain with independent fencing/restore/activation adapters.
No deployed adapter is inferred from a health probe, checkbox or restored database.
"""
import base64
import datetime as dt
import hashlib
import importlib.metadata
import json
import re
import sqlite3
import uuid

try:
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
    from cryptography.exceptions import InvalidSignature
    _version = tuple(int(x) for x in importlib.metadata.version("cryptography").split(".")[:3])
    CRYPTO_READY = _version >= (50, 0, 2)
except (ImportError, ValueError, importlib.metadata.PackageNotFoundError):
    CRYPTO_READY = False

SHA = re.compile(r"[a-f0-9]{64}\Z")
ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}\Z")
PURPOSES = {"FENCE", "RESTORE", "ACTIVATION"}
CHECKS = {
    "FENCE": ("databaseWritesBlocked", "storageWritesBlocked", "oldWriterLeasesInvalidated"),
    "RESTORE": ("databaseRestored", "attachmentsVerified", "keysVerified", "sessionsRevoked", "permissionsRevalidated", "sideEffectsDisabled"),
    "ACTIVATION": ("newEpochEnforced", "oldPrimaryStillFenced", "businessHealthVerified", "sessionsRevoked", "permissionsRevalidated"),
}


def canonical(receipt):
    return json.dumps({k: v for k, v in receipt.items() if k != "signature"},
                      sort_keys=True, separators=(",", ":"), ensure_ascii=True, allow_nan=False).encode("ascii")


def stamp(value):
    if not isinstance(value, str):
        raise ValueError("timestamp string required")
    parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("timezone required")
    return parsed.timestamp()


def validate_config(config):
    if config is None:
        return
    if set(config) != {"commissioned", "currentPrimaryId", "minimumEpoch", "signers"} \
            or type(config["commissioned"]) is not bool or not ID.fullmatch(config["currentPrimaryId"]) \
            or type(config["minimumEpoch"]) is not int or config["minimumEpoch"] < 1:
        raise ValueError("explicit commissioned authority and monotonic minimum epoch required")
    keys = set()
    for name, signer in config["signers"].items():
        if not ID.fullmatch(name) or set(signer) != {"publicKey", "purpose", "sourceIds", "targetIds"} \
                or not SHA.fullmatch(signer["publicKey"]) or signer["purpose"] not in PURPOSES \
                or not signer["sourceIds"] or not signer["targetIds"] \
                or any(not ID.fullmatch(x) for x in signer["sourceIds"] + signer["targetIds"]):
            raise ValueError("pre-registered scoped Ed25519 signer required")
        if signer["publicKey"] in keys:
            raise ValueError("fencing, restore verification and activation require independent signing identities")
        keys.add(signer["publicKey"])


class Coordinator:
    def __init__(self, control, refusal):
        self.control, self.refusal = control, refusal
        self.config = control.config.get("promotion")
        validate_config(self.config)
        with control.transaction() as db:
            columns = {r[1] for r in db.execute("PRAGMA table_info(jobs)")}
            for name, definition in {"kind": "TEXT NOT NULL DEFAULT 'DRILL'", "desired_epoch": "INTEGER",
                                     "source_id": "TEXT", "proofs": "TEXT"}.items():
                if name not in columns:
                    db.execute("ALTER TABLE jobs ADD COLUMN " + name + " " + definition)
            db.execute("CREATE TABLE IF NOT EXISTS receipt_ledger(id TEXT PRIMARY KEY,operation TEXT NOT NULL,purpose TEXT NOT NULL,sha256 TEXT NOT NULL)")
            db.execute("CREATE TABLE IF NOT EXISTS authority(id INTEGER PRIMARY KEY CHECK(id=1),primary_id TEXT NOT NULL,epoch INTEGER NOT NULL,mode TEXT NOT NULL)")
            db.execute("DROP INDEX IF EXISTS one_active_job")
            db.execute("CREATE UNIQUE INDEX one_active_job ON jobs((1)) WHERE state IN ('PREPARING','QUEUED','RUNNING','UNKNOWN')")
            if self.config and self.config["commissioned"]:
                db.execute("INSERT OR IGNORE INTO authority VALUES(1,?,?,'ACTIVE')",
                           (self.config["currentPrimaryId"], self.config["minimumEpoch"]))
                authority = db.execute("SELECT epoch FROM authority WHERE id=1").fetchone()
                if authority["epoch"] < self.config["minimumEpoch"]:
                    db.execute("UPDATE authority SET mode='UNKNOWN' WHERE id=1")
                    db.execute("UPDATE jobs SET state='UNKNOWN',updated=? WHERE kind='PROMOTE' AND state IN ('PREPARING','QUEUED','RUNNING')",
                               (control.clock(),))
                    control.advance(db)
                    control.audit(db, "control", "RESTORED_CONTROL_AUTHORITY_BELOW_FLOOR")

    def reasons(self):
        reasons = []
        if not CRYPTO_READY:
            reasons.append("CRYPTO_SIGNATURE_VERIFIER_NOT_READY")
        if not self.config or not self.config["commissioned"]:
            reasons.append("AUTHORITY_NOT_COMMISSIONED")
        available = {s["purpose"] for s in (self.config or {}).get("signers", {}).values()}
        for purpose in PURPOSES - available:
            reasons.append("TRUSTED_" + purpose + "_ADAPTER_NOT_REGISTERED")
        if self.config:
            with self.control.connect() as db:
                authority = db.execute("SELECT epoch,mode FROM authority WHERE id=1").fetchone()
                if not authority or authority["epoch"] < self.config["minimumEpoch"] or authority["mode"] == "UNKNOWN":
                    reasons.append("AUTHORITY_EPOCH_BELOW_FLOOR_OR_UNKNOWN")
        return sorted(reasons)

    def require_ready(self):
        if self.reasons():
            raise self.refusal("PROMOTION_NOT_COMMISSIONED", 409)

    def verify(self, receipt, purpose, job, point, now, lease=None):
        if self.config and job["desired_epoch"] < self.config["minimumEpoch"]:
            raise self.refusal("AUTHORITY_EPOCH_BELOW_FLOOR", 403)
        self.require_ready()
        required = {"version", "receiptId", "purpose", "signerId", "operationId", "sourceId", "targetId",
                    "recoveryPointId", "manifestSha256", "epoch", "issuedAt", "expiresAt", "checks",
                    "databaseSystemIdentifier", "restoredLsn", "leaseSha256", "signature"}
        try:
            if not isinstance(receipt, dict) or set(receipt) != required or type(receipt["version"]) is not int or receipt["version"] != 1:
                raise ValueError()
            uuid.UUID(receipt["receiptId"])
            signer = self.config["signers"][receipt["signerId"]]
            if signer["purpose"] != purpose or receipt["purpose"] != purpose \
                    or receipt["sourceId"] not in signer["sourceIds"] or receipt["targetId"] not in signer["targetIds"]:
                raise ValueError()
            bindings = {"operationId": job["id"], "sourceId": job["source_id"], "targetId": job["target"],
                        "recoveryPointId": job["point"], "manifestSha256": point["manifestSha256"], "epoch": job["desired_epoch"]}
            if any(receipt[k] != value for k, value in bindings.items()) or type(receipt["epoch"]) is not int:
                raise ValueError()
            issued, expires = stamp(receipt["issuedAt"]), stamp(receipt["expiresAt"])
            if issued < job["created"] or issued > now + 10 or not now < expires <= issued + 300:
                raise ValueError()
            if set(receipt["checks"]) != set(CHECKS[purpose]) or any(receipt["checks"][k] is not True for k in CHECKS[purpose]):
                raise ValueError()
            if purpose in ("RESTORE", "ACTIVATION"):
                if not re.fullmatch(r"[0-9]{1,24}", receipt["databaseSystemIdentifier"]) \
                        or not re.fullmatch(r"[A-F0-9]{1,16}/[A-F0-9]{1,16}", receipt["restoredLsn"]):
                    raise ValueError()
            elif receipt["databaseSystemIdentifier"] or receipt["restoredLsn"]:
                raise ValueError()
            if receipt["leaseSha256"] != (lease or ""):
                raise ValueError()
            signature = base64.b64decode(receipt["signature"], validate=True)
            Ed25519PublicKey.from_public_bytes(bytes.fromhex(signer["publicKey"])).verify(signature, canonical(receipt))
        except (ValueError, TypeError, KeyError, AttributeError, OverflowError, InvalidSignature if CRYPTO_READY else ValueError):
            raise self.refusal("SIGNED_RECEIPT_INVALID", 403)
        return receipt

    def consume(self, db, receipt):
        try:
            db.execute("INSERT INTO receipt_ledger VALUES(?,?,?,?)", (receipt["receiptId"], receipt["operationId"],
                       receipt["purpose"], hashlib.sha256(canonical(receipt)).hexdigest()))
        except sqlite3.IntegrityError:
            raise self.refusal("SIGNED_RECEIPT_REPLAY", 409)

    def prepare(self, user, body):
        self.require_ready()
        try:
            operation = str(uuid.UUID(body["requestId"]))
        except (ValueError, TypeError, KeyError):
            raise self.refusal("INVALID_REQUEST_ID", 400)
        control = self.control
        with control.transaction() as db:
            previous = db.execute("SELECT * FROM jobs WHERE id=?", (operation,)).fetchone()
            if previous:
                if previous["subject"] == user["subject"] and previous["kind"] == "PROMOTE" \
                        and previous["target"] == body.get("targetId") and previous["point"] == body.get("recoveryPointId"):
                    return control.job_public(previous)
                raise self.refusal("IDEMPOTENCY_CONFLICT")
            control.cas(db, body)
            authority = db.execute("SELECT * FROM authority WHERE id=1").fetchone()
            if not authority or authority["mode"] != "ACTIVE" or authority["epoch"] < self.config["minimumEpoch"] \
                    or body.get("expectedEpoch") != authority["epoch"]:
                raise self.refusal("AUTHORITY_EPOCH_UNKNOWN_OR_CHANGED")
            target = db.execute("SELECT * FROM targets WHERE id=?", (body.get("targetId"),)).fetchone()
            point = db.execute("SELECT payload,agent FROM points WHERE id=?", (body.get("recoveryPointId"),)).fetchone()
            if not target or target["kind"] != "BUSINESS" or not point \
                    or control.config["agents"][target["agent"]].get("canPromote") is not True:
                raise self.refusal("BUSINESS_TARGET_NOT_COMMISSIONED")
            if not control.point_available(db, body["recoveryPointId"], point["agent"]):
                raise self.refusal("RECOVERY_POINT_AVAILABILITY_UNCONFIRMED")
            health = db.execute("SELECT received,health FROM snapshots WHERE agent=?", (target["agent"],)).fetchone()
            if not health or health["received"] < control.clock() - 300 or health["health"] != "HEALTHY":
                raise self.refusal("PROMOTION_EXECUTOR_OFFLINE")
            point = json.loads(point[0])
            if not point["complete"] or not point.get("cipherVerified"):
                raise self.refusal("RECOVERY_POINT_CIPHERTEXT_NOT_VERIFIED")
            try:
                db.execute("INSERT INTO jobs(id,subject,request_hash,target,point,agent,state,created,updated,kind,desired_epoch,source_id) VALUES(?,?,?,?,?,?,'PREPARING',?,?,'PROMOTE',?,?)",
                           (operation, user["subject"], "promotion", target["id"], point["id"], target["agent"],
                            control.clock(), control.clock(), authority["epoch"] + 1, authority["primary_id"]))
            except sqlite3.IntegrityError:
                raise self.refusal("JOB_ALREADY_ACTIVE")
            control.advance(db)
            control.audit(db, user["subject"], "PROMOTION_PREPARING", operation)
            return control.job_public(db.execute("SELECT * FROM jobs WHERE id=?", (operation,)).fetchone())

    def authorize(self, user, body):
        self.require_ready()
        control = self.control
        with control.transaction() as db:
            control.cas(db, body)
            job = db.execute("SELECT * FROM jobs WHERE id=? AND kind='PROMOTE'", (body.get("operationId"),)).fetchone()
            if not job or job["subject"] != user["subject"] or job["state"] != "PREPARING":
                raise self.refusal("PROMOTION_OPERATION_CHANGED")
            authority = db.execute("SELECT * FROM authority WHERE id=1").fetchone()
            if authority["mode"] != "ACTIVE" or authority["epoch"] + 1 != job["desired_epoch"] \
                    or body.get("expectedEpoch") != authority["epoch"]:
                raise self.refusal("AUTHORITY_EPOCH_UNKNOWN_OR_CHANGED")
            point = json.loads(db.execute("SELECT payload FROM points WHERE id=?", (job["point"],)).fetchone()[0])
            fence = self.verify(body.get("fenceReceipt"), "FENCE", job, point, control.clock())
            restore = self.verify(body.get("restoreReceipt"), "RESTORE", job, point, control.clock())
            self.consume(db, fence)
            self.consume(db, restore)
            db.execute("UPDATE authority SET epoch=?,mode='FENCED' WHERE id=1 AND epoch=?",
                       (job["desired_epoch"], authority["epoch"]))
            db.execute("UPDATE jobs SET state='QUEUED',proofs=?,updated=? WHERE id=?",
                       (json.dumps({"fence": fence, "restore": restore}), control.clock(), job["id"]))
            control.advance(db)
            control.audit(db, user["subject"], "PROMOTION_AUTHORIZED_AFTER_SIGNED_FENCING", job["id"])
            return control.job_public(db.execute("SELECT * FROM jobs WHERE id=?", (job["id"],)).fetchone())

    def claim(self, db, job, agent):
        if agent.get("canPromote") is not True or job["target"] not in agent["targetIds"]:
            raise self.refusal("PROMOTION_EXECUTOR_NOT_COMMISSIONED", 403)
        self.require_current_authority(db, job)
        point = json.loads(db.execute("SELECT payload FROM points WHERE id=?", (job["point"],)).fetchone()[0])
        proofs = json.loads(job["proofs"])
        self.verify(proofs["fence"], "FENCE", job, point, self.control.clock())
        self.verify(proofs["restore"], "RESTORE", job, point, self.control.clock())
        return min(stamp(proofs["fence"]["expiresAt"]), stamp(proofs["restore"]["expiresAt"]), self.control.clock() + 300)

    def refresh(self, user, operation_id, body):
        control = self.control
        with control.transaction() as db:
            control.cas(db, body)
            job = db.execute("SELECT * FROM jobs WHERE id=? AND kind='PROMOTE'", (operation_id,)).fetchone()
            if not job or job["subject"] != user["subject"] or job["state"] != "QUEUED":
                raise self.refusal("PROMOTION_OPERATION_CHANGED")
            self.require_current_authority(db, job)
            point = json.loads(db.execute("SELECT payload FROM points WHERE id=?", (job["point"],)).fetchone()[0])
            fence = self.verify(body.get("fenceReceipt"), "FENCE", job, point, control.clock())
            restore = self.verify(body.get("restoreReceipt"), "RESTORE", job, point, control.clock())
            self.consume(db, fence)
            self.consume(db, restore)
            db.execute("UPDATE jobs SET proofs=?,updated=? WHERE id=?",
                       (json.dumps({"fence": fence, "restore": restore}), control.clock(), operation_id))
            control.advance(db)
            control.audit(db, user["subject"], "PROMOTION_PROOFS_REFRESHED_WITHOUT_REPLAY", operation_id)
            return control.job_public(db.execute("SELECT * FROM jobs WHERE id=?", (operation_id,)).fetchone())

    def cancel(self, user, operation_id, body):
        control = self.control
        with control.transaction() as db:
            control.cas(db, body)
            changed = db.execute("UPDATE jobs SET state='CANCELLED',updated=? WHERE id=? AND kind='PROMOTE' AND subject=? AND state='PREPARING'",
                                 (control.clock(), operation_id, user["subject"])).rowcount
            if changed != 1:
                raise self.refusal("PROMOTION_OPERATION_CHANGED")
            control.advance(db)
            control.audit(db, user["subject"], "PROMOTION_PREPARATION_CANCELLED_NO_UNFENCE", operation_id)
            return control.job_public(db.execute("SELECT * FROM jobs WHERE id=?", (operation_id,)).fetchone())

    def reconcile(self, user, operation_id, body):
        # A fresh signed observation resolves an UNKNOWN result. This endpoint
        # never queues, repeats or executes the original activation command.
        control = self.control
        with control.transaction() as db:
            control.cas(db, body)
            job = db.execute("SELECT * FROM jobs WHERE id=? AND kind='PROMOTE'", (operation_id,)).fetchone()
            if not job or job["state"] != "UNKNOWN" or not job["lease"]:
                raise self.refusal("PROMOTION_RECONCILIATION_NOT_READY")
            self.require_current_authority(db, job)
            point = json.loads(db.execute("SELECT payload FROM points WHERE id=?", (job["point"],)).fetchone()[0])
            fence = self.verify(body.get("fenceReceipt"), "FENCE", job, point, control.clock())
            activation = self.verify(body.get("activationReceipt"), "ACTIVATION", job, point, control.clock(), job["lease"])
            restored = json.loads(job["proofs"])["restore"]
            if activation["databaseSystemIdentifier"] != restored["databaseSystemIdentifier"] \
                    or activation["restoredLsn"] != restored["restoredLsn"]:
                raise self.refusal("RESTORED_DATABASE_IDENTITY_CHANGED", 403)
            self.consume(db, fence)
            self.consume(db, activation)
            if db.execute("UPDATE authority SET primary_id=?,mode='ACTIVE' WHERE id=1 AND epoch=? AND mode='FENCED'",
                          (job["target"], job["desired_epoch"])).rowcount != 1:
                raise self.refusal("AUTHORITY_EPOCH_UNKNOWN_OR_CHANGED")
            db.execute("UPDATE jobs SET state='SUCCEEDED',evidence=?,updated=? WHERE id=?",
                       (json.dumps({"activationReceiptId": activation["receiptId"], "reconciled": True}), control.clock(), operation_id))
            control.advance(db)
            control.audit(db, user["subject"], "PROMOTION_RESULT_RECONCILED_WITHOUT_REPLAY", operation_id)
            return control.job_public(db.execute("SELECT * FROM jobs WHERE id=?", (operation_id,)).fetchone())

    def complete(self, db, job, body):
        self.require_current_authority(db, job)
        if body.get("success") is not True:
            # Never reopen the old primary or lower the reserved epoch on failure.
            db.execute("UPDATE jobs SET state='FAILED',updated=? WHERE id=?", (self.control.clock(), job["id"]))
            self.control.advance(db)
            self.control.audit(db, job["agent"], "PROMOTION_FAILED_OLD_PRIMARY_REMAINS_FENCED", job["id"])
            return self.control.job_public(db.execute("SELECT * FROM jobs WHERE id=?", (job["id"],)).fetchone())
        point = json.loads(db.execute("SELECT payload FROM points WHERE id=?", (job["point"],)).fetchone()[0])
        proofs = json.loads(job["proofs"])
        self.verify(proofs["fence"], "FENCE", job, point, self.control.clock())
        activation = self.verify(body.get("activationReceipt"), "ACTIVATION", job, point, self.control.clock(), job["lease"])
        if activation["databaseSystemIdentifier"] != proofs["restore"]["databaseSystemIdentifier"] \
                or activation["restoredLsn"] != proofs["restore"]["restoredLsn"]:
            raise self.refusal("RESTORED_DATABASE_IDENTITY_CHANGED", 403)
        self.consume(db, activation)
        changed = db.execute("UPDATE authority SET primary_id=?,mode='ACTIVE' WHERE id=1 AND epoch=? AND mode='FENCED'",
                             (job["target"], job["desired_epoch"])).rowcount
        if changed != 1:
            raise self.refusal("AUTHORITY_EPOCH_UNKNOWN_OR_CHANGED")
        db.execute("UPDATE jobs SET state='SUCCEEDED',evidence=?,updated=? WHERE id=?",
                   (json.dumps({"activationReceiptId": activation["receiptId"], "newEpoch": job["desired_epoch"]}),
                    self.control.clock(), job["id"]))
        self.control.advance(db)
        self.control.audit(db, job["agent"], "PROMOTION_ACTIVATED_WITH_SIGNED_RECEIPT", job["id"])
        return self.control.job_public(db.execute("SELECT * FROM jobs WHERE id=?", (job["id"],)).fetchone())

    def require_current_authority(self, db, job):
        authority = db.execute("SELECT * FROM authority WHERE id=1").fetchone()
        if not authority or authority["mode"] != "FENCED" or authority["epoch"] != job["desired_epoch"] \
                or authority["epoch"] < self.config["minimumEpoch"]:
            raise self.refusal("AUTHORITY_EPOCH_UNKNOWN_OR_CHANGED", 409)
