-- V801 (ADR-146): 不良品仓业务规则与可用量单一口径。
--
-- 仓库用途(warehouses.is_defective)成为一等属性: 良品仓 / 不良品仓。不良品仓平时不能当普通仓用:
--   1. 正常货品不能入不良品仓, 生产领料/内料仓请领/委外发料/销售出货也不能从不良品仓取货;
--   2. 物料分析、MRP、销售可预留、出库候选等一切「可用量」都不含不良品仓;
--   3. 不良品只经两条专门通道进出良品仓: 「转不良品仓」(良品仓 -> 不良品仓) 和「不良复判转回」
--      (不良品仓 -> 良品仓), 都是仓库调拨单的一种调拨类型, 各有独立权限并必须写明原因;
--      另外不良品仓还可以盘盈盘亏、报废/其它出库、采购退货、委外成品退回(以及它们的红冲)。
-- 仓库已收敛成单主仓(V800), 「不良仓自成一个主仓」的隐式隔离不复存在, 本迁移把隔离改成显式规则。
-- 本迁移不搬库存、不改历史流水; 测试服务器不良品仓 0 流水 0 余额, 存量没有需要收敛的数据。

-- ---------------------------------------------------------------------------
-- 1. 仓库类别判定(服务层 WarehouseUsePolicy 与数据库守卫同一定义)
-- ---------------------------------------------------------------------------

-- 新单可选的不良品子仓: 启用、记账、作业叶仓、祖先链全部启用、不是车间内料仓、是不良品仓。
CREATE OR REPLACE FUNCTION fn_warehouse_is_defective_leaf(p_warehouse UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT COALESCE(fn_warehouse_is_active_accounting_leaf(p_warehouse)
        AND EXISTS (SELECT 1 FROM warehouses WHERE id = p_warehouse AND is_defective), FALSE)
$$;

-- 计入可用量的仓: 未删、记账、非不良品仓、非车间内料仓、作业叶仓(有子仓的主仓不算)。
-- 停用叶仓的既有库存仍可动用(V540 口径; V800 起有库存的仓本来就不能停用)。
CREATE OR REPLACE FUNCTION fn_warehouse_counts_as_usable(p_warehouse UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT COALESCE((SELECT NOT warehouse.is_deleted AND warehouse.is_accountable
                            AND NOT warehouse.is_defective AND NOT warehouse.is_line_side
                       FROM warehouses warehouse WHERE warehouse.id = p_warehouse), FALSE)
       AND fn_warehouse_is_operational_leaf(p_warehouse)
$$;

-- ---------------------------------------------------------------------------
-- 2. 可用量单一口径
-- ---------------------------------------------------------------------------

-- 按仓可用量: 只含计入可用量的仓; 每仓只扣「指定了本仓」的预留。
-- 全局预留(warehouse_id 为空)不落在任何一个仓上, 只在全局可用量里扣一次(不再每仓各扣一遍)。
CREATE OR REPLACE VIEW v_stock_usable AS
SELECT balance.warehouse_id,
       balance.goods_id,
       balance.color_id,
       balance.qty AS on_hand_qty,
       balance.weight AS on_hand_weight,
       COALESCE(local_reserved.qty, 0) AS reserved_qty,
       balance.qty - COALESCE(local_reserved.qty, 0) AS available_qty
FROM stock_balances balance
JOIN warehouses warehouse ON warehouse.id = balance.warehouse_id
LEFT JOIN LATERAL (
    SELECT SUM(reservation.qty - reservation.consumed_qty - reservation.released_qty) AS qty
    FROM stock_reservations reservation
    WHERE NOT reservation.is_deleted AND reservation.status = 0
      AND reservation.goods_id = balance.goods_id
      AND reservation.color_id IS NOT DISTINCT FROM balance.color_id
      AND reservation.warehouse_id = balance.warehouse_id
) local_reserved ON TRUE
WHERE fn_warehouse_counts_as_usable(warehouse.id);

-- 全局可用量(基本单位, 最小 0) = 各可用仓扣安全库存后的可动量合计 - 全部生效预留(全局预留只扣一次;
-- 落在不计入可用量的仓上的预留不扣, 它们占的不是可用库存)。p_exclude_order_items 里的销售订单行
-- 自己的预留不扣(出货/重排时「本单已经占着的」仍可用)。销售下单占用、退货重预留、委外备料、
-- 仓库销售出库、客户零星发货共用这一个函数。
CREATE OR REPLACE FUNCTION fn_stock_global_usable(
    p_goods UUID, p_color UUID, p_exclude_order_items UUID[] DEFAULT NULL)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT GREATEST(
        COALESCE((SELECT SUM(GREATEST(usable.on_hand_qty
                                      - GREATEST(COALESCE(CAST(goods.min_qty AS NUMERIC), 0), 0), 0))
                    FROM v_stock_usable usable
                    JOIN goods ON goods.id = usable.goods_id
                   WHERE usable.goods_id = p_goods
                     AND usable.color_id IS NOT DISTINCT FROM p_color), 0)
      - COALESCE((SELECT SUM(reservation.qty - reservation.consumed_qty - reservation.released_qty)
                    FROM stock_reservations reservation
                   WHERE NOT reservation.is_deleted AND reservation.status = 0
                     AND reservation.goods_id = p_goods
                     AND reservation.color_id IS NOT DISTINCT FROM p_color
                     AND (reservation.warehouse_id IS NULL
                          OR fn_warehouse_counts_as_usable(reservation.warehouse_id))
                     AND (p_exclude_order_items IS NULL OR reservation.order_item_id IS NULL
                          OR reservation.order_item_id <> ALL (p_exclude_order_items))), 0),
        0)
$$;

-- ---------------------------------------------------------------------------
-- 3. 专门通道: 仓库调拨单的调拨类型
-- ---------------------------------------------------------------------------
ALTER TABLE stock_documents
    ADD COLUMN transfer_kind TEXT NOT NULL DEFAULT 'NORMAL',
    ADD COLUMN defect_reason TEXT,
    ADD COLUMN channel_request_key TEXT;

ALTER TABLE stock_documents
    ADD CONSTRAINT stock_documents_transfer_kind_chk
        CHECK (transfer_kind IN ('NORMAL', 'TO_DEFECTIVE', 'DEFECT_RELEASE')),
    ADD CONSTRAINT stock_documents_transfer_kind_doc_type_chk
        CHECK (transfer_kind = 'NORMAL' OR doc_type = 'TRANSFER'),
    ADD CONSTRAINT stock_documents_defect_reason_chk
        CHECK ((transfer_kind = 'NORMAL' AND defect_reason IS NULL)
            OR (transfer_kind <> 'NORMAL'
                AND (defect_reason IS NULL OR char_length(btrim(defect_reason)) BETWEEN 1 AND 500)
                AND (status = 0 OR defect_reason IS NOT NULL))),
    ADD CONSTRAINT stock_documents_channel_request_key_chk
        CHECK (channel_request_key IS NULL
            OR (transfer_kind <> 'NORMAL' AND channel_request_key ~ '^[A-Za-z0-9._:-]{8,128}$'));

-- 专门通道一次建单并过账; 同一制单人同一重试键只生成一张单(网络重试/双击回放原单)。
CREATE UNIQUE INDEX ux_stock_documents_channel_request_key
    ON stock_documents (maker_id, channel_request_key) WHERE channel_request_key IS NOT NULL;

-- 调拨类型与原因在审核后不能再改: 红冲按原类型反向, 出入库守卫也按它判定。
CREATE OR REPLACE FUNCTION fn_guard_stock_document_transfer_kind()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.status <> 0
       AND (NEW.transfer_kind IS DISTINCT FROM OLD.transfer_kind
            OR NEW.defect_reason IS DISTINCT FROM OLD.defect_reason) THEN
        RAISE EXCEPTION '已审核的调拨单不能再改调拨类型或原因'
            USING ERRCODE = '23514', CONSTRAINT = 'stock_document_transfer_kind_guard';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_stock_document_transfer_kind
    BEFORE UPDATE OF transfer_kind, defect_reason ON stock_documents
    FOR EACH ROW EXECUTE FUNCTION fn_guard_stock_document_transfer_kind();

-- ---------------------------------------------------------------------------
-- 4. 出入库类别矩阵(Java WarehouseClassMovementRule 是同一张表, 契约测试逐格比对)
-- ---------------------------------------------------------------------------
-- 方向不区分: 红冲按原流水反向记同一类型, 「允许落在哪类仓」对正向和红冲天然一致。
--   采购退货 2 / 盘盈 9 / 盘亏 10 / 其它出库与报废 12 / 委外成品退回 18: 良品仓、不良品仓都可以;
--   调拨 7/8 来自仓库调拨单时按调拨类型: 普通调拨两端同类; 转不良品仓 = 良品仓 -> 不良品仓;
--   不良复判转回 = 不良品仓 -> 良品仓; 其它来源的 7/8(车间余料直送退回等)与其余一切类型只能落在良品仓。
-- 返回 NULL = 允许; 否则返回原因码(给人看的文案见 fn_stock_movement_class_message)。
CREATE OR REPLACE FUNCTION fn_stock_movement_class_violation(
    p_movement_type SMALLINT,
    p_warehouse_defective BOOLEAN,
    p_transfer_kind TEXT,
    p_from_defective BOOLEAN,
    p_to_defective BOOLEAN,
    p_transfer_end BOOLEAN)
RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN p_movement_type IN (7, 8) AND p_transfer_kind IS NOT NULL THEN
            CASE
                WHEN NOT COALESCE(p_transfer_end, FALSE) THEN 'TRANSFER_END_MISMATCH'
                WHEN p_transfer_kind = 'TO_DEFECTIVE'
                     AND (COALESCE(p_from_defective, TRUE) OR NOT COALESCE(p_to_defective, FALSE))
                    THEN 'TO_DEFECTIVE_SHAPE'
                WHEN p_transfer_kind = 'DEFECT_RELEASE'
                     AND (NOT COALESCE(p_from_defective, FALSE) OR COALESCE(p_to_defective, TRUE))
                    THEN 'DEFECT_RELEASE_SHAPE'
                WHEN p_transfer_kind = 'NORMAL'
                     AND COALESCE(p_from_defective, p_warehouse_defective)
                         IS DISTINCT FROM COALESCE(p_to_defective, p_warehouse_defective)
                    THEN 'NORMAL_TRANSFER_MIXED'
                WHEN p_transfer_kind NOT IN ('NORMAL', 'TO_DEFECTIVE', 'DEFECT_RELEASE')
                    THEN 'TRANSFER_END_MISMATCH'
                ELSE NULL
            END
        WHEN p_movement_type IN (2, 9, 10, 12, 18) THEN NULL
        WHEN COALESCE(p_warehouse_defective, FALSE) THEN 'DEFECTIVE_REJECTS_GOOD_BUSINESS'
        ELSE NULL
    END
$$;

CREATE OR REPLACE FUNCTION fn_stock_movement_type_label(p_movement_type SMALLINT)
RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE p_movement_type
        WHEN 1 THEN '采购入库' WHEN 2 THEN '采购退货' WHEN 3 THEN '销售出库' WHEN 4 THEN '销售退货'
        WHEN 5 THEN '生产领料' WHEN 6 THEN '生产退料' WHEN 7 THEN '调拨调入' WHEN 8 THEN '调拨调出'
        WHEN 9 THEN '盘盈' WHEN 10 THEN '盘亏' WHEN 11 THEN '其它入库' WHEN 12 THEN '其它出库'
        WHEN 13 THEN '产成品进仓' WHEN 14 THEN '产成品出仓' WHEN 15 THEN '委外发料'
        WHEN 16 THEN '委外材料退回' WHEN 17 THEN '委外成品进仓' WHEN 18 THEN '委外成品退回'
        WHEN 19 THEN '委外材料损耗' WHEN 20 THEN '销售其它出库' WHEN 21 THEN '内料仓盘点耗用'
        WHEN 22 THEN '内料仓盘盈' WHEN 23 THEN '内料仓盘点修正'
        ELSE '这笔出入库' END
$$;

CREATE OR REPLACE FUNCTION fn_stock_movement_class_message(
    p_code TEXT, p_warehouse_name TEXT, p_movement_type SMALLINT)
RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE p_code
        WHEN 'DEFECTIVE_REJECTS_GOOD_BUSINESS' THEN
            '「' || COALESCE(p_warehouse_name, '该仓库') || '」是不良品仓, '
            || fn_stock_movement_type_label(p_movement_type)
            || '不能进出不良品仓; 请改选良品仓, 判为不良的货请用「转不良品仓」'
        WHEN 'NORMAL_TRANSFER_MIXED' THEN
            '普通调拨的调出仓和调入仓必须同是良品仓或同是不良品仓; 良品转不良请用「转不良品仓」, '
            || '复判合格的不良品请用「不良复判转回」'
        WHEN 'TO_DEFECTIVE_SHAPE' THEN '转不良品仓只能从良品仓调出、调入不良品仓'
        WHEN 'DEFECT_RELEASE_SHAPE' THEN '不良复判转回只能从不良品仓调出、调入良品仓'
        ELSE '调拨流水的仓库必须是调拨单上的调出仓或调入仓'
    END
$$;

-- 历史导入会话(app.legacy_import = 'on', 只有老库迁移脚本设置)照搬老系统已经发生的流水, 不按新规则拦。
CREATE OR REPLACE FUNCTION fn_guard_stock_movement_warehouse_class()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    warehouse_name TEXT;
    warehouse_defective BOOLEAN;
    doc_kind TEXT;
    doc_from UUID;
    doc_to UUID;
    from_defective BOOLEAN;
    to_defective BOOLEAN;
    code TEXT;
BEGIN
    IF current_setting('app.legacy_import', true) = 'on' THEN
        RETURN NEW;
    END IF;
    SELECT name, is_defective INTO warehouse_name, warehouse_defective
      FROM warehouses WHERE id = NEW.warehouse_id;
    IF NEW.movement_type IN (7, 8) AND NEW.source_doc_type = 'STOCK_DOC' THEN
        SELECT document.transfer_kind, document.warehouse_id, document.to_warehouse_id,
               source.is_defective, target.is_defective
          INTO doc_kind, doc_from, doc_to, from_defective, to_defective
          FROM stock_documents document
          LEFT JOIN warehouses source ON source.id = document.warehouse_id
          LEFT JOIN warehouses target ON target.id = document.to_warehouse_id
         WHERE document.id = NEW.source_doc_id AND document.doc_type = 'TRANSFER';
    END IF;
    code := fn_stock_movement_class_violation(
        NEW.movement_type, COALESCE(warehouse_defective, FALSE), doc_kind,
        from_defective, to_defective,
        NEW.warehouse_id IS NOT DISTINCT FROM doc_from OR NEW.warehouse_id IS NOT DISTINCT FROM doc_to);
    IF code IS NOT NULL THEN
        RAISE EXCEPTION '%', fn_stock_movement_class_message(code, warehouse_name, NEW.movement_type)
            USING ERRCODE = '23514', CONSTRAINT = 'stock_movement_warehouse_class_guard';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_stock_movement_warehouse_class
    BEFORE INSERT ON stock_movements
    FOR EACH ROW EXECUTE FUNCTION fn_guard_stock_movement_warehouse_class();

-- ---------------------------------------------------------------------------
-- 5. 不良品仓上不允许任何正向预留(取代 V535 「合格来源可在不良品仓预留」的例外)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_guard_stock_reservation_warehouse_class()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    warehouse_name TEXT;
BEGIN
    IF TG_OP = 'UPDATE'
       AND NEW.warehouse_id IS NOT DISTINCT FROM OLD.warehouse_id
       AND NEW.qty - NEW.released_qty <= OLD.qty - OLD.released_qty
       AND NOT (NEW.status = 0 AND OLD.status <> 0)
       AND NOT (NOT NEW.is_deleted AND OLD.is_deleted) THEN
        RETURN NEW;
    END IF;
    IF NEW.is_deleted OR NEW.status <> 0 OR NEW.qty - NEW.consumed_qty - NEW.released_qty <= 0 THEN
        RETURN NEW;
    END IF;
    SELECT name INTO warehouse_name FROM warehouses WHERE id = NEW.warehouse_id AND is_defective;
    IF FOUND THEN
        RAISE EXCEPTION '「%」是不良品仓, 里面的货不能被任何订单、生产或委外预留; 复判合格请先用「不良复判转回」转回良品仓',
            COALESCE(warehouse_name, '该仓库')
            USING ERRCODE = '23514', CONSTRAINT = 'stock_reservation_defective_warehouse_guard';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_stock_reservation_warehouse_class
    BEFORE INSERT ON stock_reservations
    FOR EACH ROW WHEN (NEW.warehouse_id IS NOT NULL)
    EXECUTE FUNCTION fn_guard_stock_reservation_warehouse_class();
CREATE TRIGGER trg_guard_stock_reservation_warehouse_class_upd
    BEFORE UPDATE OF warehouse_id, qty, released_qty, status, is_deleted ON stock_reservations
    FOR EACH ROW WHEN (NEW.warehouse_id IS NOT NULL)
    EXECUTE FUNCTION fn_guard_stock_reservation_warehouse_class();

-- V535 的合格来源守卫只保留身份不可变部分; 不良品仓分支由上面的通用守卫接管(任何预留方一律拒绝)。
CREATE OR REPLACE FUNCTION fn_guard_qualified_origin_reservation_identity()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'UPDATE' AND NEW.requires_qualified_origin IS DISTINCT FROM OLD.requires_qualified_origin THEN
        RAISE EXCEPTION 'qualified-origin requirement is immutable after reservation creation'
            USING ERRCODE = '23514', CONSTRAINT = 'qualified_origin_reservation_identity';
    END IF;
    IF TG_OP = 'UPDATE'
       AND ROW(NEW.owner_type, NEW.owner_id, NEW.purpose, NEW.supply_type, NEW.supply_id,
               NEW.source_doc_type, NEW.source_doc_id, NEW.goods_id, NEW.color_id, NEW.warehouse_id, NEW.qty)
           IS DISTINCT FROM
           ROW(OLD.owner_type, OLD.owner_id, OLD.purpose, OLD.supply_type, OLD.supply_id,
               OLD.source_doc_type, OLD.source_doc_id, OLD.goods_id, OLD.color_id, OLD.warehouse_id, OLD.qty)
       AND EXISTS (SELECT 1 FROM preplan_analysis_stock_exact_pegs WHERE stock_reservation_id = OLD.id) THEN
        RAISE EXCEPTION 'exact source reservation identity and original quantity are immutable'
            USING ERRCODE = '23514', CONSTRAINT = 'qualified_origin_source_identity';
    END IF;
    RETURN NEW;
END;
$$;

-- ---------------------------------------------------------------------------
-- 6. 既有落仓守卫改用「良品子仓」口径: 入库上架、余料收料、销售出库拣货、内料仓发料来源
-- ---------------------------------------------------------------------------
DO $patch$
DECLARE
    target RECORD;
    definition TEXT;
    found_count INTEGER;
BEGIN
    FOR target IN
        SELECT * FROM (VALUES
            ('fn_guard_iqc_actual_warehouse_selection()', 1),
            ('fn_guard_material_return_receiving_confirmation()', 1),
            ('fn_guard_procurement_iqc_pre_stock_mutation()', 1),
            ('fn_guard_production_finished_arrival_registration()', 1),
            ('fn_guard_sales_shipment_picking_evidence()', 1),
            ('fn_guard_sales_shipment_picking_warehouse()', 1)) AS guard(signature, expected)
    LOOP
        SELECT replace(pg_get_functiondef(target.signature::regprocedure), E'\r\n', E'\n') INTO definition;
        found_count := (length(definition)
                        - length(replace(definition, 'fn_warehouse_is_active_accounting_leaf(', '')))
                       / length('fn_warehouse_is_active_accounting_leaf(');
        IF found_count <> target.expected THEN
            RAISE EXCEPTION 'V801: % no longer has the expected % accounting-leaf anchor(s), found %',
                target.signature, target.expected, found_count;
        END IF;
        EXECUTE replace(definition, 'fn_warehouse_is_active_accounting_leaf(', 'fn_warehouse_is_good_stock_leaf(');
    END LOOP;

    SELECT replace(pg_get_functiondef(p.oid), E'\r\n', E'\n') INTO definition
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = 'fn_workshop_material_bin_position';
    found_count := (length(definition)
                    - length(replace(definition, 'fn_warehouse_is_active_accounting_leaf(', '')))
                   / length('fn_warehouse_is_active_accounting_leaf(');
    IF found_count <> 2 THEN
        RAISE EXCEPTION 'V801: fn_workshop_material_bin_position no longer has the 2 accounting-leaf anchors, found %',
            found_count;
    END IF;
    EXECUTE replace(definition, 'fn_warehouse_is_active_accounting_leaf(', 'fn_warehouse_is_good_stock_leaf(');
END;
$patch$;

-- 委外领料(V798, ADR-143)的精确专属批次: 批次所在仓同样只认「计入可用量的仓」。V798 的内联过滤
-- (未删、非不良品仓、非车间内料仓、作业叶仓)缺「记账」一条; 把其中的作业叶仓判定换成单一口径函数
-- (它包含其余几条, 内联的几条留着只是重复判定)。锚点必须恰好一处, 否则中止。
DO $patch$
DECLARE
    definition TEXT;
    found_count INTEGER;
BEGIN
    SELECT replace(pg_get_functiondef('fn_subcontract_component_entitled_lots(uuid)'::regprocedure),
                   E'\r\n', E'\n') INTO definition;
    found_count := (length(definition)
                    - length(replace(definition, 'fn_warehouse_is_operational_leaf(warehouse.id)', '')))
                   / length('fn_warehouse_is_operational_leaf(warehouse.id)');
    IF found_count <> 1 THEN
        RAISE EXCEPTION 'V801: fn_subcontract_component_entitled_lots no longer has the 1 operational-leaf anchor, found %',
            found_count;
    END IF;
    EXECUTE replace(definition, 'fn_warehouse_is_operational_leaf(warehouse.id)',
                    'fn_warehouse_counts_as_usable(warehouse.id)');
END;
$patch$;
COMMENT ON FUNCTION fn_subcontract_component_entitled_lots(UUID) IS
    'V798(ADR-143 三.5): 订货明细按冻结计划行可接管的精确专属批次切片(顶层委外件取来源行 depth=1 节点; 认领区间按该物料节点全部在途订货明细切分)。V801(ADR-146): 批次所在仓只认 fn_warehouse_counts_as_usable';

-- 委外领料(V798, ADR-143)的逐仓可动用量: 公共可用部分只认「计入可用量的仓」(fn_warehouse_counts_as_usable,
-- 与 v_stock_usable / fn_stock_global_usable 同一仓口径), 不良品仓、车间内料仓、主仓、不记账的仓都不出货。
-- 只把 V798 的内联仓过滤换成单一口径函数, 其余(精确专属批次在前、v_stock_available 扣他人预留)不变。
-- 精确专属批次(上面)、公共可用、领料提交的锁发现(SubcontractDrawCommandService)和出仓草稿占用
-- (SubcontractMaterialPlanService.reserveDraft)四处同一个仓谓词: 候选仓 = 锁住的仓 = 允许占用的仓。
CREATE OR REPLACE FUNCTION fn_subcontract_draw_line_stock(p_plan_item UUID)
RETURNS TABLE(warehouse_id UUID, exact_qty NUMERIC, public_qty NUMERIC)
LANGUAGE sql STABLE AS $$
    WITH line AS (
        SELECT plan_item.id, plan_item.order_item_id, plan_item.goods_id, plan_item.color_id
        FROM subcontract_material_plan_items plan_item
        WHERE plan_item.id = p_plan_item AND NOT plan_item.is_deleted
    ), exact_stock AS (
        SELECT lot.warehouse_id, SUM(lot.remaining_qty) AS qty
        FROM line
        CROSS JOIN LATERAL fn_subcontract_component_entitled_lots(line.order_item_id) lot
        WHERE lot.plan_item_id = line.id
        GROUP BY lot.warehouse_id
    ), public_stock AS (
        SELECT stock.warehouse_id, GREATEST(stock.available_qty, 0) AS qty
        FROM line
        JOIN v_stock_available stock ON stock.goods_id = line.goods_id
         AND stock.color_id IS NOT DISTINCT FROM line.color_id
        WHERE fn_warehouse_counts_as_usable(stock.warehouse_id)
    )
    SELECT COALESCE(exact_stock.warehouse_id, public_stock.warehouse_id),
           COALESCE(exact_stock.qty, 0), COALESCE(public_stock.qty, 0)
    FROM exact_stock
    FULL JOIN public_stock ON public_stock.warehouse_id = exact_stock.warehouse_id
    WHERE COALESCE(exact_stock.qty, 0) > 0 OR COALESCE(public_stock.qty, 0) > 0
    ORDER BY 1
$$;
COMMENT ON FUNCTION fn_subcontract_draw_line_stock(UUID) IS
    'V798(ADR-143 三.5): 计划行在各作业叶仓的可动用量 = 精确专属批次 exact_qty + 公共可用 public_qty; 两者都为 0 的仓不返回。V801(ADR-146): 公共可用只认 fn_warehouse_counts_as_usable 的仓';

-- 仓库改成不良品仓之前, 上面不能再有没结束的预留: V800 的退出新选前置条件
-- (fn_warehouse_selection_exit_blockers) 已包含未结预留, 停用/删除/改不核算/改不良品仓同一口径。

-- 本次之前若有跨类别的普通调拨(测试服务器没有), 它们的红冲会被流水守卫拒绝; 先列出来, 由人改走专门通道。
DO $legacy_mixed$
DECLARE
    mixed TEXT;
BEGIN
    SELECT string_agg(document.bill_no, ', ' ORDER BY document.bill_no) INTO mixed
      FROM stock_documents document
      JOIN warehouses source ON source.id = document.warehouse_id
      JOIN warehouses target ON target.id = document.to_warehouse_id
     WHERE document.doc_type = 'TRANSFER' AND document.status = 1 AND NOT document.is_deleted
       AND source.is_defective IS DISTINCT FROM target.is_defective;
    IF mixed IS NOT NULL THEN
        RAISE NOTICE 'V801: 这些已审核的普通调拨跨了良品仓/不良品仓, 以后不能直接红冲, 请改用专门通道: %', mixed;
    END IF;
END;
$legacy_mixed$;

-- ---------------------------------------------------------------------------
-- 7. 独立权限
-- ---------------------------------------------------------------------------
INSERT INTO permissions (code, name, module, category, sort_order, action_type, description, grant_policy, high_risk, baseline)
VALUES
    ('stock:defective_transfer', '转不良品仓', '仓库管理', '仓库单据', 221, 'APPROVE',
     '审核「转不良品仓」调拨单: 把判为不良的货从良品仓转入不良品仓(必须写明原因); 转入后不再计入任何可用量',
     ARRAY['NORMAL']::text[], FALSE, FALSE),
    ('stock:defective_release', '不良复判转回', '仓库管理', '仓库单据', 222, 'APPROVE',
     '审核「不良复判转回」调拨单: 品质复判合格后把货从不良品仓转回良品仓(必须写明复判说明); 转回后重新计入可用量',
     ARRAY['NORMAL']::text[], FALSE, FALSE)
ON CONFLICT (code) DO UPDATE
SET name = EXCLUDED.name, module = EXCLUDED.module, category = EXCLUDED.category,
    sort_order = EXCLUDED.sort_order, action_type = EXCLUDED.action_type,
    description = EXCLUDED.description, grant_policy = EXCLUDED.grant_policy,
    high_risk = EXCLUDED.high_risk, baseline = EXCLUDED.baseline;

WITH mapping(surface_key, permission_code) AS (VALUES
        ('warehouse.stock-document', 'stock:defective_transfer'),
        ('warehouse.stock-document', 'stock:defective_release'))
INSERT INTO permission_surface_permissions (surface_id, permission_id)
SELECT surface.id, permission.id
FROM permission_surfaces surface
JOIN mapping ON surface.surface_key = mapping.surface_key
JOIN permissions permission ON permission.code = mapping.permission_code
ON CONFLICT DO NOTHING;

-- 本节是系统种子授权配置, 不是业务事实(同 V798): 部门授权的永久记录身份绑定与删除留档
-- (V775 trg_bind_business_record_parent / trg_retain_business_record)在本节内暂停, 结束后按 V775 原样
-- ENABLE ALWAYS 恢复。否则空库(首导目标)迁移后 business_record_identities 就有行, 首导守卫会判成
-- 「目标已有业务事实」拒绝首导。
ALTER TABLE department_permissions DISABLE TRIGGER trg_bind_business_record_parent;
ALTER TABLE department_permissions DISABLE TRIGGER trg_retain_business_record;

-- 转不良品仓: 默认给能审核仓库单据的部门(仓储部); 不良复判转回: 默认给品质管理部(下级部门继承)。
INSERT INTO department_permissions (department_id, permission_id)
SELECT holder.department_id, target.id
FROM department_permissions holder
JOIN permissions source ON source.id = holder.permission_id AND source.code = 'stock_doc:approve'
JOIN permissions target ON target.code = 'stock:defective_transfer'
ON CONFLICT DO NOTHING;

INSERT INTO department_permissions (department_id, permission_id)
SELECT department.id, permission.id
FROM departments department
JOIN permissions permission ON permission.code = 'stock:defective_release'
WHERE department.code = 'DEPT_QA' AND NOT department.is_deleted
ON CONFLICT DO NOTHING;

ALTER TABLE department_permissions ENABLE ALWAYS TRIGGER trg_bind_business_record_parent;
ALTER TABLE department_permissions ENABLE ALWAYS TRIGGER trg_retain_business_record;

-- ---------------------------------------------------------------------------
-- 8. 事后断言(存量): 不良品仓上没有正向预留, 货品所属仓库不是不良品仓
-- ---------------------------------------------------------------------------
DO $assert$
BEGIN
    IF EXISTS (SELECT 1 FROM stock_reservations reservation
                 JOIN warehouses warehouse ON warehouse.id = reservation.warehouse_id
                WHERE warehouse.is_defective AND NOT reservation.is_deleted AND reservation.status = 0
                  AND reservation.qty - reservation.consumed_qty - reservation.released_qty > 0) THEN
        RAISE EXCEPTION 'V801: 不良品仓上还有生效的库存预留, 请先释放或把货复判转回良品仓再升级';
    END IF;
    IF EXISTS (SELECT 1 FROM goods JOIN warehouses warehouse ON warehouse.id = goods.owning_warehouse_id
                WHERE warehouse.is_defective AND NOT goods.is_deleted) THEN
        RAISE EXCEPTION 'V801 assertion: a goods owning warehouse is a defective warehouse';
    END IF;
END;
$assert$;

COMMENT ON FUNCTION fn_warehouse_is_defective_leaf(UUID) IS
    'V801 新单可选的不良品子仓 = 启用记账作业叶仓且是不良品仓(转不良品仓的调入仓、不良复判转回的调出仓)';
COMMENT ON FUNCTION fn_warehouse_counts_as_usable(UUID) IS
    'V801 计入可用量的仓 = 未删、记账、非不良品仓、非车间内料仓、作业叶仓; 一切可用/可承诺/可领量的唯一仓口径';
COMMENT ON VIEW v_stock_usable IS
    'V801 按仓可用量: 只含计入可用量的仓, 每仓只扣指定本仓的预留; 全局预留只在 fn_stock_global_usable 扣一次';
COMMENT ON FUNCTION fn_stock_global_usable(UUID, UUID, UUID[]) IS
    'V801 全局可用量 = 可用仓扣安全库存后的合计 - 全部生效预留(可排除指定销售订单行自己的预留), 最小 0';
COMMENT ON FUNCTION fn_stock_movement_class_violation(SMALLINT, BOOLEAN, TEXT, BOOLEAN, BOOLEAN, BOOLEAN) IS
    'V801 出入库类别矩阵: 每种流水类型能落在哪类仓; 与 Java WarehouseClassMovementRule 逐格一致';
COMMENT ON FUNCTION fn_guard_stock_movement_warehouse_class() IS
    'V801 流水落仓守卫: 良品业务不进出不良品仓, 调拨按调拨类型判定两端类别';
COMMENT ON FUNCTION fn_guard_stock_reservation_warehouse_class() IS
    'V801 不良品仓上不允许任何正向预留(取代 V535 合格来源例外)';
COMMENT ON COLUMN stock_documents.transfer_kind IS
    'V801 调拨类型: NORMAL 普通调拨(两端同类) / TO_DEFECTIVE 转不良品仓 / DEFECT_RELEASE 不良复判转回; 审核后不可改';
COMMENT ON COLUMN stock_documents.channel_request_key IS
    'V801 专门通道建单的客户端重试键(同一制单人唯一), 只用于幂等回放';
COMMENT ON COLUMN stock_documents.defect_reason IS
    'V801 转不良品仓的原因或不良复判转回的复判说明(1-500 字), 两种专门通道审核前必填';
COMMENT ON COLUMN warehouses.is_defective IS
    'V801 仓库用途: TRUE=不良品仓(不计入任何可用量, 只经专门通道/盘点/报废/退货进出), FALSE=良品仓';
COMMENT ON COLUMN stock_movements.movement_type IS
    '出入库类型：1采购入库 2采购退货 3销售出库 4销售退货 5生产领料 6生产退料 7调拨入 8调拨出 9盘盈入 10盘亏出 11其它入 12其它出 13产成品进仓 14产成品出仓 15委外材料出仓 16委外材料退回 17委外成品进仓 18委外成品退 19委外材料损耗 20销售其它出库 21内料仓盘点耗用 22内料仓盘盈 23内料仓盘点修正; 能落在哪类仓见 fn_stock_movement_class_violation(V801)';
