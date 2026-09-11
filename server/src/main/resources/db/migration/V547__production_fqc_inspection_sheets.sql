-- V547 生产成品品质检查单聚合层（2026-09-10 用户口径：「登记成品」对照采购到货登记——
-- 逐行选实际成品仓、备注随批留痕，「批量送检」把同一成品仓的送检行合并成一张
-- 品质检查单，品质按单处置）。
--
-- 检查单只是展示/办理聚合（ADR-076）：数量、PASS/PARTIAL/FAIL 与守恒仍在
-- production_fqc_inspections（ADR-054 §2.3），FINISHED_IN 仍按登记批次继承仓库与
-- 库位（ADR-058 §2.5.4）。一张检查单 = 一个仓库 + 一位收货人 + 一次登记命令
-- （单张登记或批量登记）下该仓的全部 FQC PENDING 行；不回填历史 inspection，
-- 无检查单的历史任务按「无检查单」逐行显示。
-- 单号：FQC + YYYYMMDD + 6 位日流水（V279 DocNumberService 口径，终身占号）。

-- ① 单号命名空间（DocNumberPrefix.PRODUCTION_FQC_SHEET 镜像）。
INSERT INTO business_identifier_namespaces (
    namespace_key, identifier_family, fixed_prefix,
    source_table, identifier_column, discriminator_value)
VALUES ('PRODUCTION_FQC_SHEET', 'DOCUMENT', 'FQC',
        'production_fqc_inspection_sheets', 'sheet_no', NULL)
ON CONFLICT (namespace_key) DO NOTHING;

-- ② 检查单头：仓库/收货人/备注快照来自登记批次；source_kind 记录来自单张还是批量登记。
CREATE TABLE production_fqc_inspection_sheets (
    id                       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    sheet_no                 TEXT NOT NULL,
    warehouse_id             UUID NOT NULL
        REFERENCES warehouses(id) ON DELETE RESTRICT,
    warehouse_name_snapshot  TEXT NOT NULL,
    receiver_employee_id     UUID NOT NULL
        REFERENCES employees(id) ON DELETE RESTRICT,
    receiver_name_snapshot   TEXT NOT NULL,
    remark                   TEXT,
    source_kind              TEXT NOT NULL,
    batch_idempotency_key    VARCHAR(128),
    created_by               UUID NOT NULL
        REFERENCES users(id) ON DELETE RESTRICT,
    created_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT production_fqc_inspection_sheet_no_uk UNIQUE (sheet_no),
    CONSTRAINT production_fqc_inspection_sheet_no_chk CHECK (
        sheet_no ~ '^FQC[0-9]{14}$'),
    CONSTRAINT production_fqc_inspection_sheet_warehouse_name_chk CHECK (
        NULLIF(btrim(warehouse_name_snapshot), '') IS NOT NULL),
    CONSTRAINT production_fqc_inspection_sheet_receiver_name_chk CHECK (
        NULLIF(btrim(receiver_name_snapshot), '') IS NOT NULL),
    CONSTRAINT production_fqc_inspection_sheet_remark_chk CHECK (
        remark IS NULL OR length(remark) <= 500),
    CONSTRAINT production_fqc_inspection_sheet_source_chk CHECK (
        source_kind IN ('ARRIVAL_SINGLE', 'ARRIVAL_BATCH')),
    CONSTRAINT production_fqc_inspection_sheet_key_chk CHECK (
        batch_idempotency_key IS NULL
        OR (batch_idempotency_key = btrim(batch_idempotency_key)
            AND length(batch_idempotency_key) BETWEEN 8 AND 128
            AND batch_idempotency_key ~ '^[A-Za-z0-9._:-]+$'))
);

CREATE INDEX idx_production_fqc_inspection_sheet_warehouse
    ON production_fqc_inspection_sheets(warehouse_id, created_at, id);
CREATE INDEX idx_production_fqc_inspection_sheet_actor_timeline
    ON production_fqc_inspection_sheets(created_by, created_at, id);
-- 同一操作者、同一登记命令、同一仓库只允许一张检查单：幂等重放返回既有单。
CREATE UNIQUE INDEX production_fqc_inspection_sheet_batch_replay_uk
    ON production_fqc_inspection_sheets(
        created_by, batch_idempotency_key, warehouse_id)
    WHERE batch_idempotency_key IS NOT NULL;

-- 单号终身占用（V279 全局登记表）。
CREATE TRIGGER trg_business_document_production_fqc_inspection_sheets
    BEFORE INSERT OR UPDATE OF sheet_no ON production_fqc_inspection_sheets
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_business_document_identifier(
        'PRODUCTION_FQC_SHEET', 'sheet_no', '');

-- ③ 检查单明细：一条 inspection 终身只属于一张检查单；同时锚定它来自哪个登记批次/登记行。
CREATE TABLE production_fqc_inspection_sheet_items (
    id                     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    sheet_id               UUID NOT NULL
        REFERENCES production_fqc_inspection_sheets(id) ON DELETE RESTRICT,
    inspection_id          UUID NOT NULL
        REFERENCES production_fqc_inspections(id) ON DELETE RESTRICT,
    registration_id        UUID NOT NULL
        REFERENCES production_finished_arrival_registrations(id)
        ON DELETE RESTRICT,
    registration_item_id   UUID NOT NULL
        REFERENCES production_finished_arrival_registration_items(id)
        ON DELETE RESTRICT,
    line_no                INTEGER NOT NULL,
    created_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT production_fqc_inspection_sheet_item_inspection_uk
        UNIQUE (inspection_id),
    CONSTRAINT production_fqc_inspection_sheet_item_registration_item_uk
        UNIQUE (registration_item_id),
    CONSTRAINT production_fqc_inspection_sheet_item_pair_uk
        UNIQUE (sheet_id, inspection_id),
    CONSTRAINT production_fqc_inspection_sheet_item_line_uk
        UNIQUE (sheet_id, line_no),
    CONSTRAINT production_fqc_inspection_sheet_item_line_chk CHECK (line_no >= 1)
);

CREATE INDEX idx_production_fqc_inspection_sheet_items_sheet
    ON production_fqc_inspection_sheet_items(sheet_id, line_no);
CREATE INDEX idx_production_fqc_inspection_sheet_items_registration
    ON production_fqc_inspection_sheet_items(registration_id, id);

-- ④ 守卫：头/行只追加；行的 inspection、登记批次、登记行必须同仓且互相对应。
CREATE OR REPLACE FUNCTION fn_guard_production_fqc_inspection_sheet()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'production FQC inspection sheet is append-only'
            USING ERRCODE = '55000';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM warehouses warehouse
        WHERE warehouse.id = NEW.warehouse_id
          AND warehouse.is_deleted = FALSE
          AND warehouse.is_accountable = TRUE
          AND COALESCE(warehouse.status, '') <> '禁用'
    ) THEN
        RAISE EXCEPTION 'FQC inspection sheet requires an active accountable warehouse'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_fqc_inspection_sheet_warehouse_guard';
    END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION fn_guard_production_fqc_inspection_sheet_item()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    sheet_warehouse_id UUID;
    inspection_row RECORD;
    registration_row RECORD;
BEGIN
    IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'production FQC inspection sheet item is append-only'
            USING ERRCODE = '55000';
    END IF;

    SELECT warehouse_id INTO sheet_warehouse_id
    FROM production_fqc_inspection_sheets
    WHERE id = NEW.sheet_id;

    SELECT inspection.warehouse_id, inspection.status,
           inspection.source_report_item_id
    INTO inspection_row
    FROM production_fqc_inspections inspection
    WHERE inspection.id = NEW.inspection_id;

    SELECT registration.warehouse_id, registration_item.registration_id,
           registration_item.source_report_item_id
    INTO registration_row
    FROM production_finished_arrival_registration_items registration_item
    JOIN production_finished_arrival_registrations registration
      ON registration.id = registration_item.registration_id
    WHERE registration_item.id = NEW.registration_item_id;

    IF sheet_warehouse_id IS NULL
       OR inspection_row IS NULL
       OR registration_row IS NULL
       OR inspection_row.status <> 'PENDING'
       OR inspection_row.warehouse_id <> sheet_warehouse_id
       OR registration_row.warehouse_id <> sheet_warehouse_id
       OR registration_row.registration_id <> NEW.registration_id
       OR registration_row.source_report_item_id
            <> inspection_row.source_report_item_id THEN
        RAISE EXCEPTION 'FQC inspection sheet item must bind one PENDING inspection of the same warehouse registration line'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_fqc_inspection_sheet_item_source_guard';
    END IF;
    RETURN NEW;
END;
$$;

-- 事务提交前每张检查单至少一行（与 V469 登记头非空守卫同款）。
CREATE OR REPLACE FUNCTION fn_require_nonempty_production_fqc_inspection_sheet()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM production_fqc_inspection_sheet_items sheet_item
        WHERE sheet_item.sheet_id = NEW.id
    ) THEN
        RAISE EXCEPTION 'FQC inspection sheet must contain at least one inspection'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_fqc_inspection_sheet_nonempty_guard';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_production_fqc_inspection_sheets
    BEFORE INSERT OR UPDATE OR DELETE
    ON production_fqc_inspection_sheets
    FOR EACH ROW EXECUTE FUNCTION fn_guard_production_fqc_inspection_sheet();
ALTER TABLE production_fqc_inspection_sheets
    ENABLE ALWAYS TRIGGER trg_guard_production_fqc_inspection_sheets;

CREATE TRIGGER trg_guard_production_fqc_inspection_sheet_items
    BEFORE INSERT OR UPDATE OR DELETE
    ON production_fqc_inspection_sheet_items
    FOR EACH ROW EXECUTE FUNCTION
        fn_guard_production_fqc_inspection_sheet_item();
ALTER TABLE production_fqc_inspection_sheet_items
    ENABLE ALWAYS TRIGGER trg_guard_production_fqc_inspection_sheet_items;

CREATE CONSTRAINT TRIGGER trg_require_nonempty_production_fqc_inspection_sheet
    AFTER INSERT ON production_fqc_inspection_sheets
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION
        fn_require_nonempty_production_fqc_inspection_sheet();

-- ⑤ 审计：业务表，同迁移自带完整行级审计触发器（V430 同款）。
CREATE TRIGGER trg_audit_production_fqc_inspection_sheets
    AFTER INSERT OR UPDATE OR DELETE ON production_fqc_inspection_sheets
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_production_fqc_inspection_sheet_items
    AFTER INSERT OR UPDATE OR DELETE ON production_fqc_inspection_sheet_items
    FOR EACH ROW EXECUTE FUNCTION fn_audit();

-- ⑥ 工作台「清空业务数据」孪生函数：检查单随 FQC 事实一并清空（V504 同款前向补丁）。
DO $reset_policy$
DECLARE
    definition TEXT;
    needle TEXT := '(''stock_movements'', ''CLEAR'')';
    addition TEXT := E',\n            (''production_fqc_inspection_sheets'', ''CLEAR''),\n            (''production_fqc_inspection_sheet_items'', ''CLEAR'')';
    table_name TEXT;
BEGIN
    SELECT pg_get_functiondef('business_data_reset()'::regprocedure) INTO definition;
    IF (length(definition)-length(replace(definition,needle,'')))/length(needle) <> 1 THEN
        RAISE EXCEPTION 'V547 cannot extend business_data_reset policy safely';
    END IF;
    FOREACH table_name IN ARRAY ARRAY[
        'production_fqc_inspection_sheets', 'production_fqc_inspection_sheet_items'
    ] LOOP
        IF to_regclass(format('public.%I',table_name)) IS NULL
           OR position(format('(%L, %L)',table_name,'CLEAR') IN definition)>0
           OR position(format('(%L, %L)',table_name,'PRESERVE') IN definition)>0 THEN
            RAISE EXCEPTION 'V547 reset policy source missing or already classified: %', table_name;
        END IF;
    END LOOP;
    EXECUTE replace(definition,needle,needle || addition);
END;
$reset_policy$;

COMMENT ON TABLE production_fqc_inspection_sheets IS
    '生产成品品质检查单：同一登记命令、同一成品仓的 FQC 待检行聚合；只做展示/办理聚合，数量与守恒仍在 production_fqc_inspections';
COMMENT ON TABLE production_fqc_inspection_sheet_items IS
    '品质检查单明细：一条 inspection 终身只属一张检查单；锚定来源登记批次与登记行，登记撤回后作为历史保留';
COMMENT ON COLUMN production_fqc_inspection_sheets.sheet_no IS
    '检查单号 FQC+YYYYMMDD+6 位日流水；只用于识别/搜索，关联与幂等始终用 UUID';
COMMENT ON COLUMN production_fqc_inspection_sheets.batch_idempotency_key IS
    '生成本单的登记命令幂等键（单张=登记键，批量=批量键）；同操作者同键同仓只有一张';
