#!/usr/bin/env python3
"""Read-only source inventory; never connects to a server or database.

The generated references are inspection candidates, not a claim that every
dynamic authorization/SQL path is proved. Runtime values require a separate
approved read-only environment inspection.
"""
import argparse
import functools
import hashlib
import json
import re
from pathlib import Path


@functools.lru_cache(maxsize=None)
def source_lines(path):
    return path.read_text(encoding="utf-8-sig").splitlines()


def references(path, root, pattern):
    return [{"path": path.relative_to(root).as_posix(), "line": number,
             "source": line.strip()}
            for number, line in enumerate(source_lines(path), 1)
            if re.search(pattern, line)]


def build(root):
    java = sorted((root / "server/src/main/java").rglob("*.java"))
    sql = sorted((root / "server/src/main/resources/db/migration").glob("V*.sql"))
    setting_path = root / "server/src/main/java/com/uten/imp/features/admin/systemsetting/SystemSettingKey.java"
    settings = []
    declaration = re.compile(r'^\s+([A-Z][A-Z0-9_]+)\("([^\"]+)", Type\.(\w+), "([^\"]*)", ([^,]+), ([^,]+),')
    for number, line in enumerate(setting_path.read_text(encoding="utf-8-sig").splitlines(), 1):
        found = declaration.match(line)
        if found:
            name, key, kind, default, minimum, maximum = found.groups()
            settings.append({"enum": name, "key": key, "type": kind, "default": default,
                             "min": minimum, "max": maximum, "line": number,
                             "consumers": [ref for file in java if file != setting_path
                                           for ref in references(file, root, rf'SystemSettingKey\.{name}\b')]})
    patterns = {
        "permission_checks": r'@PreAuthorize|@RequiresStepUp|hasAuthority\(|hasAnyAuthority\(|\.requirePermission\(|\.hasPermission\(',
        "write_endpoints": r'@(Post|Put|Patch|Delete)Mapping\b',
        "version_and_claim_guards": r'@Version\b|auth_version|authorization_epoch|expectedVersion|requireVersion|StepClaim|attempts\s*=\s*\?|FOR UPDATE|SKIP LOCKED',
        "audit_writes": r'audit\.log|auditExplicit\(|\.bindActor\(|tx\.bind\(',
        "cleanup_operations": r'\bDELETE FROM\b|\bTRUNCATE\b|Files\.delete|\.deleteBy|\.deleteAll|\.deleteIfExists|\.purgeExpired|\.cleanupAbandoned|@Scheduled',
    }
    inventories = {name: [ref for path in java for ref in references(path, root, pattern)]
                   for name, pattern in patterns.items()}
    audit_registrations = [ref for path in sql for ref in references(path, root, r'fn_audit_track_table\(')]
    inventories["audit_migration_registrations"] = audit_registrations
    inventories["audit_trigger_and_permission_epoch_definitions"] = [ref for path in sql for ref in references(
        path, root, r'CREATE (OR REPLACE )?FUNCTION.*(audit|authorization|permission)|CREATE TRIGGER.*(audit|auth|permission)|auth_version|authorization_epoch')]
    policies = [
        {"id": "audit", "objects": "audit_log, audit_log_archive, audit_retention_evidence",
         "basis": "original created_at; whole-month hot partition move",
         "effective_policy": "SystemSettingKey hot=6 months, archive additional=30 months; V770 expired mixed evidence is recorded and preserved, not destroyed",
         "source": "server/src/main/resources/db/migration/V770__preserve_unclassified_audit_archives.sql",
         "safe_default": "retain original mixed business/security evidence; changing months does not grant destruction"},
        {"id": "ai", "objects": "ai_jobs input_bytes, result, job identity; ai_call_logs",
         "original_evidence_gap": "Phase1 baseline has no automatic original-file capture/formal binding; terminal input_bytes deletion is not archival. V773 source preservation is a separate in-progress subpackage, not yet completed by this receipt.",
         "basis": "pending updated_at; terminal finished_at >= created_at; learning lease and running receipt block expiry",
         "effective_policy": "AiProperties pending=30min, result=48h, row=7d, technical call log=180d; deployment properties, not editable SystemSettingKey values",
         "source": "server/src/main/java/com/uten/imp/features/ai/job/AiJobRepository.java",
         "safe_default": "missing/contradictory completion retained; unexpired template candidate prevents job cascade; technical logs contain no request/response body"},
        {"id": "learning", "objects": "sales_document_learning_receipts request/evidence, layout/template exactly-once evidence",
         "basis": "retry_until (V751 default 30d); executing attempt owns RUNNING state by attempt and startedAt",
         "effective_policy": "expired nonrunning minimal private payload can be stripped in <=1000 locked rows; receipt identity, outcome counts and dedupe evidence retained",
         "source": "server/src/main/java/com/uten/imp/features/sales/learning/SalesLearningReceiptService.java",
         "safe_default": "RUNNING of uncertain liveness remains retained after deadline; no implicit destruction or age-guessed success"},
        {"id": "template", "objects": "temporary sanitized candidates; immutable adopted sanitized template versions and evidence",
         "basis": "candidate expires_at, terminal AI status, retry lease and running receipt",
         "effective_policy": "V745 candidate default 7d; candidate cleanup <=1000 rows; V747 physical outbox only for object not referenced by immutable version",
         "source": "server/src/main/java/com/uten/imp/features/sales/template/SalesQuoteTemplateStore.java",
         "safe_default": "formal template/version/evidence not age-deleted; sanitized generated workbook is distinct from customer originals"},
        {"id": "upload", "objects": "attachment_upload_sessions staging; attachment_object_outbox physical intent",
         "basis": "signed expires_at, SCANNING grace, retryable lookup; late-write verification and attempt-fenced outbox",
         "effective_policy": "StorageProperties presigned default300s, stale processing15min; expiry20/tick, delete20/tick, max1h retry backoff",
         "source": "server/src/main/java/com/uten/imp/features/attachment/AttachmentUploadExpiryScheduler.java",
         "safe_default": "only staging for expired reservations; promoted/formal final objects require explicit separate deletion; unknown provider refuses deletion"},
        {"id": "scratch", "objects": "provider-private object/durability .part files",
         "basis": "last modified older than24h, bounded1000 visited files; provider lease and controlled filenames",
         "effective_policy": "internal provider only, !cloud scheduler hourly",
         "source": "server/src/main/java/com/uten/imp/common/storage/InternalStorageService.java",
         "safe_default": "not a business attachment retention policy"},
        {"id": "notice", "objects": "notices, notice_user_states, acknowledgments, blessings and business delivery identity",
         "basis": "current-user visibility/task completion, explicit interaction",
         "effective_policy": "no automatic age-based physical cleanup; explicit user removal sets deleted_at only, unfinished TODO and account security event blocked",
         "source": "server/src/main/java/com/uten/imp/features/notice/NoticeService.java",
         "safe_default": "retain unread/unfinished/delivery and security evidence; 180d proposal in07 is not an implemented destruction permission"},
        {"id": "session", "objects": "auth_sessions, refresh_tokens, visitor_refresh_tokens, auth_step_up_states; correlated audit sessions",
         "basis": "absolute login lifetime and manual activity idle timeout; revoked/reused tokens remain for detection",
         "effective_policy": "SystemSettingKey refresh default7d, idle30min; no automatic physical age purge. Step-up successful reset clears only transient failure counter and writes explicit audit",
         "source": "server/src/main/java/com/uten/imp/features/auth/AuthSessionService.java",
         "safe_default": "retain invalid/reused/revoked token and login correlation evidence; 30d proposed safety window is not an enabled purge"},
    ]
    inputs = {path.relative_to(root).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
              for path in java + sql}
    return {"format": 1, "scope": "R0.04 source inventory and R4.04 cleanup chain", "mode": "source_only_no_runtime_claim",
            "limitations": ["Dynamic SQL, grants, inherited service authorization and deployment values need their named behavior tests or runtime read-only proof.",
                            "Endpoint/guard/registration lists are exact source references, not proof every endpoint is covered by every mechanism.",
                            "Business-data reset is a separately authorized destructive maintenance path, not ordinary retention; R0.05 owns restore proof.",
                            "R4.01/.02/.03/.05/.06/.07 and the other38 parent steps are not declared implemented by this inventory."],
            "input_sha256": inputs, "counts": {name: len(values) for name, values in inventories.items()},
            "settings": settings, "policies": policies, **inventories}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--check", action="store_true", help="compare only; do not write")
    args = parser.parse_args()
    report = json.dumps(build(args.root.resolve()), ensure_ascii=False, indent=2) + "\n"
    if args.check:
        if not args.output.exists() or args.output.read_text(encoding="utf-8") != report:
            raise SystemExit("inventory differs from current source inputs")
    else:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(report, encoding="utf-8")
    print(json.dumps({"check": args.check, "output": str(args.output), "sha256": hashlib.sha256(report.encode()).hexdigest()}))


if __name__ == "__main__":
    main()
