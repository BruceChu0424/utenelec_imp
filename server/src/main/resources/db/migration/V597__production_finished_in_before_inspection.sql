-- =====================================================================
-- V597：自制产成品「先入库后质检」(登记即上架，合格自动点收) —— ADR-090 第六节
-- =====================================================================
-- 背景(2026-09-16 用户口径)：「所有入库的行为都支持『先入库后质检』或者『直接登记并质检』
-- 这样才对」。V596 已经给采购/委外到货(IQC)做了；本迁移把同一个选项补到自制产成品
-- 报工入库(FQC)这条链上——它是系统里另一条「必须先过品质才能入库」的入库链。
--
-- 这条链今天的样子(V430/V410/V338)：
--   车间报工 → 仓库「登记成品仓与库位」(送检登记：实物交到成品仓的库位上，位置落在
--   production_finished_arrival_registrations.warehouse_id + registration_items.place_snapshot)
--   → 品质 FQC 判定 → 合格放行生成 FINISHED_IN 草稿(status=0) → 仓库「点收」确认实收
--   → 才写 stock_movements / stock_balances。
--
-- 也就是说：**实物本来就已经在成品仓的库位上**，品质部本来就是到库位去检验；
-- 多出来的一步是品质合格之后仓库还要再点一次「确认实收并入库」。
-- 所以这条链上的「先入库后质检」= 仓库在登记时就承诺「按登记的仓 + 库位全量入库」，
-- 品质合格时由系统在同一事务里按这个位置自动完成点收(走 V338 同一套确认/守恒/价值/
-- 库存路径，只是不再需要仓库再点一次)；不合格仍然不动库存，走既有恢复/补产链路。
--
-- 代价说清楚：自动点收 = 实收恒等于报工量，放弃「短收改量 + 差异原因 + 余量单」那一步
-- (与 V584 车间直送入库同口径)。需要按实物改量的批次就别用这个按钮，走原「登记并送检」。
--
-- 本迁移：只加列 + 两个守卫 + 一个权限码；不新增表、不改任何既有行、不动既有触发器。

-- ① 登记头记住「本批登记就是先入库后质检」(三列同进同出)。
--    登记表是追加式的(fn_guard_production_finished_arrival_registration 拒绝任何 UPDATE)，
--    所以这个决定在登记那一刻做出、之后不可改——与「登记本身不可改」同一口径。
ALTER TABLE production_finished_arrival_registrations
    ADD COLUMN stock_in_before_inspection BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN pre_stocked_at TIMESTAMPTZ,
    ADD COLUMN pre_stocked_by_employee_id UUID REFERENCES employees(id) ON DELETE RESTRICT;

ALTER TABLE production_finished_arrival_registrations
    ADD CONSTRAINT production_finished_arrival_pre_stocked_shape_chk CHECK (
        (stock_in_before_inspection = FALSE
            AND pre_stocked_at IS NULL
            AND pre_stocked_by_employee_id IS NULL)
        OR (stock_in_before_inspection = TRUE
            AND pre_stocked_at IS NOT NULL
            AND pre_stocked_by_employee_id IS NOT NULL));

-- 品质队列要按「已上架待检」标红分组；按登记批次点查，部分索引足够。
CREATE INDEX idx_production_finished_arrival_registrations_pre_stocked
    ON production_finished_arrival_registrations(warehouse_id, created_at)
    WHERE stock_in_before_inspection;

COMMENT ON COLUMN production_finished_arrival_registrations.stock_in_before_inspection IS
    '先入库后质检(V597)：TRUE=品质合格时由系统按本登记的成品仓与库位自动点收入库，仓库不再点第二次；FALSE=原流程(合格后仓库确认实收)';
COMMENT ON COLUMN production_finished_arrival_registrations.pre_stocked_at IS
    '先入库后质检(V597)：做出「登记即上架、合格自动点收」决定的时间';
COMMENT ON COLUMN production_finished_arrival_registrations.pre_stocked_by_employee_id IS
    '先入库后质检(V597)：做出该决定的仓库员工(与 receiver_employee_id 可能同人)';

-- ② 登记守卫补两条：勾了先入库后质检的批次，目标仓必须是记账叶仓(V596 同一函数)
--    且不是线边仓(线边仓是车间料架，成品送检登记不该自动入到车间)。
--    既有三段校验(追加式、报工已审核、仓库启用可核算)逐字保留。
CREATE OR REPLACE FUNCTION fn_guard_production_finished_arrival_registration()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'production finished arrival registration is append-only'
            USING ERRCODE = '55000';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM production_daily_reports report
        WHERE report.id = NEW.source_report_id
          AND report.status = 1
          AND report.is_deleted = FALSE
    ) THEN
        RAISE EXCEPTION 'finished arrival registration requires an approved report'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_finished_arrival_report_guard';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM warehouses warehouse
        WHERE warehouse.id = NEW.warehouse_id
          AND warehouse.is_deleted = FALSE
          AND warehouse.is_accountable = TRUE
          AND COALESCE(warehouse.status, '') <> '禁用'
    ) THEN
        RAISE EXCEPTION 'finished arrival registration requires an active accountable warehouse'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_finished_arrival_warehouse_guard';
    END IF;

    -- V597 先入库后质检：合格后系统会直接按这个仓自动入库，所以落仓口径提高到
    -- 「启用中的记账叶仓且非线边仓」，与 V596 到货上架、V563 入库选仓同一函数。
    IF NEW.stock_in_before_inspection THEN
        IF NOT fn_warehouse_is_active_accounting_leaf(NEW.warehouse_id) THEN
            RAISE EXCEPTION 'pre-stocked finished arrival requires an active accounting leaf warehouse'
                USING ERRCODE = '23514',
                      DETAIL = '先入库后质检只能登记到启用中的记账叶仓。',
                      CONSTRAINT = 'production_finished_arrival_pre_stocked_leaf_chk';
        END IF;
        IF EXISTS (SELECT 1 FROM warehouses w
                   WHERE w.id = NEW.warehouse_id AND w.is_line_side) THEN
            RAISE EXCEPTION 'pre-stocked finished arrival cannot target a line-side warehouse'
                USING ERRCODE = '23514',
                      DETAIL = '线边仓是车间料架，成品送检登记不能用先入库后质检。',
                      CONSTRAINT = 'production_finished_arrival_pre_stocked_not_line_side_chk';
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

-- ③ 点收确认记来源：仓库手工点收 vs 先入库后质检的合格自动点收。
--    新列带默认值，历史行与既有写入路径一个字节不变。
ALTER TABLE production_finished_in_confirmations
    ADD COLUMN origin TEXT NOT NULL DEFAULT 'WAREHOUSE_CONFIRM';

ALTER TABLE production_finished_in_confirmations
    ADD CONSTRAINT production_finished_in_confirmation_origin_chk CHECK (
        origin IN ('WAREHOUSE_CONFIRM', 'PRE_STOCKED_AUTO'));

COMMENT ON COLUMN production_finished_in_confirmations.origin IS
    '点收来源(V597)：WAREHOUSE_CONFIRM=仓库确认实收；PRE_STOCKED_AUTO=先入库后质检的合格自动点收';

-- ④ 守卫：自动点收只能是「全量接收」，且该入库单每一行都必须来自一个「先入库后质检」
--    的登记行，落仓与库位与登记快照逐行一致——服务端也这么做，数据库再兜一层。
CREATE OR REPLACE FUNCTION fn_guard_production_finished_in_pre_stocked_confirmation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.origin IS DISTINCT FROM 'PRE_STOCKED_AUTO' THEN
        RETURN NEW;
    END IF;
    IF NEW.decision <> 'ACCEPTED' OR NEW.residual_stock_document_id IS NOT NULL THEN
        RAISE EXCEPTION 'pre-stocked automatic finished-in confirmation must accept every line'
            USING ERRCODE = '23514',
                  DETAIL = '先入库后质检的自动点收必须是全量接收，没有短收余量单。',
                  CONSTRAINT = 'production_finished_in_pre_stocked_full_accept_chk';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM stock_document_items item
        JOIN stock_documents document ON document.id = item.doc_id
        WHERE item.doc_id = NEW.stock_document_id
          AND item.is_deleted = FALSE
          AND NOT EXISTS (
              SELECT 1
              FROM production_finished_arrival_registration_items registration_item
              JOIN production_finished_arrival_registrations registration
                ON registration.id = registration_item.registration_id
              WHERE registration_item.source_report_item_id
                        = item.source_daily_report_item_id
                AND registration_item.reversal_id IS NULL
                AND registration.stock_in_before_inspection
                AND registration.warehouse_id = document.warehouse_id
                AND registration_item.place_snapshot IS NOT DISTINCT FROM item.place)
    ) THEN
        RAISE EXCEPTION 'automatic finished-in confirmation must match the pre-stocked registration'
            USING ERRCODE = '23514',
                  DETAIL = '自动点收只能落在先入库后质检登记的成品仓与库位上。',
                  CONSTRAINT = 'production_finished_in_pre_stocked_registration_chk';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_production_finished_in_pre_stocked_confirmation
    BEFORE INSERT ON production_finished_in_confirmations
    FOR EACH ROW EXECUTE FUNCTION fn_guard_production_finished_in_pre_stocked_confirmation();

-- ⑤ 权限码：把「合格就自动入库、不再人工点收」定成一个独立的、可回收的决定，
--    不靠 stock_doc:approve 顺带(它同时是登记与点收的按钮码)。
INSERT INTO permissions (code, name, module, category, sort_order, action_type, description,
                         active, assignable, bulk_assignable, sensitivity)
VALUES ('production_finished_in:before_inspection', '产成品先入库后质检(合格自动点收)', '仓库管理', '仓库单据', 220,
        'EXECUTE',
        '自制产成品送检登记时选择「先入库后质检」：品质合格由系统按登记的成品仓与库位自动完成点收入库，'
        || '仓库不再点第二次确认(实收恒等于报工量，放弃短收改量)；不合格仍不动库存。'
        || '原「登记并送检」流程保留为默认。',
        TRUE, TRUE, TRUE, 'NORMAL')
ON CONFLICT (code) DO UPDATE SET
    name = EXCLUDED.name, module = EXCLUDED.module, category = EXCLUDED.category,
    sort_order = EXCLUDED.sort_order, action_type = EXCLUDED.action_type,
    description = EXCLUDED.description, active = EXCLUDED.active,
    assignable = EXCLUDED.assignable, bulk_assignable = EXCLUDED.bulk_assignable,
    sensitivity = EXCLUDED.sensitivity;

-- 默认授予仓储部与其上级 PMC 运营部、总经办(与 V596 到货先入库同一批岗位)。
INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id
FROM departments d
JOIN permissions p ON p.code = 'production_finished_in:before_inspection'
WHERE d.is_deleted = FALSE
  AND d.code IN ('DEPT_PMC', 'SUB_WH', 'GM')
ON CONFLICT DO NOTHING;

-- 登记到入库任务中心面(产成品送检登记与待点收任务都在这个面上)。
INSERT INTO permission_surface_permissions(surface_id, permission_id)
SELECT surface.id, permission.id
FROM permission_surfaces surface
JOIN permissions permission
  ON permission.code = 'production_finished_in:before_inspection'
 AND permission.active = TRUE
WHERE surface.surface_key IN ('warehouse.inbound-tasks')
ON CONFLICT (surface_id, permission_id) DO NOTHING;
