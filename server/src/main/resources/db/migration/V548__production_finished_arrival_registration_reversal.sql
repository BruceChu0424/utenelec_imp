-- V548 产成品送检登记撤回（兑现 ADR-058 §4.5 承诺的受控、幂等、追加式反向）。
--
-- 前提：该登记批次的每条 FQC 仍 PENDING（合格/不合格均为 0），且没有决定事件、放行命令
-- 与恢复授权；来源日报仍已审核未红冲。撤回事务 = 追加一条撤回记录 → 该批次登记行打上
-- reversal_id 标记 → 逐条 FQC 追加 REGISTRATION_REVERSED 取消事件（状态 CANCELLED）；
-- 提交前延迟守卫核对该批次没有残留未取消 inspection。检查单明细保留为历史，库位偏好
-- 指向已撤回登记的行保留。撤回后这些报工行重新出现在仓库待登记，可再次登记到任意仓。
--
-- 唯一性口径前向放宽：登记行/inspection 对同一报工行不再终身唯一，改为「同时只有一条
-- 有效登记行（reversal_id IS NULL）/ 一条未取消 inspection（status <> 'CANCELLED'）」。
-- 历史登记、inspection、决定与放行字节均不改写。
-- 「未登记」谓词收口到视图 v_production_report_items_pending_registration，服务端与
-- 数据库守卫统一引用。

-- ① 撤回记录：逐登记批次唯一、幂等、只追加。
CREATE TABLE production_finished_arrival_registration_reversals (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    registration_id  UUID NOT NULL UNIQUE
        REFERENCES production_finished_arrival_registrations(id)
        ON DELETE RESTRICT,
    reason           TEXT NOT NULL,
    idempotency_key  VARCHAR(128) NOT NULL,
    request_hash     CHAR(64) NOT NULL,
    created_by       UUID NOT NULL
        REFERENCES users(id) ON DELETE RESTRICT,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT production_finished_arrival_reversal_reason_chk CHECK (
        reason = btrim(reason)
        AND length(reason) BETWEEN 2 AND 500),
    CONSTRAINT production_finished_arrival_reversal_key_chk CHECK (
        idempotency_key = btrim(idempotency_key)
        AND length(idempotency_key) BETWEEN 8 AND 128
        AND idempotency_key ~ '^[A-Za-z0-9._:-]+$'),
    CONSTRAINT production_finished_arrival_reversal_hash_chk CHECK (
        request_hash ~ '^[0-9a-f]{64}$'),
    CONSTRAINT production_finished_arrival_reversal_actor_key_uk UNIQUE (
        created_by, idempotency_key)
);

CREATE INDEX idx_production_finished_arrival_reversal_timeline
    ON production_finished_arrival_registration_reversals(created_at, id);

-- ② 登记行撤回标记；V430 的「报工行终身唯一」改为「有效登记行唯一」。
ALTER TABLE production_finished_arrival_registration_items
    ADD COLUMN IF NOT EXISTS reversal_id UUID
        REFERENCES production_finished_arrival_registration_reversals(id)
        ON DELETE RESTRICT;

DO $drop_item_unique$
DECLARE
    constraint_name TEXT;
BEGIN
    FOR constraint_name IN
        SELECT con.conname
        FROM pg_constraint con
        JOIN pg_class rel ON rel.oid = con.conrelid
        JOIN pg_namespace nsp ON nsp.oid = rel.relnamespace
        WHERE nsp.nspname = 'public'
          AND rel.relname = 'production_finished_arrival_registration_items'
          AND con.contype = 'u'
          AND array_length(con.conkey, 1) = 1
          AND EXISTS (
              SELECT 1 FROM pg_attribute att
              WHERE att.attrelid = rel.oid
                AND att.attnum = con.conkey[1]
                AND att.attname = 'source_report_item_id')
    LOOP
        EXECUTE format(
            'ALTER TABLE production_finished_arrival_registration_items DROP CONSTRAINT %I',
            constraint_name);
    END LOOP;
END;
$drop_item_unique$;

CREATE UNIQUE INDEX IF NOT EXISTS production_finished_arrival_registration_item_active_uk
    ON production_finished_arrival_registration_items(source_report_item_id)
    WHERE reversal_id IS NULL;
CREATE INDEX IF NOT EXISTS idx_production_finished_arrival_registration_items_reversal
    ON production_finished_arrival_registration_items(reversal_id, registration_id)
    WHERE reversal_id IS NOT NULL;
-- 逐行「上次成品仓」建议按货品+颜色反查最近登记；报工明细按 (goods, color) 命中。
CREATE INDEX IF NOT EXISTS idx_production_daily_report_items_goods_color
    ON production_daily_report_items(goods_id, color_id, id);

-- ③ inspection 的「报工行终身唯一」改为「未取消 inspection 唯一」。
DO $drop_inspection_unique$
DECLARE
    constraint_name TEXT;
BEGIN
    FOR constraint_name IN
        SELECT con.conname
        FROM pg_constraint con
        JOIN pg_class rel ON rel.oid = con.conrelid
        JOIN pg_namespace nsp ON nsp.oid = rel.relnamespace
        WHERE nsp.nspname = 'public'
          AND rel.relname = 'production_fqc_inspections'
          AND con.contype = 'u'
          AND (
              (array_length(con.conkey, 1) = 1
               AND EXISTS (
                   SELECT 1 FROM pg_attribute att
                   WHERE att.attrelid = rel.oid
                     AND att.attnum = con.conkey[1]
                     AND att.attname = 'source_report_item_id'))
              OR con.conname = 'production_fqc_inspection_report_pair_uk')
    LOOP
        EXECUTE format(
            'ALTER TABLE production_fqc_inspections DROP CONSTRAINT %I',
            constraint_name);
    END LOOP;
END;
$drop_inspection_unique$;

CREATE UNIQUE INDEX IF NOT EXISTS production_fqc_inspection_active_report_item_uk
    ON production_fqc_inspections(source_report_item_id)
    WHERE status <> 'CANCELLED';
CREATE INDEX IF NOT EXISTS idx_production_fqc_inspection_report_item_history
    ON production_fqc_inspections(source_report_item_id, created_at, id);

-- ④ 待登记视图：仓库待办、登记详情、库位建议、通知投递、链路健康与数据库守卫的唯一口径。
CREATE OR REPLACE VIEW v_production_report_items_pending_registration AS
SELECT report_item.id AS report_item_id,
       report_item.report_id
FROM production_daily_report_items report_item
JOIN production_daily_reports report
  ON report.id = report_item.report_id
WHERE report.status = 1
  AND report.is_deleted = FALSE
  AND report_item.is_deleted = FALSE
  AND report_item.execution_segment_id IS NOT NULL
  AND NOT EXISTS (
      SELECT 1
      FROM production_finished_arrival_registration_items registered_item
      WHERE registered_item.source_report_item_id = report_item.id
        AND registered_item.reversal_id IS NULL)
  AND NOT EXISTS (
      SELECT 1
      FROM production_fqc_inspections inspection
      WHERE inspection.source_report_item_id = report_item.id
        AND inspection.status <> 'CANCELLED')
  AND NOT EXISTS (
      SELECT 1
      FROM production_fqc_legacy_exemptions exemption
      WHERE exemption.source_report_item_id = report_item.id);

COMMENT ON VIEW v_production_report_items_pending_registration IS
    '仓库待送检登记的报工行：日报已审未红冲、带执行段、无有效登记行、无未取消 FQC、无 V414 历史豁免';

-- ⑤ 前向替换登记行守卫：INSERT 以待登记视图为准（撤回后可再登记）；
--    UPDATE 只允许撤回事务把 reversal_id 从 NULL 置为当前撤回记录，其余列不可变。
CREATE OR REPLACE FUNCTION fn_guard_production_finished_arrival_item()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    registration_report_id UUID;
    item_report_id UUID;
    reversal_registration_id UUID;
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'production finished arrival registration item is append-only'
            USING ERRCODE = '55000';
    END IF;

    IF TG_OP = 'UPDATE' THEN
        SELECT registration_id INTO reversal_registration_id
        FROM production_finished_arrival_registration_reversals
        WHERE id = NEW.reversal_id;
        IF OLD.reversal_id IS NOT NULL
           OR NEW.reversal_id IS NULL
           OR reversal_registration_id IS DISTINCT FROM OLD.registration_id
           OR current_setting('app.production_finished_arrival_reversal_id', TRUE)
                IS DISTINCT FROM NEW.reversal_id::text
           OR (to_jsonb(NEW) - 'reversal_id')
                IS DISTINCT FROM (to_jsonb(OLD) - 'reversal_id') THEN
            RAISE EXCEPTION 'production finished arrival registration item is append-only'
                USING ERRCODE = '55000';
        END IF;
        RETURN NEW;
    END IF;

    SELECT source_report_id INTO registration_report_id
    FROM production_finished_arrival_registrations
    WHERE id = NEW.registration_id;

    SELECT report_id INTO item_report_id
    FROM production_daily_report_items
    WHERE id = NEW.source_report_item_id
      AND is_deleted = FALSE
      AND execution_segment_id IS NOT NULL;

    IF registration_report_id IS NULL
       OR item_report_id IS NULL
       OR item_report_id <> registration_report_id
       OR NEW.reversal_id IS NOT NULL
       OR NOT EXISTS (
           SELECT 1
           FROM v_production_report_items_pending_registration pending
           WHERE pending.report_item_id = NEW.source_report_item_id) THEN
        RAISE EXCEPTION 'finished arrival item does not belong to an eligible report line'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_finished_arrival_item_source_guard';
    END IF;

    RETURN NEW;
END;
$$;

-- ⑥ 前向替换 V430 的 FQC 来源守卫：只认有效（未撤回）登记行。
CREATE OR REPLACE FUNCTION fn_guard_production_fqc_inspection()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    source_row RECORD;
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'production FQC inspections cannot be deleted'
            USING ERRCODE = '55000';
    END IF;

    IF TG_OP = 'UPDATE' THEN
        IF current_setting('app.production_fqc_projection_id', TRUE)
               IS DISTINCT FROM OLD.id::text
           OR (to_jsonb(NEW) - ARRAY[
                    'passed_qty', 'failed_qty', 'status', 'updated_at'])
              IS DISTINCT FROM
              (to_jsonb(OLD) - ARRAY[
                    'passed_qty', 'failed_qty', 'status', 'updated_at']) THEN
            RAISE EXCEPTION 'production FQC inspection identity is immutable'
                USING ERRCODE = '55000';
        END IF;
        RETURN NEW;
    END IF;

    SELECT report.status AS report_status,
           report.is_deleted AS report_deleted,
           registration.warehouse_id AS registered_warehouse_id,
           report.maker_id AS report_maker_id,
           item.report_id AS item_report_id,
           item.plan_item_id,
           item.execution_segment_id,
           item.execution_segment_sales_allocation_id,
           item.goods_id,
           item.color_id,
           item.unit_id,
           COALESCE(item.unit_rate, 1) AS unit_rate,
           item.qty,
           item.is_deleted AS item_deleted,
           segment.plan_id,
           segment.status AS segment_status,
           segment.is_deleted AS segment_deleted,
           package.status AS package_status,
           package.is_deleted AS package_deleted
    INTO source_row
    FROM production_daily_report_items item
    JOIN production_daily_reports report ON report.id = item.report_id
    JOIN production_finished_arrival_registration_items registration_item
      ON registration_item.source_report_item_id = item.id
     AND registration_item.reversal_id IS NULL
    JOIN production_finished_arrival_registrations registration
      ON registration.id = registration_item.registration_id
     AND registration.source_report_id = report.id
    JOIN production_execution_segments segment
      ON segment.id = item.execution_segment_id
    JOIN production_planning_packages package ON package.id = segment.package_id
    WHERE item.id = NEW.source_report_item_id;

    IF source_row IS NULL
       OR source_row.report_status <> 1
       OR source_row.report_deleted
       OR source_row.item_deleted
       OR source_row.registered_warehouse_id IS NULL
       OR source_row.report_maker_id IS NULL
       OR source_row.item_report_id <> NEW.source_report_id
       OR source_row.plan_item_id IS DISTINCT FROM NEW.source_plan_item_id
       OR source_row.execution_segment_id IS DISTINCT FROM NEW.execution_segment_id
       OR source_row.execution_segment_sales_allocation_id
            IS DISTINCT FROM NEW.execution_segment_sales_allocation_id
       OR source_row.registered_warehouse_id <> NEW.warehouse_id
       OR source_row.goods_id <> NEW.goods_id
       OR source_row.color_id IS DISTINCT FROM NEW.color_id
       OR source_row.unit_id <> NEW.unit_id
       OR source_row.unit_rate IS DISTINCT FROM NEW.unit_rate
       OR source_row.qty IS DISTINCT FROM NEW.reported_qty
       OR source_row.report_maker_id <> NEW.report_maker_id
       OR source_row.segment_status <> 'IN_PROGRESS'
       OR source_row.segment_deleted
       OR source_row.package_status <> 'CONFIRMED'
       OR source_row.package_deleted THEN
        RAISE EXCEPTION 'production FQC source report identity or arrival registration is invalid'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_fqc_source_report_guard';
    END IF;
    RETURN NEW;
END;
$$;

-- ⑦ FQC 取消事件新增原因 REGISTRATION_REVERSED：只允许撤回事务对该批次仍 PENDING 且
--    无决定/放行/恢复授权的 inspection 追加；SOURCE_REPORT_REVERSED 分支保持 V412 口径。
ALTER TABLE production_fqc_cancellation_events
    DROP CONSTRAINT production_fqc_cancellation_reason_chk;
ALTER TABLE production_fqc_cancellation_events
    ADD CONSTRAINT production_fqc_cancellation_reason_chk CHECK (
        reason_code IN ('SOURCE_REPORT_REVERSED', 'REGISTRATION_REVERSED'));

CREATE OR REPLACE FUNCTION fn_guard_production_fqc_cancellation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    inspection production_fqc_inspections%ROWTYPE;
    report_status SMALLINT;
BEGIN
    SELECT * INTO inspection
    FROM production_fqc_inspections
    WHERE id = NEW.inspection_id
    FOR UPDATE;
    SELECT status INTO report_status
    FROM production_daily_reports
    WHERE id = NEW.source_report_id
      AND is_deleted = FALSE;

    IF NEW.reason_code = 'REGISTRATION_REVERSED' THEN
        IF inspection.id IS NULL
           OR inspection.source_report_id <> NEW.source_report_id
           OR report_status IS DISTINCT FROM 1
           OR inspection.status <> 'PENDING'
           OR inspection.passed_qty <> 0
           OR inspection.failed_qty <> 0
           OR EXISTS (
               SELECT 1 FROM production_fqc_decision_events decision
               WHERE decision.inspection_id = inspection.id)
           OR EXISTS (
               SELECT 1 FROM production_fqc_release_commands command
               WHERE command.inspection_id = inspection.id)
           OR EXISTS (
               SELECT 1 FROM production_fqc_recovery_authorizations recovery_auth
               WHERE recovery_auth.source_inspection_id = inspection.id)
           OR NOT EXISTS (
               SELECT 1
               FROM production_finished_arrival_registration_reversals reversal
               JOIN production_finished_arrival_registration_items registration_item
                 ON registration_item.registration_id = reversal.registration_id
                AND registration_item.reversal_id = reversal.id
               WHERE registration_item.source_report_item_id =
                     inspection.source_report_item_id
                 AND current_setting(
                         'app.production_finished_arrival_reversal_id', TRUE)
                     = reversal.id::text) THEN
            RAISE EXCEPTION
                'FQC cancellation requires a reversed arrival registration with untouched PENDING inspections'
                USING ERRCODE = '23514',
                      CONSTRAINT = 'production_fqc_cancellation_registration_guard';
        END IF;
        RETURN NEW;
    END IF;

    IF inspection.id IS NULL
       OR inspection.source_report_id <> NEW.source_report_id
       OR report_status <> -1 THEN
        RAISE EXCEPTION
            'FQC cancellation requires its exact reversed source report'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_fqc_cancellation_source_guard';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM stock_document_items item
        JOIN stock_documents document
          ON document.id = item.doc_id
        WHERE item.source_daily_report_item_id =
              inspection.source_report_item_id
          AND item.is_deleted = FALSE
          AND document.is_deleted = FALSE
          AND document.doc_type = 'FINISHED_IN'
          AND document.status <> -1
    ) THEN
        RAISE EXCEPTION
            'active FINISHED_IN must be reversed or removed before FQC cancellation'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_fqc_cancellation_inbound_guard';
    END IF;
    RETURN NEW;
END;
$$;

-- ⑧ 撤回记录守卫：只追加；来源日报仍已审；批次每条有效登记行恰有一条未取消 inspection
--    且仍 PENDING、无决定/放行/恢复授权；必须由带 app.production_finished_arrival_reversal_id
--    会话变量的撤回事务写入。
CREATE OR REPLACE FUNCTION fn_guard_production_finished_arrival_registration_reversal()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_report_id UUID;
BEGIN
    IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'production finished arrival registration reversal is append-only'
            USING ERRCODE = '55000';
    END IF;

    IF current_setting('app.production_finished_arrival_reversal_id', TRUE)
           IS DISTINCT FROM NEW.id::text THEN
        RAISE EXCEPTION 'arrival registration reversal must run inside its reversal command'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_finished_arrival_reversal_command_guard';
    END IF;

    SELECT registration.source_report_id INTO v_report_id
    FROM production_finished_arrival_registrations registration
    JOIN production_daily_reports report
      ON report.id = registration.source_report_id
     AND report.status = 1
     AND report.is_deleted = FALSE
    WHERE registration.id = NEW.registration_id;
    IF v_report_id IS NULL THEN
        RAISE EXCEPTION 'arrival registration reversal requires an approved, unreversed report'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_finished_arrival_reversal_report_guard';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM production_finished_arrival_registration_items registration_item
        WHERE registration_item.registration_id = NEW.registration_id
          AND registration_item.reversal_id IS NULL
    ) OR EXISTS (
        SELECT 1
        FROM production_finished_arrival_registration_items registration_item
        LEFT JOIN production_fqc_inspections inspection
          ON inspection.source_report_item_id =
             registration_item.source_report_item_id
         AND inspection.status <> 'CANCELLED'
        WHERE registration_item.registration_id = NEW.registration_id
          AND registration_item.reversal_id IS NULL
          AND (inspection.id IS NULL
               OR inspection.status <> 'PENDING'
               OR inspection.passed_qty <> 0
               OR inspection.failed_qty <> 0
               OR EXISTS (
                   SELECT 1 FROM production_fqc_decision_events decision
                   WHERE decision.inspection_id = inspection.id)
               OR EXISTS (
                   SELECT 1 FROM production_fqc_release_commands command
                   WHERE command.inspection_id = inspection.id)
               OR EXISTS (
                   SELECT 1 FROM production_fqc_recovery_authorizations recovery_auth
                   WHERE recovery_auth.source_inspection_id = inspection.id))
    ) THEN
        RAISE EXCEPTION 'arrival registration can only be reversed while every inspection is untouched PENDING'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_finished_arrival_reversal_state_guard';
    END IF;

    RETURN NEW;
END;
$$;

-- ⑨ 撤回落地：同事务把该批次全部有效登记行标记为已撤回。
CREATE OR REPLACE FUNCTION fn_apply_production_finished_arrival_registration_reversal()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE production_finished_arrival_registration_items
    SET reversal_id = NEW.id
    WHERE registration_id = NEW.registration_id
      AND reversal_id IS NULL;
    RETURN NEW;
END;
$$;

-- ⑩ 提交前核对：撤回批次至少一行被标记，且这些报工行不再有未取消 inspection。
CREATE OR REPLACE FUNCTION fn_require_complete_production_finished_arrival_reversal()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM production_finished_arrival_registration_items registration_item
        WHERE registration_item.reversal_id = NEW.id
    ) OR EXISTS (
        SELECT 1
        FROM production_finished_arrival_registration_items registration_item
        JOIN production_fqc_inspections inspection
          ON inspection.source_report_item_id =
             registration_item.source_report_item_id
         AND inspection.status <> 'CANCELLED'
        WHERE registration_item.reversal_id = NEW.id
    ) THEN
        RAISE EXCEPTION 'arrival registration reversal must cancel every inspection of its batch'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_finished_arrival_reversal_complete_guard';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_production_finished_arrival_registration_reversals
    BEFORE INSERT OR UPDATE OR DELETE
    ON production_finished_arrival_registration_reversals
    FOR EACH ROW EXECUTE FUNCTION
        fn_guard_production_finished_arrival_registration_reversal();
ALTER TABLE production_finished_arrival_registration_reversals
    ENABLE ALWAYS TRIGGER
        trg_guard_production_finished_arrival_registration_reversals;

CREATE TRIGGER trg_apply_production_finished_arrival_registration_reversals
    AFTER INSERT ON production_finished_arrival_registration_reversals
    FOR EACH ROW EXECUTE FUNCTION
        fn_apply_production_finished_arrival_registration_reversal();

CREATE CONSTRAINT TRIGGER trg_require_complete_production_finished_arrival_reversal
    AFTER INSERT ON production_finished_arrival_registration_reversals
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION
        fn_require_complete_production_finished_arrival_reversal();

-- ⑪ 审计：业务事实，同迁移自带完整行级审计触发器。
CREATE TRIGGER trg_audit_production_finished_arrival_registration_reversals
    AFTER INSERT OR UPDATE OR DELETE
    ON production_finished_arrival_registration_reversals
    FOR EACH ROW EXECUTE FUNCTION fn_audit();

-- ⑫ 工作台「清空业务数据」孪生函数：撤回记录随登记事实一并清空（V504 同款前向补丁）。
DO $reset_policy$
DECLARE
    definition TEXT;
    needle TEXT := '(''stock_movements'', ''CLEAR'')';
    addition TEXT := E',\n            (''production_finished_arrival_registration_reversals'', ''CLEAR'')';
    table_name TEXT;
BEGIN
    SELECT pg_get_functiondef('business_data_reset()'::regprocedure) INTO definition;
    IF (length(definition)-length(replace(definition,needle,'')))/length(needle) <> 1 THEN
        RAISE EXCEPTION 'V548 cannot extend business_data_reset policy safely';
    END IF;
    FOREACH table_name IN ARRAY ARRAY[
        'production_finished_arrival_registration_reversals'
    ] LOOP
        IF to_regclass(format('public.%I',table_name)) IS NULL
           OR position(format('(%L, %L)',table_name,'CLEAR') IN definition)>0
           OR position(format('(%L, %L)',table_name,'PRESERVE') IN definition)>0 THEN
            RAISE EXCEPTION 'V548 reset policy source missing or already classified: %', table_name;
        END IF;
    END LOOP;
    EXECUTE replace(definition,needle,needle || addition);
END;
$reset_policy$;

COMMENT ON TABLE production_finished_arrival_registration_reversals IS
    '产成品送检登记撤回记录：逐登记批次唯一、幂等、只追加；仅品质未处理（全部 PENDING）时允许';
COMMENT ON COLUMN production_finished_arrival_registration_items.reversal_id IS
    '该登记行所属批次被撤回时的撤回记录；NULL = 有效登记行（同一报工行同时只有一条）';
COMMENT ON TABLE production_finished_arrival_registration_items IS
    '送检登记逐行库位快照；同一报工行同时只有一条有效登记行，撤回后可再次登记；不是库存或FQC PASS';
COMMENT ON TABLE production_fqc_inspections IS
    'One explicit FQC projection per registered production report item; a reversed registration cancels its inspection and the line may be registered again';
