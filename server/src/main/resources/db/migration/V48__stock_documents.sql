-- =====================================================================
-- V48：仓库管理 · 统一出入库单据（stock_documents + stock_document_items）
-- =====================================================================
-- 设计依据：docs/数据迁移/17-仓库管理-新库与迁移.md
-- 重新设计（更优秀/更快）：老库 9 套同构单据表（O_Transfer/O_In/O_Out/O_OtherIn/
--   O_OtherOut/O_PDraw/O_WDraw/O_Waste/O_Check，18 张）→ 合并为 2 张统一表 +
--   doc_type 判别。库存效果复用 V45 的 stock_movements（movement_type 5-14 已为
--   仓库各类预留/本模块扩展），审核同事务写流水 + upsert stock_balances。
-- 为什么统一：9 类单据主表/明细字段几乎一致，差异（调拨双仓、盘点盘盈亏、领料挂计划）
--   用少量可空列承载。省 16 张表、单一审核路径（applyStockEffect(doc_type→流水)）、
--   18 张报表视图收敛为查 stock_movements 的 2 个参数化查询。
-- 与采购的关系：采购用 4 套独立表（差异大），仓库用统一表（同构）——两者共 stock_movements
--   骨架，这是全链路打通的枢纽。
--
-- doc_type 枚举（文本，不建 PG enum 以便扩展）：
--   TRANSFER 仓库调拨 / OTHER_IN 其它入库 / OTHER_OUT 其它出库 /
--   DRAW 生产领料 / WDRAW 生产退料 / WASTE 生产损耗(老库空) /
--   FINISHED_IN 产成品进仓 / FINISHED_OUT 产成品出仓 / CHECK 盘点
--
-- 分区：stock_document_items 暂不分区（与 V44 purchase_order_items 一致：plain 表）。
--   海量提速可后置改为 RANGE(bill_date) 分区 + pg_partman（见 doc 17 §九，"先熟悉后优化"）。
-- =====================================================================

-- ====================== 统一单据头 ======================
CREATE TABLE stock_documents (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    legacy_id       INT,                                 -- 老库 O_*.ID 溯源；不设 UNIQUE（各 O_ 表 IDENTITY 独立，ID 跨表会重复）
    doc_type        TEXT NOT NULL,                       -- TRANSFER/OTHER_IN/OTHER_OUT/DRAW/WDRAW/WASTE/FINISHED_IN/FINISHED_OUT/CHECK
    bill_no         TEXT NOT NULL,
    bill_date       DATE NOT NULL,
    warehouse_id    UUID REFERENCES warehouses(id),      -- 主仓库（TRANSFER=调出仓）
    to_warehouse_id UUID REFERENCES warehouses(id),      -- 调拨调入仓（仅 TRANSFER）
    supplier_id     UUID,                                -- 产成品进仓等可选供应商（无 FK，留位）
    client_id       UUID,                                -- 产成品出仓/领料可选客户（无 FK，留位）
    worker_id       UUID,                                -- 经手人 → employees（迁移留空）
    maker_id        UUID,                                -- 制单 → employees（迁移留空）
    approver_id     UUID,                                -- 审批 → employees（迁移留空）
    plan_no         TEXT,                                -- 关联生产计划号（领料/进仓，占位文本）
    remark          TEXT,
    total_original  NUMERIC(18,4) DEFAULT 0,
    total_local     NUMERIC(18,4) DEFAULT 0,
    status          SMALLINT NOT NULL DEFAULT 0,         -- 0草稿/1已审/-1红冲
    is_closed       BOOLEAN NOT NULL DEFAULT FALSE,
    source_doc_no   TEXT,                                -- 软关联占位（销售单号等）
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by   UUID,
    updated_by   UUID,
    is_deleted   BOOLEAN NOT NULL DEFAULT FALSE,
    deleted_at   TIMESTAMPTZ,
    UNIQUE (doc_type, bill_no)
);

CREATE INDEX idx_sd_type_date ON stock_documents(doc_type, bill_date DESC);
CREATE INDEX idx_sd_wh        ON stock_documents(warehouse_id);
CREATE INDEX idx_sd_towh      ON stock_documents(to_warehouse_id);
CREATE INDEX idx_sd_status    ON stock_documents(status);
CREATE INDEX idx_sd_legacy    ON stock_documents(legacy_id);

-- ====================== 统一明细 ======================
-- bill_type/bill_no/bill_date 冗余（分区友好 + 报表免 JOIN 主表）。
CREATE TABLE stock_document_items (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    legacy_id       INT,
    doc_id          UUID NOT NULL REFERENCES stock_documents(id) ON DELETE CASCADE,
    bill_type       TEXT NOT NULL,                       -- 冗余 doc_type
    bill_no         TEXT NOT NULL,
    bill_date       DATE NOT NULL,
    line_no         INT,
    goods_id        UUID NOT NULL REFERENCES goods(id),
    color_id        UUID REFERENCES colors(id),
    unit_id         UUID REFERENCES units(id),
    unit_rate       NUMERIC(18,6) DEFAULT 1,             -- URate（qty×unit_rate=基本量）
    qty             NUMERIC(18,4) NOT NULL,              -- 单据数量（主单位）
    base_qty        NUMERIC(18,4),                       -- 基本量 = qty×unit_rate（库存用，迁移算好）
    price           NUMERIC(18,4),
    amount_original NUMERIC(18,4),
    amount_local    NUMERIC(18,4),
    weight          NUMERIC(18,4),
    gift_qty        NUMERIC(18,4) DEFAULT 0,
    surplus_qty     NUMERIC(18,4),                       -- 盘点盘盈(+)盘亏(-)（仅 CHECK）
    count_qty       NUMERIC(18,4),                       -- 盘点实盘数 NowQTY（仅 CHECK）
    place           TEXT,                                -- 库位（文本，首版；存 legacy id 或名）
    upstream_item_id UUID,                               -- 链路：退料→领料明细 等（迁移按 legacy_id 映射）
    source_doc_no   TEXT,                                -- 软关联占位（销售单号/BOM 等，多值降级文本）
    remark          TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by   UUID,                                   -- 审计（明细继承 BaseEntity → AuditableEntity，同 V47 采购明细）
    updated_by   UUID,
    is_deleted   BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE INDEX idx_sdi_doc    ON stock_document_items(doc_id);
CREATE INDEX idx_sdi_goods  ON stock_document_items(goods_id);
CREATE INDEX idx_sdi_type_date ON stock_document_items(bill_type, bill_date);
CREATE INDEX idx_sdi_legacy ON stock_document_items(legacy_id);
CREATE INDEX idx_sdi_upstream ON stock_document_items(upstream_item_id);

COMMENT ON TABLE stock_documents IS '仓库管理统一出入库单据头（doc_type 判别 9 类）；审核写 stock_movements+upsert balances';
COMMENT ON TABLE stock_document_items IS '仓库管理统一明细；base_qty=qty×unit_rate（库存基本量）；盘点用 surplus_qty/count_qty';

-- ====================== movement_type 扩展注释 ======================
-- V45 stock_movements.movement_type 仅注释到 12。本模块用 13/14（SMALLINT，无需改列）：
COMMENT ON COLUMN stock_movements.movement_type IS '1采购入库 2采购退货 3销售出库 4销售退货 5生产领料 6生产退料 7调拨入 8调拨出 9盘盈入 10盘亏出 11其它入 12其它出 13产成品进仓 14产成品出仓';

-- ====================== 权限点 ======================
-- 首版粗粒度（view 全员 / edit 归 PMC）。未来按 doc_type 细分（如 领料/盘点 分权）。
INSERT INTO permissions (code, name, category, sort_order) VALUES
    ('stock_doc:view', '查看仓库单据', '库存管理', 210),
    ('stock_doc:edit', '维护仓库单据', '库存管理', 211)
ON CONFLICT (code) DO NOTHING;

-- view 给所有部门（仓库出入库内部可见）
INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id FROM departments d, permissions p
WHERE p.code = 'stock_doc:view' AND d.is_deleted = false
ON CONFLICT DO NOTHING;

-- edit 给 PMC 运营部（仓库单据操作归 PMC；超管恒有）
INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id FROM departments d, permissions p
WHERE d.code = 'DEPT_PMC' AND p.code = 'stock_doc:edit'
ON CONFLICT DO NOTHING;
