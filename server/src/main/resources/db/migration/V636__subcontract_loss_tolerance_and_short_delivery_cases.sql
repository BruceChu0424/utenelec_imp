-- =====================================================================
-- V636 委外允许损耗与回厂短交案件
-- =====================================================================
-- 背景(2026-09-20 用户口径, ADR-098)：「委外件是可能有损耗的...在委外下单那里每个货品加个列
-- 允许损耗范围, 加个记忆下次自动填写...仓库收货数量少于允许范围就弹窗并通知委外人员...
-- 让委外自己判断是分批入库还是允许入库(结案)...记录这个订单的损耗比, 以后按供应商汇总」。
-- 此前委外链路只有材料侧的损耗单/超耗责任(V330/ADR-047), 目标件回厂少于订货量这件事从未被
-- 定义: 仓库照实登记, 订货行一直挂着待到货, 没人判定, 供应商也没有损耗统计。
--
-- 本迁移：
--   1. goods.subcontract_allowed_loss_pct: 货品主档默认允许损耗(记忆落点), 订货编辑页新增行经
--      /last-terms 预填, 保存订货单按明细回写。
--   2. subcontract_order_items.allowed_loss_pct: 本行允许损耗, 保存即冻结; 到货登记按
--      qty*(1-pct/100) 算允许下限, 累计回厂低于下限须仓库确认并通知委外判定。
--   3. subcontract_short_delivery_cases + _events: 回厂短交案件与追加式事件(发现/再次到货/判定/
--      逾期/完成/作废), 一行订货明细同一时刻最多一个开放案件(部分唯一索引)。
--   4. 权限 subcontract_short_delivery:decide(委外回厂短交判定), 面 subcontract.order, 默认授予
--      当前持有 subcontract_order:submit_finance 的部门。
--   5. 视图 v_subcontract_supplier_goods_loss_summary / v_subcontract_supplier_loss_summary:
--      已结清订货行(自然到齐或接受损耗)的损耗汇总, 供应商列表「损耗率(%)」与详情页「委外损耗」段读它。
-- 不改已有行数据, 不动触发器函数; 条数 588→589。
-- =====================================================================

-- 1. 货品主档默认允许损耗(记忆)
ALTER TABLE goods
    ADD COLUMN subcontract_allowed_loss_pct NUMERIC(5,2)
        CHECK (subcontract_allowed_loss_pct IS NULL
               OR (subcontract_allowed_loss_pct >= 0 AND subcontract_allowed_loss_pct <= 100));
COMMENT ON COLUMN goods.subcontract_allowed_loss_pct IS
    '委外允许损耗百分比默认值(记忆): 委外订货明细新增行预填, 保存委外订货单时按明细最近一次填写值回写; 空=未设';

-- 2. 订货明细允许损耗(冻结)
ALTER TABLE subcontract_order_items
    ADD COLUMN allowed_loss_pct NUMERIC(5,2)
        CHECK (allowed_loss_pct IS NULL OR (allowed_loss_pct >= 0 AND allowed_loss_pct <= 100));
COMMENT ON COLUMN subcontract_order_items.allowed_loss_pct IS
    '本行允许损耗百分比(保存即冻结, 主档后续修改不影响): 回厂累计低于 qty*(1-pct/100) 即低于下限, 到货登记须确认并通知委外判定; 空=未设(短交只开中性案件, 不弹窗不通知)';

-- 3. 回厂短交案件
CREATE TABLE subcontract_short_delivery_cases (
    id                        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    order_id                  UUID NOT NULL REFERENCES subcontract_orders(id) ON DELETE RESTRICT,
    order_item_id             UUID NOT NULL REFERENCES subcontract_order_items(id) ON DELETE RESTRICT,
    order_bill_no_snapshot    TEXT NOT NULL,
    supplier_id               UUID REFERENCES suppliers(id) ON DELETE RESTRICT,
    goods_id                  UUID NOT NULL REFERENCES goods(id) ON DELETE RESTRICT,
    color_id                  UUID REFERENCES colors(id) ON DELETE RESTRICT,
    unit_id                   UUID REFERENCES units(id) ON DELETE RESTRICT,
    goods_code_snapshot       TEXT,
    goods_name_snapshot       TEXT,
    receipt_id                UUID,
    receipt_bill_no_snapshot  TEXT,
    ordered_qty               NUMERIC(18,4) NOT NULL CHECK (ordered_qty > 0),
    allowed_loss_pct          NUMERIC(5,2)
        CHECK (allowed_loss_pct IS NULL OR (allowed_loss_pct >= 0 AND allowed_loss_pct <= 100)),
    floor_qty                 NUMERIC(18,4) CHECK (floor_qty IS NULL OR floor_qty >= 0),
    delivered_qty             NUMERIC(18,4) NOT NULL CHECK (delivered_qty >= 0),
    shortfall_qty             NUMERIC(18,4) NOT NULL CHECK (shortfall_qty >= 0),
    shortfall_pct             NUMERIC(7,2) NOT NULL CHECK (shortfall_pct >= 0),
    severity                  TEXT NOT NULL CHECK (severity IN (
        'SEVERE', 'BELOW_FLOOR', 'WITHIN_TOLERANCE', 'UNSET_TOLERANCE')),
    status                    TEXT NOT NULL CHECK (status IN (
        'PENDING_OWNER', 'WAITING_MORE', 'ACCEPTED_LOSS', 'COMPLETED', 'CANCELED')),
    decision                  TEXT CHECK (decision IN ('WAIT_MORE', 'ACCEPT_LOSS')),
    expected_complete_by      DATE,
    decision_note             TEXT CHECK (char_length(decision_note) <= 500),
    arrival_count             INTEGER NOT NULL DEFAULT 1 CHECK (arrival_count >= 1),
    owner_employee_id         UUID REFERENCES employees(id) ON DELETE RESTRICT,
    owner_user_id             UUID REFERENCES users(id) ON DELETE RESTRICT,
    detected_by_user_id       UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    detected_by_employee_id   UUID NOT NULL REFERENCES employees(id) ON DELETE RESTRICT,
    detected_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_evaluated_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    decided_by_user_id        UUID REFERENCES users(id) ON DELETE RESTRICT,
    decided_by_employee_id    UUID REFERENCES employees(id) ON DELETE RESTRICT,
    decided_at                TIMESTAMPTZ,
    closed_at                 TIMESTAMPTZ,
    loss_qty                  NUMERIC(18,4) CHECK (loss_qty IS NULL OR loss_qty >= 0),
    loss_pct                  NUMERIC(7,2) CHECK (loss_pct IS NULL OR loss_pct >= 0),
    waste_id                  UUID REFERENCES subcontract_wastes(id) ON DELETE RESTRICT,
    qty_change_log_id         UUID,
    version                   BIGINT NOT NULL DEFAULT 1 CHECK (version > 0),
    created_at                TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at                TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK ((decision IS NULL) = (decided_at IS NULL)),
    CHECK ((decision IS NULL) = (decided_by_user_id IS NULL)),
    CHECK ((decision IS NULL) = (decided_by_employee_id IS NULL)),
    CHECK (decision IS DISTINCT FROM 'WAIT_MORE' OR expected_complete_by IS NOT NULL),
    CHECK (status <> 'WAITING_MORE' OR decision = 'WAIT_MORE'),
    CHECK (status <> 'ACCEPTED_LOSS' OR (decision = 'ACCEPT_LOSS'
           AND loss_qty IS NOT NULL AND loss_pct IS NOT NULL AND closed_at IS NOT NULL)),
    CHECK (status NOT IN ('COMPLETED', 'CANCELED') OR closed_at IS NOT NULL),
    CHECK (status NOT IN ('PENDING_OWNER', 'WAITING_MORE') OR closed_at IS NULL)
);
COMMENT ON TABLE subcontract_short_delivery_cases IS
    'ADR-098 委外回厂短交案件: 到货登记后累计回厂少于订货量即按行开立/刷新, 由委外判定分批到货继续等(WAIT_MORE)或接受损耗结案(ACCEPT_LOSS: 自动损耗单 + 受控改量 + 记损耗率); 一行明细同一时刻最多一个开放案件';
COMMENT ON COLUMN subcontract_short_delivery_cases.severity IS
    'SEVERE=低于下限且短交率>=max(2*允许损耗,20)% / BELOW_FLOOR=低于下限 / WITHIN_TOLERANCE=容差内未到齐 / UNSET_TOLERANCE=本行未设允许损耗; 前两档红色并通知, 后两档中性';
COMMENT ON COLUMN subcontract_short_delivery_cases.ordered_qty IS
    '评估时的订货量(接受损耗改量前的原量, 汇总视图按它算损耗率)';
COMMENT ON COLUMN subcontract_short_delivery_cases.delivered_qty IS
    '评估时的累计回厂 = received_qty - returned_qty - IQC 已退回不合格量(与预计到货 accepted_qty 同口径, 不封顶)';
COMMENT ON COLUMN subcontract_short_delivery_cases.qty_change_log_id IS
    '接受损耗结案时 ADR-072 受控改量的记录 id(procurement_order_qty_change_logs.id, 只记引用)';
CREATE UNIQUE INDEX uq_subcontract_short_delivery_open_item
    ON subcontract_short_delivery_cases(order_item_id)
    WHERE status IN ('PENDING_OWNER', 'WAITING_MORE');
CREATE INDEX idx_subcontract_short_delivery_order
    ON subcontract_short_delivery_cases(order_id);
CREATE INDEX idx_subcontract_short_delivery_supplier_status
    ON subcontract_short_delivery_cases(supplier_id, status);
CREATE INDEX idx_subcontract_short_delivery_status_detected
    ON subcontract_short_delivery_cases(status, detected_at DESC);
CREATE INDEX idx_subcontract_short_delivery_waiting_due
    ON subcontract_short_delivery_cases(expected_complete_by)
    WHERE status = 'WAITING_MORE';

-- 审计触发器(对齐全库口径：一表一 trg_audit_*，ALWAYS)。
-- 逐条字面写, 不用 DO + format 动态生成: AuditTriggerCoverageMigrationContractTest
-- 要求新表自带可评审的行级审计触发器, 判定方式就是在迁移正文里找
-- `create trigger trg_audit_<表>` / `after insert or update or delete on <表>` /
-- `for each row execute function fn_audit()` 三段字面量。
CREATE TRIGGER trg_audit_subcontract_short_delivery_cases
    AFTER INSERT OR UPDATE OR DELETE ON subcontract_short_delivery_cases
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
ALTER TABLE subcontract_short_delivery_cases
    ENABLE ALWAYS TRIGGER trg_audit_subcontract_short_delivery_cases;

CREATE TABLE subcontract_short_delivery_case_events (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    case_id             UUID NOT NULL REFERENCES subcontract_short_delivery_cases(id) ON DELETE RESTRICT,
    event_type          TEXT NOT NULL CHECK (event_type IN (
        'DETECTED', 'REDETECTED', 'WAIT_MORE_DECIDED', 'ACCEPT_LOSS_DECIDED',
        'COMPLETED', 'CANCELED')),
    actor_user_id       UUID REFERENCES users(id) ON DELETE RESTRICT,
    actor_employee_id   UUID REFERENCES employees(id) ON DELETE RESTRICT,
    event_snapshot      JSONB NOT NULL DEFAULT '{}'::JSONB,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);
COMMENT ON TABLE subcontract_short_delivery_case_events IS
    'ADR-098 短交案件追加式事件(禁改禁删): 发现/再次到货/分批判定/接受损耗判定/自然到齐/作废; 分批等待逾期不落事件, 按有效状态计算并每日提醒';
CREATE INDEX idx_subcontract_short_delivery_events_case
    ON subcontract_short_delivery_case_events(case_id, created_at);

CREATE FUNCTION fn_guard_subcontract_short_delivery_case_event() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'Subcontract short delivery case events are append-only'
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_subcontract_short_delivery_case_event
    BEFORE INSERT OR UPDATE OR DELETE ON subcontract_short_delivery_case_events
    FOR EACH ROW EXECUTE FUNCTION fn_guard_subcontract_short_delivery_case_event();

CREATE TRIGGER trg_audit_subcontract_short_delivery_case_events
    AFTER INSERT OR UPDATE OR DELETE ON subcontract_short_delivery_case_events
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
ALTER TABLE subcontract_short_delivery_case_events
    ENABLE ALWAYS TRIGGER trg_audit_subcontract_short_delivery_case_events;

-- 运行期清库策略补丁(V474 模式)：读已安装的 business_data_reset() 定义, 在 stock_movements 锚点前
-- 插入两张新表的 CLEAR 行; 锚点缺失即失败关闭, 不改任何已应用迁移。
DO $reset_policy$
DECLARE definition TEXT; anchor TEXT:='(''stock_movements'', ''CLEAR'')';
BEGIN
    SELECT pg_get_functiondef('business_data_reset()'::regprocedure) INTO definition;
    IF position(anchor IN definition)=0 THEN RAISE EXCEPTION 'V636 missing business reset anchor'; END IF;
    EXECUTE replace(definition,anchor,'(''subcontract_short_delivery_case_events'', ''CLEAR''),(''subcontract_short_delivery_cases'', ''CLEAR''),'||anchor);
END;
$reset_policy$;

-- 4. 权限：委外回厂短交判定(独立权限点; 结案内部走损耗单审核与受控改量的专用入口, 不再各自要求权限)
INSERT INTO permissions
    (code, name, module, category, sort_order, action_type, description,
     active, assignable)
VALUES
    ('subcontract_short_delivery:decide',
     '委外回厂短交判定', '委外管理', '委外订货', 331,
     'EDIT',
     '回厂数量少于订货量时判定: 分批到货继续等, 或接受损耗结案(自动生成委外损耗单并把订货量改为已回厂量, 超出允许损耗的部分转财务责任判定)',
     TRUE, TRUE)
ON CONFLICT (code) DO UPDATE
SET name = EXCLUDED.name,
    module = EXCLUDED.module,
    category = EXCLUDED.category,
    sort_order = EXCLUDED.sort_order,
    action_type = EXCLUDED.action_type,
    description = EXCLUDED.description,
    active = TRUE,
    assignable = TRUE;

WITH mapping(surface_key, permission_code) AS (VALUES
    ('subcontract.order', 'subcontract_short_delivery:decide')
)
INSERT INTO permission_surface_permissions (surface_id, permission_id)
SELECT surface.id, permission.id
FROM mapping
JOIN permission_surfaces surface ON surface.surface_key = mapping.surface_key
JOIN permissions permission ON permission.code = mapping.permission_code
ON CONFLICT (surface_id, permission_id) DO NOTHING;

-- 默认授权：能提交委外订货给财务的部门就能判定短交(同一批人跟单)。
INSERT INTO department_permissions (department_id, permission_id)
SELECT holder_grant.department_id, target.id
FROM department_permissions holder_grant
JOIN permissions holder ON holder.id = holder_grant.permission_id
                       AND holder.code = 'subcontract_order:submit_finance'
CROSS JOIN permissions target
WHERE target.code = 'subcontract_short_delivery:decide'
ON CONFLICT DO NOTHING;

-- 5. 供应商损耗汇总视图：已结清的委外订货行 = 接受损耗结案的行(订货量取案件记录的改量前原量,
--    损耗量取案件 loss_qty) + 自然到齐的行(损耗 0)。按供应商×货品与按供应商两层。
CREATE OR REPLACE VIEW v_subcontract_supplier_goods_loss_summary AS
WITH settled_lines AS (
    SELECT order_item.id AS order_item_id,
           order_doc.supplier_id,
           order_item.goods_id,
           COALESCE(accepted.ordered_qty, order_item.qty) AS ordered_qty,
           COALESCE(accepted.loss_qty, 0) AS loss_qty,
           accepted.id AS case_id,
           accepted.closed_at
    FROM subcontract_order_items order_item
    JOIN subcontract_orders order_doc
      ON order_doc.id = order_item.order_id
     AND order_doc.status = 1
     AND order_doc.is_deleted = FALSE
    LEFT JOIN LATERAL (
        SELECT c.id, c.ordered_qty, c.loss_qty, c.closed_at
        FROM subcontract_short_delivery_cases c
        WHERE c.order_item_id = order_item.id AND c.status = 'ACCEPTED_LOSS'
        ORDER BY c.closed_at DESC
        LIMIT 1
    ) accepted ON TRUE
    WHERE order_item.is_deleted = FALSE
      AND order_doc.supplier_id IS NOT NULL
      AND COALESCE(order_item.qty, 0) > 0
      AND (accepted.id IS NOT NULL
           OR COALESCE(order_item.received_qty, 0) - COALESCE(order_item.returned_qty, 0)
              >= COALESCE(order_item.qty, 0))
)
SELECT supplier_id,
       goods_id,
       COUNT(*)::bigint AS settled_line_count,
       COUNT(case_id)::bigint AS accepted_loss_count,
       SUM(ordered_qty) AS ordered_qty,
       SUM(loss_qty) AS loss_qty,
       CASE WHEN SUM(ordered_qty) > 0
            THEN ROUND(SUM(loss_qty) * 100 / SUM(ordered_qty), 2) ELSE 0 END AS loss_pct,
       MAX(CASE WHEN ordered_qty > 0 THEN ROUND(loss_qty * 100 / ordered_qty, 2) ELSE 0 END) AS max_loss_pct,
       MAX(closed_at) AS last_loss_at
FROM settled_lines
GROUP BY supplier_id, goods_id;
COMMENT ON VIEW v_subcontract_supplier_goods_loss_summary IS
    'ADR-098 供应商×货品委外损耗汇总: 已结清订货行(接受损耗结案或自然到齐), 加权损耗率 = 累计损耗/累计订货(接受损耗行按改量前原量)';

CREATE OR REPLACE VIEW v_subcontract_supplier_loss_summary AS
SELECT supplier_id,
       SUM(settled_line_count)::bigint AS settled_line_count,
       SUM(accepted_loss_count)::bigint AS accepted_loss_count,
       SUM(ordered_qty) AS ordered_qty,
       SUM(loss_qty) AS loss_qty,
       CASE WHEN SUM(ordered_qty) > 0
            THEN ROUND(SUM(loss_qty) * 100 / SUM(ordered_qty), 2) ELSE 0 END AS loss_pct,
       MAX(max_loss_pct) AS max_loss_pct,
       MAX(last_loss_at) AS last_loss_at
FROM v_subcontract_supplier_goods_loss_summary
GROUP BY supplier_id;
COMMENT ON VIEW v_subcontract_supplier_loss_summary IS
    'ADR-098 供应商委外损耗汇总(供应商列表「损耗率(%)」列与详情页「委外损耗」段的来源)';
