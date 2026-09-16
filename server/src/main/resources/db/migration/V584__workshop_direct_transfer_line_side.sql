-- V584 车间直送：自制子件不入公共仓库，自检合格后直接交给下一个车间。
--
-- 背景(2026-09-15 用户需求)：
--   「物料A 的子件 物料B 做完(可能只做了一部分)，班组内部检查合格后，不入库，
--     直接投入 物料A 的生产。流程尽量简化，就在报工页面选送仓库还是转送车间。」
--   用户补充的关键思路：「通知对应的那个生产任务领料，但是领料位置是另一个。」
--   用户当日复核后的**适用边界**：「两个不同的车间必须走仓库；同一个车间才可以不走仓库。」
--   所以直送是**车间内部流转**：子件工单与上层工单必须属于同一个车间部门。
--   跨车间一律走原路线(仓库送检登记 → 品质部 FQC → 仓库点收入库 → 仓库发料)，
--   因为料一旦离开本车间就脱离了同一批人的视线，必须由仓库承担交接与账实相符的责任。
--
-- 为什么不做成「纯归属账」(只记 B 交给 A 多少个、完全不碰库存)：
--   四道既有硬闸会同时挡死，而且其中两道是改不动的。
--   1. V249 段进 READY 要求每条需求 stock_backed >= required；
--   2. 需求 FULFILLED 的唯一来源是预留的 consumed_qty(ProductionMaterialStockLedgerService)；
--   3. V152 的 can_close 要求 issued_qty > 0，否则父段永远完工不了；
--   4. V517 成本产出行的 movement_id 是 NOT NULL —— 没有库存移动就没有成本产出，
--      B 的成本会永远停在在制，结不出来。
--   绕开第 4 条要新开一条不经 stock_balances 的价值路径，与 V500「池头节点必须等于唯一一行
--   stock_balances」正面冲突。
--
-- 所以本迁移的取向是：**不绕开「仓库」这个数据概念，只绕开「仓库」这个部门角色。**
--   给车间一个真实的线边仓(车间自己的料架，仓库部门不管、不点收、不进成品仓报表)，
--   于是「谁登记、谁放行、入哪个仓、谁点收」四个角色从仓库/品质部换成车间/班组，
--   价值、成本、清账、退料、结算、完工判定六条链一行都不用改。
--
-- 本迁移不改任何既有业务行，不新增过账类型，不新增预留归属类型。

-- ============ ① 线边仓主档标记 ============
-- 车间归属沿用 V274 就有的 warehouses.workshop_department_id
--(注释原文：'Live workshop UUID -> departments.id; must be a non-deleted direct child
-- of DEPT_PROD')，本迁移只加「是不是线边仓」这一个新事实。
-- 不要再建一列车间归属：V274 已经带外键、带索引、带回填，重复建会是第二份权威。
-- 也不要复用 warehouses.workshop_legacy_id(V43)——V274 的头注释写明它是
-- B_Storage.WorkID -> Sys_Operator.ID，历史上被误命名，从来不是车间桥。
ALTER TABLE warehouses
    ADD COLUMN is_line_side BOOLEAN NOT NULL DEFAULT FALSE;

CREATE INDEX idx_warehouses_line_side_workshop
    ON warehouses(workshop_department_id)
    WHERE is_line_side AND NOT is_deleted;

-- 线边仓形状守卫：必须是叶子仓、参与核算、非不良品仓，且必须指明属于哪个车间。
-- 叶子仓是硬要求——库存余额/预留/流水全部按叶仓 UUID 记(ADR-073)，
-- 把在制品记到一个还有下级的仓上会让同主仓分仓领料的映射失去唯一解。
CREATE OR REPLACE FUNCTION fn_guard_warehouse_line_side()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    -- 非线边仓照旧：V274 起普通仓库也可以挂车间归属，这里不管它。
    IF NOT NEW.is_line_side THEN
        RETURN NEW;
    END IF;

    IF NEW.workshop_department_id IS NULL
       OR NEW.is_accountable = FALSE
       OR NEW.is_defective = TRUE
       OR EXISTS (SELECT 1 FROM warehouses child
                  WHERE child.parent_id = NEW.id AND child.is_deleted = FALSE) THEN
        RAISE EXCEPTION 'a line-side warehouse must be an accountable non-defective leaf owned by one workshop'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'warehouse_line_side_shape_guard';
    END IF;

    -- 还有余额时不许摘掉线边仓标记：摘掉之后这批在制品会立刻出现在公共可用量里，
    -- 被毫不知情的别的工单领走。
    IF TG_OP = 'UPDATE' AND OLD.is_line_side AND NOT NEW.is_line_side
       AND EXISTS (SELECT 1 FROM stock_balances balance
                   WHERE balance.warehouse_id = NEW.id AND balance.qty <> 0) THEN
        RAISE EXCEPTION 'a line-side warehouse still holding stock cannot be converted'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'warehouse_line_side_shape_guard';
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_guard_warehouse_line_side ON warehouses;
CREATE TRIGGER trg_guard_warehouse_line_side
    BEFORE INSERT OR UPDATE ON warehouses
    FOR EACH ROW EXECUTE FUNCTION fn_guard_warehouse_line_side();

-- ============ ② 报工明细行的产出去向 ============
-- 放在行上而不是单头：一张报工里一部分送仓库、一部分转车间是常态(用户口径)。
-- 一行只有一个去向——V548 的 production_finished_arrival_registration_item_active_uk
-- 与 V410 的 inspection 都是按 source_report_item_id 唯一，行内拆量要同时改这两处唯一性。
-- 要拆量就拆行。
ALTER TABLE production_daily_report_items
    ADD COLUMN destination TEXT NOT NULL DEFAULT 'WAREHOUSE'
        CHECK (destination IN ('WAREHOUSE', 'WORKSHOP'));

-- ============ ③ 直送事实(追加式，可撤回不可改) ============
CREATE TABLE production_workshop_direct_transfers (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    source_report_id UUID NOT NULL REFERENCES production_daily_reports(id),
    -- 本车间的线边仓：料实际去了哪个料架。
    line_side_warehouse_id UUID NOT NULL REFERENCES warehouses(id),
    -- 车间部门。直送只在车间内部发生，所以发料方与收料方是同一个部门，
    -- 权限与对象范围都按它判；跨车间的场景在守卫里直接拒掉。
    workshop_department_id UUID NOT NULL REFERENCES departments(id),
    idempotency_key TEXT NOT NULL CHECK (length(idempotency_key) BETWEEN 8 AND 128),
    reason TEXT,
    created_by UUID REFERENCES users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_workshop_direct_transfer_key
        UNIQUE (source_report_id, idempotency_key)
);
CREATE INDEX idx_workshop_direct_transfer_report
    ON production_workshop_direct_transfers(source_report_id);
CREATE INDEX idx_workshop_direct_transfer_workshop
    ON production_workshop_direct_transfers(workshop_department_id);

CREATE TABLE production_workshop_direct_transfer_reversals (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    transfer_id UUID NOT NULL REFERENCES production_workshop_direct_transfers(id),
    reason TEXT NOT NULL CHECK (length(btrim(reason)) BETWEEN 2 AND 500),
    created_by UUID REFERENCES users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_workshop_direct_transfer_reversal_transfer
    ON production_workshop_direct_transfer_reversals(transfer_id);

CREATE TABLE production_workshop_direct_transfer_items (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    transfer_id UUID NOT NULL REFERENCES production_workshop_direct_transfers(id),
    source_report_item_id UUID NOT NULL REFERENCES production_daily_report_items(id),
    -- 收料的上层执行工单及其那条「需要这个子件」的物料需求。
    to_execution_segment_id UUID NOT NULL REFERENCES production_execution_segments(id),
    to_demand_id UUID NOT NULL REFERENCES production_material_demands(id),
    qty NUMERIC(18, 4) NOT NULL CHECK (qty > 0),
    reversal_id UUID REFERENCES production_workshop_direct_transfer_reversals(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
-- 一条报工行同时只能有一条有效直送行(撤回后可以重来)。与 V548 登记行同范式。
CREATE UNIQUE INDEX production_workshop_direct_transfer_item_active_uk
    ON production_workshop_direct_transfer_items(source_report_item_id)
    WHERE reversal_id IS NULL;
CREATE INDEX idx_workshop_direct_transfer_item_demand
    ON production_workshop_direct_transfer_items(to_demand_id)
    WHERE reversal_id IS NULL;

-- 追加式：行一旦写下只能打撤回标记，不能改数量、改收料方、改来源。
CREATE OR REPLACE FUNCTION fn_guard_workshop_direct_transfer_item()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'workshop direct transfer items cannot be deleted'
            USING ERRCODE = '55000';
    END IF;
    IF TG_OP = 'UPDATE' THEN
        IF OLD.reversal_id IS NOT NULL
           OR NEW.reversal_id IS NULL
           OR (to_jsonb(NEW) - 'reversal_id')
              IS DISTINCT FROM (to_jsonb(OLD) - 'reversal_id') THEN
            RAISE EXCEPTION 'a workshop direct transfer item is immutable apart from one reversal stamp'
                USING ERRCODE = '55000';
        END IF;
        RETURN NEW;
    END IF;

    -- 去向必须真的是「转送车间」，数量必须等于该报工行的申报量(V1 不做行内拆量)。
    IF NOT EXISTS (
            SELECT 1 FROM production_daily_report_items item
            WHERE item.id = NEW.source_report_item_id
              AND item.destination = 'WORKSHOP'
              AND item.is_deleted = FALSE
              AND item.qty = NEW.qty) THEN
        RAISE EXCEPTION 'a workshop direct transfer must mirror one whole WORKSHOP-destined report line'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'workshop_direct_transfer_item_source_guard';
    END IF;

    -- 收料需求必须属于收料工单，且货品/颜色与这条报工行一致：
    -- 直送是点对点承诺，认错料就是把 A 的需求用别的货顶掉。
    IF NOT EXISTS (
            SELECT 1
            FROM production_material_demands demand
            JOIN production_daily_report_items item
              ON item.id = NEW.source_report_item_id
            WHERE demand.id = NEW.to_demand_id
              AND demand.execution_segment_id = NEW.to_execution_segment_id
              AND demand.is_deleted = FALSE
              AND demand.status NOT IN ('RELEASED', 'REVERSED')
              AND demand.goods_id = item.goods_id
              AND demand.color_id IS NOT DISTINCT FROM item.color_id) THEN
        RAISE EXCEPTION 'a workshop direct transfer must point at one live demand of the same goods'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'workshop_direct_transfer_item_demand_guard';
    END IF;

    -- 指向同一条需求的有效直送量不得超过该需求的需求量：超出的部分没有指向对象，
    -- 只能走仓库变成公共备货(V577 口径)。
    IF (SELECT COALESCE(SUM(existing.qty), 0) + NEW.qty
        FROM production_workshop_direct_transfer_items existing
        WHERE existing.to_demand_id = NEW.to_demand_id
          AND existing.reversal_id IS NULL)
       > (SELECT demand.required_qty FROM production_material_demands demand
          WHERE demand.id = NEW.to_demand_id) THEN
        RAISE EXCEPTION 'workshop direct transfers cannot exceed the receiving demand'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'workshop_direct_transfer_item_quantity_guard';
    END IF;

    -- 适用边界(用户 2026-09-15 口径)：**子件工单与上层工单必须同一个车间**。
    -- 跨车间一律走仓库——料离开本车间就脱离同一批人的视线，交接与账实相符必须由仓库承担。
    -- 同时线边仓必须是这个车间自己的，且与收料需求同主仓
    -- (fn_warehouse_same_main 是同主仓分仓领料的硬前提，V489)。
    IF NOT EXISTS (
            SELECT 1
            FROM production_workshop_direct_transfers transfer
            JOIN warehouses line_side
              ON line_side.id = transfer.line_side_warehouse_id
            JOIN production_material_demands demand ON demand.id = NEW.to_demand_id
            JOIN production_execution_segments receiving
              ON receiving.id = NEW.to_execution_segment_id
            JOIN production_daily_report_items item
              ON item.id = NEW.source_report_item_id
            JOIN production_execution_segments producing
              ON producing.id = item.execution_segment_id
            WHERE transfer.id = NEW.transfer_id
              AND line_side.is_line_side
              AND line_side.is_deleted = FALSE
              AND line_side.workshop_department_id = transfer.workshop_department_id
              AND receiving.workshop_department_id = transfer.workshop_department_id
              AND producing.workshop_department_id = transfer.workshop_department_id
              AND fn_warehouse_same_main(line_side.id, demand.warehouse_id)) THEN
        RAISE EXCEPTION 'workshop direct transfer requires both segments and the line-side warehouse in one workshop'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'workshop_direct_transfer_item_workshop_guard';
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_guard_workshop_direct_transfer_item
    ON production_workshop_direct_transfer_items;
CREATE TRIGGER trg_guard_workshop_direct_transfer_item
    BEFORE INSERT OR UPDATE OR DELETE ON production_workshop_direct_transfer_items
    FOR EACH ROW EXECUTE FUNCTION fn_guard_workshop_direct_transfer_item();

-- 审计触发器(对齐全库口径：一表一 trg_audit_*，ALWAYS)。
-- 逐条字面写、不用 DO + format：AuditTriggerCoverageMigrationContractTest 在迁移正文里
-- 找 `create trigger trg_audit_<表>` / `after insert or update or delete on <表>` /
-- `for each row execute function fn_audit()` 三段字面量。
CREATE TRIGGER trg_audit_production_workshop_direct_transfers
    AFTER INSERT OR UPDATE OR DELETE ON production_workshop_direct_transfers
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
ALTER TABLE production_workshop_direct_transfers
    ENABLE ALWAYS TRIGGER trg_audit_production_workshop_direct_transfers;

CREATE TRIGGER trg_audit_production_workshop_direct_transfer_items
    AFTER INSERT OR UPDATE OR DELETE ON production_workshop_direct_transfer_items
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
ALTER TABLE production_workshop_direct_transfer_items
    ENABLE ALWAYS TRIGGER trg_audit_production_workshop_direct_transfer_items;

CREATE TRIGGER trg_audit_production_workshop_direct_transfer_reversals
    AFTER INSERT OR UPDATE OR DELETE ON production_workshop_direct_transfer_reversals
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
ALTER TABLE production_workshop_direct_transfer_reversals
    ENABLE ALWAYS TRIGGER trg_audit_production_workshop_direct_transfer_reversals;

-- ============ ④ 班组自检：复用 FQC 三张表，只标记「谁判的」 ============
-- 不另起一套自检表：requireInboundReleased、成本对象的覆盖判定、FAIL 的返工/报废/补产闭环、
-- 报工红冲时的 FQC 取消——四套既有机制全部以「这条报工行有没有 inspection」为判据。
-- 另起炉灶要在四处各开一个口子，每个口子都是一次 fail-open 风险。
ALTER TABLE production_fqc_inspections
    ADD COLUMN inspection_kind TEXT NOT NULL DEFAULT 'ARRIVAL'
        CHECK (inspection_kind IN ('ARRIVAL', 'WORKSHOP_SELF'));

-- ============ ⑤ 前向替换 FQC 来源守卫：按 inspection_kind 分流锚点 ============
-- V548 版只认「有效仓库送检登记行」，自检 inspection 没有登记行，插不进去。
-- 这里整体重写，但先做形状断言：上游被别人改过就停下，不静默覆盖别人的改动。
DO $$
DECLARE
    definition TEXT;
BEGIN
    SELECT pg_get_functiondef('fn_guard_production_fqc_inspection'::regproc)
      INTO definition;
    IF definition IS NULL
       OR position('registered_warehouse_id' IN definition) = 0
       OR position('production_fqc_source_report_guard' IN definition) = 0 THEN
        RAISE EXCEPTION 'fn_guard_production_fqc_inspection no longer matches the V548 shape'
            USING ERRCODE = '23514';
    END IF;
END;
$$;

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

    -- 唯一的差别是「入哪个仓这件事由谁证明」：
    --   ARRIVAL       → 仓库的送检登记行(V430/V548)
    --   WORKSHOP_SELF → 车间的直送行(V584)，仓库全程不参与
    SELECT report.status AS report_status,
           report.is_deleted AS report_deleted,
           CASE WHEN NEW.inspection_kind = 'WORKSHOP_SELF'
                THEN transfer.line_side_warehouse_id
                ELSE registration.warehouse_id END AS registered_warehouse_id,
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
           item.destination,
           segment.plan_id,
           segment.status AS segment_status,
           segment.is_deleted AS segment_deleted,
           package.status AS package_status,
           package.is_deleted AS package_deleted
    INTO source_row
    FROM production_daily_report_items item
    JOIN production_daily_reports report ON report.id = item.report_id
    LEFT JOIN production_finished_arrival_registration_items registration_item
      ON NEW.inspection_kind = 'ARRIVAL'
     AND registration_item.source_report_item_id = item.id
     AND registration_item.reversal_id IS NULL
    LEFT JOIN production_finished_arrival_registrations registration
      ON registration.id = registration_item.registration_id
     AND registration.source_report_id = report.id
    LEFT JOIN production_workshop_direct_transfer_items transfer_item
      ON NEW.inspection_kind = 'WORKSHOP_SELF'
     AND transfer_item.source_report_item_id = item.id
     AND transfer_item.reversal_id IS NULL
    LEFT JOIN production_workshop_direct_transfers transfer
      ON transfer.id = transfer_item.transfer_id
     AND transfer.source_report_id = report.id
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
       OR source_row.package_deleted
       -- 去向与检验种类必须一致：送仓库的行不能靠班组自检放行，反之亦然。
       OR (NEW.inspection_kind = 'WORKSHOP_SELF')
            <> (source_row.destination = 'WORKSHOP') THEN
        RAISE EXCEPTION 'production FQC source report identity or release evidence is invalid'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_fqc_source_report_guard';
    END IF;
    RETURN NEW;
END;
$$;

COMMENT ON COLUMN warehouses.is_line_side IS '线边仓(V584)：车间自己的料架，仓库部门不管；默认不参与公共可用量与即时库存。车间归属沿用 V274 的 workshop_department_id';
COMMENT ON COLUMN production_daily_report_items.destination IS '产出去向(V584)：WAREHOUSE=送仓库走品质部，WORKSHOP=班组自检后直送下一车间';
COMMENT ON COLUMN production_fqc_inspections.inspection_kind IS '检验种类(V584)：ARRIVAL=仓库送检登记后品质部检，WORKSHOP_SELF=车间班组自检';
COMMENT ON TABLE production_workshop_direct_transfers IS '车间直送单(V584)：本车间内部不入库流转的产出，按本车间线边仓归集；跨车间一律走仓库';
COMMENT ON TABLE production_workshop_direct_transfer_items IS '车间直送行(V584，追加式)：一条报工行对同车间一条上层物料需求的点对点承诺';
COMMENT ON TABLE production_workshop_direct_transfer_reversals IS '车间直送撤回(V584)：撤回不删原行，只打 reversal_id 标记';
