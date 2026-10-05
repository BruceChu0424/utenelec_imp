-- V801 (ADR-148 / ADR-151 §5) 产成品实物交接批 + 到货登记批量命令
--
-- 背景: 一次报工按归属拆成「需求份 + 计划公共 + 实际超产」几份(ADR-118 切片), 但仓库登记、品质、
-- 放行建单、点收、通知都把每一份当成一份独立实物: 同一批货进同一个仓, 却生成两张入库单、两个点收任务、
-- 两条通知; 品质和仓库还要逐份判定/逐份点数, 甚至可以把不良记在需求份、超产份全合格(账实矛盾)。
--
-- 本迁移:
--   1. 切片归属优先级的唯一定义 fn_daily_report_output_slice_rank(需求 0 < 计划公共 1 < 实际超产 2)。
--   2. 实物交接批身份: 同一报工、同一产出批次(没拆分的行自成一批)、同一去向(仓库 / 直送的接收需求)的
--      各份是一批实物。报工行增加生成列 output_lot_id(由 fn_production_output_lot_id 算出, 带索引);
--      投影视图 v_production_output_handoff_lots 给登记、品质、点收、车间详情共用。
--   3. 登记整批守卫: 同一批实物送入仓库的各份必须在同一次登记里一起登记(同仓同库位), 不允许部分登记。
--   4. 品质整批决定: 新表 production_fqc_lot_decision_commands(一次整批决定 = 一条命令), 决定事件带
--      lot_command_id。合格先满足需求份、再计划公共、最后实际超产; 不良先扣实际超产(ADR-118 §4 修订)。
--      延迟约束按同一瀑布重算并核对守恒; 同一命令放行出的行必须在同一张成品入库单里。
--      分成多份的批不允许逐份判定(只能整批判定)。
--   5. 到货登记批量命令: warehouse_arrival_registration_commands 记录批量键与批量指纹, 同一批量键
--      换了内容 = 409, 原样重放 = 返回原结果。
--   6. 业务清空: 整批决定命令随业务数据清空(CLEAR)。
--   7. 自制子件「直接来源」容量守卫只数直接来源, 不把同计划被认领的公共份算进去(一批一张单后两者同事务落库)。
-- 不搬迁历史: 已经拆开的历史入库单原样保留。

-- ---------------------------------------------------------------------------
-- 1. 切片归属优先级(唯一定义)
-- ---------------------------------------------------------------------------
CREATE FUNCTION fn_daily_report_output_slice_rank(p_public BOOLEAN, p_actual_surplus BOOLEAN)
RETURNS SMALLINT LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT (CASE WHEN COALESCE(p_actual_surplus, FALSE) THEN 2
                 WHEN COALESCE(p_public, FALSE) THEN 1
                 ELSE 0 END)::SMALLINT
$$;
COMMENT ON FUNCTION fn_daily_report_output_slice_rank(BOOLEAN, BOOLEAN) IS
    'V801 (ADR-148) 同一批实物内各份的归属优先级(唯一定义): 0 需求份 < 1 计划公共备货 < 2 实际超产。'
    '合格/实收按升序先满足, 不良/短收按降序先扣; Java 只读这个函数的结果';

-- ---------------------------------------------------------------------------
-- 2. 实物交接批身份
-- ---------------------------------------------------------------------------
CREATE FUNCTION fn_production_output_lot_id(
    p_report UUID, p_batch UUID, p_destination TEXT, p_demand UUID)
RETURNS UUID LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT md5('PRODUCTION-OUTPUT-LOT:' || p_report::text || ':' || p_batch::text || ':'
               || p_destination || ':' || COALESCE(p_demand::text, ''))::uuid
$$;
COMMENT ON FUNCTION fn_production_output_lot_id(UUID, UUID, TEXT, UUID) IS
    'V801 (ADR-148) 实物交接批身份 = (报工, 产出批次, 去向, 直送接收需求) 的确定性 UUID';

ALTER TABLE production_daily_report_items
    ADD COLUMN output_lot_id UUID GENERATED ALWAYS AS (
        fn_production_output_lot_id(report_id, COALESCE(output_batch_id, id), destination, direct_transfer_demand_id)
    ) STORED;
CREATE INDEX idx_daily_report_output_lot ON production_daily_report_items(output_lot_id);
COMMENT ON COLUMN production_daily_report_items.output_lot_id IS
    'V801 (ADR-148) 实物交接批: 同一报工、同一产出批次(没拆分的行自成一批)、同一去向的各份共用一个批号; '
    '登记、品质、放行建单、点收都以批为单位办理, 批内各份分账不变';

CREATE VIEW v_production_output_handoff_lots AS
SELECT item.output_lot_id AS lot_id,
       item.report_id,
       item.id AS report_item_id,
       COALESCE(item.output_batch_id, item.id) AS output_batch_key,
       item.destination,
       item.direct_transfer_demand_id,
       fn_daily_report_output_slice_rank(item.is_public_output, item.is_actual_surplus) AS slice_rank,
       item.qty,
       item.is_public_output,
       item.is_actual_surplus,
       item.plan_item_id,
       item.execution_segment_id,
       item.goods_id,
       item.color_id,
       item.unit_id,
       COALESCE(item.unit_rate, 1) AS unit_rate,
       item.line_no,
       SUM(item.qty) OVER lot AS lot_qty,
       COUNT(*) OVER lot AS lot_slice_count,
       ROW_NUMBER() OVER (lot ORDER BY fn_daily_report_output_slice_rank(item.is_public_output, item.is_actual_surplus),
                                       item.line_no NULLS LAST, item.id) AS lot_position
FROM production_daily_report_items item
WHERE NOT item.is_deleted AND item.qty > 0
WINDOW lot AS (PARTITION BY item.report_id, item.output_lot_id);
COMMENT ON VIEW v_production_output_handoff_lots IS
    'V801 (ADR-148) 实物交接批投影: 一行一份(报工行), 带批号、归属优先级、批内合计/份数/顺序; '
    '按 report_id 或 lot_id 过滤可下推到窗口里。登记、品质、点收、车间报工详情共用';

-- ---------------------------------------------------------------------------
-- 3. 登记整批守卫
-- ---------------------------------------------------------------------------
CREATE FUNCTION fn_assert_finished_arrival_whole_lot()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    lot UUID;
    current_reversal UUID;
    current_place TEXT;
BEGIN
    SELECT registration_item.reversal_id, registration_item.place_snapshot
      INTO current_reversal, current_place
    FROM production_finished_arrival_registration_items registration_item
    WHERE registration_item.id = NEW.id;
    IF NOT FOUND OR current_reversal IS NOT NULL THEN
        RETURN NULL;
    END IF;
    SELECT source.output_lot_id INTO lot
    FROM production_daily_report_items source
    WHERE source.id = NEW.source_report_item_id;
    IF lot IS NULL THEN
        RETURN NULL;
    END IF;
    -- 同一批送入仓库的份: 不能有还没登记的(整批登记), 本事务新登记的必须在同一次登记、同一库位里。
    IF EXISTS (
        SELECT 1
        FROM production_daily_report_items member
        LEFT JOIN production_finished_arrival_registration_items member_registration
          ON member_registration.source_report_item_id = member.id
         AND member_registration.reversal_id IS NULL
        LEFT JOIN production_finished_arrival_registrations registration
          ON registration.id = member_registration.registration_id
        WHERE member.output_lot_id = lot
          AND NOT member.is_deleted
          AND member.qty > 0
          AND member.destination = 'WAREHOUSE'
          AND member.execution_segment_id IS NOT NULL
          AND NOT EXISTS (
              SELECT 1 FROM production_fqc_legacy_exemptions exemption
              WHERE exemption.source_report_item_id = member.id)
          AND (member_registration.id IS NULL
               OR (registration.created_at = now()
                   AND (member_registration.registration_id <> NEW.registration_id
                        OR member_registration.place_snapshot <> current_place))))
    THEN
        RAISE EXCEPTION '同一批实物(同一报工、同一产出批次、送入仓库)的各份必须在同一次登记里一起登记到同一个仓库和库位, 请刷新后整批登记'
            USING ERRCODE = '23514';
    END IF;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_assert_finished_arrival_whole_lot
    AFTER INSERT ON production_finished_arrival_registration_items
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_assert_finished_arrival_whole_lot();

-- ---------------------------------------------------------------------------
-- 4. 品质整批决定
-- ---------------------------------------------------------------------------
CREATE TABLE production_fqc_lot_decision_commands (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    lot_id UUID NOT NULL,
    source_report_id UUID NOT NULL REFERENCES production_daily_reports(id) ON DELETE RESTRICT,
    pass_qty NUMERIC(18,4) NOT NULL,
    fail_qty NUMERIC(18,4) NOT NULL,
    disposition_code TEXT,
    reason TEXT,
    idempotency_key VARCHAR(128) NOT NULL,
    request_hash CHAR(64) NOT NULL,
    pass_all_batch_id UUID REFERENCES production_fqc_pass_all_batches(id) ON DELETE RESTRICT,
    created_by UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT production_fqc_lot_decision_actor_key_uk UNIQUE (created_by, idempotency_key),
    CONSTRAINT production_fqc_lot_decision_qty_chk
        CHECK (pass_qty >= 0 AND fail_qty >= 0 AND pass_qty + fail_qty > 0),
    CONSTRAINT production_fqc_lot_decision_disposition_chk
        CHECK ((fail_qty = 0 AND disposition_code IS NULL)
            OR (fail_qty > 0 AND disposition_code IN ('REWORK', 'SCRAP', 'REJECT'))),
    CONSTRAINT production_fqc_lot_decision_reason_chk
        CHECK (reason IS NULL OR length(btrim(reason)) BETWEEN 2 AND 1000),
    CONSTRAINT production_fqc_lot_decision_fail_reason_chk
        CHECK (fail_qty = 0 OR reason IS NOT NULL),
    CONSTRAINT production_fqc_lot_decision_key_chk
        CHECK (idempotency_key::text = btrim(idempotency_key::text)
           AND length(idempotency_key::text) BETWEEN 8 AND 128
           AND idempotency_key::text ~ '^[A-Za-z0-9._:-]+$'),
    CONSTRAINT production_fqc_lot_decision_hash_chk CHECK (request_hash ~ '^[0-9a-f]{64}$')
);
CREATE INDEX idx_production_fqc_lot_decision_lot ON production_fqc_lot_decision_commands(lot_id, created_at, id);
CREATE INDEX idx_production_fqc_lot_decision_report ON production_fqc_lot_decision_commands(source_report_id);
CREATE INDEX idx_production_fqc_lot_decision_pass_all
    ON production_fqc_lot_decision_commands(pass_all_batch_id) WHERE pass_all_batch_id IS NOT NULL;
COMMENT ON TABLE production_fqc_lot_decision_commands IS
    'V801 (ADR-148) 品质整批决定命令: 一批实物一次判定合格/不良数量, 服务端按瀑布分给批内各份(各份仍写自己的决定事件)';
CREATE TRIGGER trg_guard_production_fqc_lot_decision_append_only
    BEFORE UPDATE OR DELETE ON production_fqc_lot_decision_commands
    FOR EACH ROW EXECUTE FUNCTION fn_guard_production_fqc_append_only();

ALTER TABLE production_fqc_decision_events
    ADD COLUMN lot_command_id UUID REFERENCES production_fqc_lot_decision_commands(id) ON DELETE RESTRICT;
CREATE INDEX idx_production_fqc_decision_lot_command
    ON production_fqc_decision_events(lot_command_id) WHERE lot_command_id IS NOT NULL;
COMMENT ON COLUMN production_fqc_decision_events.lot_command_id IS
    'V801 (ADR-148) 由哪条整批决定分配出来; 分成多份的批只能经整批决定, 逐份决定只用于单份的批';

-- 逐份决定只适用于单份的批; 整批决定的事件必须属于命令所指的批。
CREATE FUNCTION fn_guard_production_fqc_lot_decision_event()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    lot UUID;
    members INTEGER;
    command_lot UUID;
BEGIN
    SELECT source.output_lot_id INTO lot
    FROM production_fqc_inspections inspection
    JOIN production_daily_report_items source ON source.id = inspection.source_report_item_id
    WHERE inspection.id = NEW.inspection_id;
    IF NEW.lot_command_id IS NOT NULL THEN
        SELECT command.lot_id INTO command_lot
        FROM production_fqc_lot_decision_commands command
        WHERE command.id = NEW.lot_command_id;
        IF command_lot IS NULL OR lot IS NULL OR command_lot <> lot THEN
            RAISE EXCEPTION '整批判定的决定只能落在这一批实物自己的各份上'
                USING ERRCODE = '23514';
        END IF;
        RETURN NEW;
    END IF;
    IF lot IS NULL THEN
        RETURN NEW;
    END IF;
    SELECT COUNT(*) INTO members
    FROM production_fqc_inspections member
    JOIN production_daily_report_items source ON source.id = member.source_report_item_id
    WHERE source.output_lot_id = lot
      AND member.status <> 'CANCELLED';
    IF members > 1 THEN
        RAISE EXCEPTION '这批实物分成了需求、计划公共备货或实际超产几份, 请按整批判定合格与不良数量, 不要逐份判定'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_production_fqc_lot_decision_event
    BEFORE INSERT ON production_fqc_decision_events
    FOR EACH ROW EXECUTE FUNCTION fn_guard_production_fqc_lot_decision_event();

-- 瀑布与守恒: 按命令前各份的待判数量重算一遍, 必须与实际写下的逐份事件完全一致;
-- 同一命令(同一次登记、同一生产计划)放行出的合格行必须在同一张成品入库单里(不跨计划合单)。
CREATE FUNCTION fn_assert_production_fqc_lot_decision()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    command production_fqc_lot_decision_commands%ROWTYPE;
    v_before NUMERIC[];
    v_pass NUMERIC[];
    v_fail NUMERIC[];
    v_expected_pass NUMERIC[];
    v_left NUMERIC;
    v_take NUMERIC;
    v_count INTEGER;
    v_index INTEGER;
    v_split INTEGER;
BEGIN
    SELECT * INTO command FROM production_fqc_lot_decision_commands WHERE id = NEW.id;
    SELECT array_agg(member.before_qty ORDER BY member.position),
           array_agg(member.pass_qty ORDER BY member.position),
           array_agg(member.fail_qty ORDER BY member.position)
      INTO v_before, v_pass, v_fail
    FROM (
        SELECT ROW_NUMBER() OVER (ORDER BY lot.slice_rank, lot.line_no NULLS LAST, lot.report_item_id) AS position,
               inspection.reported_qty - (inspection.passed_qty - COALESCE(mine.pass_qty, 0))
                                       - (inspection.failed_qty - COALESCE(mine.fail_qty, 0)) AS before_qty,
               COALESCE(mine.pass_qty, 0) AS pass_qty,
               COALESCE(mine.fail_qty, 0) AS fail_qty
        FROM v_production_output_handoff_lots lot
        JOIN production_fqc_inspections inspection
          ON inspection.source_report_item_id = lot.report_item_id
         AND inspection.status <> 'CANCELLED'
        LEFT JOIN LATERAL (
            SELECT SUM(event.pass_qty) AS pass_qty, SUM(event.fail_qty) AS fail_qty
            FROM production_fqc_decision_events event
            WHERE event.inspection_id = inspection.id AND event.lot_command_id = command.id
        ) mine ON TRUE
        WHERE lot.report_id = command.source_report_id
          AND lot.lot_id = command.lot_id
    ) member;
    v_count := COALESCE(array_length(v_before, 1), 0);
    IF v_count = 0 THEN
        RAISE EXCEPTION '整批判定找不到这一批实物的待检任务, 请刷新后重试'
            USING ERRCODE = '23514';
    END IF;
    -- 合格: 按优先级升序(需求 -> 计划公共 -> 实际超产)填满。
    v_expected_pass := array_fill(0::numeric, ARRAY[v_count]);
    v_left := command.pass_qty;
    FOR v_index IN 1..v_count LOOP
        v_take := LEAST(v_before[v_index], v_left);
        v_expected_pass[v_index] := v_take;
        v_left := v_left - v_take;
        IF v_pass[v_index] <> v_take THEN
            RAISE EXCEPTION '同一批实物的合格数要先满足需求份、再计划公共、最后实际超产; 本次分配与这个顺序不一致, 请刷新后重试'
                USING ERRCODE = '23514';
        END IF;
    END LOOP;
    IF v_left <> 0 THEN
        RAISE EXCEPTION '整批判定的合格数超过这一批实物的待检数量, 请刷新后重试'
            USING ERRCODE = '23514';
    END IF;
    -- 不良: 按优先级降序(实际超产 -> 计划公共 -> 需求)先扣。
    v_left := command.fail_qty;
    FOR v_index IN REVERSE v_count..1 LOOP
        v_take := LEAST(v_before[v_index] - v_expected_pass[v_index], v_left);
        v_left := v_left - v_take;
        IF v_fail[v_index] <> v_take THEN
            RAISE EXCEPTION '同一批实物的不良数要先扣实际超产、再扣计划公共、最后扣需求份; 本次分配与这个顺序不一致, 请刷新后重试'
                USING ERRCODE = '23514';
        END IF;
    END LOOP;
    IF v_left <> 0
       OR (SELECT COALESCE(SUM(event.pass_qty), 0) FROM production_fqc_decision_events event
           WHERE event.lot_command_id = command.id) <> command.pass_qty
       OR (SELECT COALESCE(SUM(event.fail_qty), 0) FROM production_fqc_decision_events event
           WHERE event.lot_command_id = command.id) <> command.fail_qty THEN
        RAISE EXCEPTION '整批判定的合格与不良合计和各份决定对不上, 请刷新后重试'
            USING ERRCODE = '23514';
    END IF;

    SELECT MAX(documents.document_count) INTO v_split
    FROM (
        SELECT registration_item.registration_id, plan_item.plan_id,
               COUNT(DISTINCT stock_item.doc_id) AS document_count
        FROM production_fqc_decision_events event
        JOIN production_fqc_release_allocations allocation ON allocation.decision_event_id = event.id
        JOIN production_fqc_release_commands release ON release.id = allocation.release_command_id
        JOIN stock_document_items stock_item ON stock_item.id = release.stock_document_item_id
        JOIN production_fqc_inspections inspection ON inspection.id = event.inspection_id
        JOIN production_plan_items plan_item ON plan_item.id = inspection.source_plan_item_id
        LEFT JOIN production_finished_arrival_registration_items registration_item
          ON registration_item.source_report_item_id = inspection.source_report_item_id
         AND registration_item.reversal_id IS NULL
        WHERE event.lot_command_id = command.id
        GROUP BY registration_item.registration_id, plan_item.plan_id
    ) documents;
    IF COALESCE(v_split, 0) > 1 THEN
        RAISE EXCEPTION '同一批实物一次判定合格的数量(同一生产计划)必须进同一张成品入库单'
            USING ERRCODE = '23514';
    END IF;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_assert_production_fqc_lot_decision
    AFTER INSERT ON production_fqc_lot_decision_commands
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_assert_production_fqc_lot_decision();

-- ---------------------------------------------------------------------------
-- 5. 到货登记批量命令
-- ---------------------------------------------------------------------------
ALTER TABLE warehouse_arrival_registration_commands
    ADD COLUMN batch_idempotency_key VARCHAR(128),
    ADD COLUMN batch_request_hash CHAR(64),
    ADD CONSTRAINT warehouse_arrival_registration_command_batch_chk
        CHECK ((batch_idempotency_key IS NULL AND batch_request_hash IS NULL)
            OR (batch_idempotency_key IS NOT NULL AND batch_request_hash ~ '^[0-9a-f]{64}$'
                AND batch_idempotency_key::text = btrim(batch_idempotency_key::text)
                AND length(batch_idempotency_key::text) BETWEEN 8 AND 128
                AND batch_idempotency_key::text ~ '^[A-Za-z0-9._:-]+$'));
CREATE INDEX idx_warehouse_arrival_registration_batch
    ON warehouse_arrival_registration_commands(maker_id, batch_idempotency_key)
    WHERE batch_idempotency_key IS NOT NULL;
COMMENT ON COLUMN warehouse_arrival_registration_commands.batch_idempotency_key IS
    'V801 (ADR-151 §5) 批量登记实际到货的批量键: 一个批量命令按「订货单 x 入库仓库」分成几组, 每组一条命令行共用此键';
COMMENT ON COLUMN warehouse_arrival_registration_commands.batch_request_hash IS
    'V801 批量命令整体指纹: 同一批量键换了内容 = 409, 原样重放返回原结果';

-- 批量键与批量指纹和命令身份一样不可改。
DO $arrival_guard$
DECLARE definition TEXT; needle TEXT := 'OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN';
BEGIN
    SELECT pg_get_functiondef('fn_guard_warehouse_arrival_registration_command()'::regprocedure) INTO definition;
    IF (length(definition) - length(replace(definition, needle, ''))) / length(needle) <> 1 THEN
        RAISE EXCEPTION 'V801 warehouse arrival command identity anchor changed';
    END IF;
    EXECUTE replace(definition, needle,
        'OR NEW.created_at IS DISTINCT FROM OLD.created_at'
        || E'\n       OR NEW.batch_idempotency_key IS DISTINCT FROM OLD.batch_idempotency_key'
        || E'\n       OR NEW.batch_request_hash IS DISTINCT FROM OLD.batch_request_hash THEN');
END;
$arrival_guard$;

-- ---------------------------------------------------------------------------
-- 6. 业务清空分类
-- ---------------------------------------------------------------------------
DO $reset_policy$
DECLARE definition TEXT; anchor TEXT := '(''stock_movements'', ''CLEAR'')';
BEGIN
    SELECT pg_get_functiondef('business_data_reset()'::regprocedure) INTO definition;
    IF (length(definition) - length(replace(definition, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'V801 business_data_reset policy anchor changed';
    END IF;
    EXECUTE replace(definition, anchor, anchor || E',\n            (''production_fqc_lot_decision_commands'', ''CLEAR'')');
END;
$reset_policy$;

-- ---------------------------------------------------------------------------
-- 7. MAKE 直接来源容量只数直接来源(不含公共认领)
-- ---------------------------------------------------------------------------
-- 同一批实物合成一张入库单后, 自制子件的需求份(直接来源)与计划公共份(被别的分析认领的公共来源)
-- 会在同一个事务里落进同一张成品入库单。直接来源容量守卫原来把同计划的公共认领也算进
-- 「直接来源」合计, 只是因为以前两份分两张单、两个事务才没暴露; 服务端分配(directMakeCapacity)
-- 一直只数 make_public_claim_id 为空的直接来源。这里让守卫与分配同一口径。
DO $direct_make_claims$
DECLARE definition TEXT;
    needle TEXT := E'    JOIN production_plans plan ON plan.id=segment.plan_id\n    WHERE plan.material_analysis_item_id=child.id;';
BEGIN
    SELECT pg_get_functiondef('fn_assert_preplan_direct_make_exact_peg(uuid)'::regprocedure) INTO definition;
    IF (length(definition) - length(replace(definition, needle, ''))) / length(needle) <> 1 THEN
        RAISE EXCEPTION 'V801 direct MAKE origin capacity anchor changed';
    END IF;
    EXECUTE replace(definition, needle,
        E'    JOIN production_plans plan ON plan.id=segment.plan_id\n    WHERE plan.material_analysis_item_id=child.id AND peg.make_public_claim_id IS NULL;');
END;
$direct_make_claims$;
