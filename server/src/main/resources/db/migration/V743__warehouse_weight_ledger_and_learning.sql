-- V743 仓库重量账与单重自学习 (ADR-135, 2026-09-28; 临时号, 合并时按 main 头重编号)。
--
-- 背景: 数量(数量 + 单位 + 换算率 -> 基本数量)仍是计划、采购、销售、委外、生产与财务唯一的事实;
-- 重量是仓库自己的一条平行账。仓库每个录入/确认数量的执行行都可以带实称重量, 即时库存与出入库
-- 历史按千克(kg)统一存储并换算显示, 未称就是 NULL(永远不显示成 0), 估算值带标记; 系统按
-- 「独立点数 + 称重」的记录自学习每个货品(及每个供应商)的单重, 领料按 BOM/计划点数的称重只作
-- 旁证与超发度量。重量永远不阻塞数量过账, 不自动回写 goods.m_weight。本迁移取代
-- 2026-08-30 计量审计 §5 的 NO-GO 清单与 2026-08-31 的采集偏好学习(V442 整套退役)。
--
-- 本迁移(每步失败关闭):
--  1. 重量单位: unit_measurement_profiles 删死列 canonical_unit_id / to_canonical_factor, 加
--     mass_unit_code(G/KG/T/JIN/LB/OZ, 只允许 MASS 维度), 按单位名精确匹配播种;
--     新增 fn_weight_unit_kg_factor(code) 作为库内唯一换算表(与服务端 WeightUnit 同表)。
--  2. 库存流水: stock_movements 的 weight 语义改为千克(类型不变 NUMERIC(18,4), 不碰
--     v_stock_available / v_fulfillment_workbench 视图链), 加 weight_source / balance_weight_after /
--     ledger_seq(新序列 stock_ledger_seq, 与重量调整账共用); 索引换成按记账顺序。
--  3. IQC 两个延迟校验函数按已安装定义去掉单位项(入库校验对移动重量只在 MEASURED/SLICE 时比对),
--     随后删四个死单位列, 重建被连带删掉的两条 CHECK。
--  4. 库存余额: stock_balances 加 weight_estimated, 规整存量(数量 0 -> 重量 0, 负数量 -> NULL,
--     正数量非正重量 -> NULL, 质量单位货品 -> 数量 x 系数), 加形状 CHECK, 重建覆盖索引。
--  5. 新表 stock_weight_adjustments(只追加的重量调整账, CLEAR); 退役旧对账视图, 新建按账链末行
--     对账的 v_stock_weight_reconciliation。
--  6. 采集列: stock_document_items(qty_from_weight/count_weight/book_weight)、成品到货登记行 weight、
--     委外发料行 qty_from_weight、销售出库仓库事件 line_weights(守卫按已安装定义锚点补丁)、
--     退料收仓确认 line_weights; 生产关联单据行守卫的 jsonb 排除数组补新列。
--  7. 学习三表: goods_weight_profiles(FULL)、goods_weight_observations(COLUMN_SCOPED 只审排除原因)、
--     goods_weight_estimates(派生, NONE); 观测表进货品数量来源清单。
--  8. 退役 V442: 视图、七张表、只追加拒绝函数; 数量来源清单与清空业务数据孪生函数同步。
--  9. 权限 stock:weight:manage(称重设置与单重学习管理), 挂库存详情与货品资料两个权限面,
--     授给已有 stock_doc:edit 的部门。

-- ---------------------------------------------------------------------
-- 1. 重量单位
-- ---------------------------------------------------------------------
CREATE FUNCTION fn_weight_unit_kg_factor(p_code TEXT)
RETURNS NUMERIC
LANGUAGE sql IMMUTABLE STRICT AS $$
    SELECT CASE p_code
        WHEN 'G' THEN 0.001
        WHEN 'KG' THEN 1
        WHEN 'T' THEN 1000
        WHEN 'JIN' THEN 0.5
        WHEN 'LB' THEN 0.45359237
        WHEN 'OZ' THEN 0.028349523125
    END::NUMERIC
$$;
COMMENT ON FUNCTION fn_weight_unit_kg_factor(TEXT) IS
    '重量单位编码 -> 每单位千克数(封闭目录 G/KG/T/JIN/LB/OZ, 与服务端 com.uten.imp.common.measure.WeightUnit 同表); 其它编码返回 NULL';

ALTER TABLE unit_measurement_profiles
    DROP COLUMN canonical_unit_id,
    DROP COLUMN to_canonical_factor,
    ADD COLUMN mass_unit_code VARCHAR(4),
    ADD CONSTRAINT unit_measurement_profile_mass_code_chk CHECK (
        mass_unit_code IS NULL OR mass_unit_code IN ('G', 'KG', 'T', 'JIN', 'LB', 'OZ')),
    ADD CONSTRAINT unit_measurement_profile_mass_dimension_chk CHECK (
        mass_unit_code IS NULL OR measurement_dimension = 'MASS');

COMMENT ON COLUMN unit_measurement_profiles.mass_unit_code IS
    '该业务单位等于哪种重量单位(G/KG/T/JIN/LB/OZ); 只允许 MASS 维度; NULL=不换算(允许 MASS 单位不填)。货品基本单位有编码时库存重量按数量精确换算(EXACT)';

-- 只按「去首尾空白后的单位名」精确匹配(拉丁字母不区分大小写), 不做模糊猜测; 已删除单位不播种。
INSERT INTO unit_measurement_profiles(unit_id, measurement_dimension, mass_unit_code, provenance)
SELECT unit_master.id, 'MASS', mapping.mass_unit_code, 'GOVERNED_IMPORT'
FROM units unit_master
JOIN (VALUES
        ('kg', 'KG'), ('千克', 'KG'), ('公斤', 'KG'),
        ('g', 'G'), ('克', 'G'),
        ('t', 'T'), ('吨', 'T'),
        ('斤', 'JIN'),
        ('lb', 'LB'), ('lbs', 'LB'), ('磅', 'LB'),
        ('oz', 'OZ'), ('盎司', 'OZ')
    ) mapping(unit_name, mass_unit_code)
  ON lower(btrim(unit_master.name, E' \t' || chr(12288))) = mapping.unit_name
WHERE unit_master.is_deleted = FALSE
ON CONFLICT (unit_id) DO UPDATE
SET measurement_dimension = 'MASS',
    mass_unit_code = EXCLUDED.mass_unit_code,
    provenance = 'GOVERNED_IMPORT',
    version = unit_measurement_profiles.version + 1
WHERE unit_measurement_profiles.measurement_dimension IS DISTINCT FROM 'MASS'
   OR unit_measurement_profiles.mass_unit_code IS DISTINCT FROM EXCLUDED.mass_unit_code;

-- ---------------------------------------------------------------------
-- 2. 库存流水: 千克口径 + 来源 + 余额快照 + 记账顺序号
-- ---------------------------------------------------------------------
CREATE SEQUENCE stock_ledger_seq AS BIGINT;
COMMENT ON SEQUENCE stock_ledger_seq IS
    '库存数量流水(stock_movements)与重量调整账(stock_weight_adjustments)共用的记账顺序号; 同一仓+货+色维度的写入都持有库存锁, 序号顺序即过账顺序; 不随清空业务数据重置';

-- ledger_seq 的易变默认值让本句整表重写一次: 历史行按物理顺序补号, 不触发任何行触发器
-- (IQC 关联流水的只追加守卫不受影响); 读侧按 (transaction_date, ledger_seq) 排序。
ALTER TABLE stock_movements
    ADD COLUMN weight_source VARCHAR(10),
    ADD COLUMN balance_weight_after NUMERIC(18,4),
    ADD COLUMN ledger_seq BIGINT NOT NULL DEFAULT nextval('stock_ledger_seq'),
    ADD CONSTRAINT stock_movements_weight_source_chk CHECK (
        weight_source IS NULL
        OR weight_source IN ('MEASURED', 'EXACT', 'SLICE', 'AVERAGE', 'ESTIMATE')),
    ADD CONSTRAINT stock_movements_balance_weight_after_chk CHECK (
        balance_weight_after IS NULL OR balance_weight_after >= 0);
-- 流水只追加且 IQC 关联行禁止 UPDATE, 历史带重量行无法回填来源: 以 NOT VALID 只约束新行,
-- 读侧把「有重量无来源」的历史行按 MEASURED 读。
ALTER TABLE stock_movements
    ADD CONSTRAINT stock_movements_weight_source_presence_chk CHECK (
        (weight IS NULL) = (weight_source IS NULL)) NOT VALID;

DROP INDEX idx_sm_goods_date;
CREATE INDEX idx_sm_goods_ledger
    ON stock_movements (goods_id, transaction_date DESC, ledger_seq DESC);
CREATE INDEX idx_sm_src_item
    ON stock_movements (source_doc_type, source_doc_id, source_item_id);
-- (source_doc_type, source_doc_id) 是新索引的前缀, 保留即冗余(索引卫生契约)。
DROP INDEX idx_sm_src;

COMMENT ON COLUMN stock_movements.weight IS
    '本条流水的重量(千克, 4 位小数), 方向沿用 direction, 不乘 unit_rate; NULL=不知道; 来源见 weight_source (V743/ADR-135)';
COMMENT ON COLUMN stock_movements.weight_source IS
    '重量来源: MEASURED 实称 / EXACT 质量单位按数量精确换算 / SLICE 按比例分摊已称总重 / AVERAGE 按库存均重 / ESTIMATE 按学习单重估算; weight 为 NULL 时为 NULL; V743 前有重量无来源的历史行按 MEASURED 读';
COMMENT ON COLUMN stock_movements.balance_weight_after IS
    '本条流水(含其尾差调整)之后该仓+货+色维度的库存重量(千克); NULL=未知; 与 stock_weight_adjustments.weight_after 按 ledger_seq 组成重量账链';
COMMENT ON COLUMN stock_movements.ledger_seq IS
    '记账顺序号(stock_ledger_seq, 与重量调整账共用); 应用只读不写';

-- ---------------------------------------------------------------------
-- 3. IQC 死单位列: 先按已安装定义换掉两个延迟校验函数, 再删列, 再重建被连带删除的 CHECK
-- ---------------------------------------------------------------------
DO $iqc_precondition$
DECLARE
    definition TEXT;
    needle TEXT;
BEGIN
    SELECT pg_get_functiondef('fn_validate_procurement_iqc_pass_release_value()'::regprocedure)
    INTO definition;
    FOREACH needle IN ARRAY ARRAY[
        'v_expected_weight_unit_id UUID;',
        'ELSE v_inspection.received_weight_unit_id',
        'OR NEW.released_weight_unit_id',
        'OR NEW.released_weight IS DISTINCT FROM v_expected_weight',
        'procurement_inspection_pass_release_value_chk'] LOOP
        IF position(needle IN definition) = 0 THEN
            RAISE EXCEPTION 'V743 expects the V446 IQC pass release validator, missing: %', needle;
        END IF;
    END LOOP;
    SELECT pg_get_functiondef('fn_validate_procurement_iqc_stock_in_item()'::regprocedure)
    INTO definition;
    FOREACH needle IN ARRAY ARRAY[
        'AND (NEW.weight IS NOT NULL OR NEW.weight_unit_id IS NOT NULL)',
        'IS DISTINCT FROM v_event.released_weight_unit_id',
        'OR v_movement.weight IS DISTINCT FROM NEW.weight',
        'OR v_movement.actual_weight_unit_id IS DISTINCT FROM NEW.weight_unit_id',
        'OR v_movement.warehouse_id <> NEW.warehouse_id',
        'AND value_event.known_value_local IS NOT DISTINCT FROM v_movement.amount_local)',
        'procurement_iqc_stock_in_item_identity_chk'] LOOP
        IF position(needle IN definition) = 0 THEN
            RAISE EXCEPTION 'V743 expects the V563 IQC stock-in validator, missing: %', needle;
        END IF;
    END LOOP;
END;
$iqc_precondition$;

CREATE OR REPLACE FUNCTION fn_validate_procurement_iqc_pass_release_value()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_inspection procurement_inspection_items%ROWTYPE;
    v_pass_total NUMERIC(18,4);
    v_fail_total NUMERIC(18,4);
    v_resolved_before NUMERIC(18,4);
    v_expected_amount NUMERIC(18,4);
    v_expected_weight NUMERIC(18,4);
BEGIN
    IF NEW.requires_warehouse_stock_in IS DISTINCT FROM TRUE THEN
        RETURN NEW;
    END IF;

    SELECT * INTO v_inspection
    FROM procurement_inspection_items
    WHERE id = NEW.inspection_item_id;

    SELECT COALESCE(SUM(event.base_qty) FILTER (WHERE event.action = 'PASS'), 0),
           COALESCE(SUM(event.base_qty) FILTER (WHERE event.action = 'FAIL'), 0),
           COALESCE(SUM(event.base_qty) FILTER (
               WHERE event.action IN ('PASS', 'FAIL')
                 AND (event.occurred_at, event.id) < (NEW.occurred_at, NEW.id)
           ), 0)
    INTO v_pass_total, v_fail_total, v_resolved_before
    FROM procurement_inspection_events event
    WHERE event.inspection_item_id = NEW.inspection_item_id;

    v_expected_amount := ROUND(
        v_inspection.received_amount_local
            * (v_resolved_before + NEW.base_qty)
            / v_inspection.received_base_qty,
        4
    ) - ROUND(
        v_inspection.received_amount_local
            * v_resolved_before
            / v_inspection.received_base_qty,
        4
    );

    -- V743: 到货重量统一为千克, 放行重量只按冻结的到货重量切片, 不再携带单位列。
    v_expected_weight := CASE
        WHEN v_inspection.received_weight IS NULL THEN NULL
        ELSE ROUND(
            v_inspection.received_weight
                * (v_resolved_before + NEW.base_qty)
                / v_inspection.received_base_qty,
            4
        ) - ROUND(
            v_inspection.received_weight
                * v_resolved_before
                / v_inspection.received_base_qty,
            4
        )
    END;

    IF v_inspection.id IS NULL
       OR v_pass_total IS DISTINCT FROM v_inspection.passed_base_qty
       OR v_fail_total IS DISTINCT FROM v_inspection.failed_base_qty
       OR v_pass_total + v_fail_total > v_inspection.received_base_qty
       OR NEW.released_amount_local IS DISTINCT FROM v_expected_amount
       OR NEW.released_weight IS DISTINCT FROM v_expected_weight THEN
        RAISE EXCEPTION
            'IQC PASS release value must match the frozen receipt quantity, amount and weight sequence'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'procurement_inspection_pass_release_value_chk';
    END IF;
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION fn_validate_procurement_iqc_stock_in_item()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_batch procurement_iqc_stock_in_batches%ROWTYPE;
    v_event procurement_inspection_events%ROWTYPE;
    v_inspection procurement_inspection_items%ROWTYPE;
    v_movement stock_movements%ROWTYPE;
    v_confirmed NUMERIC(18,4);
    v_confirmed_amount NUMERIC(18,4);
    v_confirmed_weight NUMERIC(18,4);
    v_confirmed_has_weight BOOLEAN;
    v_expected_weight NUMERIC(18,4);
    v_event_confirmed NUMERIC(18,4);
    v_event_confirmed_amount NUMERIC(18,4);
    v_event_confirmed_weight NUMERIC(18,4);
    v_actor_employee_id UUID;
    v_actor_active BOOLEAN;
BEGIN
    SELECT * INTO v_batch
    FROM procurement_iqc_stock_in_batches
    WHERE id = NEW.batch_id;

    SELECT user_account.employee_id,
           user_account.status = 'active' AND user_account.is_deleted = FALSE
    INTO v_actor_employee_id, v_actor_active
    FROM users user_account
    WHERE user_account.id = v_batch.actor_user_id;

    SELECT * INTO v_event
    FROM procurement_inspection_events
    WHERE id = NEW.pass_event_id;

    SELECT * INTO v_inspection
    FROM procurement_inspection_items
    WHERE id = NEW.inspection_item_id;

    SELECT * INTO v_movement
    FROM stock_movements
    WHERE id = NEW.stock_movement_id;

    SELECT COALESCE(SUM(item.base_qty), 0),
           COALESCE(SUM(item.amount_local), 0),
           COALESCE(SUM(item.weight), 0),
           BOOL_OR(item.weight IS NOT NULL)
    INTO v_confirmed, v_confirmed_amount,
         v_confirmed_weight, v_confirmed_has_weight
    FROM procurement_iqc_stock_in_batch_items item
    WHERE item.inspection_item_id = NEW.inspection_item_id;

    v_expected_weight := CASE
        WHEN v_inspection.legacy_stocked_weight IS NULL
             AND COALESCE(v_confirmed_has_weight, FALSE) = FALSE
        THEN NULL
        ELSE COALESCE(v_inspection.legacy_stocked_weight, 0)
            + v_confirmed_weight
    END;

    SELECT COALESCE(SUM(item.base_qty), 0),
           COALESCE(SUM(item.amount_local), 0),
           COALESCE(SUM(item.weight), 0)
    INTO v_event_confirmed,
         v_event_confirmed_amount,
         v_event_confirmed_weight
    FROM procurement_iqc_stock_in_batch_items item
    WHERE item.pass_event_id = NEW.pass_event_id;

    -- V743(ADR-135): 单位列已退役(重量统一千克)。库存流水可能由重量账推导出
    -- EXACT/AVERAGE/ESTIMATE 重量, 所以只有流水重量来自实称或本批切片时才要求与本批切片一致。
    IF v_batch.id IS NULL
       OR v_event.id IS NULL
       OR v_inspection.id IS NULL
       OR v_movement.id IS NULL
       OR v_event.action <> 'PASS'
       OR v_event.requires_warehouse_stock_in IS DISTINCT FROM TRUE
       OR v_event.base_qty <= 0
       OR NEW.expected_remaining_base_qty IS DISTINCT FROM
            v_event.base_qty - (SELECT COALESCE(SUM(prior.base_qty),0)
        FROM procurement_iqc_stock_in_batch_items prior
        WHERE prior.pass_event_id=NEW.pass_event_id AND prior.stock_sequence<NEW.stock_sequence)
       OR v_event.released_amount_local IS NULL
       OR v_event_confirmed_amount IS DISTINCT FROM ROUND(
            v_event.released_amount_local * v_event_confirmed / v_event.base_qty,
            4)
       OR (
            v_event.released_weight IS NULL
            AND NEW.weight IS NOT NULL
       )
       OR (
            v_event.released_weight IS NOT NULL
            AND (
                NEW.weight IS NULL
                OR v_event_confirmed_weight IS DISTINCT FROM ROUND(
                    v_event.released_weight
                        * v_event_confirmed / v_event.base_qty,
                    4)
            )
       )
       OR v_actor_active IS DISTINCT FROM TRUE
       OR v_actor_employee_id IS DISTINCT FROM v_batch.actor_employee_id
       OR v_event.inspection_item_id <> NEW.inspection_item_id
       OR v_event_confirmed > v_event.base_qty
       OR v_batch.receipt_type <> v_inspection.receipt_type
       OR v_batch.receipt_id <> v_inspection.receipt_id
       OR v_inspection.status = 'REVERSED'
       OR NEW.warehouse_id IS NULL
       OR v_inspection.goods_id <> NEW.goods_id
       OR v_inspection.color_id IS DISTINCT FROM NEW.color_id
       OR v_movement.source_doc_type
            <> v_batch.receipt_type || '_RECEIPT'
       OR v_movement.source_doc_id <> v_batch.receipt_id
       OR v_movement.source_item_id <> NEW.id
       OR v_movement.warehouse_id <> NEW.warehouse_id
       OR v_movement.goods_id <> NEW.goods_id
       OR v_movement.color_id IS DISTINCT FROM NEW.color_id
       OR v_movement.direction <> 1
       OR v_movement.qty IS DISTINCT FROM NEW.base_qty
       OR NOT EXISTS(SELECT 1 FROM stock_value_events value_event WHERE value_event.movement_id=NEW.stock_movement_id
                AND value_event.source_item_id=NEW.id AND value_event.operation='POSITION_STORE'
                AND value_event.known_value_local IS NOT DISTINCT FROM v_movement.amount_local)
       OR (NEW.weight IS NOT NULL
           AND v_movement.weight_source IS NOT NULL
           AND v_movement.weight_source IN ('MEASURED', 'SLICE')
           AND v_movement.weight IS DISTINCT FROM NEW.weight)
       OR v_inspection.warehouse_stocked_base_qty
            IS DISTINCT FROM v_inspection.legacy_stocked_base_qty + v_confirmed
       OR v_inspection.warehouse_stocked_amount_local
            IS DISTINCT FROM v_inspection.legacy_stocked_amount_local
                + v_confirmed_amount
       OR v_inspection.warehouse_stocked_weight
            IS DISTINCT FROM v_expected_weight THEN
        RAISE EXCEPTION 'invalid procurement IQC warehouse stock-in identity or quantity'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'procurement_iqc_stock_in_item_identity_chk';
    END IF;
    RETURN NEW;
END;
$function$;

-- DROP COLUMN 会连带删掉引用它的外键与 CHECK(包括多列 CHECK), 下面两条业务不变式随后按原名重建。
ALTER TABLE procurement_inspection_items DROP COLUMN received_weight_unit_id;
ALTER TABLE procurement_inspection_events DROP COLUMN released_weight_unit_id;
ALTER TABLE procurement_iqc_stock_in_batch_items DROP COLUMN weight_unit_id;
ALTER TABLE stock_movements DROP COLUMN actual_weight_unit_id;

ALTER TABLE procurement_inspection_events
    ADD CONSTRAINT procurement_inspection_events_stock_in_flag_chk CHECK (
        (requires_warehouse_stock_in = FALSE
            AND released_amount_local IS NULL
            AND released_weight IS NULL)
        OR (requires_warehouse_stock_in = TRUE
            AND action = 'PASS'
            AND actor_employee_id IS NOT NULL
            AND released_amount_local IS NOT NULL
            AND released_amount_local >= 0
            AND (released_weight IS NULL OR released_weight >= 0)));
ALTER TABLE procurement_iqc_stock_in_batch_items
    ADD CONSTRAINT procurement_iqc_stock_in_item_weight_chk CHECK (
        weight IS NULL OR weight >= 0);

COMMENT ON COLUMN procurement_inspection_items.received_weight IS
    '到货实称总重(千克, 4 位小数); NULL=未称; 放行与入库按数量比例切片 (V743 起单位列退役)';
COMMENT ON COLUMN procurement_inspection_events.released_weight IS
    '本次放行按到货重量切出的千克数; NULL=到货未称';
COMMENT ON COLUMN procurement_iqc_stock_in_batch_items.weight IS
    '本批确认入库按放行重量切出的千克数; NULL=未称; 过账为 SLICE 重量';

-- ---------------------------------------------------------------------
-- 4. 库存余额: 估算标记 + 规整存量 + 形状 CHECK + 覆盖索引
-- ---------------------------------------------------------------------
ALTER TABLE stock_balances
    ADD COLUMN weight_estimated BOOLEAN NOT NULL DEFAULT FALSE;

DROP INDEX idx_stock_balances_goods_cover;
CREATE INDEX idx_stock_balances_goods_cover
    ON stock_balances (goods_id)
    INCLUDE (warehouse_id, color_id, qty, weight, weight_estimated, last_movement_date);

-- 余额上的延迟约束触发器(价值池核对)对只改重量的行天然通过; 这里临时改为立即执行, 让规整语句
-- 的触发事件当场处理完, 下面的 ADD CONSTRAINT 才不会撞上「表上还有待处理触发事件」。
SET CONSTRAINTS trg_stock_balance_managed_value IMMEDIATE;
UPDATE stock_balances balance
SET weight = normalized.weight,
    weight_estimated = FALSE
FROM (
    SELECT candidate.id,
           CASE
               WHEN candidate.qty = 0 THEN 0::NUMERIC
               WHEN candidate.qty < 0 THEN NULL
               WHEN profile.mass_unit_code IS NOT NULL
                   THEN NULLIF(round(candidate.qty * fn_weight_unit_kg_factor(profile.mass_unit_code), 4), 0)
               WHEN candidate.weight <= 0 THEN NULL
               ELSE candidate.weight
           END AS weight
    FROM stock_balances candidate
    LEFT JOIN goods material ON material.id = candidate.goods_id
    LEFT JOIN unit_measurement_profiles profile ON profile.unit_id = material.unit_id
) normalized
WHERE normalized.id = balance.id
  AND (balance.weight IS DISTINCT FROM normalized.weight OR balance.weight_estimated);
SET CONSTRAINTS trg_stock_balance_managed_value DEFERRED;

ALTER TABLE stock_balances
    ADD CONSTRAINT stock_balances_weight_shape_chk CHECK (
        weight IS NULL
        OR (qty = 0 AND weight = 0)
        OR (qty > 0 AND weight > 0));

COMMENT ON COLUMN stock_balances.weight IS
    '当前库存重量(千克, 仓+货+色); NULL=不知道; 数量为 0 时为 0, 数量为负时为 NULL; 质量单位货品=数量 x 系数 (V743/ADR-135)';
COMMENT ON COLUMN stock_balances.weight_estimated IS
    '库存重量是否含估算成分(按库存均重/学习单重推算的入库或起算); 盘点定重、人工核重后清除';

-- ---------------------------------------------------------------------
-- 5. 重量调整账 + 新对账视图
-- ---------------------------------------------------------------------
CREATE TABLE stock_weight_adjustments (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    ledger_seq              BIGINT NOT NULL DEFAULT nextval('stock_ledger_seq'),
    transaction_date        TIMESTAMPTZ NOT NULL,
    warehouse_id            UUID NOT NULL REFERENCES warehouses(id),
    goods_id                UUID NOT NULL REFERENCES goods(id),
    color_id                UUID REFERENCES colors(id),
    kind                    VARCHAR(10) NOT NULL,
    weight_before           NUMERIC(18,4),
    weight_after            NUMERIC(18,4),
    delta_kg                NUMERIC(18,4),
    movement_id             UUID,
    reverses_adjustment_id  UUID REFERENCES stock_weight_adjustments(id),
    source_doc_type         TEXT,
    source_doc_id           UUID,
    source_item_id          UUID,
    reason                  TEXT,
    idempotency_key         TEXT UNIQUE,
    created_by              UUID,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT stock_weight_adjustment_kind_chk CHECK (
        kind IN ('ANCHOR', 'RESIDUAL', 'COUNT', 'MANUAL', 'REVERSAL')),
    CONSTRAINT stock_weight_adjustment_after_chk CHECK (
        (weight_after IS NOT NULL OR kind = 'REVERSAL')
        AND (weight_after IS NULL OR weight_after >= 0)),
    CONSTRAINT stock_weight_adjustment_delta_chk CHECK (
        delta_kg IS NOT DISTINCT FROM weight_after - weight_before),
    CONSTRAINT stock_weight_adjustment_reversal_chk CHECK (
        (kind = 'REVERSAL') = (reverses_adjustment_id IS NOT NULL)),
    CONSTRAINT stock_weight_adjustment_manual_reason_chk CHECK (
        kind <> 'MANUAL' OR NULLIF(btrim(reason), '') IS NOT NULL)
);
CREATE INDEX idx_stock_weight_adjustments_goods_ledger
    ON stock_weight_adjustments (goods_id, transaction_date DESC, ledger_seq DESC);
CREATE INDEX idx_stock_weight_adjustments_dimension
    ON stock_weight_adjustments (warehouse_id, goods_id, color_id, ledger_seq DESC);

COMMENT ON TABLE stock_weight_adjustments IS
    '只改重量的库存账行(不动数量与价值; 只追加, 永不 UPDATE): ANCHOR 重量起算 / RESIDUAL 重量尾差调整 / COUNT 盘点定重 / MANUAL 人工核重 / REVERSAL 撤销盘点重量; 与 stock_movements 按 ledger_seq 组成同一条重量账链 (V743/ADR-135)';
COMMENT ON COLUMN stock_weight_adjustments.weight_before IS '调整前该维度库存重量(千克); NULL=之前不知道';
COMMENT ON COLUMN stock_weight_adjustments.weight_after IS '调整后该维度库存重量(千克); 只有撤销后仍不知道重量的 REVERSAL 为 NULL';
COMMENT ON COLUMN stock_weight_adjustments.delta_kg IS '= weight_after - weight_before, 两者有一个不知道时为 NULL';
COMMENT ON COLUMN stock_weight_adjustments.movement_id IS '触发本行的库存流水(软引用, ANCHOR/RESIDUAL)';
COMMENT ON COLUMN stock_weight_adjustments.idempotency_key IS '人工核重的幂等键(同键重放返回原结果)';

SELECT fn_audit_track_table('stock_weight_adjustments', 'NONE', 'data_change', false);

DROP VIEW v_stock_weight_reconciliation;

CREATE VIEW v_stock_weight_reconciliation AS
SELECT balance.warehouse_id,
       balance.goods_id,
       balance.color_id,
       balance.qty,
       balance.weight AS balance_weight,
       balance.weight_estimated,
       exact_mass.kg_per_unit AS exact_kg_per_unit,
       latest.row_kind AS last_ledger_row_kind,
       latest.row_id AS last_ledger_row_id,
       latest.ledger_seq AS last_ledger_seq,
       latest.weight_after AS ledger_weight_after,
       expected.weight AS expected_weight,
       CASE
           WHEN exact_mass.kg_per_unit IS NOT NULL THEN
               CASE WHEN balance.weight IS NOT DISTINCT FROM expected.weight
                    THEN 'RECONCILED' ELSE 'DRIFT' END
           WHEN balance.weight IS NULL OR latest.weight_after IS NULL THEN 'UNKNOWN'
           WHEN balance.weight = latest.weight_after THEN 'RECONCILED'
           ELSE 'DRIFT'
       END AS reconciliation_status,
       balance.weight - expected.weight AS weight_difference
FROM stock_balances balance
LEFT JOIN goods material ON material.id = balance.goods_id
LEFT JOIN LATERAL (
    SELECT fn_weight_unit_kg_factor(profile.mass_unit_code) AS kg_per_unit
    FROM unit_measurement_profiles profile
    WHERE profile.unit_id = material.unit_id
      AND profile.mass_unit_code IS NOT NULL
) exact_mass ON TRUE
LEFT JOIN LATERAL (
    SELECT candidate.row_kind, candidate.row_id, candidate.ledger_seq, candidate.weight_after
    FROM (
        (SELECT 'M'::TEXT AS row_kind, movement.id AS row_id, movement.ledger_seq,
                movement.balance_weight_after AS weight_after
         FROM stock_movements movement
         WHERE movement.goods_id = balance.goods_id
           AND movement.warehouse_id = balance.warehouse_id
           AND movement.color_id IS NOT DISTINCT FROM balance.color_id
         ORDER BY movement.ledger_seq DESC
         LIMIT 1)
        UNION ALL
        (SELECT 'W'::TEXT, adjustment.id, adjustment.ledger_seq, adjustment.weight_after
         FROM stock_weight_adjustments adjustment
         WHERE adjustment.goods_id = balance.goods_id
           AND adjustment.warehouse_id = balance.warehouse_id
           AND adjustment.color_id IS NOT DISTINCT FROM balance.color_id
         ORDER BY adjustment.ledger_seq DESC
         LIMIT 1)
    ) candidate
    ORDER BY candidate.ledger_seq DESC
    LIMIT 1
) latest ON TRUE
CROSS JOIN LATERAL (
    SELECT CASE
               WHEN exact_mass.kg_per_unit IS NULL THEN latest.weight_after
               WHEN balance.qty > 0 THEN NULLIF(round(balance.qty * exact_mass.kg_per_unit, 4), 0)
               WHEN balance.qty = 0 THEN 0::NUMERIC
           END AS weight
) expected;

COMMENT ON VIEW v_stock_weight_reconciliation IS
    '库存重量对账(V743/ADR-135): 每个余额维度的重量与重量账链末行(流水 balance_weight_after 或调整 weight_after, 取最大 ledger_seq)比对; 质量单位货品与数量 x 系数比对。RECONCILED 一致 / DRIFT 不一致 / UNKNOWN 重量未知或账链尚未起算';

-- ---------------------------------------------------------------------
-- 6. 仓库采集列
-- ---------------------------------------------------------------------
-- 千克重量表(销售出库仓库事件 / 退料收仓确认): 键=明细 UUID, 值=非负千克数(最多 4 位小数)。
CREATE FUNCTION fn_weight_kg_map_is_valid(p_map JSONB)
RETURNS BOOLEAN
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    entry RECORD;
    kilograms NUMERIC;
BEGIN
    IF p_map IS NULL OR jsonb_typeof(p_map) <> 'object' THEN
        RETURN FALSE;
    END IF;
    FOR entry IN SELECT * FROM jsonb_each(p_map) LOOP
        IF entry.key !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
           OR jsonb_typeof(entry.value) <> 'number' THEN
            RETURN FALSE;
        END IF;
        kilograms := (entry.value #>> '{}')::NUMERIC;
        IF kilograms < 0 OR kilograms >= 100000000000000 OR kilograms <> round(kilograms, 4) THEN
            RETURN FALSE;
        END IF;
    END LOOP;
    RETURN TRUE;
END;
$$;
COMMENT ON FUNCTION fn_weight_kg_map_is_valid(JSONB) IS
    '千克重量表形状校验: JSON 对象, 键为明细 UUID, 值为非负数且最多 4 位小数 (V743/ADR-135)';

ALTER TABLE stock_document_items
    ADD COLUMN qty_from_weight BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN count_weight NUMERIC(18,4),
    ADD COLUMN book_weight NUMERIC(18,4),
    ADD CONSTRAINT stock_document_item_count_weight_chk CHECK (count_weight IS NULL OR count_weight >= 0),
    ADD CONSTRAINT stock_document_item_book_weight_chk CHECK (book_weight IS NULL OR book_weight >= 0);
COMMENT ON COLUMN stock_document_items.weight IS
    '本行实称重量(千克, 4 位小数); NULL=未称; 生产关联单据行不写入(每轮实称只在流水上)';
COMMENT ON COLUMN stock_document_items.qty_from_weight IS
    '数量是否由称重计数推算(按称重改数量); 为真时该行不进单重学习';
COMMENT ON COLUMN stock_document_items.count_weight IS
    '盘点实盘重量(千克); NULL=只盘数量; 审核时记盘点定重(COUNT)';
COMMENT ON COLUMN stock_document_items.book_weight IS
    '盘点保存时的账面重量快照(千克), 只用于显示';

ALTER TABLE production_finished_arrival_registration_items
    ADD COLUMN weight NUMERIC(18,4),
    ADD CONSTRAINT production_finished_arrival_item_weight_chk CHECK (weight IS NULL OR weight > 0);
COMMENT ON COLUMN production_finished_arrival_registration_items.weight IS
    '成品到货登记时的实称重量(千克); NULL=未称; 只在插入时写入, 成品入库草稿按比例分摊';

ALTER TABLE subcontract_material_issue_items
    ADD COLUMN qty_from_weight BOOLEAN NOT NULL DEFAULT FALSE;
COMMENT ON COLUMN subcontract_material_issue_items.qty_from_weight IS
    '委外发料数量是否由称重计数推算; 为真时不进单重学习';

ALTER TABLE sales_shipment_warehouse_events
    ADD COLUMN line_weights JSONB NOT NULL DEFAULT '{}'::JSONB,
    ADD CONSTRAINT sales_shipment_warehouse_weights_shape_chk CHECK (fn_weight_kg_map_is_valid(line_weights));
COMMENT ON COLUMN sales_shipment_warehouse_events.line_weights IS
    '出库确认时各出货明细的实称重量(千克): 明细 UUID -> 千克; 只有 SHIPPED 事件可以非空; 销售出库流水按它记 MEASURED';

ALTER TABLE production_material_return_receiving_confirmations
    ADD COLUMN line_weights JSONB NOT NULL DEFAULT '{}'::JSONB,
    ADD CONSTRAINT production_material_return_receiving_weights_shape_chk CHECK (fn_weight_kg_map_is_valid(line_weights));
COMMENT ON COLUMN production_material_return_receiving_confirmations.line_weights IS
    '退料收仓确认时各退料明细的实称重量(千克): 明细 UUID -> 千克; 退料入库流水按它记 MEASURED';

-- 销售出库证据守卫(已安装定义, 单行锚点补丁): 非 SHIPPED 事件不许带重量; SHIPPED 事件的重量键必须是本单明细。
DO $picking_evidence$
DECLARE
    definition TEXT;
    status_needle TEXT := 'IF NEW.line_stock_places<>''{}''::jsonb OR NEW.line_warehouses<>''{}''::jsonb THEN';
    loop_anchor TEXT := 'FOR entry IN SELECT * FROM jsonb_each(NEW.line_stock_places) LOOP';
BEGIN
    SELECT pg_get_functiondef('fn_guard_sales_shipment_picking_evidence()'::regprocedure) INTO definition;
    IF (length(definition) - length(replace(definition, status_needle, ''))) / length(status_needle) <> 1
       OR (length(definition) - length(replace(definition, loop_anchor, ''))) / length(loop_anchor) <> 1
       OR position('line_weights' IN definition) > 0 THEN
        RAISE EXCEPTION 'V743 cannot patch fn_guard_sales_shipment_picking_evidence safely';
    END IF;
    definition := replace(definition, status_needle,
        'IF NEW.line_stock_places<>''{}''::jsonb OR NEW.line_warehouses<>''{}''::jsonb OR NEW.line_weights<>''{}''::jsonb THEN');
    definition := replace(definition, loop_anchor,
        'IF NOT fn_weight_kg_map_is_valid(NEW.line_weights) THEN' || E'\n'
        || '        RAISE EXCEPTION ''Outbound line weights require exact shipment item UUIDs and non-negative kilograms'' USING ERRCODE=''23514'';' || E'\n'
        || '    END IF;' || E'\n'
        || '    FOR entry IN SELECT * FROM jsonb_each(NEW.line_weights) LOOP' || E'\n'
        || '        IF NOT EXISTS(SELECT 1 FROM sales_shipment_items item WHERE item.id=entry.key::uuid' || E'\n'
        || '            AND item.shipment_id=document.id AND NOT item.is_deleted) THEN' || E'\n'
        || '            RAISE EXCEPTION ''Outbound line weight does not belong to this shipment'' USING ERRCODE=''23514'';' || E'\n'
        || '        END IF;' || E'\n'
        || '    END LOOP;' || E'\n'
        || '    ' || loop_anchor);
    EXECUTE definition;
END;
$picking_evidence$;

-- 生产关联单据行守卫(已安装定义, 单行锚点补丁): 成品入库确认通道的两个 jsonb 排除数组补上新列。
-- 新列不在 _upd 触发器的 WHEN 列清单里, 其它通道只改新列时守卫不起跳(我们的代码不会在生产关联行上写它们)。
DO $production_linked_item$
DECLARE
    definition TEXT;
    needle TEXT := '''weight'',''gift_qty'',''updated_at'',''updated_by''])';
    patched TEXT := '''weight'',''gift_qty'',''updated_at'',''updated_by'',''qty_from_weight'',''count_weight'',''book_weight''])';
BEGIN
    SELECT pg_get_functiondef('fn_guard_production_linked_stock_document_item()'::regprocedure) INTO definition;
    IF (length(definition) - length(replace(definition, needle, ''))) / length(needle) <> 2
       OR position('qty_from_weight' IN definition) > 0 THEN
        RAISE EXCEPTION 'V743 cannot extend fn_guard_production_linked_stock_document_item safely';
    END IF;
    EXECUTE replace(definition, needle, patched);
END;
$production_linked_item$;

-- ---------------------------------------------------------------------
-- 7. 单重学习三表
-- ---------------------------------------------------------------------
CREATE TABLE goods_weight_profiles (
    goods_id                UUID PRIMARY KEY REFERENCES goods(id),
    default_tare_kg         NUMERIC(20,6),
    tolerance_pct           NUMERIC(6,3),
    piece_cv_pct            NUMERIC(6,3),
    manual_unit_weight_kg   NUMERIC(24,12),
    manual_unit_id          UUID REFERENCES units(id),
    manual_reason           TEXT,
    manual_set_by           UUID,
    manual_set_at           TIMESTAMPTZ,
    learning_enabled        BOOLEAN NOT NULL DEFAULT TRUE,
    regime_mode             VARCHAR(6) NOT NULL DEFAULT 'AUTO',
    manual_regime_start_at  TIMESTAMPTZ,
    version                 BIGINT NOT NULL DEFAULT 0,
    updated_by              UUID,
    updated_at              TIMESTAMPTZ DEFAULT now(),
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT goods_weight_profile_tare_chk CHECK (default_tare_kg IS NULL OR default_tare_kg >= 0),
    CONSTRAINT goods_weight_profile_tolerance_chk CHECK (
        tolerance_pct IS NULL OR (tolerance_pct > 0 AND tolerance_pct <= 100)),
    CONSTRAINT goods_weight_profile_piece_cv_chk CHECK (
        piece_cv_pct IS NULL OR (piece_cv_pct >= 0 AND piece_cv_pct <= 100)),
    CONSTRAINT goods_weight_profile_manual_chk CHECK (
        (manual_unit_weight_kg IS NULL AND manual_unit_id IS NULL)
        OR (manual_unit_weight_kg > 0 AND manual_unit_id IS NOT NULL)),
    CONSTRAINT goods_weight_profile_regime_mode_chk CHECK (regime_mode IN ('AUTO', 'MANUAL')),
    CONSTRAINT goods_weight_profile_version_chk CHECK (version >= 0)
);
CREATE TRIGGER trg_set_updated_at_goods_weight_profiles
    BEFORE UPDATE ON goods_weight_profiles
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();
COMMENT ON TABLE goods_weight_profiles IS
    '货品称重设置(仓库设置, 随主档保留): 默认皮重、核对容差、单件离散、人工单重、学习开关与批次切换方式 (V743/ADR-135)';
COMMENT ON COLUMN goods_weight_profiles.tolerance_pct IS '核对容差百分比; NULL=系统默认 3.0';
COMMENT ON COLUMN goods_weight_profiles.piece_cv_pct IS '单件重量离散百分比; NULL=系统默认 2.0';
COMMENT ON COLUMN goods_weight_profiles.manual_unit_weight_kg IS '人工设定的单重(千克/基本单位)';
COMMENT ON COLUMN goods_weight_profiles.manual_unit_id IS '设定人工单重时货品基本单位快照; 与当前 goods.unit_id 不同则人工单重失效';
COMMENT ON COLUMN goods_weight_profiles.regime_mode IS 'AUTO 自动识别换批(单重突变即切段) / MANUAL 只按 manual_regime_start_at 切段';

SELECT fn_audit_track_table('goods_weight_profiles', 'FULL', 'data_change', false);

CREATE TABLE goods_weight_observations (
    id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    goods_id                    UUID NOT NULL REFERENCES goods(id),
    color_id                    UUID REFERENCES colors(id),
    warehouse_id                UUID REFERENCES warehouses(id),
    supplier_id                 UUID REFERENCES suppliers(id),
    counterpart_kind            VARCHAR(12),
    counterpart_id              UUID,
    source_kind                 VARCHAR(10) NOT NULL,
    role                        VARCHAR(9) NOT NULL,
    qty_base                    NUMERIC(18,4) NOT NULL,
    weight_kg                   NUMERIC(20,6) NOT NULL,
    gross_kg                    NUMERIC(20,6),
    tare_kg                     NUMERIC(20,6),
    qty_eps                     NUMERIC(8,5),
    observed_at                 TIMESTAMPTZ NOT NULL,
    source_doc_type             TEXT,
    source_doc_id               UUID,
    source_item_id              UUID,
    movement_id                 UUID,
    capture_key                 TEXT NOT NULL,
    stage                       VARCHAR(8) NOT NULL DEFAULT 'ACTIVE',
    reversed_at                 TIMESTAMPTZ,
    excluded_reason             VARCHAR(16),
    excluded_by                 UUID,
    excluded_at                 TIMESTAMPTZ,
    expected_unit_weight_kg     NUMERIC(24,12),
    expected_weight_kg          NUMERIC(20,6),
    deviation_pct               NUMERIC(9,4),
    alert_level                 VARCHAR(5) NOT NULL DEFAULT 'NONE',
    estimate_basis_used         VARCHAR(12),
    estimate_tier_used          VARCHAR(6),
    tolerance_pct_used          NUMERIC(6,3),
    new_regime                  BOOLEAN NOT NULL DEFAULT FALSE,
    remark                      TEXT,
    recorded_by                 UUID,
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT goods_weight_observation_capture_key_uk UNIQUE (capture_key),
    CONSTRAINT goods_weight_observation_kind_chk CHECK (source_kind IN (
        'SAMPLE', 'COUNT', 'RECEIPT', 'FINISHED', 'OTHER_IN',
        'DRAW', 'ISSUE', 'SHIPMENT', 'RETURN', 'OTHER_OUT', 'TRANSFER')),
    CONSTRAINT goods_weight_observation_role_chk CHECK (role = CASE
        WHEN source_kind IN ('SAMPLE', 'COUNT', 'RECEIPT', 'FINISHED', 'OTHER_IN') THEN 'REFERENCE'
        ELSE 'CHECK' END),
    CONSTRAINT goods_weight_observation_supplier_chk CHECK (
        supplier_id IS NULL OR source_kind IN ('RECEIPT', 'SAMPLE', 'OTHER_IN')),
    CONSTRAINT goods_weight_observation_counterpart_chk CHECK (
        (counterpart_kind IS NULL OR counterpart_kind IN ('WORKSHOP', 'SUBCONTRACTOR', 'CLIENT', 'SUPPLIER'))
        AND (counterpart_kind IS NULL) = (counterpart_id IS NULL)),
    CONSTRAINT goods_weight_observation_amount_chk CHECK (
        qty_base > 0 AND weight_kg > 0
        AND (gross_kg IS NULL OR gross_kg >= 0)
        AND (tare_kg IS NULL OR tare_kg >= 0)
        AND (qty_eps IS NULL OR qty_eps >= 0)),
    CONSTRAINT goods_weight_observation_stage_chk CHECK (stage IN ('ACTIVE', 'REVERSED')),
    CONSTRAINT goods_weight_observation_excluded_chk CHECK (
        excluded_reason IS NULL OR excluded_reason IN ('MANUAL_EXCLUDE', 'ECHO', 'QTY_ECHO')),
    CONSTRAINT goods_weight_observation_alert_chk CHECK (alert_level IN ('NONE', 'WARN', 'ALERT')),
    CONSTRAINT goods_weight_observation_basis_chk CHECK (
        estimate_basis_used IS NULL
        OR estimate_basis_used IN ('EXACT', 'MANUAL', 'LEARNED', 'MASTER_PRIOR', 'NONE')),
    CONSTRAINT goods_weight_observation_tier_chk CHECK (
        estimate_tier_used IS NULL OR estimate_tier_used IN ('GREEN', 'YELLOW', 'RED'))
);
CREATE INDEX idx_goods_weight_observations_goods_time
    ON goods_weight_observations (goods_id, observed_at DESC);
CREATE INDEX idx_goods_weight_observations_alerts
    ON goods_weight_observations (observed_at DESC) WHERE alert_level <> 'NONE';
CREATE INDEX idx_goods_weight_observations_supplier_time
    ON goods_weight_observations (supplier_id, observed_at DESC) WHERE supplier_id IS NOT NULL;
CREATE INDEX idx_goods_weight_observations_source_item
    ON goods_weight_observations (source_doc_type, source_item_id);

COMMENT ON TABLE goods_weight_observations IS
    '单重学习的称重观测(随主档保留; 来源单据是软引用, 清空业务数据后显示「来源单据已清空」): REFERENCE 类(称样/盘点/到货/成品登记/其它入库)训练单重, CHECK 类(领料/委外发料/出货/退料/其它出库/调拨)只做核对与超发度量 (V743/ADR-135)';
COMMENT ON COLUMN goods_weight_observations.qty_base IS '独立点数的数量(货品基本单位)';
COMMENT ON COLUMN goods_weight_observations.weight_kg IS '净重(千克)';
COMMENT ON COLUMN goods_weight_observations.capture_key IS '采集键(<来源类别>:<明细或流水 id>), 同一次称重只记一次';
COMMENT ON COLUMN goods_weight_observations.excluded_reason IS 'MANUAL_EXCLUDE 人工排除 / ECHO 重量就是按单重估出来的 / QTY_ECHO 数量就是按重量推算的; 排除的观测不进学习';
COMMENT ON COLUMN goods_weight_observations.expected_weight_kg IS '记录时(加入本条之前)按当时单重推算的应称重量快照';

-- 只审计人为决定(排除/恢复); 插入由采集自动产生, 行本身就是留痕。
SELECT fn_audit_track_table('goods_weight_observations', 'COLUMN_SCOPED', 'data_change', false,
    ARRAY['excluded_reason'], false);

CREATE TABLE goods_weight_estimates (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    goods_id                UUID NOT NULL REFERENCES goods(id),
    supplier_id             UUID REFERENCES suppliers(id),
    evidence                VARCHAR(10),
    log_mean                DOUBLE PRECISION,
    unit_weight_kg          NUMERIC(24,12),
    log_se                  DOUBLE PRECISION,
    tau_lot                 DOUBLE PRECISION,
    tau_between             DOUBLE PRECISION,
    shrink_weight           DOUBLE PRECISION,
    raw_log_mean            DOUBLE PRECISION,
    n_obs                   INT,
    n_ref                   INT,
    n_inliers               INT,
    n_eff                   DOUBLE PRECISION,
    rel_half_width          DOUBLE PRECISION,
    tier                    VARCHAR(6),
    draw_bias_log           DOUBLE PRECISION,
    draw_bias_se            DOUBLE PRECISION,
    n_draw                  INT,
    label_bias_log          DOUBLE PRECISION,
    label_bias_se           DOUBLE PRECISION,
    regime_started_at       TIMESTAMPTZ,
    regime_changed_at       TIMESTAMPTZ,
    last_observed_at        TIMESTAMPTZ,
    as_of                   TIMESTAMPTZ,
    outliers                JSONB NOT NULL DEFAULT '[]'::JSONB,
    suggested_sample_size   INT,
    algorithm_version       SMALLINT,
    computed_at             TIMESTAMPTZ,
    CONSTRAINT goods_weight_estimate_goods_supplier_uk UNIQUE NULLS NOT DISTINCT (goods_id, supplier_id),
    CONSTRAINT goods_weight_estimate_evidence_chk CHECK (
        evidence IS NULL OR evidence IN ('REFERENCE', 'DRAW_ONLY', 'CONFLICT')),
    CONSTRAINT goods_weight_estimate_tier_chk CHECK (tier IS NULL OR tier IN ('GREEN', 'YELLOW', 'RED')),
    CONSTRAINT goods_weight_estimate_unit_weight_chk CHECK (unit_weight_kg IS NULL OR unit_weight_kg > 0),
    CONSTRAINT goods_weight_estimate_outliers_chk CHECK (jsonb_typeof(outliers) = 'array')
);
COMMENT ON TABLE goods_weight_estimates IS
    '单重学习结果(派生, 可由观测重算; 随主档保留): supplier_id 为 NULL 的是货品总体行, 其余为分供应商行; 只在货品有至少一条有效观测时存在 (V743/ADR-135)';
COMMENT ON COLUMN goods_weight_estimates.unit_weight_kg IS '学习单重(千克/基本单位)';

SELECT fn_audit_track_table('goods_weight_estimates', 'NONE', 'data_change', false);

-- ---------------------------------------------------------------------
-- 8. 退役 V442 采集偏好学习
-- ---------------------------------------------------------------------
DROP VIEW v_measurement_capture_profile_resolution;
DROP TABLE measurement_capture_decision_events, measurement_capture_evidence,
    measurement_capture_line_snapshots, measurement_capture_profiles,
    legacy_measurement_exceptions, legacy_measurement_profile_snapshots,
    legacy_measurement_source_registry;
DROP FUNCTION fn_reject_measurement_append_only_mutation();

-- 货品数量来源清单(已安装定义, 单行锚点补丁): 去掉三张退役表, 加入称重观测(按基本单位记数量)。
DO $quantity_sources$
DECLARE
    definition TEXT;
    needle TEXT;
    anchor TEXT := '(''goods_bom_items'', ARRAY[''component_goods_id'',''goods_id''], ''true''),';
BEGIN
    SELECT pg_get_functiondef('fn_goods_quantity_reference_sources()'::regprocedure) INTO definition;
    FOREACH needle IN ARRAY ARRAY[
        '(''legacy_measurement_profile_snapshots'', ARRAY[''goods_id''], ''n.distinct_document_count > 0''),',
        '(''measurement_capture_evidence'', ARRAY[''goods_id''], ''true''),',
        '(''measurement_capture_line_snapshots'', ARRAY[''goods_id''], ''true''),'] LOOP
        IF (length(definition) - length(replace(definition, needle, ''))) / length(needle) <> 1 THEN
            RAISE EXCEPTION 'V743 cannot drop retired quantity source % safely', needle;
        END IF;
        definition := replace(definition, needle, '');
    END LOOP;
    IF (length(definition) - length(replace(definition, anchor, ''))) / length(anchor) <> 1
       OR position('goods_weight_observations' IN definition) > 0 THEN
        RAISE EXCEPTION 'V743 cannot extend goods quantity reference sources safely';
    END IF;
    EXECUTE replace(definition, anchor,
        anchor || E'\n    (''goods_weight_observations'', ARRAY[''goods_id''], ''true''),');
END;
$quantity_sources$;

-- 清空业务数据孪生函数(已安装定义, V590/V677 单行 needle 删除 + V711 锚点插入): 七张退役表移出策略,
-- 重量调整账随业务清空, 学习三表随主档保留。
DO $reset_policy$
DECLARE
    definition TEXT;
    needle TEXT;
    anchor TEXT := '(''stock_movements'', ''CLEAR'')';
BEGIN
    SELECT pg_get_functiondef('business_data_reset()'::regprocedure) INTO definition;
    FOREACH needle IN ARRAY ARRAY[
        '(''measurement_capture_decision_events'', ''CLEAR''),',
        '(''measurement_capture_evidence'', ''CLEAR''),',
        '(''measurement_capture_line_snapshots'', ''CLEAR''),',
        '(''measurement_capture_profiles'', ''CLEAR''),',
        '(''legacy_measurement_exceptions'', ''PRESERVE''),',
        '(''legacy_measurement_profile_snapshots'', ''PRESERVE''),',
        '(''legacy_measurement_source_registry'', ''PRESERVE''),'] LOOP
        IF position(needle IN definition) = 0 THEN
            RAISE EXCEPTION 'V743 cannot drop retired measurement policy row % from business_data_reset', needle;
        END IF;
        definition := replace(definition, needle, '');
    END LOOP;
    IF (length(definition) - length(replace(definition, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'V743 cannot extend business-data reset policy safely';
    END IF;
    EXECUTE replace(definition, anchor, anchor || E',\n            (''stock_weight_adjustments'', ''CLEAR''),\n            (''goods_weight_profiles'', ''PRESERVE''),\n            (''goods_weight_observations'', ''PRESERVE''),\n            (''goods_weight_estimates'', ''PRESERVE'')');
END;
$reset_policy$;

-- ---------------------------------------------------------------------
-- 9. 权限: 称重设置与单重学习管理
-- ---------------------------------------------------------------------
INSERT INTO permissions (code, name, module, category, sort_order, action_type, description, grant_policy)
VALUES ('stock:weight:manage', '称重设置与单重学习管理', '仓库管理', '库存', 203, 'CONFIGURE',
        '维护货品称重显示单位、皮重、容差、人工单重与学习开关; 录入称样; 排除或恢复称重记录; 重置单重学习; 人工核重',
        ARRAY['NORMAL']::text[])
ON CONFLICT (code) DO UPDATE
SET name = EXCLUDED.name, module = EXCLUDED.module, category = EXCLUDED.category,
    sort_order = EXCLUDED.sort_order, action_type = EXCLUDED.action_type,
    description = EXCLUDED.description, grant_policy = EXCLUDED.grant_policy;

WITH mapping(surface_key, permission_code) AS (VALUES
        ('warehouse.stock-item', 'stock:weight:manage'),
        ('basic.goods', 'stock:weight:manage'))
INSERT INTO permission_surface_permissions (surface_id, permission_id)
SELECT surface.id, permission.id
FROM permission_surfaces surface
JOIN mapping ON surface.surface_key = mapping.surface_key
JOIN permissions permission ON permission.code = mapping.permission_code
WHERE surface.enabled
ON CONFLICT DO NOTHING;

-- 管仓库单据的部门(现为 PMC 运营仓储部)默认获得; 其余由管理员按人授权。
INSERT INTO department_permissions (department_id, permission_id)
SELECT holder.department_id, target.id
FROM department_permissions holder
JOIN permissions source ON source.id = holder.permission_id AND source.code = 'stock_doc:edit'
JOIN permissions target ON target.code = 'stock:weight:manage'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------
-- 10. 失败关闭终检
-- ---------------------------------------------------------------------
DO $final_check$
DECLARE
    offending TEXT;
    definition TEXT;
BEGIN
    SELECT string_agg(name, ', ' ORDER BY name) INTO offending
    FROM unnest(ARRAY[
        'measurement_capture_decision_events', 'measurement_capture_evidence',
        'measurement_capture_line_snapshots', 'measurement_capture_profiles',
        'legacy_measurement_exceptions', 'legacy_measurement_profile_snapshots',
        'legacy_measurement_source_registry', 'v_measurement_capture_profile_resolution']) AS name
    WHERE to_regclass('public.' || name) IS NOT NULL;
    IF offending IS NOT NULL OR to_regprocedure('fn_reject_measurement_append_only_mutation()') IS NOT NULL THEN
        RAISE EXCEPTION 'V743 left retired measurement objects behind: %', offending;
    END IF;

    SELECT string_agg(relation || '.' || column_name, ', ' ORDER BY relation, column_name) INTO offending
    FROM (VALUES
        ('procurement_inspection_items', 'received_weight_unit_id'),
        ('procurement_inspection_events', 'released_weight_unit_id'),
        ('procurement_iqc_stock_in_batch_items', 'weight_unit_id'),
        ('stock_movements', 'actual_weight_unit_id'),
        ('unit_measurement_profiles', 'canonical_unit_id'),
        ('unit_measurement_profiles', 'to_canonical_factor')) retired(relation, column_name)
    WHERE EXISTS (SELECT 1 FROM information_schema.columns c
                  WHERE c.table_schema = 'public' AND c.table_name = retired.relation
                    AND c.column_name = retired.column_name);
    IF offending IS NOT NULL THEN
        RAISE EXCEPTION 'V743 left retired unit columns behind: %', offending;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                   WHERE conname = 'procurement_inspection_events_stock_in_flag_chk'
                     AND conrelid = 'procurement_inspection_events'::regclass AND convalidated)
       OR NOT EXISTS (SELECT 1 FROM pg_constraint
                      WHERE conname = 'procurement_iqc_stock_in_item_weight_chk'
                        AND conrelid = 'procurement_iqc_stock_in_batch_items'::regclass AND convalidated)
       OR NOT EXISTS (SELECT 1 FROM pg_constraint
                      WHERE conname = 'stock_balances_weight_shape_chk'
                        AND conrelid = 'stock_balances'::regclass AND convalidated) THEN
        RAISE EXCEPTION 'V743 must keep the IQC stock-in flag/weight checks and the balance weight shape check';
    END IF;

    IF to_regclass('public.v_stock_available') IS NULL
       OR to_regclass('public.v_fulfillment_workbench') IS NULL
       OR to_regclass('public.v_fulfillment_workbench_actions') IS NULL THEN
        RAISE EXCEPTION 'V743 must not touch the fulfillment workbench view chain';
    END IF;

    -- plpgsql 晚绑定: 任何函数体里残留退役列/表名都会在运行时才报错, 这里提前失败关闭。
    SELECT string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.oid::regprocedure::text) INTO offending
    FROM pg_proc p
    WHERE p.pronamespace = 'public'::regnamespace
      AND NOT EXISTS (SELECT 1 FROM pg_depend d
                      WHERE d.classid = 'pg_proc'::regclass AND d.objid = p.oid AND d.deptype = 'e')
      AND (p.prosrc ~ '\m(received_weight_unit_id|released_weight_unit_id|actual_weight_unit_id|weight_unit_id|canonical_unit_id|to_canonical_factor)\M'
           OR p.prosrc ~ '(measurement_capture_|legacy_measurement_)');
    IF offending IS NOT NULL THEN
        RAISE EXCEPTION 'V743 left functions reading retired weight/measurement objects: %', offending;
    END IF;

    SELECT pg_get_functiondef('business_data_reset()'::regprocedure) INTO definition;
    IF position('(''stock_weight_adjustments'', ''CLEAR'')' IN definition) = 0
       OR position('(''goods_weight_profiles'', ''PRESERVE'')' IN definition) = 0
       OR position('(''goods_weight_observations'', ''PRESERVE'')' IN definition) = 0
       OR position('(''goods_weight_estimates'', ''PRESERVE'')' IN definition) = 0 THEN
        RAISE EXCEPTION 'V743 business_data_reset policy is incomplete';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM fn_goods_quantity_reference_sources()
                   WHERE relation_name = 'goods_weight_observations')
       OR EXISTS (SELECT 1 FROM fn_goods_quantity_reference_sources()
                  WHERE to_regclass('public.' || relation_name) IS NULL) THEN
        RAISE EXCEPTION 'V743 goods quantity reference sources must name only live tables incl. observations';
    END IF;
END;
$final_check$;
