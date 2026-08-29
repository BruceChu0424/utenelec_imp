#!/usr/bin/env bash
# =====================================================================
# 老库数据引导迁移（不启动 server）
# =====================================================================
# 这些 SQL 会重建目标模块数据，只能用于尚未切流模块的首次导入/演练。
# 已切流模块不得再次运行本脚本；后续追平必须使用另行受审的增量方案，当前尚未交付。
#
# 用法：
#   # 无参数/未知参数只显示帮助并失败，不会执行任何迁移
#   bash server/legacy_migration/migrate.sh --goods      # 只迁货品分类
#   bash server/legacy_migration/migrate.sh --goods-bom  # 只迁货品组装信息（BOM → V79 goods_bom_items）
#   bash server/legacy_migration/migrate.sh --mould      # 只迁模具分类
#   bash server/legacy_migration/migrate.sh --mould-data # 只迁模具主档
#   bash server/legacy_migration/migrate.sh --purchase   # 只迁采购四单据
#   bash server/legacy_migration/migrate.sh --stock-docs # 只迁仓库管理 9 单据 + 台账余额
#   bash server/legacy_migration/migrate.sh --sales      # 只迁销售五单据（报价/订货+BOM/出货/其它出货/退货）
#   bash server/legacy_migration/migrate.sh --subcontract # 只迁委外八单据（询价/申请/订单+BOM/入库/发料/退料/次品退/废料）
#   bash server/legacy_migration/migrate.sh --production # 只迁生产（F_Plan/F_PlanItem/F_PlanCostItem/F_DateReport，依赖 --sales 先迁）
#   bash server/legacy_migration/migrate.sh --finance    # 只迁钱流（账户/付款方式 + AR/AP + 收支/对账）
#   bash server/legacy_migration/migrate.sh --hr-workers # 只迁人事老库（B_Worker 全量试迁，含加密敏感信息）
#   bash server/legacy_migration/migrate.sh --hr-cleanup # 人事清理：只留 admin（正式名录导入前执行）
#   bash server/legacy_migration/migrate.sh --hr-roster  # 只迁 HR 正式名录（职工信息表 141 人，先 build_hr_roster.py）
#   bash server/legacy_migration/migrate.sh --shelf-labels # 只迁货架库位（人工维护 data/shelf_labels.csv → goods.stock_place）
#   bash server/legacy_migration/migrate.sh --goods-owner # 只迁货品归属（外贸按人授权，V85）
#   bash server/legacy_migration/migrate.sh --client-owner # 补客户/供应商归属（业务员 UUID，V261）
#   UTEN_CONFIRM_DESTRUCTIVE_MIGRATION=RESET_uten_imp \
#     bash server/legacy_migration/migrate.sh --bootstrap-all
#
# 当前已实现：货品/模具/客户/供应商（分类+主档）、颜色/单位/币种/仓库主档、采购四单据、
#   仓库管理 9 单据（统一 stock_documents + 台账余额 + 流水）、销售五单据（含 BOM 成本子表）、
#   委外八单据（含 BOM 成本子表）、生产（F_Plan 系列 + 日报）、钱流（账户/付款方式 + AR/AP 总账 +
#   收支/对账）。依赖顺序：主档 -> 采购 -> 仓库 -> 销售 -> 委外 -> 生产 -> 钱流
#   （production 依赖 sales_order_items 已迁，跨模块 FK 映射 sales_order_item_id）。
#   新增模块时在下方加 case + 对应 .sql。
#
# 依赖：docker（PG 容器在跑）。CSV 是老库快照（更新老库数据后重新导出 CSV 即可）。
# =====================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CONTAINER="${PG_CONTAINER:-uten-imp-postgres}"
PG_USER="${PG_USER:-uten}"
PG_DB="${PG_DB:-uten_imp}"
TARGET=""
CONFIRMED=0
FULL_BOOTSTRAP=0
# docker 可执行文件自动探测（Windows git bash 常不在 PATH，可用 DOCKER 环境变量覆盖）
DOCKER="${DOCKER:-$(command -v docker || command -v docker.exe || echo '/c/Program Files/Docker/Docker/resources/bin/docker.exe')}"
LOCK_DIR="/tmp/uten-legacy-migration.lock"
REMOTE_TMP_FILES=()
LOCAL_KEY_FILE=""
RUN_ID=""
EXPORT_MANIFEST_SHA256=""
CHECKSUM_MANIFEST_SHA256=""
MIGRATION_REPOSITORY_COMMIT="unknown"
MIGRATION_SCRIPT_SHA256=""
FLYWAY_CHECKSUM_MANIFEST="${UTEN_FLYWAY_CHECKSUM_MANIFEST:-$HERE/../target/uten-imp-flyway-checksums.tsv}"
FLYWAY_MANIFEST_SHA256=""
FLYWAY_MANIFEST_BYTES=""
EXPECTED_FLYWAY_MIGRATION_COUNT=385
EXPECTED_FLYWAY_HEAD=423
MAPPING_VERSION="bootstrap-v9-v423"

usage () {
    cat <<EOF
用法：
  bash server/legacy_migration/migrate.sh <目标> --confirm-destructive

目标：
  --goods | --goods-data | --goods-bom
  --mould | --mould-data
  --client | --client-data | --client-owner
  --supplier | --supplier-data
  --color-data | --unit-data | --currency-data | --warehouse-data
  --purchase | --stock-docs | --sales | --sales-owner
  --subcontract | --production | --finance | --hr-workers
  --hr-cleanup | --hr-roster
  --shelf-labels（货架库位：人工 CSV，非老库导出）
  --goods-owner
  --bootstrap-all（兼容别名：--all、-a）

安全确认（二选一）：
  1. 第二个参数传 --confirm-destructive
  2. 环境变量 UTEN_CONFIRM_DESTRUCTIVE_MIGRATION=RESET_${PG_DB}

  注意：这些迁移会受控重建目标模块，只能用于首次导入或迁移演练；
        FK、审计触发器和系统主档 UUID 保护始终保持启用。
EOF
}

for arg in "$@"; do
    case "$arg" in
        --help|-h)
            usage
            exit 0
            ;;
        --confirm-destructive)
            CONFIRMED=1
            ;;
        --goods|-g|--goods-data|--goods-owner|--goods-bom|\
        --mould|-m|--mould-data|--client|--client-data|--client-owner|\
        --supplier|--supplier-data|--color-data|--unit-data|--currency-data|\
        --warehouse-data|--purchase|--stock-docs|--sales|--sales-owner|\
        --subcontract|--production|--finance|--hr-workers|\
        --hr-cleanup|--hr-roster|--shelf-labels|\
        --bootstrap-all|--all|-a)
            if [ -n "$TARGET" ]; then
                echo "✗ 一次只能执行一个迁移目标：$TARGET、$arg" >&2
                usage >&2
                exit 64
            fi
            TARGET="$arg"
            ;;
        *)
            echo "✗ 未知参数：$arg；已拒绝执行，未修改数据库。" >&2
            usage >&2
            exit 64
            ;;
    esac
done

if [ -z "$TARGET" ]; then
    echo "✗ 必须显式指定迁移目标；已拒绝执行，未修改数据库。" >&2
    usage >&2
    exit 64
fi

EXPECTED_CONFIRMATION="RESET_${PG_DB}"
if [ "$CONFIRMED" -ne 1 ] && \
   [ "${UTEN_CONFIRM_DESTRUCTIVE_MIGRATION:-}" != "$EXPECTED_CONFIRMATION" ]; then
    echo "✗ 该操作会重建目标模块数据，缺少破坏性操作确认；未修改数据库。" >&2
    echo "  请传 --confirm-destructive，或设置 UTEN_CONFIRM_DESTRUCTIVE_MIGRATION=$EXPECTED_CONFIRMATION" >&2
    exit 65
fi

finish_run () {
    local exit_code=$?
    set +e

    if [ -n "$LOCAL_KEY_FILE" ]; then
        rm -f "$LOCAL_KEY_FILE"
    fi
    if [ "${#REMOTE_TMP_FILES[@]}" -gt 0 ]; then
        "$DOCKER" exec "$CONTAINER" rm -f "${REMOTE_TMP_FILES[@]}" >/dev/null 2>&1
    fi
    "$DOCKER" exec "$CONTAINER" rm -f /tmp/_uten_keys.sql >/dev/null 2>&1

    if [ -n "$RUN_ID" ]; then
        "$DOCKER" exec -i "$CONTAINER" psql -U "$PG_USER" -d "$PG_DB" \
            -v ON_ERROR_STOP=1 \
            -c "UPDATE legacy_migration_runs
                SET status = CASE
                        WHEN $exit_code = 0 AND NOT EXISTS (
                            SELECT 1
                            FROM legacy_migration_reconciliation_items
                            WHERE run_id = '$RUN_ID'::uuid
                              AND passed = FALSE
                        ) THEN 'SUCCESS'
                        ELSE 'FAILED'
                    END,
                    finished_at = CURRENT_TIMESTAMP,
                    exit_code = $exit_code,
                    rejected_count = (
                        SELECT COUNT(*)
                        FROM legacy_migration_rejects
                        WHERE run_id = '$RUN_ID'::uuid
                    ),
                    reconciliation_status = CASE
                        WHEN EXISTS (
                            SELECT 1
                            FROM legacy_migration_reconciliation_items
                            WHERE run_id = '$RUN_ID'::uuid
                              AND passed = FALSE
                        ) THEN 'FAILED'
                        WHEN EXISTS (
                            SELECT 1
                            FROM legacy_migration_reconciliation_items
                            WHERE run_id = '$RUN_ID'::uuid
                        ) THEN 'PASSED'
                        ELSE 'NOT_RUN'
                    END,
                    reconciliation_summary = jsonb_build_object(
                        'automatedCheckCount', (
                            SELECT COUNT(*)
                            FROM legacy_migration_reconciliation_items
                            WHERE run_id = '$RUN_ID'::uuid
                        ),
                        'failedAutomatedCheckCount', (
                            SELECT COUNT(*)
                            FROM legacy_migration_reconciliation_items
                            WHERE run_id = '$RUN_ID'::uuid
                              AND passed = FALSE
                        ),
                        'structuralChecksOnly', TRUE,
                        'sourceTargetBusinessReconciliationRequired', TRUE,
                        'productionAcceptance', FALSE
                    )
                WHERE run_id = '$RUN_ID'::uuid" >/dev/null 2>&1
    fi

    "$DOCKER" exec "$CONTAINER" rmdir "$LOCK_DIR" >/dev/null 2>&1
    exit "$exit_code"
}
trap finish_run EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

verify_full_bootstrap_export () {
    case "$TARGET" in
        --hr-cleanup|--hr-roster|--shelf-labels) return ;;
        *) ;;
    esac

    if ! command -v python3 >/dev/null 2>&1; then
        echo "✗ 缺少 python3，无法严格验证完整导出清单；已拒绝全量迁移。" >&2
        exit 69
    fi

    if ! python3 -I - \
        "$HERE/data/export_manifest.json" \
        "$HERE/data/export_manifest.sha256" \
        "$HERE/export_legacy.ps1" \
        "$MIGRATION_REPOSITORY_COMMIT" <<'PY'
import csv
import datetime as dt
import hashlib
import json
import pathlib
import re
import sys

manifest_path = pathlib.Path(sys.argv[1])
checksum_path = pathlib.Path(sys.argv[2])
exporter_path = pathlib.Path(sys.argv[3])
current_repository_commit = sys.argv[4]
data_dir = manifest_path.parent

manifest = json.loads(manifest_path.read_text(encoding="utf-8-sig"))
required_manifest_keys = {
    "formatVersion", "target", "exportedAtUtc", "sourceAuthorityId",
    "consistency", "offlineBackupRequired", "sourceBackupSha256",
    "approvalReference", "repositoryCommit",
    "exportScriptSha256", "checksumManifestSha256", "files",
}
if set(manifest) != required_manifest_keys:
    raise ValueError("export manifest has missing or unknown top-level fields")
if manifest["formatVersion"] != 3 or manifest["target"] != "All":
    raise ValueError("legacy import requires one formatVersion=3 target=All export")
if manifest["consistency"] != "serializable-read-transaction":
    raise ValueError("export was not captured in one serializable read transaction")
if manifest["offlineBackupRequired"] is not True:
    raise ValueError("offline source backup is not mandatory in the export authority")
if not isinstance(manifest["sourceAuthorityId"], str) or not re.fullmatch(
        r"[A-Za-z0-9][A-Za-z0-9._:-]{2,127}", manifest["sourceAuthorityId"]):
    raise ValueError("sourceAuthorityId is missing or invalid")
if not isinstance(manifest["sourceBackupSha256"], str) or not re.fullmatch(
        r"[0-9a-f]{64}", manifest["sourceBackupSha256"]):
    raise ValueError("reviewed offline source backup digest is missing")
if not isinstance(manifest["approvalReference"], str) or not re.fullmatch(
        r"[A-Za-z0-9][A-Za-z0-9._:-]{2,127}", manifest["approvalReference"]):
    raise ValueError("export approval reference is missing or invalid")
if not re.fullmatch(r"[0-9a-fA-F]{40}|[0-9a-fA-F]{64}", manifest["repositoryCommit"]):
    raise ValueError("export repository commit is not a reviewed Git object id")
if manifest["repositoryCommit"].lower() != current_repository_commit:
    raise ValueError("export repository commit does not match the importer candidate")
exported_at = dt.datetime.fromisoformat(manifest["exportedAtUtc"].replace("Z", "+00:00"))
if exported_at.tzinfo is None or exported_at.utcoffset() != dt.timedelta(0):
    raise ValueError("exportedAtUtc is not an explicit UTC timestamp")

exporter_bytes = exporter_path.read_bytes()
exporter_sha = hashlib.sha256(exporter_bytes).hexdigest()
if manifest["exportScriptSha256"].lower() != exporter_sha:
    raise ValueError("export was not produced by the current reviewed exporter bytes")

exporter_text = exporter_bytes.decode("utf-8-sig")
expected_files = set(re.findall(
    r"Join-Path\s+\$dataDir\s+'([A-Za-z0-9][A-Za-z0-9_.-]*[.]csv)'",
    exporter_text,
))
if not expected_files:
    raise ValueError("reviewed exporter has no discoverable CSV inventory")

checksum_bytes = checksum_path.read_bytes()
if manifest["checksumManifestSha256"].lower() != hashlib.sha256(checksum_bytes).hexdigest():
    raise ValueError("JSON manifest and checksum sidecar are not the same export")
checksums = {}
for raw_line in checksum_bytes.decode("ascii").splitlines():
    match = re.fullmatch(r"([0-9a-f]{64}) \*([A-Za-z0-9][A-Za-z0-9_.-]*[.]csv)", raw_line)
    if match is None or match.group(2) in checksums:
        raise ValueError("checksum sidecar has an invalid or duplicate row")
    checksums[match.group(2)] = match.group(1)
if set(checksums) != expected_files:
    raise ValueError("checksum sidecar is not the exact target=All CSV inventory")

records = manifest["files"]
if not isinstance(records, list):
    raise ValueError("manifest files is not an array")
by_name = {}
for record in records:
    if not isinstance(record, dict) or set(record) != {"file", "rows", "bytes", "sha256"}:
        raise ValueError("manifest file record has missing or unknown fields")
    name = record["file"]
    if not isinstance(name, str) or not re.fullmatch(
            r"[A-Za-z0-9][A-Za-z0-9_.-]*[.]csv", name) or name in by_name:
        raise ValueError("manifest has an invalid or duplicate file name")
    if not isinstance(record["rows"], int) or record["rows"] < 0:
        raise ValueError("manifest row count is invalid")
    if not isinstance(record["bytes"], int) or record["bytes"] <= 0:
        raise ValueError("manifest byte count is invalid")
    if not isinstance(record["sha256"], str) or not re.fullmatch(
            r"[0-9a-f]{64}", record["sha256"]):
        raise ValueError("manifest file digest is invalid")
    by_name[name] = record
if set(by_name) != expected_files:
    raise ValueError("JSON manifest is not the exact target=All CSV inventory")

for name in sorted(expected_files):
    path = data_dir / name
    record = by_name[name]
    if not path.is_file() or path.is_symlink():
        raise ValueError(f"missing or non-regular export file: {name}")
    if path.stat().st_size != record["bytes"]:
        raise ValueError(f"export byte count drift: {name}")
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    actual_sha = digest.hexdigest()
    if actual_sha != record["sha256"] or actual_sha != checksums[name]:
        raise ValueError(f"export digest drift: {name}")
    with path.open("r", encoding="utf-8-sig", newline="") as source:
        rows = csv.reader(source, delimiter="|")
        try:
            header = next(rows)
        except StopIteration as error:
            raise ValueError(f"export has no header: {name}") from error
        if not header or any(not column for column in header):
            raise ValueError(f"export has an invalid header: {name}")
        actual_rows = sum(1 for _ in rows)
    if actual_rows != record["rows"]:
        raise ValueError(f"export row count drift: {name}")
PY
    then
        echo "✗ 完整导出 JSON、checksum 或 CSV inventory/rows/bytes/digest 校验失败；迁移尚未写库。" >&2
        exit 66
    fi
}

record_run_file () {
    local source_path="$1"
    local audit_name="$2"
    if [[ ! "$audit_name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] \
        || [ ! -f "$source_path" ] || [ -L "$source_path" ]; then
        echo "✗ 迁移运行文件非法或不是普通文件：$audit_name" >&2
        exit 66
    fi

    local before_state after_state
    before_state=$(stat -c '%d:%i:%f:%u:%g:%h:%s:%Y:%Z' -- "$source_path")
    RECORDED_FILE_SHA256=$(sha256sum "$source_path" | awk '{print tolower($1)}')
    RECORDED_FILE_BYTES=$(wc -c < "$source_path" | tr -d '[:space:]')
    after_state=$(stat -c '%d:%i:%f:%u:%g:%h:%s:%Y:%Z' -- "$source_path")
    if [ "$before_state" != "$after_state" ] \
        || [[ ! "$RECORDED_FILE_SHA256" =~ ^[0-9a-f]{64}$ ]] \
        || [[ ! "$RECORDED_FILE_BYTES" =~ ^[1-9][0-9]*$ ]]; then
        echo "✗ 迁移运行文件在校验期间漂移：$audit_name" >&2
        exit 74
    fi

    "$DOCKER" exec "$CONTAINER" psql -U "$PG_USER" -d "$PG_DB" \
        -v ON_ERROR_STOP=1 \
        -c "INSERT INTO legacy_migration_run_files(run_id, file_name, sha256, byte_size)
            VALUES (
                '$RUN_ID'::uuid,
                '$audit_name',
                '$RECORDED_FILE_SHA256',
                $RECORDED_FILE_BYTES
            )" >/dev/null
}

preflight () {
    echo "→ 预检 Docker、数据库、迁移版本与并发锁..."
    local export_manifest="$HERE/data/export_manifest.json"
    local checksum_manifest="$HERE/data/export_manifest.sha256"
    if [ ! -s "$FLYWAY_CHECKSUM_MANIFEST" ]; then
        echo "✗ 缺少当前候选的 Flyway checksum manifest：$FLYWAY_CHECKSUM_MANIFEST" >&2
        echo "  必须先用 FlywayChecksumManifestExporterTest 生成受审清单；禁止只按 head 猜测。" >&2
        exit 66
    fi
    if ! awk -F '\t' -v expected_count="$EXPECTED_FLYWAY_MIGRATION_COUNT" \
        -v expected_head="$EXPECTED_FLYWAY_HEAD" '
            NR == 1 {
                if ($0 != "# uten-imp-flyway-checksums-v1") exit 1
                next
            }
            NF != 3 || $1 !~ /^[0-9]+$/ ||
                $2 !~ /^V[0-9]+__[A-Za-z0-9_]+[.]sql$/ ||
                $3 !~ /^-?[0-9]+$/ { exit 1 }
            {
                count++
                if (($1 + 0) > head) head = $1 + 0
                if (seen[$1]++) exit 1
            }
            END {
                if (count != expected_count || head != expected_head) exit 1
            }
        ' "$FLYWAY_CHECKSUM_MANIFEST"; then
        echo "✗ Flyway checksum manifest 结构、数量或 head 非法；已拒绝迁移。" >&2
        exit 66
    fi
    FLYWAY_MANIFEST_SHA256=$(sha256sum "$FLYWAY_CHECKSUM_MANIFEST" | awk '{print tolower($1)}')
    FLYWAY_MANIFEST_BYTES=$(wc -c < "$FLYWAY_CHECKSUM_MANIFEST" | tr -d '[:space:]')
    # HR 清理/正式名录、货架库位不依赖老库导出快照：HR 输入来自 build_hr_roster.py 生成的
    # data/hr_roster.csv + hr_managers.csv；货架库位来自人工维护的 data/shelf_labels.csv，
    # 其 sha256 由 copy_shelf_csv 现算并直接登记进 legacy_migration_run_files。
    # export_manifest.json 不存在时仅跳过老库交叉校验。
    local legacy_export_free=0
    case "$TARGET" in
        --hr-cleanup|--hr-roster|--shelf-labels) legacy_export_free=1 ;;
    esac
    if [ ! -s "$export_manifest" ] || [ ! -s "$checksum_manifest" ]; then
        if [ "$legacy_export_free" -eq 1 ] && [ -s "$checksum_manifest" ]; then
            echo "→ HR 名录流程：无老库导出清单，改用 build_hr_roster.py 登记的 sha256 校验。"
        else
            echo "✗ 缺少完整导出清单，请先用 export_legacy.ps1 重新导出一致性快照。" >&2
            exit 66
        fi
    fi
    if ! command -v sha256sum >/dev/null 2>&1; then
        echo "✗ 缺少 sha256sum，无法校验迁移输入。" >&2
        exit 69
    fi

    if [ -s "$export_manifest" ]; then
        EXPORT_MANIFEST_SHA256=$(sha256sum "$export_manifest" | awk '{print tolower($1)}')
    else
        # 审计表要求 64-hex：用 sha256('na-hr-roster-flow') 作占位，语义见上方注释
        EXPORT_MANIFEST_SHA256="44029600705801d0aa5663674ba5a5cdc5f6943f1d9ab6e80356f649c6e82181"
    fi
    CHECKSUM_MANIFEST_SHA256=$(sha256sum "$checksum_manifest" | awk '{print tolower($1)}')
    if [ -s "$export_manifest" ]; then
        local declared_checksum_hash
        declared_checksum_hash=$(
            grep -m1 '"checksumManifestSha256"' "$export_manifest" \
                | sed 's/.*:[[:space:]]*"\([0-9A-Fa-f]*\)".*/\1/' \
                | tr 'A-F' 'a-f'
        )
        if [[ ! "$declared_checksum_hash" =~ ^[0-9a-f]{64}$ ]] \
            || [ "$declared_checksum_hash" != "$CHECKSUM_MANIFEST_SHA256" ]; then
            echo "✗ export_manifest.json 与 export_manifest.sha256 不属于同一次导出；已拒绝迁移。" >&2
            exit 66
        fi
    fi
    if ! command -v git >/dev/null 2>&1; then
        echo "✗ 缺少 Git，无法把导出快照绑定到受审迁移候选。" >&2
        exit 69
    fi
    local repository_commit scoped_status
    repository_commit=$(git -C "$HERE/../.." rev-parse HEAD 2>/dev/null || true)
    if [[ ! "$repository_commit" =~ ^[0-9A-Fa-f]{40,64}$ ]]; then
        echo "✗ 当前迁移候选不是可验证的 Git 提交。" >&2
        exit 66
    fi
    MIGRATION_REPOSITORY_COMMIT=$(printf '%s' "$repository_commit" | tr 'A-F' 'a-f')
    scoped_status=$(git -C "$HERE/../.." status --porcelain=v1 --untracked-files=all -- \
        server/legacy_migration/export_legacy.ps1 \
        server/legacy_migration/migrate.sh \
        ':(glob)server/legacy_migration/migrate_*.sql' \
        server/src/main/resources/db/migration)
    if [ -n "$scoped_status" ]; then
        echo "✗ 导出器、导入器或 Flyway 字节尚未提交；已拒绝迁移。" >&2
        exit 66
    fi

    MIGRATION_SCRIPT_SHA256=$(sha256sum "$HERE/migrate.sh" | awk '{print tolower($1)}')
    verify_full_bootstrap_export

    "$DOCKER" version >/dev/null
    [ "$("$DOCKER" inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" = "true" ] || {
        echo "✗ PostgreSQL 容器未运行：$CONTAINER" >&2
        exit 69
    }
    "$DOCKER" exec "$CONTAINER" psql -U "$PG_USER" -d "$PG_DB" \
        -v ON_ERROR_STOP=1 -Atqc "SELECT 1" >/dev/null
    local flyway_state
    flyway_state=$("$DOCKER" exec "$CONTAINER" psql -U "$PG_USER" -d "$PG_DB" \
        -v ON_ERROR_STOP=1 -AtF '|' -c \
        "SELECT COUNT(*),
                COUNT(*) FILTER (WHERE success),
                COUNT(DISTINCT version),
                COALESCE(MAX(version::integer), 0)
         FROM flyway_schema_history
         WHERE version IS NOT NULL")
    if [ "$flyway_state" != \
        "$EXPECTED_FLYWAY_MIGRATION_COUNT|$EXPECTED_FLYWAY_MIGRATION_COUNT|$EXPECTED_FLYWAY_MIGRATION_COUNT|$EXPECTED_FLYWAY_HEAD" ]; then
        echo "✗ 目标库 Flyway 数量、成功状态、唯一版本或 head 与当前候选不一致；已拒绝迁移。" >&2
        exit 69
    fi
    if ! cmp -s \
        <(tail -n +2 "$FLYWAY_CHECKSUM_MANIFEST") \
        <("$DOCKER" exec "$CONTAINER" psql -U "$PG_USER" -d "$PG_DB" \
            -v ON_ERROR_STOP=1 -AtF $'\t' -c \
            "SELECT version, script, checksum
             FROM flyway_schema_history
             WHERE version IS NOT NULL
             ORDER BY installed_rank"); then
        echo "✗ 目标库逐行 Flyway history 与当前候选 checksum manifest 不一致；已拒绝迁移。" >&2
        exit 69
    fi
    [ "$("$DOCKER" exec "$CONTAINER" psql -U "$PG_USER" -d "$PG_DB" \
        -Atqc "SELECT to_regclass('public.legacy_migration_run_files') IS NOT NULL
               AND EXISTS (
                   SELECT 1
                   FROM information_schema.columns
                   WHERE table_schema = 'public'
                     AND table_name = 'legacy_migration_runs'
                     AND column_name = 'export_manifest_sha256'
               )")" = "t" ] || {
        echo "✗ 数据库未应用最新迁移追溯结构，请先启动 server 完成 Flyway。" >&2
        exit 69
    }
    "$DOCKER" exec "$CONTAINER" mkdir "$LOCK_DIR" 2>/dev/null || {
        echo "✗ 已有迁移正在运行（锁：$LOCK_DIR）；已拒绝并发执行。" >&2
        exit 75
    }
    RUN_ID=$("$DOCKER" exec "$CONTAINER" psql -U "$PG_USER" -d "$PG_DB" \
        -v ON_ERROR_STOP=1 -Atqc \
        "INSERT INTO legacy_migration_runs(
             target,
             status,
             migration_mode,
             export_manifest_sha256,
             checksum_manifest_sha256,
             migration_repository_commit,
             migration_script_sha256,
             mapping_version
         )
         VALUES (
             '$TARGET',
             'RUNNING',
             'BOOTSTRAP',
             '$EXPORT_MANIFEST_SHA256',
             '$CHECKSUM_MANIFEST_SHA256',
             '$MIGRATION_REPOSITORY_COMMIT',
             '$MIGRATION_SCRIPT_SHA256',
             '$MAPPING_VERSION'
         )
         RETURNING run_id")
    "$DOCKER" exec -i "$CONTAINER" psql -U "$PG_USER" -d "$PG_DB" \
        -v ON_ERROR_STOP=1 \
        -c "INSERT INTO legacy_migration_run_files(run_id, file_name, sha256, byte_size)
            VALUES (
                '$RUN_ID'::uuid,
                'uten-imp-flyway-checksums.tsv',
                '$FLYWAY_MANIFEST_SHA256',
                $FLYWAY_MANIFEST_BYTES
            )" >/dev/null
    record_run_file "$HERE/migrate.sh" "migrate.sh"
    record_run_file "$HERE/export_legacy.ps1" "export_legacy.ps1"
    record_run_file "$checksum_manifest" "export_manifest.sha256"
    if [ -s "$export_manifest" ]; then
        record_run_file "$export_manifest" "export_manifest.json"
    fi
}

run_sql () {  # $1 = sql 文件名（HERE 下）
    record_run_file "$HERE/$1" "$1"
    local verified_sha="$RECORDED_FILE_SHA256"
    local verified_bytes="$RECORDED_FILE_BYTES"
    "$DOCKER" exec -i "$CONTAINER" psql -U "$PG_USER" -d "$PG_DB" -v ON_ERROR_STOP=1 < "$HERE/$1"
    if [ "$(sha256sum "$HERE/$1" | awk '{print tolower($1)}')" != "$verified_sha" ] \
        || [ "$(wc -c < "$HERE/$1" | tr -d '[:space:]')" != "$verified_bytes" ]; then
        echo "✗ 迁移 SQL 在执行期间漂移：$1" >&2
        exit 74
    fi
}

reconcile_full_bootstrap () {
    local expectation_output
    local expectations=()
    expectation_output=$(python3 -I - "$HERE/data/export_manifest.json" <<'PY'
import json
import pathlib
import sys

manifest = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8-sig"))
records = {record["file"]: record["rows"] for record in manifest["files"]}
required = [
    "goods_categories.csv",
    "mould_categories.csv",
    "client_categories.csv",
    "supplier_categories.csv",
    "color.csv",
    "unit.csv",
    "currency.csv",
    "warehouse.csv",
    "mould.csv",
    "client.csv",
    "supplier.csv",
    "goods.csv",
]
if any(name not in records for name in required):
    raise ValueError("full export manifest is missing a core reconciliation source")
for name in required:
    print(records[name])
print(len(records))
PY
    ) || {
        echo "✗ 无法从受审导出清单读取全量对账基线。" >&2
        exit 66
    }
    mapfile -t expectations <<< "$expectation_output"
    if [ "${#expectations[@]}" -ne 13 ]; then
        echo "✗ 全量对账基线字段数量非法。" >&2
        exit 66
    fi
    for expected_value in "${expectations[@]}"; do
        if [[ ! "$expected_value" =~ ^[0-9]+$ ]]; then
            echo "✗ 全量对账基线包含非法行数。" >&2
            exit 66
        fi
    done

    record_run_file "$HERE/migrate_reconciliation.sql" "migrate_reconciliation.sql"
    local verified_sha="$RECORDED_FILE_SHA256"
    local verified_bytes="$RECORDED_FILE_BYTES"
    "$DOCKER" exec -i "$CONTAINER" psql -U "$PG_USER" -d "$PG_DB" \
        -v ON_ERROR_STOP=1 \
        -v run_id="$RUN_ID" \
        -v expected_material_categories="${expectations[0]}" \
        -v expected_mould_categories="${expectations[1]}" \
        -v expected_client_categories="${expectations[2]}" \
        -v expected_supplier_categories="${expectations[3]}" \
        -v expected_colors="${expectations[4]}" \
        -v expected_units="${expectations[5]}" \
        -v expected_currencies="${expectations[6]}" \
        -v expected_warehouses="${expectations[7]}" \
        -v expected_moulds="${expectations[8]}" \
        -v expected_clients="${expectations[9]}" \
        -v expected_suppliers="${expectations[10]}" \
        -v expected_goods="${expectations[11]}" \
        -v expected_csv_files="${expectations[12]}" \
        < "$HERE/migrate_reconciliation.sql"
    if [ "$(sha256sum "$HERE/migrate_reconciliation.sql" | awk '{print tolower($1)}')" != "$verified_sha" ] \
        || [ "$(wc -c < "$HERE/migrate_reconciliation.sql" | tr -d '[:space:]')" != "$verified_bytes" ]; then
        echo "✗ 全量对账 SQL 在执行期间漂移。" >&2
        exit 74
    fi

    local reconciliation_state
    reconciliation_state=$("$DOCKER" exec "$CONTAINER" psql -U "$PG_USER" -d "$PG_DB" \
        -v ON_ERROR_STOP=1 -Atqc \
        "SELECT count(*) || '|' || count(*) FILTER (WHERE passed = FALSE)
         FROM legacy_migration_reconciliation_items
         WHERE run_id = '$RUN_ID'::uuid")
    if [ "$reconciliation_state" != "20|0" ]; then
        echo "✗ 全量结构化对账失败（检查状态：$reconciliation_state）；已拒绝形成切换候选。" >&2
        exit 78
    fi
}

copy_csv () {  # $1 = csv 文件名（HERE/data 下）；按校验后的原始字节导入
    if [ ! -s "$HERE/data/$1" ]; then
        echo "✗ CSV 不存在或为空：$HERE/data/$1" >&2
        exit 66
    fi
    local checksum_manifest="$HERE/data/export_manifest.sha256"
    if [ ! -s "$checksum_manifest" ]; then
        echo "✗ 缺少 export_manifest.sha256，请先用 export_legacy.ps1 重新导出一致性快照。" >&2
        exit 66
    fi
    local checksum_line
    checksum_line=$(grep -F " *$1" "$checksum_manifest" || true)
    if [ -z "$checksum_line" ]; then
        echo "✗ 导出指纹不包含 $1，请按本次目标重新导出。" >&2
        exit 66
    fi
    if ! (cd "$HERE/data" && printf '%s\n' "$checksum_line" | sha256sum -c - >/dev/null); then
        echo "✗ CSV 校验和不匹配：$1；已拒绝迁移。" >&2
        exit 66
    fi
    local verified_sha
    local file_bytes
    verified_sha=$(printf '%s' "$checksum_line" | awk '{print tolower($1)}')
    file_bytes=$(wc -c < "$HERE/data/$1" | tr -d '[:space:]')
    if [[ ! "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] \
        || [[ ! "$verified_sha" =~ ^[0-9a-f]{64}$ ]] \
        || [[ ! "$file_bytes" =~ ^[1-9][0-9]*$ ]]; then
        echo "✗ CSV 审计元数据非法：$1；已拒绝迁移。" >&2
        exit 66
    fi
    "$DOCKER" cp "$HERE/data/$1" "$CONTAINER:/tmp/$1"
    REMOTE_TMP_FILES+=("/tmp/$1")
    "$DOCKER" exec "$CONTAINER" psql -U "$PG_USER" -d "$PG_DB" \
        -v ON_ERROR_STOP=1 \
        -c "INSERT INTO legacy_migration_run_files(run_id, file_name, sha256, byte_size)
            VALUES ('$RUN_ID'::uuid, '$1', '$verified_sha', $file_bytes)
            ON CONFLICT (run_id, file_name) DO NOTHING" >/dev/null
}

migrate_goods () {
    echo "→ [货品分类] 复制 CSV..."
    copy_csv goods_categories.csv
    echo "→ [货品分类] 执行迁移 SQL..."
    run_sql migrate_goods.sql
}

migrate_goods_data () {
    echo "→ [货品主档] 复制 CSV..."
    copy_csv goods.csv
    echo "→ [货品主档] 执行迁移 SQL..."
    run_sql migrate_goods_data.sql
}

# 货品组装信息（BOM）：B_BomItem → goods_bom_items（V79）。
# 依赖：--goods-data 先迁（goods.legacy_id 映射父/组件）；孤儿行（父或组件货品不存在）跳过。
migrate_goods_bom () {
    echo "→ [货品组装BOM] 复制 CSV..."
    copy_csv goods_bom.csv
    echo "→ [货品组装BOM] 执行迁移 SQL..."
    run_sql migrate_goods_bom.sql
}

migrate_mould () {
    echo "→ [模具分类] 复制 CSV..."
    copy_csv mould_categories.csv
    echo "→ [模具分类] 执行迁移 SQL..."
    run_sql migrate_mould.sql
}

migrate_mould_data () {
    echo "→ [模具主档] 复制 CSV..."
    copy_csv mould.csv
    echo "→ [模具主档] 执行迁移 SQL..."
    run_sql migrate_mould_data.sql
}

migrate_client () {
    echo "→ [客户分类] 复制 CSV..."
    copy_csv client_categories.csv
    echo "→ [客户分类] 执行迁移 SQL..."
    run_sql migrate_client.sql
}

migrate_client_data () {
    echo "→ [客户主档] 复制 CSV..."
    copy_csv client.csv
    echo "→ [客户主档] 执行迁移 SQL..."
    run_sql migrate_client_data.sql
}

migrate_supplier () {
    echo "→ [供应商分类] 复制 CSV..."
    copy_csv supplier_categories.csv
    echo "→ [供应商分类] 执行迁移 SQL..."
    run_sql migrate_supplier.sql
}

migrate_supplier_data () {
    echo "→ [供应商主档] 复制 CSV..."
    copy_csv supplier.csv
    echo "→ [供应商主档] 执行迁移 SQL..."
    run_sql migrate_supplier_data.sql
}

migrate_color_data () {
    echo "→ [颜色主档] 复制 CSV..."
    copy_csv color.csv
    echo "→ [颜色主档] 执行迁移 SQL..."
    run_sql migrate_color.sql
}

migrate_unit_data () {
    echo "→ [基本单位主档] 复制 CSV..."
    copy_csv unit.csv
    echo "→ [基本单位主档] 执行迁移 SQL..."
    run_sql migrate_unit.sql
}

migrate_currency_data () {
    echo "→ [币种主档] 复制 CSV..."
    copy_csv currency.csv
    echo "→ [币种主档] 执行迁移 SQL..."
    run_sql migrate_currency.sql
}

migrate_warehouse_data () {
    echo "→ [仓库主档] 复制 CSV..."
    copy_csv warehouse.csv
    echo "→ [仓库主档] 执行迁移 SQL..."
    run_sql migrate_warehouse.sql
}

migrate_purchase () {
    echo "→ [采购四单据] 复制 CSV（11 个：8 单据 + 人员/部门参考）..."
    for f in purchase_applications purchase_application_items \
             purchase_orders purchase_order_items \
             purchase_receipts purchase_receipt_items \
             purchase_returns purchase_return_items \
             legacy_workers_ref legacy_operators_ref legacy_departments; do
        copy_csv "$f.csv"
    done
    echo "→ [采购四单据] 执行迁移 SQL..."
    run_sql migrate_purchase.sql
}

# 仓库管理 9 单据（统一 stock_documents）+ StockGoods 台账余额 + 仓库流水回填。
# 依赖：主档（goods/colors/units/suppliers/clients/warehouses）+ 采购已迁（采购单据可选，
#   本脚本独立清/建 stock_documents + stock_balances，与采购表无外键耦合）。
migrate_stock_docs () {
    echo "→ [仓库单据] 复制 CSV（19 个：8 单据主/明 + StockGoods + B_Worker/Sys_Operator 参考）..."
    for f in stock_transfer_m stock_transfer_i \
             stock_other_in_m stock_other_in_i \
             stock_other_out_m stock_other_out_i \
             stock_draw_m stock_draw_i \
             stock_wdraw_m stock_wdraw_i \
             stock_finished_in_m stock_finished_in_i \
             stock_finished_out_m stock_finished_out_i \
             stock_check_m stock_check_i \
             stock_goods \
             legacy_workers legacy_operators_ref; do
        copy_csv "$f.csv"
    done
    echo "→ [仓库单据] 执行迁移 SQL（统一表 + 余额 + 流水 + 人员补录）..."
    run_sql migrate_stock_docs.sql
}

# 销售五单据：报价 / 订货(+BOM 成本) / 出货 / 其它出货 / 退货（11 张表，含明细 + BOM 子表）。
# 依赖：主档（goods/colors/units/warehouses/currencies/clients）已迁。
# 受控重建：在外键和审计触发器始终生效时，按从属到主表顺序 DELETE 后导入。
migrate_sales () {
    echo "→ [销售五单据] 复制 CSV（11 个）..."
    for f in sales_quotes sales_quote_items \
             sales_orders sales_order_items sales_order_cost_items \
             sales_shipments sales_shipment_items \
             sales_other_shipments sales_other_shipment_items \
             sales_returns sales_return_items; do
        copy_csv "$f.csv"
    done
    echo "→ [销售五单据] 执行迁移 SQL..."
    run_sql migrate_sales.sql
}

# 委外（outsourcing）八单据：询价 / 申请 / 订单(+BOM) / 入库 / 发料 / 退料 / 次品退 / 废料
#   （17 张表 = 8 main + 8 item + 1 BOM cost）。
# 依赖：主档已迁；与采购/仓库无 FK 耦合（仅 stock_movements 类型命名空间共享）。
migrate_subcontract () {
    echo "→ [委外八单据] 复制 CSV（17 个）..."
    for f in subcontract_ask_m subcontract_ask_i \
             subcontract_application_m subcontract_application_i \
             subcontract_order_m subcontract_order_i subcontract_order_cost_i \
             subcontract_in_m subcontract_in_i \
             subcontract_sout_m subcontract_sout_i \
             subcontract_withdraw_m subcontract_withdraw_i \
             subcontract_swithdraw_m subcontract_swithdraw_i \
             subcontract_swaste_m subcontract_swaste_i; do
        copy_csv "$f.csv"
    done
    echo "→ [委外八单据] 执行迁移 SQL..."
    run_sql migrate_subcontract.sql
}

# 生产模块：F_Plan / F_PlanItem / F_PlanCostItem / F_DateReport / F_DateReportItem。
# 依赖：主档 + V51 sales_order_items / sales_order_cost_items（销售必须先迁，
#   跨模块 FK 映射 sales_order_item_id；F_PlanItem.S_OrderID 经 legacy_id 子查询映射）。
# production_plan_costs 按年度分区（13 个 + DEFAULT 兜底）；受控 DELETE 覆盖父表及其分区。
migrate_production () {
    echo "→ [生产模块] 复制 CSV（5 个）..."
    for f in production_plans production_plan_items production_plan_costs \
             production_daily_reports production_daily_report_items; do
        copy_csv "$f.csv"
    done
    echo "→ [生产模块] 执行迁移 SQL..."
    run_sql migrate_production.sql
}

# 钱流模块：账户（accounts）+ 付款方式（payment_styles）+ AR/AP 总账（ar_ap_ledger，
#   M_in/M_out 双向）+ 收支单据（finance_receipts/payments/expenses/other_incomes）
#   + 对账（finance_reconciliations）。M_Bank legacy 0 行，结构在 V57 已建，本期不迁。
# 依赖：主档（clients/suppliers/currencies）已迁；与销售/采购/委外独立（按 BillNo 前缀溯源）。
migrate_finance () {
    echo "→ [钱流模块] 复制 CSV（含 RecStyle 独立收付款方式字典）..."
    for f in recstyle m_acc m_style m_in m_out m_get m_paid \
             m_dpaid m_dpaid_item m_oget m_oget_item m_allcheck \
             legacy_workers; do
        copy_csv "$f.csv"
    done
    echo "→ [钱流模块] 执行迁移 SQL（含 B_Worker→employees stub + 刷 finance_ar_ap_mv）..."
    run_sql migrate_finance.sql
}

# 人事老库（B_Worker 72 人全量试迁）：employees 主档 + Emp_Style 职位建档 +
#   身份证/手机 pgcrypto+HMAC 敏感信息。只动 LEGACY-W-* stub，HR 真员工不覆盖；幂等重跑。
# 密钥注入：从 server/.env 读 UTEN_PGP_MASTER_KEY/UTEN_HMAC_KEY 生成临时 \set 文件送入容器，
#   用完本地/容器两侧即删（不落库、不进日志、不进 git）。
migrate_hr_workers () {
    echo "→ [人事老库] 复制 CSV（1 个：hr_workers）..."
    copy_csv hr_workers.csv
    echo "→ [人事老库] 注入加密密钥（临时文件，用后删除）..."
    local envf="$HERE/../.env" keyf
    local pgp_key pgp_ver hmac_key
    if [ ! -f "$envf" ]; then
        echo "✗ 找不到 server/.env，无法注入人事加密密钥" >&2
        exit 66
    fi
    pgp_key=$(grep '^UTEN_PGP_MASTER_KEY=' "$envf" | cut -d= -f2-)
    pgp_ver=$(grep '^UTEN_PGP_KEY_VERSION=' "$envf" | cut -d= -f2-)
    hmac_key=$(grep '^UTEN_HMAC_KEY=' "$envf" | cut -d= -f2-)
    if [ -z "$pgp_key" ] || [ -z "$hmac_key" ]; then
        echo "✗ server/.env 缺少 UTEN_PGP_MASTER_KEY 或 UTEN_HMAC_KEY"; exit 1
    fi
    pgp_ver="${pgp_ver:-v1}"
    keyf=$(mktemp "$HERE/.uten_keys.XXXXXX.sql")
    chmod 600 "$keyf"
    LOCAL_KEY_FILE="$keyf"
    {
        printf "\\set pgp_key '%s'\n"  "${pgp_key//\'/\'\'}"
        printf "\\set pgp_ver '%s'\n"  "${pgp_ver//\'/\'\'}"
        printf "\\set hmac_key '%s'\n" "${hmac_key//\'/\'\'}"
    } > "$keyf"
    "$DOCKER" cp "$keyf" "$CONTAINER:/tmp/_uten_keys.sql"
    "$DOCKER" exec "$CONTAINER" chmod 600 /tmp/_uten_keys.sql
    REMOTE_TMP_FILES+=("/tmp/_uten_keys.sql")
    rm -f "$keyf"
    LOCAL_KEY_FILE=""
    echo "→ [人事老库] 执行迁移 SQL（部门映射 + 职位建档 + 员工/敏感信息 upsert）..."
    run_sql migrate_hr_workers.sql
    "$DOCKER" exec "$CONTAINER" rm -f /tmp/_uten_keys.sql
}

# 人事清理：删除所有非 admin 员工（级联 users/敏感信息/任职轨迹等）+ LEG-P 遗留岗位，
#   业务表外键 RESTRICT 保护（有引用则整体回滚）。正式名录导入前执行。
migrate_hr_cleanup () {
    echo "→ [人事清理] 执行清理 SQL（只留 admin）..."
    run_sql cleanup_hr_keep_admin.sql
}

# HR 正式名录（职工信息表 141 人）：employees + 岗位建档 + 加密敏感信息 + onboard 轨迹 +
#   部门负责人/headcount。数据来自 build_hr_roster.py 生成的 data/hr_roster.csv +
#   hr_managers.csv（| 分隔，已登记 sha256 审计清单）。幂等（按 code upsert）。
# 密钥注入同 --hr-workers：server/.env → 临时 \set 文件，用后两侧即删。
migrate_hr_roster () {
    echo "→ [人事名录] 复制 CSV（2 个：hr_roster / hr_managers）..."
    copy_csv hr_roster.csv
    copy_csv hr_managers.csv
    echo "→ [人事名录] 注入加密密钥（临时文件，用后删除）..."
    local envf="$HERE/../.env" keyf
    local pgp_key pgp_ver hmac_key
    if [ ! -f "$envf" ]; then
        echo "✗ 找不到 server/.env，无法注入人事加密密钥" >&2
        exit 66
    fi
    pgp_key=$(grep '^UTEN_PGP_MASTER_KEY=' "$envf" | cut -d= -f2-)
    pgp_ver=$(grep '^UTEN_PGP_KEY_VERSION=' "$envf" | cut -d= -f2-)
    hmac_key=$(grep '^UTEN_HMAC_KEY=' "$envf" | cut -d= -f2-)
    if [ -z "$pgp_key" ] || [ -z "$hmac_key" ]; then
        echo "✗ server/.env 缺少 UTEN_PGP_MASTER_KEY 或 UTEN_HMAC_KEY"; exit 1
    fi
    pgp_ver="${pgp_ver:-v1}"
    keyf=$(mktemp "$HERE/.uten_keys.XXXXXX.sql")
    chmod 600 "$keyf"
    LOCAL_KEY_FILE="$keyf"
    {
        printf "\\set pgp_key '%s'\n"  "${pgp_key//\'/\'\'}"
        printf "\\set pgp_ver '%s'\n"  "${pgp_ver//\'/\'\'}"
        printf "\\set hmac_key '%s'\n" "${hmac_key//\'/\'\'}"
    } > "$keyf"
    "$DOCKER" cp "$keyf" "$CONTAINER:/tmp/_uten_keys.sql"
    "$DOCKER" exec "$CONTAINER" chmod 600 /tmp/_uten_keys.sql
    REMOTE_TMP_FILES+=("/tmp/_uten_keys.sql")
    rm -f "$keyf"
    LOCAL_KEY_FILE=""
    echo "→ [人事名录] 执行迁移 SQL（部门改名 + 岗位建档 + 员工/敏感信息 upsert + 负责人/轨迹/headcount）..."
    run_sql migrate_hr_roster.sql
    "$DOCKER" exec "$CONTAINER" rm -f /tmp/_uten_keys.sql
}

# 货架库位（目视化清单）：data/shelf_labels.csv（人工按现场挂牌整理，非老库导出）
#   → goods.stock_place。老库 B_Goods.StockPlace 是历史残值（'18'/'20'），与现场
#   「库行-层-位」（A31-3-1）无关，故不走 export_manifest 校验，sha256 现算直接登记审计。
# 依赖：--goods-data 先迁（goods.legacy_id / goods.code 匹配锚）。幂等可重跑。
copy_shelf_csv () {  # $1 = csv 文件名（HERE/data 下，人工维护）
    if [ ! -s "$HERE/data/$1" ]; then
        echo "✗ CSV 不存在或为空：$HERE/data/$1" >&2
        echo "  请按 migrate_shelf_labels.sql 头部格式整理现场挂牌数据（place|goods_code|goods_legacy_id）。" >&2
        exit 66
    fi
    if [[ ! "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
        echo "✗ CSV 文件名非法：$1；已拒绝迁移。" >&2
        exit 66
    fi
    local verified_sha file_bytes
    verified_sha=$(sha256sum "$HERE/data/$1" | awk '{print tolower($1)}')
    file_bytes=$(wc -c < "$HERE/data/$1" | tr -d '[:space:]')
    if [[ ! "$verified_sha" =~ ^[0-9a-f]{64}$ ]] \
        || [[ ! "$file_bytes" =~ ^[1-9][0-9]*$ ]]; then
        echo "✗ CSV 审计元数据非法：$1；已拒绝迁移。" >&2
        exit 66
    fi
    "$DOCKER" cp "$HERE/data/$1" "$CONTAINER:/tmp/$1"
    REMOTE_TMP_FILES+=("/tmp/$1")
    "$DOCKER" exec "$CONTAINER" psql -U "$PG_USER" -d "$PG_DB" \
        -v ON_ERROR_STOP=1 \
        -c "INSERT INTO legacy_migration_run_files(run_id, file_name, sha256, byte_size)
            VALUES ('$RUN_ID'::uuid, '$1', '$verified_sha', $file_bytes)
            ON CONFLICT (run_id, file_name) DO NOTHING" >/dev/null
}

migrate_shelf_labels () {
    echo "→ [货架库位] 复制 CSV（1 个：shelf_labels，人工维护挂牌数据）..."
    copy_shelf_csv shelf_labels.csv
    echo "→ [货架库位] 执行迁移 SQL（按 legacy id/物料编码回填 goods.stock_place）..."
    run_sql migrate_shelf_labels.sql
}

# 货品归属（外贸按人授权）：老库外贸子树 → goods.owner_employee_id（无 CSV，纯 UPDATE）。
# 依赖：goods/material_categories 已迁 + employees 有 legacy_id + V85 已应用。幂等（先清零再灌）。
migrate_goods_owner () {
    echo "→ [货品归属] 执行归属迁移 SQL（外贸子树 → owner_employee_id）..."
    run_sql migrate_goods_owner.sql
}

# 客户/供应商归属：emp_id 快照 → owner_employee_id（无 CSV，纯 UPDATE）。
# 依赖：两个主档已迁 + employees 有 legacy_id + V261 已应用。幂等，只补 UUID 空缺。
migrate_client_owner () {
    echo "→ [客户/供应商归属] 执行归属迁移 SQL（emp_id → owner_employee_id）..."
    run_sql migrate_client_owner.sql
}

# 销售单据归属（业务员按人授权）：seller_legacy_id → owner_employee_id（无 CSV，纯 UPDATE）。
# 依赖：销售单据已迁 + employees 有 legacy_id + V91 已应用。幂等（先清零再灌）。
migrate_sales_owner () {
    echo "→ [销售归属] 执行归属迁移 SQL（seller_legacy_id → owner_employee_id）..."
    run_sql migrate_sales_owner.sql
}

preflight

case "$TARGET" in
    --goods|-g) migrate_goods ;;
    --goods-data) migrate_goods_data ;;
    --goods-owner) migrate_goods_owner ;;
    --client-owner) migrate_client_owner ;;
    --sales-owner) migrate_sales_owner ;;
    --goods-bom) migrate_goods_bom ;;
    --mould|-m) migrate_mould ;;
    --mould-data) migrate_mould_data ;;
    --client) migrate_client ;;
    --client-data) migrate_client_data ;;
    --supplier) migrate_supplier ;;
    --supplier-data) migrate_supplier_data ;;
    --color-data) migrate_color_data ;;
    --unit-data) migrate_unit_data ;;
    --currency-data) migrate_currency_data ;;
    --warehouse-data) migrate_warehouse_data ;;
    --purchase) migrate_purchase ;;
    --stock-docs) migrate_stock_docs ;;
    --sales) migrate_sales ;;
    --subcontract) migrate_subcontract ;;
    --production) migrate_production ;;
    --finance) migrate_finance ;;
    --hr-workers) migrate_hr_workers ;;
    --hr-cleanup) migrate_hr_cleanup ;;
    --hr-roster) migrate_hr_roster ;;
    --shelf-labels) migrate_shelf_labels ;;
    --bootstrap-all|--all|-a)
        FULL_BOOTSTRAP=1
        # UUID-authoritative dependency order: all category authorities first,
        # then referenced masters, then goods, then transactional documents.
        # The former order imported goods before mould/client/supplier/unit/color
        # and silently left current UUID relationships NULL.
        migrate_goods
        migrate_mould
        migrate_client
        migrate_supplier
        migrate_color_data
        migrate_unit_data
        migrate_currency_data
        migrate_warehouse_data
        migrate_mould_data
        migrate_client_data
        migrate_supplier_data
        migrate_goods_data
        migrate_goods_bom
        migrate_purchase
        migrate_stock_docs
        migrate_sales
        migrate_subcontract
        migrate_production
        migrate_finance
        migrate_hr_workers
        migrate_goods_owner
        migrate_client_owner
        migrate_sales_owner
        ;;
esac

echo "→ 更新 PostgreSQL 统计信息..."
"$DOCKER" exec "$CONTAINER" psql -U "$PG_USER" -d "$PG_DB" \
    -v ON_ERROR_STOP=1 -c "ANALYZE" >/dev/null

if [ "$FULL_BOOTSTRAP" -eq 1 ]; then
    echo "→ 写入并验证本次全量导入的结构化对账证据..."
    reconcile_full_bootstrap
fi

echo ""
if [ "$FULL_BOOTSTRAP" -eq 1 ]; then
    echo "✔ 全量导入与自动结构对账通过（运行号：$RUN_ID）。"
    echo "  金额、数量、来源谱系、恢复演练和业务/财务签字仍须完成后才能切流。"
else
    echo "✔ 单模块导入步骤完成（运行号：$RUN_ID）。"
    echo "  本次 reconciliation_status=NOT_RUN，不得作为全量切换证据。"
fi
