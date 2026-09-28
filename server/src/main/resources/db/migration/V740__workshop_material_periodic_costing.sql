-- V740: 车间整批领料与盘点计耗 (ADR-131, 首例: 注塑颗粒)
--
-- 整批领料的料 (goods.issue_method = 'PERIODIC') 由仓库整批发到车间内料仓 (原线边仓),
-- 不再按工单领料; 车间不设周期、随时盘点, 两次盘点之间为一期:
--   实际用量 = 期初 + 领入 - 退回 - 其它耗用 - 期末,
-- 结算时按报工产量 x BOM 单个重量 (理论用量) 比例分到各成本范围。
--
-- 本迁移只占 V740 一个文件, 不依赖在途的 ADR-127/129/132; 完全不触碰 V711 的 BOM 学习对象
-- (不替换、不挂触发器、新对象也不引用), 只提供共用的"报工耗料产量"函数
-- fn_report_item_material_output_qty, 供以后按不良数调整时 CREATE OR REPLACE。
--
-- 文件内顺序固定 (LANGUAGE sql 函数建立时就校验引用对象):
--   1. 开头断言; 2. 新表、新列、约束、索引; 3. 只依赖表的流水视图;
--   4. 函数; 5. 其余视图; 6. 触发器函数、触发器与锚点替换; 7. 数据、权限、编号、审计与清空登记。
-- 锚点替换一律 pg_get_functiondef / pg_get_viewdef / pg_get_constraintdef 现取, 找不到或多于一处即中止。

-- =====================================================================
-- 1. 开头断言
-- =====================================================================
DO $v740_preconditions$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema = 'public' AND table_name = 'goods' AND column_name = 'issue_method') THEN
        RAISE EXCEPTION 'V740 goods.issue_method already exists; align with ADR-131 section 11 before migrating';
    END IF;
    IF EXISTS (SELECT 1 FROM stock_movements WHERE movement_type IN (21, 22)) THEN
        RAISE EXCEPTION 'V740 stock movement types 21/22 are already in use';
    END IF;
END;
$v740_preconditions$;

-- =====================================================================
-- 2. 新表、新列、约束与索引
-- =====================================================================

-- 2.1 通用命令账本: 内料仓全部写命令的幂等键, 业务写完后在同一事务最后写一次, 只追加。
CREATE TABLE workshop_material_commands (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    command_kind TEXT NOT NULL CHECK (command_kind ~ '^[A-Z_]{3,40}$'),
    created_by UUID NOT NULL REFERENCES users(id),
    idempotency_key TEXT NOT NULL CHECK (idempotency_key ~ '^[A-Za-z0-9._:-]{8,128}$'),
    request_hash VARCHAR(64) NOT NULL,
    target_id UUID,
    result JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_workshop_material_command_key UNIQUE (created_by, idempotency_key)
);
COMMENT ON TABLE workshop_material_commands IS
    '车间内料仓写命令幂等账本 (ADR-131): 同人同键同请求返回原结果, 业务表不带命令列';

-- 2.2 货品: 发料方式、分摊方式、每袋净重、是否回收料。
ALTER TABLE goods
    ADD COLUMN issue_method TEXT NOT NULL DEFAULT 'ORDER',
    ADD COLUMN periodic_cost_basis TEXT,
    ADD COLUMN bulk_package_qty NUMERIC(18,4),
    ADD COLUMN is_recycled_material BOOLEAN NOT NULL DEFAULT FALSE,
    ADD CONSTRAINT goods_issue_method_chk CHECK (issue_method IN ('ORDER', 'PERIODIC')),
    ADD CONSTRAINT goods_periodic_cost_basis_chk CHECK (
        (issue_method = 'ORDER' AND periodic_cost_basis IS NULL)
        OR (issue_method = 'PERIODIC' AND periodic_cost_basis IN ('OWN', 'SHARED', 'EXPENSE'))),
    ADD CONSTRAINT goods_bulk_package_qty_chk CHECK (bulk_package_qty IS NULL OR bulk_package_qty > 0);
COMMENT ON COLUMN goods.issue_method IS
    'ORDER 按工单领料; PERIODIC 整批领到车间内料仓、按盘点计耗 (ADR-131)。只能经基础资料的发料方式切换服务改';
COMMENT ON COLUMN goods.periodic_cost_basis IS
    '整批领料的料怎么进成本: OWN 按 BOM 单个重量记到产品; SHARED 辅料按当期主料用量分摊; EXPENSE 记车间费用';

-- 2.3 车间整批领料设置: 一个车间一个按盘点计耗的内料仓。
CREATE TABLE workshop_material_settings (
    workshop_department_id UUID PRIMARY KEY REFERENCES departments(id),
    periodic_enabled BOOLEAN NOT NULL DEFAULT FALSE,
    periodic_bin_warehouse_id UUID REFERENCES warehouses(id),
    go_live_date DATE,
    enabled_by UUID REFERENCES users(id),
    enabled_at TIMESTAMPTZ,
    disabled_by UUID REFERENCES users(id),
    disabled_at TIMESTAMPTZ,
    row_version BIGINT NOT NULL DEFAULT 0,
    created_by UUID NOT NULL REFERENCES users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT workshop_material_settings_enabled_chk CHECK (NOT periodic_enabled OR (
        periodic_bin_warehouse_id IS NOT NULL AND go_live_date IS NOT NULL
        AND enabled_by IS NOT NULL AND enabled_at IS NOT NULL))
);
CREATE UNIQUE INDEX uq_workshop_material_settings_bin
    ON workshop_material_settings(periodic_bin_warehouse_id) WHERE periodic_bin_warehouse_id IS NOT NULL;
COMMENT ON TABLE workshop_material_settings IS
    '车间整批领料设置 (ADR-131): 指定的内料仓与启用日期在有进出记录后不可改; 停用只用来撤销设错的开启';

-- 2.4 机台与机台容器 (盘点按机台录入料斗、储料桶)。
CREATE TABLE workshop_machines (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    workshop_department_id UUID NOT NULL REFERENCES departments(id),
    code TEXT NOT NULL CHECK (length(btrim(code)) BETWEEN 1 AND 40),
    name TEXT NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 100),
    model TEXT CHECK (model IS NULL OR length(model) <= 100),
    tonnage NUMERIC(10,2) CHECK (tonnage IS NULL OR tonnage > 0),
    enabled BOOLEAN NOT NULL DEFAULT TRUE,
    sort_order INT NOT NULL DEFAULT 0,
    remark TEXT,
    is_deleted BOOLEAN NOT NULL DEFAULT FALSE,
    deleted_at TIMESTAMPTZ,
    row_version BIGINT NOT NULL DEFAULT 0,
    created_by UUID NOT NULL REFERENCES users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID REFERENCES users(id),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX uq_workshop_machine_code ON workshop_machines(workshop_department_id, code) WHERE NOT is_deleted;
CREATE INDEX idx_workshop_machines_workshop ON workshop_machines(workshop_department_id);

CREATE TABLE workshop_machine_containers (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    machine_id UUID NOT NULL REFERENCES workshop_machines(id),
    name TEXT NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 40),
    capacity_qty NUMERIC(18,4) NOT NULL CHECK (capacity_qty > 0),
    enabled BOOLEAN NOT NULL DEFAULT TRUE,
    sort_order INT NOT NULL DEFAULT 0,
    is_deleted BOOLEAN NOT NULL DEFAULT FALSE,
    deleted_at TIMESTAMPTZ,
    row_version BIGINT NOT NULL DEFAULT 0,
    created_by UUID NOT NULL REFERENCES users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID REFERENCES users(id),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX uq_workshop_machine_container_name
    ON workshop_machine_containers(machine_id, name) WHERE NOT is_deleted;
CREATE INDEX idx_workshop_machine_containers_machine ON workshop_machine_containers(machine_id);
COMMENT ON TABLE workshop_machines IS '车间机台 (ADR-131): 盘点按机台录入; 盘点用过后只能停用不能删除';
COMMENT ON TABLE workshop_machine_containers IS '机台上的料斗、储料桶等容器, 容量按基本单位 (千克)';

-- 2.5 认料 (产品级): 产品没有 BOM 期间边时, 开工确认表里选"用内料仓的哪种料"或"不用内料仓的料"。
CREATE TABLE goods_periodic_material_choices (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    product_goods_id UUID NOT NULL REFERENCES goods(id),
    kind TEXT NOT NULL CHECK (kind IN ('MATERIAL', 'NONE')),
    material_goods_id UUID REFERENCES goods(id),
    material_color_id UUID REFERENCES colors(id),
    also_order_materials BOOLEAN NOT NULL DEFAULT FALSE,
    prefill_source TEXT CHECK (prefill_source IS NULL OR prefill_source = 'LEGACY_MATERIAL_TEXT'),
    chosen_by UUID NOT NULL REFERENCES users(id),
    chosen_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    chosen_workshop_department_id UUID REFERENCES departments(id),
    superseded_at TIMESTAMPTZ,
    superseded_by UUID REFERENCES users(id),
    superseded_reason TEXT CHECK (superseded_reason IN ('BOM_TAKEOVER', 'CHANGED', 'ISSUE_METHOD_SWITCH')),
    CONSTRAINT goods_periodic_material_choice_kind_chk CHECK (
        (kind = 'MATERIAL' AND material_goods_id IS NOT NULL)
        OR (kind = 'NONE' AND material_goods_id IS NULL AND material_color_id IS NULL AND NOT also_order_materials)),
    CONSTRAINT goods_periodic_material_choice_superseded_chk CHECK ((superseded_at IS NULL) = (superseded_reason IS NULL))
);
-- 有效认料唯一; 这条部分唯一索引也承担"按产品查有效认料" (不另建同谓词的产品索引, 否则冗余)。
CREATE UNIQUE INDEX uq_periodic_choice_active
    ON goods_periodic_material_choices(product_goods_id, material_goods_id, material_color_id)
    NULLS NOT DISTINCT WHERE superseded_at IS NULL;
CREATE INDEX idx_periodic_choice_product ON goods_periodic_material_choices(product_goods_id);
CREATE INDEX idx_periodic_choice_material
    ON goods_periodic_material_choices(material_goods_id) WHERE material_goods_id IS NOT NULL;
CREATE INDEX idx_periodic_choice_color
    ON goods_periodic_material_choices(material_color_id) WHERE material_color_id IS NOT NULL;
CREATE INDEX idx_periodic_choice_chosen_by ON goods_periodic_material_choices(chosen_by);
CREATE INDEX idx_periodic_choice_workshop
    ON goods_periodic_material_choices(chosen_workshop_department_id) WHERE chosen_workshop_department_id IS NOT NULL;
CREATE INDEX idx_periodic_choice_superseded_by
    ON goods_periodic_material_choices(superseded_by) WHERE superseded_by IS NOT NULL;
COMMENT ON TABLE goods_periodic_material_choices IS
    '认料 (ADR-131): 产品第一次有了 BOM 期间边时同一事务全部作废 (BOM_TAKEOVER), 以后开工一律按 BOM';

-- 2.6 段级换料与段的期间料行 (开工时建, 建即绑定内料仓)。
CREATE TABLE production_execution_material_changes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    execution_segment_id UUID NOT NULL REFERENCES production_execution_segments(id),
    from_row_id UUID,
    to_material_goods_id UUID NOT NULL REFERENCES goods(id),
    to_material_color_id UUID REFERENCES colors(id),
    effective_from DATE NOT NULL,
    weight_basis TEXT NOT NULL DEFAULT 'FROM_REPLACED' CHECK (weight_basis IN ('FROM_REPLACED', 'OWN_BOM')),
    reason TEXT CHECK (reason IS NULL OR length(btrim(reason)) BETWEEN 2 AND 500),
    created_by UUID NOT NULL REFERENCES users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT production_execution_material_change_basis_chk CHECK (from_row_id IS NOT NULL OR weight_basis = 'OWN_BOM')
);

CREATE TABLE production_execution_periodic_materials (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    execution_segment_id UUID NOT NULL REFERENCES production_execution_segments(id),
    bin_warehouse_id UUID NOT NULL REFERENCES warehouses(id),
    material_goods_id UUID NOT NULL REFERENCES goods(id),
    material_color_id UUID REFERENCES colors(id),
    unit_id UUID NOT NULL REFERENCES units(id),
    origin TEXT NOT NULL CHECK (origin IN ('BOM', 'CHOICE', 'CHANGE', 'INHERITED')),
    -- 快照引用, 不建外键 (BOM 行可能被删除)。
    bom_item_id UUID,
    choice_id UUID REFERENCES goods_periodic_material_choices(id),
    change_id UUID REFERENCES production_execution_material_changes(id) DEFERRABLE INITIALLY DEFERRED,
    source_row_id UUID REFERENCES production_execution_periodic_materials(id),
    design_qty_snapshot NUMERIC(18,5),
    effective_from DATE NOT NULL,
    effective_to DATE,
    created_by UUID REFERENCES users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT production_execution_periodic_material_origin_chk CHECK (
        (origin = 'BOM' AND bom_item_id IS NOT NULL AND design_qty_snapshot > 0)
        OR (origin = 'CHOICE' AND choice_id IS NOT NULL AND design_qty_snapshot IS NULL)
        OR (origin = 'CHANGE' AND change_id IS NOT NULL)
        OR (origin = 'INHERITED' AND source_row_id IS NOT NULL)),
    CONSTRAINT production_execution_periodic_material_range_chk CHECK (
        effective_to IS NULL OR effective_to >= effective_from - 1)
);
ALTER TABLE production_execution_material_changes ADD CONSTRAINT fk_material_change_from_row
    FOREIGN KEY (from_row_id) REFERENCES production_execution_periodic_materials(id) DEFERRABLE INITIALLY DEFERRED;
CREATE INDEX idx_periodic_rows_bin_segment ON production_execution_periodic_materials(bin_warehouse_id, execution_segment_id);
CREATE INDEX idx_periodic_rows_segment ON production_execution_periodic_materials(execution_segment_id);
CREATE INDEX idx_periodic_rows_material ON production_execution_periodic_materials(material_goods_id);
CREATE INDEX idx_periodic_rows_choice ON production_execution_periodic_materials(choice_id) WHERE choice_id IS NOT NULL;
CREATE INDEX idx_periodic_rows_change ON production_execution_periodic_materials(change_id) WHERE change_id IS NOT NULL;
CREATE INDEX idx_periodic_rows_source ON production_execution_periodic_materials(source_row_id) WHERE source_row_id IS NOT NULL;
CREATE INDEX idx_periodic_rows_color ON production_execution_periodic_materials(material_color_id) WHERE material_color_id IS NOT NULL;
CREATE INDEX idx_periodic_rows_unit ON production_execution_periodic_materials(unit_id);
CREATE INDEX idx_material_changes_segment ON production_execution_material_changes(execution_segment_id);
CREATE INDEX idx_material_changes_from_row ON production_execution_material_changes(from_row_id) WHERE from_row_id IS NOT NULL;
CREATE INDEX idx_material_changes_material ON production_execution_material_changes(to_material_goods_id);
CREATE INDEX idx_material_changes_color ON production_execution_material_changes(to_material_color_id) WHERE to_material_color_id IS NOT NULL;
CREATE INDEX idx_material_changes_created_by ON production_execution_material_changes(created_by);
COMMENT ON TABLE production_execution_periodic_materials IS
    '段的期间料行 (ADR-131): 开工时按 BOM 期间边、认料或来源段建出, 除换料时写一次截止日外不可改';

-- 2.7 零料原因加 PERIODIC_MATERIAL: 现取 V249 约束原文, 前三支不变, 追加第四支。
DO $requirement_check$
DECLARE definition TEXT;
BEGIN
    SELECT pg_get_constraintdef(oid) INTO definition
    FROM pg_constraint
    WHERE conrelid = 'production_execution_segments'::regclass
      AND conname = 'production_execution_segment_material_requirement_chk';
    IF definition IS NULL
       OR position('NO_PRODUCTION_HARD_GATE' IN definition) = 0
       OR position('PERIODIC_MATERIAL' IN definition) > 0
       OR left(definition, 7) <> 'CHECK (' THEN
        RAISE EXCEPTION 'V740 production_execution_segment_material_requirement_chk anchor changed';
    END IF;
    ALTER TABLE production_execution_segments DROP CONSTRAINT production_execution_segment_material_requirement_chk;
    EXECUTE 'ALTER TABLE production_execution_segments ADD CONSTRAINT production_execution_segment_material_requirement_chk CHECK (('
        || substr(definition, 8, length(definition) - 8)
        || ') OR (material_requirement_mode = ''ZERO_MATERIAL'' AND zero_material_reason = ''PERIODIC_MATERIAL'''
        || ' AND zero_material_analysis_id IS NULL AND zero_material_exception_reason IS NULL'
        || ' AND zero_material_authorized_by IS NULL)) NOT VALID';
END;
$requirement_check$;
ALTER TABLE production_execution_segments VALIDATE CONSTRAINT production_execution_segment_material_requirement_chk;

-- 2.8 期间 (按内料仓, 相邻两次盘点之间为一期; 不设盘点周期)。进出来源表引用它, 所以先建。
CREATE TABLE workshop_material_periods (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    bin_warehouse_id UUID NOT NULL REFERENCES warehouses(id),
    workshop_department_id UUID NOT NULL REFERENCES departments(id),
    period_no INT NOT NULL CHECK (period_no > 0),
    start_date DATE NOT NULL,
    end_date DATE,
    status TEXT NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN', 'COUNTING', 'COUNTED', 'CLOSED')),
    counting_started_by UUID REFERENCES users(id),
    counting_started_at TIMESTAMPTZ,
    close_state TEXT NOT NULL DEFAULT 'NONE' CHECK (close_state IN ('NONE', 'QUEUED', 'BLOCKED', 'HELD', 'FAILED')),
    close_blockers JSONB NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(close_blockers) = 'array'),
    close_attempted_at TIMESTAMPTZ,
    close_attempts INT NOT NULL DEFAULT 0,
    close_last_error TEXT,
    close_failures INT NOT NULL DEFAULT 0 CHECK (close_failures >= 0),
    held_until TIMESTAMPTZ,
    row_version BIGINT NOT NULL DEFAULT 0,
    created_by UUID REFERENCES users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_workshop_material_period_no UNIQUE (bin_warehouse_id, period_no),
    CONSTRAINT uq_workshop_material_period_start UNIQUE (bin_warehouse_id, start_date),
    CONSTRAINT workshop_material_period_open_chk CHECK ((status = 'OPEN') = (end_date IS NULL)),
    CONSTRAINT workshop_material_period_range_chk CHECK (end_date IS NULL OR end_date >= start_date),
    CONSTRAINT workshop_material_period_close_state_chk CHECK (close_state = 'NONE' OR status = 'COUNTED'),
    CONSTRAINT workshop_material_period_held_chk CHECK ((close_state = 'HELD') = (held_until IS NOT NULL))
);
CREATE INDEX idx_wm_periods_status ON workshop_material_periods(status, close_state) WHERE status = 'COUNTED';
CREATE INDEX idx_wm_periods_workshop ON workshop_material_periods(workshop_department_id);
COMMENT ON TABLE workshop_material_periods IS
    '内料仓期间 (ADR-131): 开着 -> 盘点中 -> 已盘点 -> 已结算; 第 1 期从启用日开始, 之后每期接上一期截止日次日';

-- 2.9 内料仓进出: 领料单/退回单、明细、登记的库存单据、调拨关联、其它耗用。
CREATE TABLE workshop_material_requisitions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    request_no TEXT NOT NULL UNIQUE CHECK (request_no ~ '^Z[LT][0-9]{14}$'),
    kind TEXT NOT NULL CHECK (kind IN ('ISSUE', 'RETURN')),
    origin TEXT NOT NULL CHECK (origin IN ('WORKSHOP_REQUEST', 'WAREHOUSE_DIRECT')),
    bin_warehouse_id UUID NOT NULL REFERENCES warehouses(id),
    workshop_department_id UUID NOT NULL REFERENCES departments(id),
    receiver_employee_id UUID REFERENCES employees(id),
    status TEXT NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING', 'DONE', 'CANCELLED')),
    requested_by UUID NOT NULL REFERENCES users(id),
    requested_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    done_by UUID REFERENCES users(id),
    done_at TIMESTAMPTZ,
    cancelled_by UUID REFERENCES users(id),
    cancelled_at TIMESTAMPTZ,
    cancel_reason TEXT,
    remark TEXT CHECK (remark IS NULL OR length(remark) <= 500),
    row_version BIGINT NOT NULL DEFAULT 0,
    CONSTRAINT workshop_material_requisition_prefix_chk CHECK ((kind = 'ISSUE') = (request_no LIKE 'ZL%')),
    CONSTRAINT workshop_material_requisition_direct_chk CHECK (
        origin <> 'WAREHOUSE_DIRECT' OR (kind = 'ISSUE' AND receiver_employee_id IS NOT NULL)),
    CONSTRAINT workshop_material_requisition_status_chk CHECK (
        (status = 'PENDING' AND done_by IS NULL AND cancelled_by IS NULL)
        OR (status = 'DONE' AND done_by IS NOT NULL AND done_at IS NOT NULL AND cancelled_by IS NULL)
        OR (status = 'CANCELLED' AND cancelled_by IS NOT NULL AND cancelled_at IS NOT NULL AND done_by IS NULL))
);
CREATE INDEX idx_wm_requisitions_bin_status ON workshop_material_requisitions(bin_warehouse_id, status);
CREATE INDEX idx_wm_requisitions_pending ON workshop_material_requisitions(requested_at, id) WHERE status = 'PENDING';
CREATE INDEX idx_wm_requisitions_workshop ON workshop_material_requisitions(workshop_department_id);
CREATE INDEX idx_wm_requisitions_receiver
    ON workshop_material_requisitions(receiver_employee_id) WHERE receiver_employee_id IS NOT NULL;
CREATE INDEX idx_wm_requisitions_requested_by ON workshop_material_requisitions(requested_by);

CREATE TABLE workshop_material_requisition_lines (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    requisition_id UUID NOT NULL REFERENCES workshop_material_requisitions(id),
    line_no INT NOT NULL,
    goods_id UUID NOT NULL REFERENCES goods(id),
    color_id UUID REFERENCES colors(id),
    unit_id UUID NOT NULL REFERENCES units(id),
    requested_qty NUMERIC(18,4) NOT NULL CHECK (requested_qty > 0),
    requested_bags NUMERIC(18,4) CHECK (requested_bags IS NULL OR requested_bags > 0),
    suggested_leaf_warehouse_id UUID REFERENCES warehouses(id),
    fulfilled_qty NUMERIC(18,4) NOT NULL DEFAULT 0 CHECK (fulfilled_qty >= 0),
    CONSTRAINT uq_wm_requisition_line_material UNIQUE NULLS NOT DISTINCT (requisition_id, goods_id, color_id),
    CONSTRAINT uq_wm_requisition_line_no UNIQUE (requisition_id, line_no)
);
CREATE INDEX idx_wm_requisition_lines_goods ON workshop_material_requisition_lines(goods_id);

CREATE TABLE workshop_material_stock_documents (
    stock_document_id UUID PRIMARY KEY REFERENCES stock_documents(id),
    bin_warehouse_id UUID NOT NULL REFERENCES warehouses(id),
    kind TEXT NOT NULL CHECK (kind IN ('ISSUE', 'RETURN', 'OTHER_ISSUE')),
    requisition_id UUID REFERENCES workshop_material_requisitions(id),
    other_issue_id UUID,
    created_by UUID NOT NULL REFERENCES users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT workshop_material_stock_document_source_chk CHECK (
        (kind IN ('ISSUE', 'RETURN') AND requisition_id IS NOT NULL AND other_issue_id IS NULL)
        OR (kind = 'OTHER_ISSUE' AND other_issue_id IS NOT NULL AND requisition_id IS NULL))
);
CREATE INDEX idx_wm_stock_documents_requisition
    ON workshop_material_stock_documents(requisition_id) WHERE requisition_id IS NOT NULL;
CREATE INDEX idx_wm_stock_documents_other_issue
    ON workshop_material_stock_documents(other_issue_id) WHERE other_issue_id IS NOT NULL;

CREATE TABLE workshop_material_requisition_postings (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    line_id UUID NOT NULL REFERENCES workshop_material_requisition_lines(id),
    stock_document_item_id UUID NOT NULL UNIQUE REFERENCES stock_document_items(id),
    leaf_warehouse_id UUID NOT NULL REFERENCES warehouses(id),
    bin_warehouse_id UUID NOT NULL REFERENCES warehouses(id),
    goods_id UUID NOT NULL REFERENCES goods(id),
    color_id UUID REFERENCES colors(id),
    -- 内料仓一侧的流水: 发料为 7 型入, 退回为 8 型出。
    movement_id UUID NOT NULL UNIQUE REFERENCES stock_movements(id),
    qty NUMERIC(18,4) NOT NULL CHECK (qty > 0),
    period_id UUID NOT NULL REFERENCES workshop_material_periods(id),
    business_date DATE NOT NULL,
    is_supplement BOOLEAN NOT NULL DEFAULT FALSE,
    supplement_reason TEXT,
    created_by UUID NOT NULL REFERENCES users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT workshop_material_posting_supplement_chk CHECK (
        NOT is_supplement OR length(btrim(supplement_reason)) BETWEEN 2 AND 500)
);
CREATE INDEX idx_wm_postings_ledger ON workshop_material_requisition_postings(bin_warehouse_id, goods_id, color_id, period_id);
CREATE INDEX idx_wm_postings_period ON workshop_material_requisition_postings(period_id);
CREATE INDEX idx_wm_postings_line ON workshop_material_requisition_postings(line_id);

CREATE TABLE workshop_material_other_issues (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    bin_warehouse_id UUID NOT NULL REFERENCES warehouses(id),
    workshop_department_id UUID NOT NULL REFERENCES departments(id),
    goods_id UUID NOT NULL REFERENCES goods(id),
    color_id UUID REFERENCES colors(id),
    unit_id UUID NOT NULL REFERENCES units(id),
    qty NUMERIC(18,4) NOT NULL CHECK (qty > 0),
    reason TEXT NOT NULL CHECK (reason IN ('TRIAL_MOULD', 'PURGE', 'SCRAP_MATERIAL', 'OTHER')),
    reason_text TEXT CHECK (reason <> 'OTHER' OR length(btrim(reason_text)) BETWEEN 2 AND 200),
    period_id UUID NOT NULL REFERENCES workshop_material_periods(id),
    business_date DATE NOT NULL,
    stock_document_item_id UUID UNIQUE REFERENCES stock_document_items(id) DEFERRABLE INITIALLY DEFERRED,
    movement_id UUID UNIQUE REFERENCES stock_movements(id) DEFERRABLE INITIALLY DEFERRED,
    created_by UUID NOT NULL REFERENCES users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_wm_other_issues_ledger ON workshop_material_other_issues(bin_warehouse_id, goods_id, color_id, period_id);
CREATE INDEX idx_wm_other_issues_period ON workshop_material_other_issues(period_id);
ALTER TABLE workshop_material_stock_documents ADD CONSTRAINT fk_wm_stock_doc_other_issue
    FOREIGN KEY (other_issue_id) REFERENCES workshop_material_other_issues(id) DEFERRABLE INITIALLY DEFERRED;

-- 2.10 盘点单、盘点行、期间行、盘点过账。
CREATE TABLE workshop_material_counts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    period_id UUID NOT NULL REFERENCES workshop_material_periods(id),
    version INT NOT NULL CHECK (version > 0),
    status TEXT NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT', 'SUBMITTED', 'SUPERSEDED')),
    submitted_by UUID REFERENCES users(id),
    submitted_at TIMESTAMPTZ,
    correction_reason TEXT CHECK (correction_reason IS NULL OR length(btrim(correction_reason)) BETWEEN 2 AND 500),
    row_version BIGINT NOT NULL DEFAULT 0,
    created_by UUID NOT NULL REFERENCES users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_wm_count_version UNIQUE (period_id, version),
    CONSTRAINT workshop_material_count_submitted_chk CHECK ((status = 'DRAFT') = (submitted_at IS NULL)),
    CONSTRAINT workshop_material_count_correction_chk CHECK (version = 1 OR correction_reason IS NOT NULL)
);
CREATE UNIQUE INDEX uq_wm_count_draft ON workshop_material_counts(period_id) WHERE status = 'DRAFT';
CREATE UNIQUE INDEX uq_wm_count_submitted ON workshop_material_counts(period_id) WHERE status = 'SUBMITTED';

CREATE TABLE workshop_material_count_lines (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    count_id UUID NOT NULL REFERENCES workshop_material_counts(id),
    client_line_key TEXT NOT NULL CHECK (client_line_key ~ '^[A-Za-z0-9._:-]{1,80}$'),
    -- 整袋 / 机台容器 / 过秤公斤数 (开口袋、搅好未上机、散料或明确为 0 都按过秤)。
    line_kind TEXT NOT NULL CHECK (line_kind IN ('FULL_BAGS', 'CONTAINER', 'WEIGHED')),
    -- 只给界面分组显示用, 不参与计算。
    weigh_note TEXT CHECK (weigh_note IS NULL OR weigh_note IN ('OPEN_BAG', 'MIXED', 'LOOSE')),
    goods_id UUID REFERENCES goods(id),
    color_id UUID REFERENCES colors(id),
    unit_id UUID REFERENCES units(id),
    bag_count NUMERIC(18,4) CHECK (bag_count IS NULL OR bag_count >= 0),
    bag_net_qty NUMERIC(18,4) CHECK (bag_net_qty IS NULL OR bag_net_qty > 0),
    weighed_qty NUMERIC(18,4) CHECK (weighed_qty IS NULL OR weighed_qty >= 0),
    machine_id UUID REFERENCES workshop_machines(id),
    container_id UUID REFERENCES workshop_machine_containers(id),
    capacity_qty_snapshot NUMERIC(18,4) CHECK (capacity_qty_snapshot IS NULL OR capacity_qty_snapshot > 0),
    fill_level TEXT CHECK (fill_level IN ('FULL', 'HALF', 'EMPTY', 'WEIGHED')),
    qty_base NUMERIC(18,4) GENERATED ALWAYS AS (CASE line_kind
        WHEN 'FULL_BAGS' THEN round(bag_count * bag_net_qty, 4)
        WHEN 'CONTAINER' THEN CASE fill_level
            WHEN 'FULL' THEN capacity_qty_snapshot
            WHEN 'HALF' THEN round(capacity_qty_snapshot * 0.5, 4)
            WHEN 'EMPTY' THEN 0
            ELSE weighed_qty END
        ELSE weighed_qty END) STORED,
    entered_by UUID NOT NULL REFERENCES users(id),
    entered_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    row_version BIGINT NOT NULL DEFAULT 0,
    CONSTRAINT uq_wm_count_line_key UNIQUE (count_id, client_line_key),
    CONSTRAINT workshop_material_count_line_note_chk CHECK (line_kind = 'WEIGHED' OR weigh_note IS NULL),
    CONSTRAINT workshop_material_count_line_shape_chk CHECK (
        (line_kind = 'FULL_BAGS' AND goods_id IS NOT NULL AND bag_count IS NOT NULL AND bag_net_qty IS NOT NULL)
        OR (line_kind = 'WEIGHED' AND goods_id IS NOT NULL AND weighed_qty IS NOT NULL)
        OR (line_kind = 'CONTAINER' AND machine_id IS NOT NULL AND container_id IS NOT NULL
            AND capacity_qty_snapshot IS NOT NULL AND fill_level IS NOT NULL
            AND (goods_id IS NOT NULL OR fill_level = 'EMPTY')
            AND (fill_level <> 'WEIGHED' OR weighed_qty IS NOT NULL)))
);
CREATE UNIQUE INDEX uq_wm_count_line_container ON workshop_material_count_lines(count_id, container_id) WHERE line_kind = 'CONTAINER';
CREATE INDEX idx_wm_count_lines_machine ON workshop_material_count_lines(machine_id) WHERE machine_id IS NOT NULL;
CREATE INDEX idx_wm_count_lines_container ON workshop_material_count_lines(container_id) WHERE container_id IS NOT NULL;

CREATE TABLE workshop_material_period_lines (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    period_id UUID NOT NULL REFERENCES workshop_material_periods(id),
    goods_id UUID NOT NULL REFERENCES goods(id),
    color_id UUID REFERENCES colors(id),
    unit_id UUID NOT NULL REFERENCES units(id),
    -- 建行时货品分摊方式的快照, 结算只认它。
    cost_basis TEXT NOT NULL CHECK (cost_basis IN ('OWN', 'SHARED', 'EXPENSE')),
    opening_qty NUMERIC(18,4) NOT NULL CHECK (opening_qty >= 0),
    transfer_in_qty NUMERIC(18,4) NOT NULL DEFAULT 0 CHECK (transfer_in_qty >= 0),
    return_qty NUMERIC(18,4) NOT NULL DEFAULT 0 CHECK (return_qty >= 0),
    other_issue_qty NUMERIC(18,4) NOT NULL DEFAULT 0 CHECK (other_issue_qty >= 0),
    closing_qty NUMERIC(18,4) NOT NULL CHECK (closing_qty >= 0),
    actual_qty NUMERIC(18,4) GENERATED ALWAYS AS (
        opening_qty + transfer_in_qty - return_qty - other_issue_qty - closing_qty) STORED,
    row_version BIGINT NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_wm_period_line_material UNIQUE NULLS NOT DISTINCT (period_id, goods_id, color_id)
);
CREATE INDEX idx_wm_period_lines_goods ON workshop_material_period_lines(goods_id);

CREATE TABLE workshop_material_count_postings (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    period_line_id UUID NOT NULL REFERENCES workshop_material_period_lines(id),
    count_id UUID NOT NULL REFERENCES workshop_material_counts(id),
    bin_warehouse_id UUID NOT NULL REFERENCES warehouses(id),
    goods_id UUID NOT NULL REFERENCES goods(id),
    color_id UUID REFERENCES colors(id),
    kind TEXT NOT NULL CHECK (kind IN ('CONSUME', 'CONSUME_REVERSE', 'GAIN', 'GAIN_REVERSE')),
    reverses_posting_id UUID REFERENCES workshop_material_count_postings(id),
    qty NUMERIC(18,4) NOT NULL CHECK (qty > 0),
    business_date DATE NOT NULL,
    reason TEXT NOT NULL CHECK (reason IN ('SUBMIT', 'CORRECTION', 'SUPPLEMENT')),
    movement_id UUID UNIQUE REFERENCES stock_movements(id) DEFERRABLE INITIALLY DEFERRED,
    created_by UUID NOT NULL REFERENCES users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT workshop_material_count_posting_reverse_chk CHECK (
        (kind IN ('CONSUME_REVERSE', 'GAIN_REVERSE')) = (reverses_posting_id IS NOT NULL))
);
CREATE INDEX idx_wm_count_postings_ledger
    ON workshop_material_count_postings(bin_warehouse_id, goods_id, color_id, period_line_id);
CREATE INDEX idx_wm_count_postings_period_line ON workshop_material_count_postings(period_line_id);
CREATE INDEX idx_wm_count_postings_count ON workshop_material_count_postings(count_id);
CREATE INDEX idx_wm_count_postings_reverses
    ON workshop_material_count_postings(reverses_posting_id) WHERE reverses_posting_id IS NOT NULL;

-- 2.11 结算结果 (按"次"存, 只追加; 撤销写一次撤销列)。
CREATE TABLE workshop_material_period_closes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    period_id UUID NOT NULL REFERENCES workshop_material_periods(id),
    close_no INT NOT NULL CHECK (close_no > 0),
    status TEXT NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE', 'REVERSED')),
    trigger_kind TEXT NOT NULL CHECK (trigger_kind IN ('AFTER_COUNT', 'SCHEDULED', 'MANUAL')),
    closed_by UUID NOT NULL REFERENCES users(id),
    closed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    reversal_event_id UUID UNIQUE,
    reversed_by UUID REFERENCES users(id),
    reversed_at TIMESTAMPTZ,
    reverse_reason TEXT CHECK (reverse_reason IS NULL OR length(btrim(reverse_reason)) BETWEEN 2 AND 500),
    CONSTRAINT uq_wm_close_no UNIQUE (period_id, close_no),
    CONSTRAINT workshop_material_close_status_chk CHECK (
        (status = 'ACTIVE' AND reversed_at IS NULL AND reversal_event_id IS NULL)
        OR (status = 'REVERSED' AND reversed_at IS NOT NULL AND reversed_by IS NOT NULL
            AND reversal_event_id IS NOT NULL AND reverse_reason IS NOT NULL))
);
CREATE UNIQUE INDEX uq_wm_close_active ON workshop_material_period_closes(period_id) WHERE status = 'ACTIVE';

CREATE TABLE workshop_material_close_materials (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    close_id UUID NOT NULL REFERENCES workshop_material_period_closes(id),
    period_line_id UUID NOT NULL REFERENCES workshop_material_period_lines(id),
    cost_basis TEXT NOT NULL CHECK (cost_basis IN ('OWN', 'SHARED', 'EXPENSE')),
    theory_qty NUMERIC(18,6),
    allocation_basis_qty NUMERIC(18,6),
    outcome TEXT NOT NULL CHECK (outcome IN ('ALLOCATED', 'UNALLOCATED_LOSS', 'GAIN', 'NOTHING', 'EXPENSED')),
    consumed_qty NUMERIC(18,4) NOT NULL DEFAULT 0 CHECK (consumed_qty >= 0),
    loss_qty NUMERIC(18,4) NOT NULL DEFAULT 0 CHECK (loss_qty >= 0),
    waste_rate NUMERIC(12,6),
    flags TEXT[] NOT NULL DEFAULT '{}' CHECK (flags <@ ARRAY[
        'WASTE_OUT_OF_RANGE', 'OTHER_ISSUE_LARGE', 'ACTUAL_WITHOUT_THEORY', 'GAIN_PRICE_ZERO']::text[]),
    value_at_close NUMERIC(18,4),
    CONSTRAINT uq_wm_close_material_line UNIQUE (close_id, period_line_id),
    CONSTRAINT workshop_material_close_material_shared_chk CHECK (cost_basis <> 'SHARED' OR theory_qty IS NULL),
    CONSTRAINT workshop_material_close_material_own_chk CHECK (cost_basis <> 'OWN' OR allocation_basis_qty IS NULL),
    CONSTRAINT workshop_material_close_material_outcome_chk CHECK (
        (outcome = 'ALLOCATED' AND consumed_qty > 0 AND loss_qty = 0)
        OR (outcome = 'UNALLOCATED_LOSS' AND loss_qty > 0 AND consumed_qty = 0)
        OR (outcome IN ('GAIN', 'NOTHING', 'EXPENSED') AND consumed_qty = 0 AND loss_qty = 0))
);
CREATE INDEX idx_wm_close_materials_period_line ON workshop_material_close_materials(period_line_id);

CREATE TABLE workshop_material_close_theory_lines (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    close_id UUID NOT NULL REFERENCES workshop_material_period_closes(id),
    close_material_id UUID NOT NULL REFERENCES workshop_material_close_materials(id),
    report_item_id UUID NOT NULL REFERENCES production_daily_report_items(id),
    report_id UUID NOT NULL REFERENCES production_daily_reports(id),
    business_date DATE NOT NULL,
    execution_segment_id UUID NOT NULL REFERENCES production_execution_segments(id),
    cost_scope_segment_id UUID NOT NULL REFERENCES production_execution_segments(id),
    product_goods_id UUID NOT NULL REFERENCES goods(id),
    periodic_row_id UUID NOT NULL REFERENCES production_execution_periodic_materials(id),
    output_qty_base NUMERIC(18,6) NOT NULL CHECK (output_qty_base >= 0),
    unit_weight NUMERIC(18,6) NOT NULL CHECK (unit_weight > 0),
    weight_source TEXT NOT NULL CHECK (weight_source IN ('BOM_AT_CLOSE', 'SEGMENT_SNAPSHOT', 'REPLACED_ROW_BOM')),
    theory_qty NUMERIC(18,6) NOT NULL,
    CONSTRAINT uq_wm_theory_line UNIQUE (close_material_id, report_item_id, periodic_row_id),
    CONSTRAINT workshop_material_theory_line_qty_chk CHECK (theory_qty = round(output_qty_base * unit_weight, 6))
);
CREATE INDEX idx_wm_theory_lines_close ON workshop_material_close_theory_lines(close_id);
CREATE INDEX idx_wm_theory_lines_report_item ON workshop_material_close_theory_lines(report_item_id);
CREATE INDEX idx_wm_theory_lines_report ON workshop_material_close_theory_lines(report_id);
CREATE INDEX idx_wm_theory_lines_scope ON workshop_material_close_theory_lines(cost_scope_segment_id);
CREATE INDEX idx_wm_theory_lines_segment ON workshop_material_close_theory_lines(execution_segment_id);
CREATE INDEX idx_wm_theory_lines_product ON workshop_material_close_theory_lines(product_goods_id);
CREATE INDEX idx_wm_theory_lines_periodic_row ON workshop_material_close_theory_lines(periodic_row_id);

CREATE TABLE workshop_material_close_allocations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    close_material_id UUID NOT NULL REFERENCES workshop_material_close_materials(id),
    cost_scope_segment_id UUID NOT NULL REFERENCES production_execution_segments(id),
    basis_qty NUMERIC(18,6) NOT NULL CHECK (basis_qty > 0),
    allocated_qty NUMERIC(18,4) NOT NULL CHECK (allocated_qty >= 0),
    is_tail BOOLEAN NOT NULL DEFAULT FALSE,
    value_node_id UUID REFERENCES stock_value_nodes(id),
    value_at_close NUMERIC(18,4),
    reversed_at TIMESTAMPTZ,
    CONSTRAINT uq_wm_allocation_scope UNIQUE (close_material_id, cost_scope_segment_id),
    CONSTRAINT workshop_material_allocation_node_chk CHECK (allocated_qty > 0 OR value_node_id IS NULL)
);
CREATE INDEX idx_wm_allocations_scope
    ON workshop_material_close_allocations(cost_scope_segment_id) WHERE reversed_at IS NULL;
CREATE INDEX idx_wm_allocations_value_node
    ON workshop_material_close_allocations(value_node_id) WHERE value_node_id IS NOT NULL;

-- 2.12 成本投入种类加 PERIODIC_MATERIAL (原 V517 内联约束, 按查到的系统名替换)。
DO $cost_input_kind$
DECLARE constraint_name TEXT; definition TEXT;
BEGIN
    SELECT conname, pg_get_constraintdef(oid) INTO constraint_name, definition
    FROM pg_constraint
    WHERE conrelid = 'stock_value_production_cost_inputs'::regclass AND contype = 'c'
      AND pg_get_constraintdef(oid) LIKE '%input_kind%';
    IF constraint_name IS NULL OR position('CONFIRMED_PROCESSING_FEE' IN definition) = 0
       OR position('PERIODIC_MATERIAL' IN definition) > 0 THEN
        RAISE EXCEPTION 'V740 stock_value_production_cost_inputs input_kind anchor changed';
    END IF;
    EXECUTE format('ALTER TABLE stock_value_production_cost_inputs DROP CONSTRAINT %I', constraint_name);
END;
$cost_input_kind$;
ALTER TABLE stock_value_production_cost_inputs ADD CONSTRAINT stock_value_production_cost_inputs_input_kind_check
    CHECK (input_kind IN ('CONSUMED', 'NORMAL_LOSS', 'CONFIRMED_PROCESSING_FEE', 'PERIODIC_MATERIAL'));

-- 期间分摊与损失的价值事件按来源行回查 (投入发现视图、报表现值); 部分索引只收这两类事件。
CREATE INDEX idx_stock_value_events_workshop_period_source ON stock_value_events(source_event_id)
    WHERE source_doc_type IN ('WORKSHOP_PERIOD_ALLOCATION', 'WORKSHOP_PERIOD_LOSS');

-- =====================================================================
-- 3. 只依赖表的流水视图: 内料仓里整批领料货品的每一笔进出 (带符号数量、所属期间)
-- =====================================================================
CREATE VIEW v_workshop_material_bin_ledger AS
SELECT posting.id AS source_row_id, 'ISSUE'::text AS source_kind, posting.bin_warehouse_id,
       posting.goods_id, posting.color_id, posting.qty AS signed_qty, posting.period_id,
       posting.business_date, posting.movement_id, posting.is_supplement
FROM workshop_material_requisition_postings posting
JOIN workshop_material_requisition_lines line ON line.id = posting.line_id
JOIN workshop_material_requisitions requisition ON requisition.id = line.requisition_id AND requisition.kind = 'ISSUE'
UNION ALL
SELECT posting.id, 'RETURN'::text, posting.bin_warehouse_id,
       posting.goods_id, posting.color_id, -posting.qty, posting.period_id,
       posting.business_date, posting.movement_id, posting.is_supplement
FROM workshop_material_requisition_postings posting
JOIN workshop_material_requisition_lines line ON line.id = posting.line_id
JOIN workshop_material_requisitions requisition ON requisition.id = line.requisition_id AND requisition.kind = 'RETURN'
UNION ALL
SELECT other.id, 'OTHER_ISSUE'::text, other.bin_warehouse_id,
       other.goods_id, other.color_id, -other.qty, other.period_id,
       other.business_date, other.movement_id, FALSE
FROM workshop_material_other_issues other
UNION ALL
SELECT counted.id, counted.kind, counted.bin_warehouse_id,
       counted.goods_id, counted.color_id,
       CASE counted.kind WHEN 'CONSUME' THEN -counted.qty WHEN 'CONSUME_REVERSE' THEN counted.qty
                         WHEN 'GAIN' THEN counted.qty ELSE -counted.qty END,
       line.period_id, counted.business_date, counted.movement_id, FALSE
FROM workshop_material_count_postings counted
JOIN workshop_material_period_lines line ON line.id = counted.period_line_id;
COMMENT ON VIEW v_workshop_material_bin_ledger IS
    '车间内料仓整批领料货品的全部进出 (ADR-131): 发料、退回、其它耗用、盘点过账; 期间归属按 period_id, 不按日期';

-- =====================================================================
-- 4. 函数 (按依赖顺序)
-- =====================================================================

-- 4.1 产品有没有 BOM: 全部 / 按单 (组件不是整批领料) / 期间边 (组件是整批领料)。
CREATE FUNCTION fn_goods_has_bom(p_goods UUID) RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT EXISTS (SELECT 1 FROM goods_bom_items bom WHERE bom.goods_id = p_goods AND NOT bom.is_deleted)
$$;

CREATE FUNCTION fn_goods_has_order_bom(p_goods UUID) RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT EXISTS (
        SELECT 1 FROM goods_bom_items bom
        JOIN goods component ON component.id = bom.component_goods_id AND component.issue_method <> 'PERIODIC'
        WHERE bom.goods_id = p_goods AND NOT bom.is_deleted)
$$;

CREATE FUNCTION fn_goods_has_periodic_bom(p_goods UUID) RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT EXISTS (
        SELECT 1 FROM goods_bom_items bom
        JOIN goods component ON component.id = bom.component_goods_id AND component.issue_method = 'PERIODIC'
        WHERE bom.goods_id = p_goods AND NOT bom.is_deleted)
$$;

-- 4.2 内料仓已结算到哪一天 (没有已结算期间时为启用日前一天)。
CREATE FUNCTION fn_workshop_material_closed_through(p_bin UUID) RETURNS DATE LANGUAGE sql STABLE AS $$
    SELECT COALESCE(
        (SELECT max(period.end_date) FROM workshop_material_periods period
         WHERE period.bin_warehouse_id = p_bin AND period.status = 'CLOSED'),
        (SELECT settings.go_live_date - 1 FROM workshop_material_settings settings
         WHERE settings.periodic_bin_warehouse_id = p_bin),
        DATE '1900-01-01')
$$;

-- 4.3 按单需求"未核清"的唯一定义 (聚合口径同 V711 的发退与清账过账)。
CREATE FUNCTION fn_material_demand_uncleared(p_demand UUID) RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT EXISTS (
        SELECT 1
        FROM production_material_demands demand
        LEFT JOIN LATERAL (
            SELECT sum(CASE posting_type WHEN 'ISSUE' THEN qty_base WHEN 'ISSUE_REVERSE' THEN -qty_base ELSE 0 END) AS issued,
                   sum(CASE posting_type WHEN 'GOOD_RETURN' THEN qty_base WHEN 'GOOD_RETURN_REVERSE' THEN -qty_base ELSE 0 END) AS returned
            FROM production_material_stock_postings
            WHERE demand_id = demand.id) stock ON TRUE
        LEFT JOIN LATERAL (
            SELECT sum(CASE WHEN posting.settlement_type = 'CONSUMED' THEN CASE event.event_type WHEN 'POST' THEN posting.qty_base ELSE -posting.qty_base END ELSE 0 END) AS consumed,
                   sum(CASE WHEN posting.settlement_type = 'APPROVED_LOSS' THEN CASE event.event_type WHEN 'POST' THEN posting.qty_base ELSE -posting.qty_base END ELSE 0 END) AS loss,
                   sum(CASE WHEN posting.settlement_type = 'LEGAL_WIP' THEN CASE event.event_type WHEN 'POST' THEN posting.qty_base ELSE -posting.qty_base END ELSE 0 END) AS wip
            FROM production_material_settlement_postings posting
            JOIN production_material_settlement_events event ON event.id = posting.event_id
            WHERE posting.demand_id = demand.id) settled ON TRUE
        WHERE demand.id = p_demand
          AND NOT demand.is_deleted
          AND demand.status NOT IN ('RELEASED', 'REVERSED')
          AND (demand.status <> 'FULFILLED'
               OR COALESCE(stock.issued, 0) - COALESCE(stock.returned, 0)
                  <> COALESCE(settled.consumed, 0) + COALESCE(settled.loss, 0)
               OR COALESCE(settled.wip, 0) <> 0
               OR EXISTS (
                   SELECT 1 FROM production_material_stock_postings posting
                   WHERE posting.demand_id = demand.id AND posting.posting_type = 'ISSUE'
                     AND fn_material_issue_pending_return(posting.id, NULL) > 0)))
$$;

-- 4.4 全系统"报工耗料产量"的唯一定义: 第一期取良品基本量, FQC 返工补产不计, 报废/拒收补产照计。
--     以后加不良数时 CREATE OR REPLACE 本函数即可, 期间理论随之生效。
CREATE FUNCTION fn_report_item_material_output_qty(p_report_item_id UUID) RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT CASE WHEN auth.disposition_code = 'REWORK' THEN 0::numeric
                ELSE COALESCE(item.qty, 0) * COALESCE(item.unit_rate, 1) END
    FROM production_daily_report_items item
    LEFT JOIN production_fqc_recovery_authorizations auth ON auth.id = item.fqc_recovery_authorization_id
    WHERE item.id = p_report_item_id
$$;

-- 4.5 单个重量: 产品当前 BOM 上这种料的期间边用量 (颜色按边上颜色, 没有则按料本身颜色)。
CREATE FUNCTION fn_workshop_material_edge_weight(p_product UUID, p_material UUID, p_color UUID)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT bom.qty
    FROM goods_bom_items bom
    JOIN goods component ON component.id = bom.component_goods_id AND component.issue_method = 'PERIODIC'
    WHERE bom.goods_id = p_product AND bom.component_goods_id = p_material AND NOT bom.is_deleted
      AND COALESCE(bom.color_id, component.color_id) IS NOT DISTINCT FROM p_color
    ORDER BY bom.id
    LIMIT 1
$$;

-- 单重规则的逐层求值 (继承行沿来源行、换料行按原料或新料; 深度封顶防止异常数据成环)。
CREATE FUNCTION fn_workshop_material_unit_weight_step(p_row UUID, p_depth INT, OUT unit_weight NUMERIC, OUT weight_source TEXT)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    material_row production_execution_periodic_materials%ROWTYPE;
    material_change production_execution_material_changes%ROWTYPE;
    replaced_row production_execution_periodic_materials%ROWTYPE;
    product UUID;
BEGIN
    IF p_depth > 32 THEN RETURN; END IF;
    SELECT * INTO material_row FROM production_execution_periodic_materials WHERE id = p_row;
    IF NOT FOUND THEN RETURN; END IF;
    SELECT segment.product_goods_id INTO product
    FROM production_execution_segments segment WHERE segment.id = material_row.execution_segment_id;

    IF material_row.origin IN ('BOM', 'CHOICE', 'INHERITED') THEN
        unit_weight := fn_workshop_material_edge_weight(product, material_row.material_goods_id, material_row.material_color_id);
        IF unit_weight IS NOT NULL THEN
            weight_source := 'BOM_AT_CLOSE';
            RETURN;
        END IF;
        IF material_row.design_qty_snapshot IS NOT NULL THEN
            unit_weight := material_row.design_qty_snapshot;
            weight_source := 'SEGMENT_SNAPSHOT';
            RETURN;
        END IF;
        IF material_row.origin = 'INHERITED' THEN
            SELECT step.unit_weight, step.weight_source INTO unit_weight, weight_source
            FROM fn_workshop_material_unit_weight_step(material_row.source_row_id, p_depth + 1) step;
        END IF;
        RETURN;
    END IF;

    SELECT * INTO material_change FROM production_execution_material_changes WHERE id = material_row.change_id;
    IF material_change.weight_basis = 'FROM_REPLACED' AND material_change.from_row_id IS NOT NULL THEN
        SELECT * INTO replaced_row FROM production_execution_periodic_materials WHERE id = material_change.from_row_id;
        unit_weight := fn_workshop_material_edge_weight(product, replaced_row.material_goods_id, replaced_row.material_color_id);
        IF unit_weight IS NOT NULL THEN
            weight_source := 'REPLACED_ROW_BOM';
            RETURN;
        END IF;
        SELECT step.unit_weight, step.weight_source INTO unit_weight, weight_source
        FROM fn_workshop_material_unit_weight_step(replaced_row.id, p_depth + 1) step;
        IF weight_source = 'BOM_AT_CLOSE' THEN
            weight_source := 'REPLACED_ROW_BOM';
        END IF;
        RETURN;
    END IF;

    unit_weight := fn_workshop_material_edge_weight(product, material_row.material_goods_id, material_row.material_color_id);
    IF unit_weight IS NOT NULL THEN
        weight_source := 'BOM_AT_CLOSE';
    ELSIF material_row.design_qty_snapshot IS NOT NULL THEN
        unit_weight := material_row.design_qty_snapshot;
        weight_source := 'SEGMENT_SNAPSHOT';
    END IF;
END;
$$;

-- 4.6 单重唯一规则 (BOM/认料/继承行取产品当前 BOM 期间边, 没有取段快照; 换料行按换料单的单重依据)。
CREATE FUNCTION fn_workshop_material_unit_weight(p_row UUID, OUT unit_weight NUMERIC, OUT weight_source TEXT)
LANGUAGE plpgsql STABLE AS $$
BEGIN
    SELECT step.unit_weight, step.weight_source INTO unit_weight, weight_source
    FROM fn_workshop_material_unit_weight_step(p_row, 0) step;
END;
$$;

-- 4.7 理论用量唯一定义: 已审报工 x 所在期间料行的单个重量 (只用 BOM 设计单重)。
CREATE FUNCTION fn_workshop_material_period_theory(p_bin UUID, p_from DATE, p_to DATE)
RETURNS TABLE(report_item_id UUID, report_id UUID, business_date DATE, execution_segment_id UUID,
              cost_scope_segment_id UUID, product_goods_id UUID, periodic_row_id UUID,
              material_goods_id UUID, material_color_id UUID, output_qty_base NUMERIC,
              unit_weight NUMERIC, weight_source TEXT, theory_qty NUMERIC)
LANGUAGE sql STABLE AS $$
    WITH pairs AS MATERIALIZED (
        SELECT item.id AS item_id, item.report_id AS item_report_id, report.bill_date AS bill_date,
               item.execution_segment_id AS segment_id, segment.product_goods_id AS product_id,
               material_row.id AS row_id, material_row.material_goods_id AS material_id,
               material_row.material_color_id AS color_id
        FROM production_execution_periodic_materials material_row
        JOIN production_execution_segments segment ON segment.id = material_row.execution_segment_id
        JOIN production_daily_report_items item
          ON item.execution_segment_id = material_row.execution_segment_id AND NOT item.is_deleted
        JOIN production_daily_reports report
          ON report.id = item.report_id AND report.status = 1 AND NOT report.is_deleted
         AND report.bill_date BETWEEN p_from AND p_to
         AND report.bill_date >= material_row.effective_from
         AND (material_row.effective_to IS NULL OR report.bill_date <= material_row.effective_to)
        WHERE material_row.bin_warehouse_id = p_bin
    ), weights AS MATERIALIZED (
        SELECT used.row_id, weight.unit_weight AS weight_value, weight.weight_source AS weight_label
        FROM (SELECT DISTINCT pairs.row_id FROM pairs) used
        CROSS JOIN LATERAL fn_workshop_material_unit_weight(used.row_id) weight
    ), scopes AS MATERIALIZED (
        SELECT used.segment_id, fn_production_execution_cost_scope(used.segment_id) AS scope_id
        FROM (SELECT DISTINCT pairs.segment_id FROM pairs) used
    )
    SELECT pairs.item_id, pairs.item_report_id, pairs.bill_date, pairs.segment_id, scopes.scope_id,
           pairs.product_id, pairs.row_id, pairs.material_id, pairs.color_id, produced.qty,
           weights.weight_value, weights.weight_label,
           CASE WHEN weights.weight_value IS NULL THEN NULL ELSE round(produced.qty * weights.weight_value, 6) END
    FROM pairs
    JOIN weights ON weights.row_id = pairs.row_id
    JOIN scopes ON scopes.segment_id = pairs.segment_id
    CROSS JOIN LATERAL (SELECT fn_report_item_material_output_qty(pairs.item_id) AS qty) produced
$$;

-- 4.8 截至某期期末的账面 (按期间归属, 含该期盘点过账)。
CREATE FUNCTION fn_workshop_material_book_as_of(p_period UUID, p_goods UUID, p_color UUID)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT COALESCE(sum(ledger.signed_qty), 0)
    FROM workshop_material_periods target
    JOIN workshop_material_periods ledger_period
      ON ledger_period.bin_warehouse_id = target.bin_warehouse_id AND ledger_period.period_no <= target.period_no
    JOIN v_workshop_material_bin_ledger ledger
      ON ledger.period_id = ledger_period.id AND ledger.bin_warehouse_id = target.bin_warehouse_id
    WHERE target.id = p_period AND ledger.goods_id = p_goods AND ledger.color_id IS NOT DISTINCT FROM p_color
$$;

-- 4.9 段的内料仓用料状态: NO_BIN / NEED_BIN / NEED_CHOICE / KNOWN / ORDER_ONLY。
--     带事实参数的版本供插入前的开工门使用 (段行尚未落库)。
CREATE FUNCTION fn_segment_bin_material_state_of(p_segment UUID, p_product UUID, p_workshop UUID, p_source UUID)
RETURNS TEXT LANGUAGE plpgsql STABLE AS $$
DECLARE
    enabled BOOLEAN;
    has_edge BOOLEAN;
    source_segment UUID;
BEGIN
    -- 段上有整批领料货品的未核清按单需求 (上线前按工单领过): 按工单做完为止, 不绑定。
    IF EXISTS (
        SELECT 1 FROM production_material_demands demand
        WHERE demand.execution_segment_id = p_segment
          AND CASE WHEN (SELECT goods.issue_method FROM goods WHERE goods.id = demand.goods_id) = 'PERIODIC'
                   THEN fn_material_demand_uncleared(demand.id) ELSE FALSE END) THEN
        RETURN 'ORDER_ONLY';
    END IF;
    enabled := EXISTS (
        SELECT 1 FROM workshop_material_settings settings
        WHERE settings.workshop_department_id = p_workshop AND settings.periodic_enabled);
    has_edge := fn_goods_has_periodic_bom(p_product);
    IF NOT enabled THEN
        RETURN CASE WHEN has_edge THEN 'NEED_BIN' ELSE 'NO_BIN' END;
    END IF;
    IF has_edge THEN
        RETURN 'KNOWN';
    END IF;
    source_segment := COALESCE(p_source, (
        SELECT proof.source_execution_segment_id FROM production_actual_output_supplement_proofs proof
        WHERE proof.supplement_execution_segment_id = p_segment
        ORDER BY proof.created_at, proof.id LIMIT 1));
    IF source_segment IS NOT NULL AND EXISTS (
        SELECT 1 FROM production_execution_periodic_materials material_row
        WHERE material_row.execution_segment_id = source_segment AND material_row.effective_to IS NULL) THEN
        RETURN 'KNOWN';
    END IF;
    IF EXISTS (
        SELECT 1 FROM goods_periodic_material_choices choice
        WHERE choice.product_goods_id = p_product AND choice.superseded_at IS NULL AND choice.kind = 'MATERIAL') THEN
        RETURN 'KNOWN';
    END IF;
    IF EXISTS (
        SELECT 1 FROM goods_periodic_material_choices choice
        WHERE choice.product_goods_id = p_product AND choice.superseded_at IS NULL AND choice.kind = 'NONE') THEN
        RETURN 'ORDER_ONLY';
    END IF;
    RETURN 'NEED_CHOICE';
END;
$$;

CREATE FUNCTION fn_segment_bin_material_state(p_segment UUID) RETURNS TEXT LANGUAGE plpgsql STABLE AS $$
DECLARE
    segment RECORD;
BEGIN
    IF EXISTS (SELECT 1 FROM production_execution_periodic_materials material_row
               WHERE material_row.execution_segment_id = p_segment) THEN
        RETURN 'KNOWN';
    END IF;
    SELECT execution.product_goods_id, execution.workshop_department_id, execution.source_segment_id INTO segment
    FROM production_execution_segments execution WHERE execution.id = p_segment;
    IF NOT FOUND THEN
        RETURN 'NO_BIN';
    END IF;
    RETURN fn_segment_bin_material_state_of(p_segment, segment.product_goods_id,
        segment.workshop_department_id, segment.source_segment_id);
END;
$$;

-- 4.10 报工截止: 只看段绑定了哪个内料仓, 不看期间料行的有效区间。
CREATE FUNCTION fn_workshop_material_report_date_locked(p_segment UUID, p_date DATE)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT EXISTS (
        SELECT 1
        FROM production_execution_periodic_materials material_row
        JOIN workshop_material_periods period
          ON period.bin_warehouse_id = material_row.bin_warehouse_id AND period.status = 'CLOSED'
         AND p_date BETWEEN period.start_date AND period.end_date
        WHERE material_row.execution_segment_id = p_segment)
$$;

-- 4.11 拦结算的情况: 等上一期结算、未审报工、缺单重、有理论没进过料。
CREATE FUNCTION fn_workshop_material_close_blockers(p_period UUID)
RETURNS TABLE(kind TEXT, report_id UUID, product_goods_id UUID, material_goods_id UUID, material_color_id UUID, qty NUMERIC)
LANGUAGE sql STABLE AS $$
    WITH target AS (
        SELECT period.id AS period_id, period.bin_warehouse_id AS bin_id, period.period_no AS target_no,
               period.start_date AS from_date, COALESCE(period.end_date, 'infinity'::date) AS to_date
        FROM workshop_material_periods period WHERE period.id = p_period
    ), theory AS MATERIALIZED (
        SELECT used.* FROM target
        CROSS JOIN LATERAL fn_workshop_material_period_theory(target.bin_id, target.from_date, target.to_date) used
    )
    SELECT 'PREVIOUS_PERIOD_OPEN'::text, NULL::uuid, NULL::uuid, NULL::uuid, NULL::uuid, NULL::numeric
    FROM target
    JOIN workshop_material_periods previous
      ON previous.bin_warehouse_id = target.bin_id AND previous.period_no = target.target_no - 1
     AND previous.status <> 'CLOSED'
    UNION ALL
    SELECT 'DRAFT_REPORT'::text, report.id, NULL::uuid, NULL::uuid, NULL::uuid, NULL::numeric
    FROM target
    JOIN production_daily_reports report
      ON report.status = 0 AND NOT report.is_deleted AND report.bill_date BETWEEN target.from_date AND target.to_date
    WHERE EXISTS (
        SELECT 1 FROM production_daily_report_items item
        JOIN production_execution_periodic_materials material_row
          ON material_row.execution_segment_id = item.execution_segment_id AND material_row.bin_warehouse_id = target.bin_id
        WHERE item.report_id = report.id AND NOT item.is_deleted)
    UNION ALL
    SELECT 'MISSING_WEIGHT'::text, NULL::uuid, theory.product_goods_id, theory.material_goods_id,
           theory.material_color_id, sum(theory.output_qty_base)
    FROM theory
    WHERE theory.unit_weight IS NULL
    GROUP BY theory.product_goods_id, theory.material_goods_id, theory.material_color_id
    UNION ALL
    SELECT 'THEORY_WITHOUT_STOCK'::text, NULL::uuid, NULL::uuid, theory.material_goods_id,
           theory.material_color_id, sum(theory.theory_qty)
    FROM theory CROSS JOIN target
    WHERE theory.theory_qty IS NOT NULL
    GROUP BY target.period_id, theory.material_goods_id, theory.material_color_id
    HAVING sum(theory.theory_qty) > 0 AND NOT EXISTS (
        SELECT 1 FROM workshop_material_period_lines line
        WHERE line.period_id = target.period_id AND line.goods_id = theory.material_goods_id
          AND line.color_id IS NOT DISTINCT FROM theory.material_color_id
          AND line.opening_qty + line.transfer_in_qty > 0)
$$;

-- 4.12 内料仓页每种料的账面、上次实盘、本期进出、估算已用与估计还剩、仓库可发、缺单重件数、未审报工张数。
--      估计还剩 = 最近一次已盘点期末 + 之后各期进出 - 之后的理论已用 (缺单重的不计入)。
CREATE FUNCTION fn_workshop_material_bin_position(p_bin UUID)
RETURNS TABLE(goods_id UUID, color_id UUID, book_qty NUMERIC, last_count_qty NUMERIC, last_count_date DATE,
              period_in_qty NUMERIC, period_return_qty NUMERIC, period_other_qty NUMERIC,
              estimated_used_qty NUMERIC, estimated_remaining_qty NUMERIC, warehouse_available_qty NUMERIC,
              missing_weight_products INT, draft_report_count INT)
LANGUAGE sql STABLE AS $$
    WITH open_period AS (
        SELECT period.id AS period_id, period.start_date AS from_date
        FROM workshop_material_periods period
        WHERE period.bin_warehouse_id = p_bin AND period.status = 'OPEN'
    ), counted AS (
        SELECT period.id AS period_id, period.period_no AS counted_no, period.end_date AS count_date
        FROM workshop_material_periods period
        WHERE period.bin_warehouse_id = p_bin AND period.status IN ('COUNTED', 'CLOSED')
        ORDER BY period.period_no DESC
        LIMIT 1
    ), since AS (
        SELECT COALESCE((SELECT counted.count_date + 1 FROM counted),
                        (SELECT min(period.start_date) FROM workshop_material_periods period
                         WHERE period.bin_warehouse_id = p_bin)) AS from_date
    ), theory AS MATERIALIZED (
        SELECT used.* FROM since
        CROSS JOIN LATERAL fn_workshop_material_period_theory(p_bin, since.from_date, 'infinity'::date) used
        WHERE since.from_date IS NOT NULL AND EXISTS (SELECT 1 FROM open_period)
    ), materials AS (
        SELECT DISTINCT ledger.goods_id AS material_id, ledger.color_id AS material_color
        FROM v_workshop_material_bin_ledger ledger WHERE ledger.bin_warehouse_id = p_bin
        UNION
        SELECT theory.material_goods_id, theory.material_color_id FROM theory
    ), figures AS (
        SELECT material.material_id, material.material_color,
            COALESCE((SELECT sum(ledger.signed_qty) FROM v_workshop_material_bin_ledger ledger
                      WHERE ledger.bin_warehouse_id = p_bin AND ledger.goods_id = material.material_id
                        AND ledger.color_id IS NOT DISTINCT FROM material.material_color), 0) AS book,
            CASE WHEN EXISTS (SELECT 1 FROM counted) THEN COALESCE((
                SELECT line.closing_qty FROM counted
                JOIN workshop_material_period_lines line ON line.period_id = counted.period_id
                WHERE line.goods_id = material.material_id
                  AND line.color_id IS NOT DISTINCT FROM material.material_color), 0) END AS last_count,
            (SELECT counted.count_date FROM counted) AS last_count_date,
            COALESCE((SELECT sum(ledger.signed_qty) FROM v_workshop_material_bin_ledger ledger JOIN open_period
                        ON ledger.period_id = open_period.period_id
                      WHERE ledger.source_kind = 'ISSUE' AND ledger.goods_id = material.material_id
                        AND ledger.color_id IS NOT DISTINCT FROM material.material_color), 0) AS period_in,
            COALESCE((SELECT -sum(ledger.signed_qty) FROM v_workshop_material_bin_ledger ledger JOIN open_period
                        ON ledger.period_id = open_period.period_id
                      WHERE ledger.source_kind = 'RETURN' AND ledger.goods_id = material.material_id
                        AND ledger.color_id IS NOT DISTINCT FROM material.material_color), 0) AS period_return,
            COALESCE((SELECT -sum(ledger.signed_qty) FROM v_workshop_material_bin_ledger ledger JOIN open_period
                        ON ledger.period_id = open_period.period_id
                      WHERE ledger.source_kind = 'OTHER_ISSUE' AND ledger.goods_id = material.material_id
                        AND ledger.color_id IS NOT DISTINCT FROM material.material_color), 0) AS period_other,
            COALESCE((SELECT sum(ledger.signed_qty) FROM v_workshop_material_bin_ledger ledger
                      JOIN workshop_material_periods ledger_period ON ledger_period.id = ledger.period_id
                      WHERE ledger.bin_warehouse_id = p_bin AND ledger.goods_id = material.material_id
                        AND ledger.color_id IS NOT DISTINCT FROM material.material_color
                        AND ledger.source_kind IN ('ISSUE', 'RETURN', 'OTHER_ISSUE')
                        AND ledger_period.period_no > COALESCE((SELECT counted.counted_no FROM counted), 0)), 0) AS moved_since,
            COALESCE((SELECT sum(theory.theory_qty) FROM theory
                      WHERE theory.material_goods_id = material.material_id
                        AND theory.material_color_id IS NOT DISTINCT FROM material.material_color), 0) AS used,
            GREATEST(
                COALESCE((SELECT sum(balance.qty) FROM stock_balances balance
                          WHERE balance.goods_id = material.material_id
                            AND balance.color_id IS NOT DISTINCT FROM material.material_color
                            AND fn_warehouse_is_active_accounting_leaf(balance.warehouse_id)), 0)
                - COALESCE((SELECT sum(reservation.qty - reservation.consumed_qty - reservation.released_qty)
                            FROM stock_reservations reservation
                            WHERE NOT reservation.is_deleted AND reservation.status = 0
                              AND reservation.goods_id = material.material_id
                              AND reservation.color_id IS NOT DISTINCT FROM material.material_color
                              AND (reservation.warehouse_id IS NULL
                                   OR fn_warehouse_is_active_accounting_leaf(reservation.warehouse_id))), 0)
                - COALESCE((SELECT GREATEST(COALESCE(goods.min_qty::numeric, 0), 0) FROM goods
                            WHERE goods.id = material.material_id), 0),
                0) AS available,
            (SELECT count(DISTINCT theory.product_goods_id) FROM theory
             WHERE theory.material_goods_id = material.material_id
               AND theory.material_color_id IS NOT DISTINCT FROM material.material_color
               AND theory.unit_weight IS NULL)::int AS missing_products,
            (SELECT count(DISTINCT report.id)
             FROM since
             JOIN production_daily_reports report
               ON report.status = 0 AND NOT report.is_deleted AND report.bill_date >= since.from_date
             JOIN production_daily_report_items item ON item.report_id = report.id AND NOT item.is_deleted
             JOIN production_execution_periodic_materials material_row
               ON material_row.execution_segment_id = item.execution_segment_id
              AND material_row.bin_warehouse_id = p_bin
              AND material_row.material_goods_id = material.material_id
              AND material_row.material_color_id IS NOT DISTINCT FROM material.material_color)::int AS draft_reports
        FROM materials material
    )
    SELECT figures.material_id, figures.material_color, figures.book, figures.last_count, figures.last_count_date,
           figures.period_in, figures.period_return, figures.period_other, figures.used,
           COALESCE(figures.last_count, 0) + figures.moved_since - figures.used,
           figures.available, figures.missing_products, figures.draft_reports
    FROM figures
    ORDER BY figures.material_id, figures.material_color
$$;

-- 4.13 内料仓货品出库的来源核验: 只认本事务里内料仓服务刚登记的单据或盘点过账。
CREATE FUNCTION fn_workshop_material_bin_movement_authorized(
    p_kind TEXT, p_source UUID, p_doc UUID, p_item UUID, p_warehouse UUID, p_goods UUID, p_color UUID, p_qty NUMERIC)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT CASE
        WHEN p_kind IN ('ISSUE_OUT', 'RETURN_OUT', 'OTHER_ISSUE_OUT') THEN EXISTS (
            SELECT 1
            FROM workshop_material_stock_documents registration
            JOIN stock_documents document ON document.id = registration.stock_document_id
            JOIN stock_document_items item ON item.doc_id = document.id
            JOIN goods material ON material.id = item.goods_id AND material.issue_method = 'PERIODIC'
            WHERE registration.stock_document_id = p_source
              AND document.id = p_doc
              AND registration.xmin = pg_current_xact_id()::xid
              AND item.id = p_item AND NOT item.is_deleted AND NOT document.is_deleted
              AND item.goods_id = p_goods AND item.color_id IS NOT DISTINCT FROM p_color
              AND p_qty > 0
              AND ((p_kind = 'ISSUE_OUT' AND registration.kind = 'ISSUE' AND document.doc_type = 'TRANSFER'
                    AND p_warehouse = document.warehouse_id
                    AND document.to_warehouse_id = registration.bin_warehouse_id)
                OR (p_kind = 'RETURN_OUT' AND registration.kind = 'RETURN' AND document.doc_type = 'TRANSFER'
                    AND p_warehouse = registration.bin_warehouse_id
                    AND document.warehouse_id = registration.bin_warehouse_id)
                OR (p_kind = 'OTHER_ISSUE_OUT' AND registration.kind = 'OTHER_ISSUE' AND document.doc_type = 'OTHER_OUT'
                    AND p_warehouse = registration.bin_warehouse_id
                    AND document.warehouse_id = registration.bin_warehouse_id)))
        WHEN p_kind IN ('CONSUME', 'CONSUME_REVERSE', 'GAIN', 'GAIN_REVERSE') THEN EXISTS (
            SELECT 1
            FROM workshop_material_count_postings posting
            JOIN goods material ON material.id = posting.goods_id AND material.issue_method = 'PERIODIC'
            WHERE posting.id = p_source
              AND posting.xmin = pg_current_xact_id()::xid
              AND posting.movement_id IS NULL
              AND posting.kind = p_kind AND posting.count_id = p_doc AND posting.period_line_id = p_item
              AND posting.bin_warehouse_id = p_warehouse AND posting.goods_id = p_goods
              AND posting.color_id IS NOT DISTINCT FROM p_color AND posting.qty = p_qty)
        ELSE FALSE
    END
$$;

-- 4.14 FQC 报废/拒收补产: 段在内料仓用料 (期间料行仍有效) 且产品没有按单的生产硬门槛边时, 不再等领料。
CREATE FUNCTION fn_fqc_replenishment_periodic_only(p_authorization_id UUID) RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT EXISTS (
        SELECT 1 FROM production_fqc_recovery_authorizations auth
        WHERE auth.id = p_authorization_id
          AND auth.disposition_code IN ('SCRAP', 'REJECT')
          AND EXISTS (
              SELECT 1 FROM production_execution_periodic_materials material_row
              WHERE material_row.execution_segment_id = auth.execution_segment_id AND material_row.effective_to IS NULL)
          AND NOT EXISTS (
              SELECT 1 FROM goods_bom_items bom
              JOIN goods component ON component.id = bom.component_goods_id
              WHERE bom.goods_id = auth.goods_id AND NOT bom.is_deleted AND bom.hard_gate
                AND bom.control_stage IN ('START', 'ASSEMBLY', 'FINISH')
                AND component.issue_method <> 'PERIODIC'))
$$;

-- 4.15 什么时候解除领料发现门: 内料仓用料已知, 且认料没勾"还要按工单领别的料"。
CREATE FUNCTION fn_segment_bin_discovery_released(p_segment UUID) RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT fn_segment_bin_material_state(p_segment) = 'KNOWN'
       AND NOT EXISTS (
           SELECT 1
           FROM production_execution_segments segment
           JOIN goods_periodic_material_choices choice
             ON choice.product_goods_id = segment.product_goods_id AND choice.superseded_at IS NULL
            AND choice.kind = 'MATERIAL' AND choice.also_order_materials
           WHERE segment.id = p_segment)
$$;

-- 4.16 缺单重清单: 本仓每个未结算期间里有产量没单重的 (期, 产品, 料, 产量)。
CREATE FUNCTION fn_workshop_material_missing_weights(p_bin UUID)
RETURNS TABLE(period_id UUID, product_goods_id UUID, material_goods_id UUID, material_color_id UUID, output_qty NUMERIC)
LANGUAGE sql STABLE AS $$
    SELECT period.id, theory.product_goods_id, theory.material_goods_id, theory.material_color_id,
           sum(theory.output_qty_base)
    FROM workshop_material_periods period
    CROSS JOIN LATERAL fn_workshop_material_period_theory(
        period.bin_warehouse_id, period.start_date, COALESCE(period.end_date, 'infinity'::date)) theory
    WHERE period.bin_warehouse_id = p_bin AND period.status <> 'CLOSED' AND theory.unit_weight IS NULL
    GROUP BY period.id, theory.product_goods_id, theory.material_goods_id, theory.material_color_id
$$;

-- =====================================================================
-- 5. 其余视图 (报表只读结果表; 金额读价值节点现值)
-- =====================================================================
CREATE VIEW v_workshop_material_period_report AS
SELECT period.bin_warehouse_id, period.workshop_department_id, period.id AS period_id, period.period_no,
       period.start_date, period.end_date, period.status AS period_status,
       line.id AS period_line_id, line.goods_id, line.color_id, line.unit_id, line.cost_basis,
       line.opening_qty, line.transfer_in_qty, line.return_qty, line.other_issue_qty, line.closing_qty,
       line.actual_qty,
       close.id AS close_id, close.close_no, close.closed_at,
       material.id AS close_material_id, material.theory_qty, material.allocation_basis_qty,
       CASE WHEN material.theory_qty IS NULL THEN NULL ELSE line.actual_qty - material.theory_qty END AS diff_qty,
       material.waste_rate, material.outcome, material.flags, material.consumed_qty, material.loss_qty,
       CASE WHEN material.id IS NULL THEN NULL ELSE
           COALESCE((SELECT sum(node.basis_value_local)
                     FROM workshop_material_close_allocations allocation
                     JOIN stock_value_nodes node ON node.id = allocation.value_node_id
                     WHERE allocation.close_material_id = material.id AND allocation.reversed_at IS NULL), 0)
         + COALESCE((SELECT sum(node.basis_value_local)
                     FROM stock_value_events event
                     JOIN stock_value_nodes node ON node.id = event.result_node_id
                     WHERE event.source_event_id = material.id
                       AND event.source_doc_type = 'WORKSHOP_PERIOD_LOSS'), 0) END AS current_value,
       material.value_at_close
FROM workshop_material_period_lines line
JOIN workshop_material_periods period ON period.id = line.period_id
LEFT JOIN workshop_material_period_closes close ON close.period_id = period.id AND close.status = 'ACTIVE'
LEFT JOIN workshop_material_close_materials material ON material.close_id = close.id AND material.period_line_id = line.id;

CREATE VIEW v_workshop_material_product_report AS
WITH active AS (
    SELECT close.id AS close_id, close.period_id, material.id AS close_material_id,
           material.cost_basis, material.period_line_id
    FROM workshop_material_period_closes close
    JOIN workshop_material_close_materials material ON material.close_id = close.id
    WHERE close.status = 'ACTIVE'
), theory AS (
    SELECT theory_line.close_material_id, theory_line.product_goods_id,
           sum(theory_line.output_qty_base) AS output_qty, sum(theory_line.theory_qty) AS theory_qty
    FROM workshop_material_close_theory_lines theory_line
    JOIN active ON active.close_material_id = theory_line.close_material_id
    GROUP BY theory_line.close_material_id, theory_line.product_goods_id
), allocated AS (
    SELECT allocation.close_material_id, scope.product_goods_id,
           sum(allocation.allocated_qty) AS allocated_qty, sum(COALESCE(node.basis_value_local, 0)) AS current_value
    FROM workshop_material_close_allocations allocation
    JOIN active ON active.close_material_id = allocation.close_material_id
    JOIN production_execution_segments scope ON scope.id = allocation.cost_scope_segment_id
    LEFT JOIN stock_value_nodes node ON node.id = allocation.value_node_id
    WHERE allocation.reversed_at IS NULL
    GROUP BY allocation.close_material_id, scope.product_goods_id
), products AS (
    SELECT COALESCE(theory.close_material_id, allocated.close_material_id) AS close_material_id,
           COALESCE(theory.product_goods_id, allocated.product_goods_id) AS product_goods_id,
           theory.output_qty, theory.theory_qty, allocated.allocated_qty, allocated.current_value
    FROM theory
    FULL JOIN allocated
      ON allocated.close_material_id = theory.close_material_id AND allocated.product_goods_id = theory.product_goods_id
)
SELECT period.bin_warehouse_id, period.workshop_department_id, period.id AS period_id, period.period_no,
       period.start_date, period.end_date, active.close_id, active.close_material_id, active.cost_basis,
       line.goods_id AS material_goods_id, line.color_id AS material_color_id, line.unit_id AS material_unit_id,
       products.product_goods_id, products.output_qty, products.theory_qty,
       COALESCE(products.allocated_qty, 0) AS allocated_qty, COALESCE(products.current_value, 0) AS current_value,
       (SELECT count(DISTINCT exclusive.product_goods_id) FROM workshop_material_close_theory_lines exclusive
        WHERE exclusive.close_material_id = active.close_material_id) = 1 AS exclusive_period
FROM products
JOIN active ON active.close_material_id = products.close_material_id
JOIN workshop_material_period_lines line ON line.id = active.period_line_id
JOIN workshop_material_periods period ON period.id = active.period_id;

CREATE VIEW v_workshop_material_waste_trend AS
SELECT report.bin_warehouse_id, report.goods_id, report.color_id, report.period_id, report.period_no,
       report.start_date, report.end_date, report.waste_rate
FROM v_workshop_material_period_report report
WHERE report.cost_basis = 'OWN' AND report.close_id IS NOT NULL AND report.waste_rate IS NOT NULL;

-- 生产成本投入发现只有一个口径: 清账过账投入 (原 ProductionInventoryValueService 查询) 并上期间分摊投入。
CREATE VIEW v_production_cost_input_candidates AS
SELECT demand.execution_segment_id AS member_segment_id, event.result_node_id, posting.id AS approved_posting_id,
       CASE WHEN posting.settlement_type = 'CONSUMED' THEN 'CONSUMED' ELSE 'NORMAL_LOSS' END AS input_kind,
       pool.goods_id, pool.color_id, node.active AS node_active
FROM production_material_settlement_postings posting
JOIN production_material_demands demand ON demand.id = posting.demand_id
JOIN stock_value_events event ON event.source_event_id = posting.id AND event.source_doc_type = 'PRODUCTION_CONSUMED_VALUE'
JOIN stock_value_nodes node ON node.id = event.result_node_id
JOIN stock_value_pools pool ON pool.id = node.pool_id
UNION ALL
SELECT allocation.cost_scope_segment_id, event.result_node_id, allocation.id,
       'PERIODIC_MATERIAL', pool.goods_id, pool.color_id, node.active
FROM workshop_material_close_allocations allocation
JOIN workshop_material_close_materials material ON material.id = allocation.close_material_id
JOIN workshop_material_period_closes close ON close.id = material.close_id AND close.status = 'ACTIVE'
JOIN stock_value_events event ON event.source_event_id = allocation.id AND event.source_doc_type = 'WORKSHOP_PERIOD_ALLOCATION'
JOIN stock_value_nodes node ON node.id = event.result_node_id
JOIN stock_value_pools pool ON pool.id = node.pool_id
WHERE allocation.reversed_at IS NULL AND allocation.allocated_qty > 0;

-- =====================================================================
-- 6. 触发器函数、触发器与锚点替换
-- =====================================================================

-- 6.1 只追加 (可带"由空写一次"的列名参数)。
CREATE FUNCTION fn_guard_workshop_material_append_only() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    old_row JSONB;
    new_row JSONB;
    stamped TEXT;
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION '车间内料仓的记录只能追加, 不能删除'
            USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_append_only_guard';
    END IF;
    old_row := to_jsonb(OLD);
    new_row := to_jsonb(NEW);
    IF TG_NARGS > 0 THEN
        FOREACH stamped IN ARRAY TG_ARGV LOOP
            IF old_row -> stamped <> 'null'::jsonb AND old_row -> stamped IS DISTINCT FROM new_row -> stamped THEN
                RAISE EXCEPTION '车间内料仓的记录已经写定, 不能再改'
                    USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_append_only_guard';
            END IF;
            old_row := old_row - stamped;
            new_row := new_row - stamped;
        END LOOP;
    END IF;
    IF old_row IS DISTINCT FROM new_row THEN
        RAISE EXCEPTION '车间内料仓的记录只能追加, 不能修改'
            USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_append_only_guard';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_workshop_material_commands_append_only BEFORE UPDATE OR DELETE ON workshop_material_commands
    FOR EACH ROW EXECUTE FUNCTION fn_guard_workshop_material_append_only();
CREATE TRIGGER trg_material_changes_append_only BEFORE UPDATE OR DELETE ON production_execution_material_changes
    FOR EACH ROW EXECUTE FUNCTION fn_guard_workshop_material_append_only();
CREATE TRIGGER trg_wm_stock_documents_append_only BEFORE UPDATE OR DELETE ON workshop_material_stock_documents
    FOR EACH ROW EXECUTE FUNCTION fn_guard_workshop_material_append_only();
CREATE TRIGGER trg_wm_postings_append_only BEFORE UPDATE OR DELETE ON workshop_material_requisition_postings
    FOR EACH ROW EXECUTE FUNCTION fn_guard_workshop_material_append_only();
CREATE TRIGGER trg_wm_other_issues_append_only BEFORE UPDATE OR DELETE ON workshop_material_other_issues
    FOR EACH ROW EXECUTE FUNCTION fn_guard_workshop_material_append_only('stock_document_item_id', 'movement_id');
CREATE TRIGGER trg_wm_count_postings_append_only BEFORE UPDATE OR DELETE ON workshop_material_count_postings
    FOR EACH ROW EXECUTE FUNCTION fn_guard_workshop_material_append_only('movement_id');
CREATE TRIGGER trg_wm_close_materials_append_only BEFORE UPDATE OR DELETE ON workshop_material_close_materials
    FOR EACH ROW EXECUTE FUNCTION fn_guard_workshop_material_append_only('value_at_close');
CREATE TRIGGER trg_wm_theory_lines_append_only BEFORE UPDATE OR DELETE ON workshop_material_close_theory_lines
    FOR EACH ROW EXECUTE FUNCTION fn_guard_workshop_material_append_only();
CREATE TRIGGER trg_wm_allocations_append_only BEFORE UPDATE OR DELETE ON workshop_material_close_allocations
    FOR EACH ROW EXECUTE FUNCTION fn_guard_workshop_material_append_only('value_node_id', 'value_at_close', 'reversed_at');

-- 6.2 货品发料方式: 整批领料必须是重量单位; 发料方式与分摊方式只能经切换服务 (会话标记) 改。
CREATE FUNCTION fn_guard_goods_issue_method() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.issue_method = 'PERIODIC' AND NOT EXISTS (
        SELECT 1 FROM unit_measurement_profiles profile
        WHERE profile.unit_id = NEW.unit_id AND profile.measurement_dimension = 'MASS') THEN
        RAISE EXCEPTION '整批领料的料基本单位必须是重量单位'
            USING ERRCODE = '23514', CONSTRAINT = 'goods_periodic_mass_unit_guard';
    END IF;
    IF TG_OP = 'UPDATE'
       AND (OLD.issue_method IS DISTINCT FROM NEW.issue_method
            OR OLD.periodic_cost_basis IS DISTINCT FROM NEW.periodic_cost_basis)
       AND COALESCE(current_setting('app.workshop_material_issue_method_switch', true), '') <> 'on' THEN
        RAISE EXCEPTION '请在基础资料的"发料方式"里切换, 系统会先核对并转换相关 BOM'
            USING ERRCODE = '23514', CONSTRAINT = 'goods_issue_method_switch_guard';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_goods_issue_method BEFORE INSERT ON goods
    FOR EACH ROW WHEN (NEW.issue_method = 'PERIODIC') EXECUTE FUNCTION fn_guard_goods_issue_method();
CREATE TRIGGER trg_guard_goods_issue_method_upd BEFORE UPDATE OF issue_method, periodic_cost_basis, unit_id ON goods
    FOR EACH ROW WHEN (OLD.issue_method IS DISTINCT FROM NEW.issue_method
        OR OLD.periodic_cost_basis IS DISTINCT FROM NEW.periodic_cost_basis
        OR OLD.unit_id IS DISTINCT FROM NEW.unit_id)
    EXECUTE FUNCTION fn_guard_goods_issue_method();

-- 提交时核对切换前提 (按提交时的货品现状判定)。
CREATE FUNCTION fn_assert_goods_issue_method_switch() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    current_goods goods%ROWTYPE;
    material_name TEXT;
BEGIN
    SELECT * INTO current_goods FROM goods WHERE id = NEW.id;
    IF NOT FOUND THEN RETURN NULL; END IF;
    material_name := COALESCE(NULLIF(btrim(current_goods.name), ''), current_goods.code, '这种料');

    IF current_goods.issue_method = 'PERIODIC' AND OLD.issue_method IS DISTINCT FROM 'PERIODIC' THEN
        IF EXISTS (
            SELECT 1 FROM goods_bom_items bom
            WHERE bom.component_goods_id = current_goods.id AND NOT bom.is_deleted
              AND (current_goods.periodic_cost_basis IN ('SHARED', 'EXPENSE')
                   OR bom.control_stage <> 'START' OR bom.consumption_basis <> 'PER_UNIT'
                   OR bom.basis_output_qty <> 1 OR bom.hard_gate OR bom.qty <= 0)) THEN
            RAISE EXCEPTION '「%」在 BOM 里还有按包、按批或齐套门槛的用法, 请在发料方式切换里先转换这些 BOM 行', material_name
                USING ERRCODE = '23514', CONSTRAINT = 'goods_issue_method_bom_shape_guard';
        END IF;
        IF EXISTS (
            SELECT 1 FROM production_material_demands demand
            WHERE demand.goods_id = current_goods.id AND NOT demand.is_deleted
              AND demand.status NOT IN ('RELEASED', 'REVERSED')
              AND fn_material_demand_uncleared(demand.id)) THEN
            RAISE EXCEPTION '「%」还有按工单领出、没有清账的料, 请先做完这些工单或退料清账, 再改为整批领料', material_name
                USING ERRCODE = '23514', CONSTRAINT = 'goods_issue_method_uncleared_demand_guard';
        END IF;
    END IF;

    IF OLD.issue_method = 'PERIODIC' AND current_goods.issue_method = 'ORDER' THEN
        IF EXISTS (
               SELECT 1 FROM stock_balances balance
               JOIN warehouses warehouse ON warehouse.id = balance.warehouse_id AND warehouse.is_line_side
               WHERE balance.goods_id = current_goods.id AND balance.qty <> 0)
           OR EXISTS (
               SELECT 1 FROM production_execution_periodic_materials material_row
               JOIN production_execution_segments segment ON segment.id = material_row.execution_segment_id
               WHERE material_row.material_goods_id = current_goods.id AND material_row.effective_to IS NULL
                 AND segment.status = 'IN_PROGRESS')
           OR EXISTS (
               SELECT 1 FROM goods_periodic_material_choices choice
               WHERE choice.material_goods_id = current_goods.id AND choice.kind = 'MATERIAL'
                 AND choice.superseded_at IS NULL)
           OR EXISTS (
               SELECT 1 FROM workshop_material_period_lines line
               JOIN workshop_material_periods period ON period.id = line.period_id AND period.status <> 'CLOSED'
               WHERE line.goods_id = current_goods.id)
           OR EXISTS (
               SELECT 1 FROM v_workshop_material_bin_ledger ledger
               JOIN workshop_material_periods period ON period.id = ledger.period_id AND period.status <> 'CLOSED'
               WHERE ledger.goods_id = current_goods.id)
           OR EXISTS (
               SELECT 1 FROM workshop_material_settings settings
               CROSS JOIN LATERAL fn_workshop_material_period_theory(
                   settings.periodic_bin_warehouse_id,
                   fn_workshop_material_closed_through(settings.periodic_bin_warehouse_id) + 1,
                   'infinity'::date) theory
               WHERE settings.periodic_enabled AND theory.material_goods_id = current_goods.id) THEN
            RAISE EXCEPTION '「%」还在车间内料仓里用 (有库存、在做的工单、认料或没结算的期间), 处理完才能改回按工单领料', material_name
                USING ERRCODE = '23514', CONSTRAINT = 'goods_issue_method_order_switch_guard';
        END IF;
    END IF;

    IF OLD.periodic_cost_basis IS DISTINCT FROM current_goods.periodic_cost_basis THEN
        IF (current_goods.periodic_cost_basis IN ('SHARED', 'EXPENSE') AND (
                EXISTS (SELECT 1 FROM goods_bom_items bom
                        WHERE bom.component_goods_id = current_goods.id AND NOT bom.is_deleted)
                OR EXISTS (SELECT 1 FROM goods_periodic_material_choices choice
                           WHERE choice.material_goods_id = current_goods.id AND choice.kind = 'MATERIAL'
                             AND choice.superseded_at IS NULL)
                OR EXISTS (SELECT 1 FROM production_execution_periodic_materials material_row
                           JOIN production_execution_segments segment ON segment.id = material_row.execution_segment_id
                           WHERE material_row.material_goods_id = current_goods.id AND material_row.effective_to IS NULL
                             AND segment.status = 'IN_PROGRESS')))
           OR EXISTS (
               SELECT 1 FROM stock_balances balance
               JOIN warehouses warehouse ON warehouse.id = balance.warehouse_id AND warehouse.is_line_side
               WHERE balance.goods_id = current_goods.id AND balance.qty <> 0)
           OR EXISTS (
               SELECT 1 FROM workshop_material_period_lines line
               JOIN workshop_material_periods period ON period.id = line.period_id AND period.status <> 'CLOSED'
               WHERE line.goods_id = current_goods.id)
           OR EXISTS (
               SELECT 1 FROM v_workshop_material_bin_ledger ledger
               JOIN workshop_material_periods period ON period.id = ledger.period_id AND period.status <> 'CLOSED'
               WHERE ledger.goods_id = current_goods.id) THEN
            RAISE EXCEPTION '「%」正在车间内料仓里用, 分摊方式要等这些期间结算、内料仓用完后再改', material_name
                USING ERRCODE = '23514', CONSTRAINT = 'goods_periodic_cost_basis_switch_guard';
        END IF;
    END IF;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_assert_goods_issue_method_switch
    AFTER UPDATE OF issue_method, periodic_cost_basis ON goods
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
    WHEN (OLD.issue_method IS DISTINCT FROM NEW.issue_method
        OR OLD.periodic_cost_basis IS DISTINCT FROM NEW.periodic_cost_basis)
    EXECUTE FUNCTION fn_assert_goods_issue_method_switch();

-- 6.3 BOM 期间边形状与 BOM 接管认料。
CREATE FUNCTION fn_guard_periodic_bom_edge() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    component goods%ROWTYPE;
BEGIN
    IF NEW.is_deleted THEN RETURN NEW; END IF;
    SELECT * INTO component FROM goods WHERE id = NEW.component_goods_id;
    IF NOT FOUND OR component.issue_method <> 'PERIODIC' THEN RETURN NEW; END IF;
    IF component.periodic_cost_basis IN ('SHARED', 'EXPENSE') THEN
        RAISE EXCEPTION '色母这类辅料不写进 BOM, 按当期主料用量分到各产品'
            USING ERRCODE = '23514', CONSTRAINT = 'periodic_bom_edge_shared_guard';
    END IF;
    IF NOT (NEW.control_stage = 'START' AND NEW.consumption_basis = 'PER_UNIT' AND NEW.basis_output_qty = 1
            AND NOT NEW.hard_gate AND NEW.qty > 0) THEN
        RAISE EXCEPTION '整批领料的料在 BOM 里只填单个重量, 不能设成按包、按批或齐套门槛'
            USING ERRCODE = '23514', CONSTRAINT = 'periodic_bom_edge_shape_guard';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_periodic_bom_edge_shape BEFORE INSERT OR UPDATE ON goods_bom_items
    FOR EACH ROW EXECUTE FUNCTION fn_guard_periodic_bom_edge();

CREATE FUNCTION fn_periodic_bom_takeover() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.is_deleted OR NOT EXISTS (
        SELECT 1 FROM goods component WHERE component.id = NEW.component_goods_id AND component.issue_method = 'PERIODIC') THEN
        RETURN NULL;
    END IF;
    -- 与认料同一把产品锁, 认料和新增期间边不会互相看不见。
    PERFORM pg_advisory_xact_lock(hashtextextended('WM-CHOICE:' || NEW.goods_id::text, 740));
    IF EXISTS (
        SELECT 1 FROM goods_periodic_material_choices choice
        WHERE choice.product_goods_id = NEW.goods_id AND choice.superseded_at IS NULL
          AND choice.kind = 'MATERIAL' AND choice.also_order_materials)
       AND NOT fn_goods_has_order_bom(NEW.goods_id) THEN
        RAISE EXCEPTION '这个产品开工时选了"还要按工单领别的料", 请先在 BOM 里填上这些料 (例如嵌件), 再填塑料单个重量'
            USING ERRCODE = '23514', CONSTRAINT = 'periodic_bom_takeover_also_order_guard';
    END IF;
    UPDATE goods_periodic_material_choices
    SET superseded_at = now(),
        superseded_by = NULLIF(current_setting('app.actor_id', true), '')::uuid,
        superseded_reason = 'BOM_TAKEOVER'
    WHERE product_goods_id = NEW.goods_id AND superseded_at IS NULL;
    RETURN NULL;
END;
$$;
CREATE TRIGGER trg_periodic_bom_takeover AFTER INSERT OR UPDATE OF component_goods_id, is_deleted ON goods_bom_items
    FOR EACH ROW EXECUTE FUNCTION fn_periodic_bom_takeover();

-- 6.4 车间整批领料设置。
CREATE FUNCTION fn_guard_workshop_material_settings() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM departments workshop
        JOIN departments production_department
          ON production_department.id = workshop.parent_id AND production_department.code = 'DEPT_PROD'
         AND NOT production_department.is_deleted
        WHERE workshop.id = NEW.workshop_department_id AND NOT workshop.is_deleted) THEN
        RAISE EXCEPTION '整批领料只能在生产部下的车间开启'
            USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_settings_workshop_guard';
    END IF;
    IF NEW.periodic_bin_warehouse_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM warehouses bin
        WHERE bin.id = NEW.periodic_bin_warehouse_id AND bin.is_line_side AND NOT bin.is_deleted
          AND bin.is_accountable AND bin.workshop_department_id = NEW.workshop_department_id) THEN
        RAISE EXCEPTION '只能指定本车间的内料仓'
            USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_settings_bin_guard';
    END IF;
    IF NEW.periodic_enabled AND NOT COALESCE(OLD.periodic_enabled, FALSE) THEN
        IF EXISTS (
            SELECT 1 FROM stock_balances balance
            JOIN goods material ON material.id = balance.goods_id AND material.issue_method = 'PERIODIC'
            WHERE balance.warehouse_id = NEW.periodic_bin_warehouse_id AND balance.qty <> 0) THEN
            RAISE EXCEPTION '这个内料仓里已经有整批领料的料, 请先清空再开启'
                USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_settings_enable_guard';
        END IF;
        IF EXISTS (
            SELECT 1 FROM workshop_material_periods period
            WHERE period.bin_warehouse_id = NEW.periodic_bin_warehouse_id AND period.status = 'CLOSED'
              AND period.end_date >= NEW.go_live_date) THEN
            RAISE EXCEPTION '启用日期必须晚于这个内料仓已结算的日期'
                USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_settings_enable_guard';
        END IF;
    END IF;
    IF TG_OP = 'UPDATE' THEN
        IF OLD.periodic_bin_warehouse_id IS NOT NULL
           AND (NEW.periodic_bin_warehouse_id IS DISTINCT FROM OLD.periodic_bin_warehouse_id
                OR NEW.go_live_date IS DISTINCT FROM OLD.go_live_date)
           AND EXISTS (SELECT 1 FROM v_workshop_material_bin_ledger ledger
                       WHERE ledger.bin_warehouse_id = OLD.periodic_bin_warehouse_id) THEN
            RAISE EXCEPTION '这个车间的内料仓已经有进出记录, 内料仓和启用日期不能再改'
                USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_settings_immutable_guard';
        END IF;
        IF OLD.periodic_enabled AND NOT NEW.periodic_enabled AND (
               EXISTS (SELECT 1 FROM v_workshop_material_bin_ledger ledger
                       WHERE ledger.bin_warehouse_id = OLD.periodic_bin_warehouse_id)
               OR EXISTS (SELECT 1 FROM production_execution_periodic_materials material_row
                          WHERE material_row.bin_warehouse_id = OLD.periodic_bin_warehouse_id)
               OR EXISTS (SELECT 1 FROM workshop_material_requisitions requisition
                          WHERE requisition.bin_warehouse_id = OLD.periodic_bin_warehouse_id
                            AND requisition.status = 'PENDING')) THEN
            RAISE EXCEPTION '这个车间的内料仓已经在用, 不能停用'
                USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_settings_disable_guard';
        END IF;
        IF NEW.row_version <> OLD.row_version + 1 THEN
            RAISE EXCEPTION '整批领料设置已被别人改过, 请刷新后再试'
                USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_settings_version_guard';
        END IF;
        NEW.updated_at := now();
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_workshop_material_settings BEFORE INSERT OR UPDATE ON workshop_material_settings
    FOR EACH ROW EXECUTE FUNCTION fn_guard_workshop_material_settings();

-- 6.5 盘点用过的机台与容器只能停用不能删除 (硬删除靠外键拦住)。
CREATE FUNCTION fn_guard_workshop_machine_soft_delete() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF (TG_TABLE_NAME = 'workshop_machines' AND EXISTS (
            SELECT 1 FROM workshop_material_count_lines line WHERE line.machine_id = NEW.id))
       OR (TG_TABLE_NAME = 'workshop_machine_containers' AND EXISTS (
            SELECT 1 FROM workshop_material_count_lines line WHERE line.container_id = NEW.id)) THEN
        RAISE EXCEPTION '盘点用过的机台或容器只能停用, 不能删除'
            USING ERRCODE = '23514', CONSTRAINT = 'workshop_machine_soft_delete_guard';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_workshop_machine_soft_delete BEFORE UPDATE OF is_deleted ON workshop_machines
    FOR EACH ROW WHEN (NEW.is_deleted AND NOT OLD.is_deleted) EXECUTE FUNCTION fn_guard_workshop_machine_soft_delete();
CREATE TRIGGER trg_guard_workshop_container_soft_delete BEFORE UPDATE OF is_deleted ON workshop_machine_containers
    FOR EACH ROW WHEN (NEW.is_deleted AND NOT OLD.is_deleted) EXECUTE FUNCTION fn_guard_workshop_machine_soft_delete();

-- 6.6 认料。
CREATE FUNCTION fn_guard_periodic_material_choice() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION '认料记录不能删除'
            USING ERRCODE = '23514', CONSTRAINT = 'periodic_choice_history_guard';
    END IF;
    IF TG_OP = 'UPDATE' THEN
        IF OLD.superseded_at IS NOT NULL OR NEW.superseded_at IS NULL
           OR (to_jsonb(NEW) - ARRAY['superseded_at', 'superseded_by', 'superseded_reason'])
              IS DISTINCT FROM (to_jsonb(OLD) - ARRAY['superseded_at', 'superseded_by', 'superseded_reason']) THEN
            RAISE EXCEPTION '认料记录不能修改, 只能作废后重新认料'
                USING ERRCODE = '23514', CONSTRAINT = 'periodic_choice_history_guard';
        END IF;
        RETURN NEW;
    END IF;
    IF NEW.superseded_at IS NOT NULL THEN
        RAISE EXCEPTION '新认料不能是已作废的记录'
            USING ERRCODE = '23514', CONSTRAINT = 'periodic_choice_history_guard';
    END IF;
    PERFORM pg_advisory_xact_lock(hashtextextended('WM-CHOICE:' || NEW.product_goods_id::text, 740));
    IF NEW.kind = 'MATERIAL' THEN
        IF NOT EXISTS (SELECT 1 FROM goods material WHERE material.id = NEW.material_goods_id
                       AND material.issue_method = 'PERIODIC' AND material.periodic_cost_basis = 'OWN') THEN
            RAISE EXCEPTION '认的料必须是整批领料、按单个重量记到产品上的料'
                USING ERRCODE = '23514', CONSTRAINT = 'periodic_choice_material_guard';
        END IF;
        IF EXISTS (SELECT 1 FROM goods_periodic_material_choices choice
                   WHERE choice.product_goods_id = NEW.product_goods_id AND choice.superseded_at IS NULL
                     AND choice.kind = 'NONE') THEN
            RAISE EXCEPTION '这个产品已经选了"不用内料仓的料", 要改请先作废原来的选择'
                USING ERRCODE = '23514', CONSTRAINT = 'periodic_choice_exclusive_guard';
        END IF;
        IF fn_goods_has_periodic_bom(NEW.product_goods_id) THEN
            RAISE EXCEPTION '这个产品 BOM 里已经有整批领料的料, 按 BOM 用料'
                USING ERRCODE = '23514', CONSTRAINT = 'periodic_choice_bom_guard';
        END IF;
        IF NEW.also_order_materials AND fn_goods_has_bom(NEW.product_goods_id) THEN
            RAISE EXCEPTION '这个产品有 BOM, 按 BOM 领料, 不需要勾"还要按工单领别的料"'
                USING ERRCODE = '23514', CONSTRAINT = 'periodic_choice_also_order_guard';
        END IF;
        IF EXISTS (SELECT 1 FROM goods_periodic_material_choices choice
                   WHERE choice.product_goods_id = NEW.product_goods_id AND choice.superseded_at IS NULL
                     AND choice.kind = 'MATERIAL' AND choice.also_order_materials <> NEW.also_order_materials) THEN
            RAISE EXCEPTION '同一个产品认的几种料, "还要按工单领别的料"要选得一样'
                USING ERRCODE = '23514', CONSTRAINT = 'periodic_choice_also_order_guard';
        END IF;
    ELSIF EXISTS (SELECT 1 FROM goods_periodic_material_choices choice
                  WHERE choice.product_goods_id = NEW.product_goods_id AND choice.superseded_at IS NULL
                    AND choice.kind = 'MATERIAL') THEN
        RAISE EXCEPTION '这个产品已经认了内料仓的料, 要改请先作废原来的认料'
            USING ERRCODE = '23514', CONSTRAINT = 'periodic_choice_exclusive_guard';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_periodic_material_choice BEFORE INSERT OR UPDATE OR DELETE ON goods_periodic_material_choices
    FOR EACH ROW EXECUTE FUNCTION fn_guard_periodic_material_choice();

-- 6.7 段的期间料行。
CREATE FUNCTION fn_guard_periodic_material_row() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    settings workshop_material_settings%ROWTYPE;
    closed_through DATE;
    material_change production_execution_material_changes%ROWTYPE;
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION '工单的内料仓用料记录不能删除'
            USING ERRCODE = '23514', CONSTRAINT = 'periodic_row_history_guard';
    END IF;
    IF TG_OP = 'UPDATE' THEN
        IF OLD.effective_to IS NOT NULL OR NEW.effective_to IS NULL
           OR (to_jsonb(NEW) - 'effective_to') IS DISTINCT FROM (to_jsonb(OLD) - 'effective_to') THEN
            RAISE EXCEPTION '工单的内料仓用料记录只能写一次截止日期'
                USING ERRCODE = '23514', CONSTRAINT = 'periodic_row_history_guard';
        END IF;
        -- 截止日可以等于已结算截止日 (已结算期间的用料不变), 不能更早。
        IF NEW.effective_to < fn_workshop_material_closed_through(NEW.bin_warehouse_id) THEN
            RAISE EXCEPTION '已经结算的期间不能再改用料'
                USING ERRCODE = '23514', CONSTRAINT = 'periodic_row_closed_period_guard';
        END IF;
        RETURN NEW;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM goods material WHERE material.id = NEW.material_goods_id
                   AND material.issue_method = 'PERIODIC' AND material.periodic_cost_basis = 'OWN') THEN
        RAISE EXCEPTION '只有整批领料、按单个重量记到产品上的料才能作为工单的内料仓用料'
            USING ERRCODE = '23514', CONSTRAINT = 'periodic_row_material_guard';
    END IF;
    SELECT settings_row.* INTO settings
    FROM production_execution_segments segment
    JOIN workshop_material_settings settings_row
      ON settings_row.workshop_department_id = segment.workshop_department_id AND settings_row.periodic_enabled
    WHERE segment.id = NEW.execution_segment_id;
    IF NOT FOUND OR settings.periodic_bin_warehouse_id IS DISTINCT FROM NEW.bin_warehouse_id THEN
        RAISE EXCEPTION '工单所在车间没有开启整批领料, 或这不是该车间的内料仓'
            USING ERRCODE = '23514', CONSTRAINT = 'periodic_row_bin_guard';
    END IF;
    closed_through := fn_workshop_material_closed_through(NEW.bin_warehouse_id);
    IF NEW.effective_from <= closed_through OR NEW.effective_from < settings.go_live_date THEN
        RAISE EXCEPTION '用料的起始日期必须在已结算期间之后, 且不早于整批领料的启用日期'
            USING ERRCODE = '23514', CONSTRAINT = 'periodic_row_start_guard';
    END IF;
    IF NEW.origin IN ('BOM', 'CHOICE', 'INHERITED')
       AND NEW.effective_from <> GREATEST(settings.go_live_date, closed_through + 1) THEN
        RAISE EXCEPTION '工单开工时的用料要从本期起始日算起'
            USING ERRCODE = '23514', CONSTRAINT = 'periodic_row_start_guard';
    END IF;
    IF NEW.origin = 'CHANGE' THEN
        SELECT * INTO material_change FROM production_execution_material_changes WHERE id = NEW.change_id;
        IF FOUND AND (material_change.execution_segment_id <> NEW.execution_segment_id
                      OR material_change.effective_from <> NEW.effective_from
                      OR material_change.to_material_goods_id <> NEW.material_goods_id
                      OR material_change.to_material_color_id IS DISTINCT FROM NEW.material_color_id) THEN
            RAISE EXCEPTION '换料记录与工单的用料对不上'
                USING ERRCODE = '23514', CONSTRAINT = 'periodic_row_change_guard';
        END IF;
    END IF;
    IF EXISTS (
        SELECT 1 FROM production_execution_periodic_materials other
        WHERE other.execution_segment_id = NEW.execution_segment_id
          AND other.material_goods_id = NEW.material_goods_id
          AND other.material_color_id IS NOT DISTINCT FROM NEW.material_color_id
          AND (other.effective_to IS NULL OR other.effective_to >= NEW.effective_from)) THEN
        RAISE EXCEPTION '同一张工单同一种料的用料时间段不能重叠'
            USING ERRCODE = '23514', CONSTRAINT = 'periodic_row_overlap_guard';
    END IF;
    IF EXISTS (
        SELECT 1 FROM production_material_demands demand
        WHERE demand.execution_segment_id = NEW.execution_segment_id
          AND CASE WHEN (SELECT goods.issue_method FROM goods WHERE goods.id = demand.goods_id) = 'PERIODIC'
                   THEN fn_material_demand_uncleared(demand.id) ELSE FALSE END) THEN
        RAISE EXCEPTION '这张工单已经按工单领过颗粒, 做完或退料清账后再按整批领料'
            USING ERRCODE = '23514', CONSTRAINT = 'periodic_row_order_demand_guard';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_periodic_material_row BEFORE INSERT OR UPDATE OR DELETE ON production_execution_periodic_materials
    FOR EACH ROW EXECUTE FUNCTION fn_guard_periodic_material_row();

-- 6.8 零料证据守卫: 只在 V426 正文里做两处锚点替换, 不加早退 (V701/V710 的早退顺序不变)。
DO $requirement_shape$
DECLARE
    definition TEXT;
    direct_make_anchor TEXT := E'                     AND NOT EXISTS (\n'
        || E'                         SELECT 1\n'
        || E'                         FROM goods_bom_items bom\n'
        || E'                         WHERE bom.goods_id = NEW.product_goods_id\n'
        || E'                           AND bom.is_deleted = FALSE\n'
        || E'                     )';
    hard_gate_anchor TEXT := E'                         ''START'', ''ASSEMBLY'', ''FINISH'')\n'
        || E'               )\n'
        || E'           )';
BEGIN
    SELECT pg_get_functiondef('fn_guard_execution_segment_requirement_shape()'::regprocedure) INTO definition;
    IF (length(definition) - length(replace(definition, direct_make_anchor, ''))) / length(direct_make_anchor) <> 1 THEN
        RAISE EXCEPTION 'V740 fn_guard_execution_segment_requirement_shape direct-make anchor changed';
    END IF;
    IF (length(definition) - length(replace(definition, hard_gate_anchor, ''))) / length(hard_gate_anchor) <> 1 THEN
        RAISE EXCEPTION 'V740 fn_guard_execution_segment_requirement_shape hard-gate anchor changed';
    END IF;
    definition := replace(definition, direct_make_anchor,
        E'                     AND NOT fn_goods_has_order_bom(NEW.product_goods_id)');
    definition := replace(definition, hard_gate_anchor, hard_gate_anchor
        || E'\n           OR\n'
        || E'           (\n'
        || E'               NEW.zero_material_reason = ''PERIODIC_MATERIAL''\n'
        || E'               AND fn_goods_has_periodic_bom(NEW.product_goods_id)\n'
        || E'               AND NOT EXISTS (\n'
        || E'                   SELECT 1 FROM goods_bom_items bom JOIN goods c ON c.id = bom.component_goods_id\n'
        || E'                   WHERE bom.goods_id = NEW.product_goods_id AND bom.is_deleted = FALSE\n'
        || E'                     AND bom.hard_gate = TRUE AND bom.control_stage IN (''START'', ''ASSEMBLY'', ''FINISH'')\n'
        || E'                     AND c.issue_method <> ''PERIODIC'')\n'
        || E'           )');
    EXECUTE definition;
END;
$requirement_shape$;

-- 6.9 领料发现门: 只有内料仓用料已知且认料没勾"还要按工单领别的料"时才解除 (V710 全文 + 追加判定)。
CREATE OR REPLACE FUNCTION fn_material_discovery_pending(p_segment UUID) RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT CASE
        WHEN COALESCE((SELECT material_discovery_required AND material_requirement_mode='ZERO_MATERIAL'
            FROM production_execution_segments WHERE id=p_segment AND NOT is_deleted),FALSE)
        THEN NOT fn_segment_bin_discovery_released(p_segment)
        ELSE FALSE END;
$$;

CREATE OR REPLACE FUNCTION fn_guard_discovery_start() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP='UPDATE' AND OLD.material_discovery_required AND NOT NEW.material_discovery_required THEN
        RAISE EXCEPTION 'Material discovery origin is immutable' USING ERRCODE='23514';
    END IF;
    IF NEW.status='IN_PROGRESS' AND NEW.material_requirement_mode='ZERO_MATERIAL'
       AND (NEW.material_discovery_required OR (TG_OP='INSERT' AND NEW.zero_material_reason='DIRECT_MAKE' AND NEW.source_segment_id IS NULL
            AND NOT EXISTS(SELECT 1 FROM production_actual_output_supplement_proofs proof WHERE proof.supplement_execution_segment_id=NEW.id)))
       AND NOT fn_segment_bin_discovery_released(NEW.id) THEN
        RAISE EXCEPTION '请先提交领料，由仓库登记实际物料并发料后再开工' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END; $$;

-- 开工就绪只排除 NEED_BIN; 待认料 (NEED_CHOICE) 仍算可开工, 由开工确认表先认料, 开工门兜底。
CREATE OR REPLACE FUNCTION fn_execution_start_material_ready(p_segment UUID) RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT NOT fn_material_discovery_pending(p_segment)
       AND fn_segment_bin_material_state(p_segment) <> 'NEED_BIN'
       AND fn_execution_start_material_ready_before_discovery(p_segment);
$$;

-- 6.10 FQC 补产料齐: 原视图口径, 或补产段只用内料仓的料。
CREATE OR REPLACE FUNCTION fn_fqc_replenishment_material_ready(p_authorization_id UUID) RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT EXISTS (
        SELECT 1
        FROM v_production_fqc_replenishment_material_ready ready
        WHERE ready.authorization_id = p_authorization_id
    ) OR fn_fqc_replenishment_periodic_only(p_authorization_id);
$$;

-- 6.11 成本刷新来源: 结算批次或其撤销事件 (对本成本范围有分摊行、操作人一致) 也是合法来源。
DO $cost_refresh_source$
DECLARE definition TEXT; needle TEXT := 'OR EXISTS(SELECT 1 FROM production_daily_reports report';
BEGIN
    SELECT pg_get_functiondef('fn_guard_cost_business_refresh_source()'::regprocedure) INTO definition;
    IF (length(definition) - length(replace(definition, needle, ''))) / length(needle) <> 1 THEN
        RAISE EXCEPTION 'V740 fn_guard_cost_business_refresh_source anchor changed';
    END IF;
    EXECUTE replace(definition, needle,
        'OR EXISTS(SELECT 1 FROM workshop_material_period_closes close
            JOIN workshop_material_close_materials material ON material.close_id=close.id
            JOIN workshop_material_close_allocations allocation ON allocation.close_material_id=material.id
            WHERE allocation.cost_scope_segment_id=NEW.execution_segment_id
              AND ((close.id=NEW.business_refresh_event_id AND close.closed_by=NEW.business_refresh_actor_id)
                OR (close.reversal_event_id=NEW.business_refresh_event_id AND close.reversed_by=NEW.business_refresh_actor_id)))
        ' || needle);
END;
$cost_refresh_source$;

-- 6.12 线边仓来源异常视图豁免内料仓流水视图里的流水 (外包一层, 列不变)。
DO $direct_stock_anomalies$
DECLARE definition TEXT;
BEGIN
    SELECT rtrim(pg_get_viewdef('v_workshop_direct_stock_anomalies'::regclass, true), E';\n ') INTO definition;
    IF definition IS NULL
       OR position('production_workshop_material_custody_moves' IN definition) = 0
       OR position('v_workshop_material_bin_ledger' IN definition) > 0 THEN
        RAISE EXCEPTION 'V740 v_workshop_direct_stock_anomalies anchor changed';
    END IF;
    EXECUTE 'CREATE OR REPLACE VIEW v_workshop_direct_stock_anomalies AS SELECT original.* FROM ('
        || definition || ') original '
        || 'WHERE NOT EXISTS(SELECT 1 FROM v_workshop_material_bin_ledger ledger WHERE ledger.movement_id=original.movement_id)';
END;
$direct_stock_anomalies$;

-- 6.13 委外单一子件判定不把整批领料的料算作子件 (V646 全文 + 两处过滤)。
CREATE OR REPLACE FUNCTION fn_subcontract_sole_component_goods(p_goods_id UUID) RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT EXISTS (
        SELECT 1 FROM goods_bom_items edge
        JOIN goods child ON child.id=edge.component_goods_id AND NOT child.is_deleted
          AND NOT COALESCE(child.auto_created,FALSE) AND child.issue_method<>'PERIODIC'
        WHERE edge.goods_id=p_goods_id AND NOT edge.is_deleted
          AND edge.consumption_basis='PER_UNIT'
          AND edge.control_stage IN ('START','ASSEMBLY','FINISH') AND edge.qty>0
          AND (SELECT COUNT(*) FROM goods_bom_items sibling
               JOIN goods live_child ON live_child.id=sibling.component_goods_id
                 AND NOT live_child.is_deleted AND NOT COALESCE(live_child.auto_created,FALSE)
                 AND live_child.issue_method<>'PERIODIC'
               WHERE sibling.goods_id=p_goods_id AND NOT sibling.is_deleted)=1
    )
$$;

-- 6.13b 委外单一子件的权益批次与可用库存 (V646)、预排未来供给的私有能力 (V571, 之后未改) 只看按单边:
--       整批领料的料不是委外子件, 也不让父件算"有 BOM"。pg_get_functiondef 现取, 锚点恰好一处, 否则中止。
DO $periodic_edge_readers$
DECLARE
    definition TEXT;
    lots_anchor TEXT := 'JOIN goods_bom_items edge ON edge.goods_id=app.goods_id AND NOT edge.is_deleted';
    stock_anchor TEXT := 'FROM target JOIN goods_bom_items edge ON edge.goods_id=target.goods_id AND NOT edge.is_deleted';
    capacity_anchor TEXT := 'NOT EXISTS(SELECT 1 FROM goods_bom_items bom WHERE bom.goods_id=action.goods_id AND NOT bom.is_deleted)';
BEGIN
    SELECT pg_get_functiondef('fn_subcontract_component_entitled_lots(uuid,uuid)'::regprocedure) INTO definition;
    IF (length(definition) - length(replace(definition, lots_anchor, ''))) / length(lots_anchor) <> 1 THEN
        RAISE EXCEPTION 'V740 fn_subcontract_component_entitled_lots edge anchor changed';
    END IF;
    EXECUTE replace(definition, lots_anchor, lots_anchor
        || E'\n        JOIN goods edge_component ON edge_component.id=edge.component_goods_id'
        || E' AND edge_component.issue_method<>''PERIODIC''');

    SELECT pg_get_functiondef('fn_subcontract_component_available_stock(uuid,uuid)'::regprocedure) INTO definition;
    IF (length(definition) - length(replace(definition, stock_anchor, ''))) / length(stock_anchor) <> 1 THEN
        RAISE EXCEPTION 'V740 fn_subcontract_component_available_stock edge anchor changed';
    END IF;
    EXECUTE replace(definition, stock_anchor, stock_anchor
        || E'\n        JOIN goods edge_component ON edge_component.id=edge.component_goods_id'
        || E' AND edge_component.issue_method<>''PERIODIC''');

    SELECT pg_get_functiondef('fn_preplan_future_source_private_capacity_qty(uuid)'::regprocedure) INTO definition;
    IF (length(definition) - length(replace(definition, capacity_anchor, ''))) / length(capacity_anchor) <> 1 THEN
        RAISE EXCEPTION 'V740 fn_preplan_future_source_private_capacity_qty bom anchor changed';
    END IF;
    EXECUTE replace(definition, capacity_anchor, 'NOT fn_goods_has_order_bom(action.goods_id)');
END;
$periodic_edge_readers$;

-- 6.14 整批领料的料永远不能有新的按单需求, 也不能走车间直送。
CREATE FUNCTION fn_guard_periodic_goods_demand() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE material_name TEXT;
BEGIN
    SELECT COALESCE(NULLIF(btrim(material.name), ''), material.code, '这种料') INTO material_name
    FROM goods material WHERE material.id = NEW.goods_id AND material.issue_method = 'PERIODIC';
    IF FOUND THEN
        RAISE EXCEPTION '「%」是整批领到车间内料仓的料, 不能按工单领料', material_name
            USING ERRCODE = '23514', CONSTRAINT = 'periodic_goods_order_demand_guard';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_periodic_goods_demand BEFORE INSERT ON production_material_demands
    FOR EACH ROW EXECUTE FUNCTION fn_guard_periodic_goods_demand();
CREATE TRIGGER trg_guard_periodic_goods_demand_upd BEFORE UPDATE OF goods_id ON production_material_demands
    FOR EACH ROW WHEN (OLD.goods_id IS DISTINCT FROM NEW.goods_id) EXECUTE FUNCTION fn_guard_periodic_goods_demand();

CREATE FUNCTION fn_guard_periodic_goods_direct_transfer() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE material_name TEXT;
BEGIN
    SELECT COALESCE(NULLIF(btrim(material.name), ''), material.code, '这种料') INTO material_name
    FROM production_daily_report_items item
    JOIN goods material ON material.id = item.goods_id AND material.issue_method = 'PERIODIC'
    WHERE item.id = NEW.source_report_item_id;
    IF FOUND THEN
        RAISE EXCEPTION '「%」是整批领到车间内料仓的料, 不能走车间直送', material_name
            USING ERRCODE = '23514', CONSTRAINT = 'periodic_goods_direct_transfer_guard';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_periodic_goods_direct_transfer BEFORE INSERT ON production_workshop_direct_transfer_items
    FOR EACH ROW EXECUTE FUNCTION fn_guard_periodic_goods_direct_transfer();

-- 6.15 开工门 (数据库兜底, 服务端开工门先给更具体的文案)。
CREATE FUNCTION fn_guard_workshop_material_start() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE state TEXT;
BEGIN
    IF TG_OP = 'INSERT' THEN
        state := fn_segment_bin_material_state_of(NEW.id, NEW.product_goods_id, NEW.workshop_department_id, NEW.source_segment_id);
    ELSE
        state := fn_segment_bin_material_state(NEW.id);
    END IF;
    IF state = 'NEED_CHOICE' THEN
        RAISE EXCEPTION '请先在开工确认表里认料, 再开工'
            USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_start_guard';
    ELSIF state = 'NEED_BIN' THEN
        RAISE EXCEPTION '这个产品要从车间内料仓用料, 本车间还没有开启整批领料'
            USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_start_guard';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_workshop_material_start_gate BEFORE UPDATE OF status ON production_execution_segments
    FOR EACH ROW WHEN (NEW.status = 'IN_PROGRESS' AND OLD.status IS DISTINCT FROM 'IN_PROGRESS')
    EXECUTE FUNCTION fn_guard_workshop_material_start();
CREATE TRIGGER trg_workshop_material_start_gate_ins BEFORE INSERT ON production_execution_segments
    FOR EACH ROW WHEN (NEW.status = 'IN_PROGRESS') EXECUTE FUNCTION fn_guard_workshop_material_start();

-- 6.16 开工即绑定内料仓: 来源段 (拆批/追加) 的有效用料 -> 产品 BOM 期间边 -> 有效认料。
--      起始日 = max(启用日, 已结算截止日 + 1), 不用开工时钟 (报工按表头日期归期)。
CREATE FUNCTION fn_bind_workshop_material_on_start() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    settings workshop_material_settings%ROWTYPE;
    from_date DATE;
    source_segment UUID;
    actor UUID := NULLIF(current_setting('app.actor_id', true), '')::uuid;
BEGIN
    IF EXISTS (SELECT 1 FROM production_execution_periodic_materials material_row
               WHERE material_row.execution_segment_id = NEW.id) THEN
        RETURN NULL;
    END IF;
    SELECT * INTO settings FROM workshop_material_settings
    WHERE workshop_department_id = NEW.workshop_department_id AND periodic_enabled;
    IF NOT FOUND THEN RETURN NULL; END IF;
    IF fn_segment_bin_material_state(NEW.id) <> 'KNOWN' THEN RETURN NULL; END IF;
    from_date := GREATEST(settings.go_live_date,
        fn_workshop_material_closed_through(settings.periodic_bin_warehouse_id) + 1);
    source_segment := COALESCE(NEW.source_segment_id, (
        SELECT proof.source_execution_segment_id FROM production_actual_output_supplement_proofs proof
        WHERE proof.supplement_execution_segment_id = NEW.id
        ORDER BY proof.created_at, proof.id LIMIT 1));
    IF source_segment IS NOT NULL AND EXISTS (
        SELECT 1 FROM production_execution_periodic_materials material_row
        WHERE material_row.execution_segment_id = source_segment AND material_row.effective_to IS NULL) THEN
        INSERT INTO production_execution_periodic_materials(
            execution_segment_id, bin_warehouse_id, material_goods_id, material_color_id, unit_id,
            origin, source_row_id, effective_from, created_by)
        SELECT NEW.id, settings.periodic_bin_warehouse_id, source_row.material_goods_id,
               source_row.material_color_id, source_row.unit_id, 'INHERITED', source_row.id, from_date, actor
        FROM production_execution_periodic_materials source_row
        WHERE source_row.execution_segment_id = source_segment AND source_row.effective_to IS NULL
        ORDER BY source_row.created_at, source_row.id;
        RETURN NULL;
    END IF;
    IF fn_goods_has_periodic_bom(NEW.product_goods_id) THEN
        INSERT INTO production_execution_periodic_materials(
            execution_segment_id, bin_warehouse_id, material_goods_id, material_color_id, unit_id,
            origin, bom_item_id, design_qty_snapshot, effective_from, created_by)
        SELECT NEW.id, settings.periodic_bin_warehouse_id, bom.component_goods_id,
               COALESCE(bom.color_id, component.color_id), component.unit_id, 'BOM', bom.id, bom.qty, from_date, actor
        FROM goods_bom_items bom
        JOIN goods component ON component.id = bom.component_goods_id AND component.issue_method = 'PERIODIC'
        WHERE bom.goods_id = NEW.product_goods_id AND NOT bom.is_deleted
        ORDER BY bom.sort_order, bom.id;
        RETURN NULL;
    END IF;
    INSERT INTO production_execution_periodic_materials(
        execution_segment_id, bin_warehouse_id, material_goods_id, material_color_id, unit_id,
        origin, choice_id, effective_from, created_by)
    SELECT NEW.id, settings.periodic_bin_warehouse_id, choice.material_goods_id, choice.material_color_id,
           material.unit_id, 'CHOICE', choice.id, from_date, actor
    FROM goods_periodic_material_choices choice
    JOIN goods material ON material.id = choice.material_goods_id
    WHERE choice.product_goods_id = NEW.product_goods_id AND choice.superseded_at IS NULL AND choice.kind = 'MATERIAL'
    ORDER BY choice.chosen_at, choice.id;
    RETURN NULL;
END;
$$;
CREATE TRIGGER trg_workshop_material_bind_on_start AFTER UPDATE OF status ON production_execution_segments
    FOR EACH ROW WHEN (NEW.status = 'IN_PROGRESS' AND OLD.status IS DISTINCT FROM 'IN_PROGRESS')
    EXECUTE FUNCTION fn_bind_workshop_material_on_start();
CREATE TRIGGER trg_workshop_material_bind_on_start_ins AFTER INSERT ON production_execution_segments
    FOR EACH ROW WHEN (NEW.status = 'IN_PROGRESS') EXECUTE FUNCTION fn_bind_workshop_material_on_start();

-- 6.17 报工截止: 已结算期间的日期不能再新建、审核、红冲或改到那一期 (删除草稿不拦)。
CREATE FUNCTION fn_guard_wm_report_date_lock() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    report production_daily_reports%ROWTYPE;
BEGIN
    IF TG_TABLE_NAME = 'production_daily_reports' THEN
        SELECT * INTO report FROM production_daily_reports WHERE id = NEW.id;
        IF NOT FOUND OR (report.is_deleted AND report.status <> 1) THEN RETURN NULL; END IF;
        IF EXISTS (
            SELECT 1 FROM production_daily_report_items item
            WHERE item.report_id = report.id AND NOT item.is_deleted AND item.execution_segment_id IS NOT NULL
              AND (fn_workshop_material_report_date_locked(item.execution_segment_id, report.bill_date)
                   OR (OLD.bill_date IS DISTINCT FROM NEW.bill_date AND OLD.status = 1
                       AND fn_workshop_material_report_date_locked(item.execution_segment_id, OLD.bill_date)))) THEN
            RAISE EXCEPTION '这个日期所在的一期车间内料仓已经结算, 不能再新建、审核或红冲这期的报工'
                USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_report_period_closed_guard';
        END IF;
        RETURN NULL;
    END IF;
    SELECT report_row.* INTO report
    FROM production_daily_report_items item
    JOIN production_daily_reports report_row ON report_row.id = item.report_id
    WHERE item.id = NEW.id AND NOT item.is_deleted AND NOT report_row.is_deleted;
    IF FOUND AND NEW.execution_segment_id IS NOT NULL
       AND fn_workshop_material_report_date_locked(NEW.execution_segment_id, report.bill_date) THEN
        RAISE EXCEPTION '这个日期所在的一期车间内料仓已经结算, 不能再新建、审核或红冲这期的报工'
            USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_report_period_closed_guard';
    END IF;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_wm_report_date_lock_upd AFTER UPDATE OF status, bill_date ON production_daily_reports
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
    WHEN (OLD.status IS DISTINCT FROM NEW.status OR OLD.bill_date IS DISTINCT FROM NEW.bill_date)
    EXECUTE FUNCTION fn_guard_wm_report_date_lock();
CREATE CONSTRAINT TRIGGER trg_wm_report_item_date_lock AFTER INSERT ON production_daily_report_items
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN (NEW.execution_segment_id IS NOT NULL)
    EXECUTE FUNCTION fn_guard_wm_report_date_lock();
CREATE CONSTRAINT TRIGGER trg_wm_report_item_date_lock_upd AFTER UPDATE OF execution_segment_id ON production_daily_report_items
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
    WHEN (OLD.execution_segment_id IS DISTINCT FROM NEW.execution_segment_id AND NEW.execution_segment_id IS NOT NULL)
    EXECUTE FUNCTION fn_guard_wm_report_date_lock();

-- 6.18 领料单/退回单与明细。
CREATE FUNCTION fn_guard_wm_requisition() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION '领料单和退回单不能删除, 不要了请作废'
            USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_requisition_guard';
    END IF;
    IF OLD.status <> 'PENDING' THEN
        RAISE EXCEPTION '已办完或已作废的领料单、退回单不能再改'
            USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_requisition_guard';
    END IF;
    IF (NEW.request_no, NEW.kind, NEW.origin, NEW.bin_warehouse_id, NEW.workshop_department_id,
        NEW.requested_by, NEW.requested_at)
       IS DISTINCT FROM (OLD.request_no, OLD.kind, OLD.origin, OLD.bin_warehouse_id, OLD.workshop_department_id,
        OLD.requested_by, OLD.requested_at) THEN
        RAISE EXCEPTION '领料单、退回单的单号、种类、仓库、车间和申请人不能改'
            USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_requisition_guard';
    END IF;
    IF NEW.row_version <> OLD.row_version + 1 THEN
        RAISE EXCEPTION '这张单据已被别人改过, 请刷新后再试'
            USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_requisition_version_guard';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_wm_requisition BEFORE UPDATE OR DELETE ON workshop_material_requisitions
    FOR EACH ROW EXECUTE FUNCTION fn_guard_wm_requisition();

CREATE FUNCTION fn_guard_wm_requisition_line() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION '领料单、退回单的明细不能删除'
            USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_requisition_line_guard';
    END IF;
    IF TG_OP = 'UPDATE' THEN
        IF (to_jsonb(NEW) - 'fulfilled_qty') IS DISTINCT FROM (to_jsonb(OLD) - 'fulfilled_qty') THEN
            RAISE EXCEPTION '领料单、退回单的明细只能记实发数量'
                USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_requisition_line_guard';
        END IF;
        RETURN NEW;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM goods material WHERE material.id = NEW.goods_id AND material.issue_method = 'PERIODIC') THEN
        RAISE EXCEPTION '车间内料仓的领料和退回只能是整批领料的料'
            USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_requisition_line_guard';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM workshop_material_requisitions requisition
                   WHERE requisition.id = NEW.requisition_id AND requisition.status = 'PENDING') THEN
        RAISE EXCEPTION '已办完或已作废的单据不能再加明细'
            USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_requisition_line_guard';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_wm_requisition_line BEFORE INSERT OR UPDATE OR DELETE ON workshop_material_requisition_lines
    FOR EACH ROW EXECUTE FUNCTION fn_guard_wm_requisition_line();

-- 明细实发数量 = 调拨关联之和 (提交时核对)。
CREATE FUNCTION fn_assert_wm_line_fulfilled() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE target_line UUID;
BEGIN
    IF TG_TABLE_NAME = 'workshop_material_requisition_lines' THEN
        target_line := NEW.id;
    ELSE
        target_line := NEW.line_id;
    END IF;
    IF EXISTS (
        SELECT 1 FROM workshop_material_requisition_lines line
        WHERE line.id = target_line
          AND line.fulfilled_qty <> COALESCE((SELECT sum(posting.qty) FROM workshop_material_requisition_postings posting
                                              WHERE posting.line_id = line.id), 0)) THEN
        RAISE EXCEPTION '领料单明细的实发数量与实际调拨数量对不上'
            USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_line_fulfilled_guard';
    END IF;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_assert_wm_line_fulfilled AFTER INSERT ON workshop_material_requisition_postings
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_assert_wm_line_fulfilled();
CREATE CONSTRAINT TRIGGER trg_assert_wm_line_fulfilled_upd AFTER UPDATE OF fulfilled_qty ON workshop_material_requisition_lines
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN (OLD.fulfilled_qty IS DISTINCT FROM NEW.fulfilled_qty)
    EXECUTE FUNCTION fn_assert_wm_line_fulfilled();

-- 登记的库存单据: 种类与来源单一致。
CREATE FUNCTION fn_guard_wm_stock_document() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.kind IN ('ISSUE', 'RETURN') AND NOT EXISTS (
        SELECT 1 FROM workshop_material_requisitions requisition
        WHERE requisition.id = NEW.requisition_id AND requisition.kind = NEW.kind
          AND requisition.bin_warehouse_id = NEW.bin_warehouse_id) THEN
        RAISE EXCEPTION '内料仓登记的单据与领料单、退回单对不上'
            USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_stock_document_guard';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM stock_documents document
        WHERE document.id = NEW.stock_document_id
          AND document.doc_type = CASE NEW.kind WHEN 'OTHER_ISSUE' THEN 'OTHER_OUT' ELSE 'TRANSFER' END) THEN
        RAISE EXCEPTION '内料仓的发料和退回只能用调拨单, 其它耗用只能用其它出库单'
            USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_stock_document_guard';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_wm_stock_document BEFORE INSERT ON workshop_material_stock_documents
    FOR EACH ROW EXECUTE FUNCTION fn_guard_wm_stock_document();

-- 6.19 进出与盘点过账的期间归属 (按期间, 不按日期)。
CREATE FUNCTION fn_guard_wm_ledger_row() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    period workshop_material_periods%ROWTYPE;
    settings workshop_material_settings%ROWTYPE;
    supplement BOOLEAN := FALSE;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM goods material WHERE material.id = NEW.goods_id AND material.issue_method = 'PERIODIC') THEN
        RAISE EXCEPTION '车间内料仓的进出只能记整批领料的料'
            USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_ledger_guard';
    END IF;
    SELECT * INTO settings FROM workshop_material_settings
    WHERE periodic_bin_warehouse_id = NEW.bin_warehouse_id AND periodic_enabled;
    IF NOT FOUND THEN
        RAISE EXCEPTION '这个仓库不是已开启整批领料的车间内料仓'
            USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_ledger_guard';
    END IF;
    IF NEW.business_date < settings.go_live_date THEN
        RAISE EXCEPTION '业务日期不能早于整批领料的启用日期'
            USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_ledger_guard';
    END IF;

    IF TG_TABLE_NAME = 'workshop_material_count_postings' THEN
        SELECT period_row.* INTO period
        FROM workshop_material_period_lines line
        JOIN workshop_material_periods period_row ON period_row.id = line.period_id
        WHERE line.id = NEW.period_line_id AND line.goods_id = NEW.goods_id
          AND line.color_id IS NOT DISTINCT FROM NEW.color_id;
        IF NOT FOUND OR period.bin_warehouse_id <> NEW.bin_warehouse_id
           OR period.status NOT IN ('COUNTING', 'COUNTED') THEN
            RAISE EXCEPTION '盘点过账必须记在这个内料仓正在盘点或已盘点、还没结算的那一期'
                USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_ledger_period_guard';
        END IF;
        IF NEW.business_date IS DISTINCT FROM period.end_date THEN
            RAISE EXCEPTION '盘点过账的业务日期必须是那一期的截止日'
                USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_ledger_period_guard';
        END IF;
        RETURN NEW;
    END IF;

    SELECT * INTO period FROM workshop_material_periods WHERE id = NEW.period_id;
    IF NOT FOUND OR period.bin_warehouse_id <> NEW.bin_warehouse_id THEN
        RAISE EXCEPTION '进出记录的期间不属于这个内料仓'
            USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_ledger_period_guard';
    END IF;
    IF TG_TABLE_NAME = 'workshop_material_requisition_postings' THEN
        supplement := NEW.is_supplement;
        IF NOT EXISTS (
            SELECT 1 FROM workshop_material_requisition_lines line
            JOIN workshop_material_requisitions requisition ON requisition.id = line.requisition_id
            WHERE line.id = NEW.line_id AND requisition.status <> 'CANCELLED'
              AND requisition.bin_warehouse_id = NEW.bin_warehouse_id
              AND line.goods_id = NEW.goods_id AND line.color_id IS NOT DISTINCT FROM NEW.color_id) THEN
            RAISE EXCEPTION '调拨记录与领料单、退回单的明细对不上'
                USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_ledger_guard';
        END IF;
    END IF;
    IF supplement THEN
        IF period.status NOT IN ('COUNTING', 'COUNTED') THEN
            RAISE EXCEPTION '漏录的料只能补记到正在盘点或已盘点、还没结算的那一期'
                USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_ledger_period_guard';
        END IF;
        IF period.status = 'COUNTED' AND NOT EXISTS (
            SELECT 1 FROM workshop_material_period_lines line
            WHERE line.period_id = period.id AND line.goods_id = NEW.goods_id
              AND line.color_id IS NOT DISTINCT FROM NEW.color_id) THEN
            RAISE EXCEPTION '那一期的盘点里没有这种料, 请先更正盘点补上实盘数, 再补记'
                USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_ledger_period_guard';
        END IF;
    ELSIF period.status <> 'OPEN' THEN
        RAISE EXCEPTION '内料仓的进出只能记进当前开着的那一期'
            USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_ledger_period_guard';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_wm_posting_ledger_row BEFORE INSERT ON workshop_material_requisition_postings
    FOR EACH ROW EXECUTE FUNCTION fn_guard_wm_ledger_row();
CREATE TRIGGER trg_guard_wm_other_issue_ledger_row BEFORE INSERT ON workshop_material_other_issues
    FOR EACH ROW EXECUTE FUNCTION fn_guard_wm_ledger_row();
CREATE TRIGGER trg_guard_wm_count_posting_ledger_row BEFORE INSERT ON workshop_material_count_postings
    FOR EACH ROW EXECUTE FUNCTION fn_guard_wm_ledger_row();

-- 调拨关联的来源核对: 本次登记、已审核的调拨单, 内料仓一侧的那条流水。
CREATE FUNCTION fn_assert_wm_posting_source() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM workshop_material_requisition_postings posting
        JOIN workshop_material_requisition_lines line ON line.id = posting.line_id
        JOIN workshop_material_requisitions requisition ON requisition.id = line.requisition_id
        JOIN stock_document_items item ON item.id = posting.stock_document_item_id
        JOIN stock_documents document ON document.id = item.doc_id
        JOIN workshop_material_stock_documents registration ON registration.stock_document_id = document.id
        JOIN stock_movements movement ON movement.id = posting.movement_id
        JOIN warehouses leaf ON leaf.id = posting.leaf_warehouse_id AND NOT leaf.is_line_side
        WHERE posting.id = NEW.id
          AND registration.kind = requisition.kind AND registration.requisition_id = requisition.id
          AND registration.bin_warehouse_id = posting.bin_warehouse_id
          AND requisition.bin_warehouse_id = posting.bin_warehouse_id
          AND document.status = 1 AND NOT document.is_deleted AND document.doc_type = 'TRANSFER'
          AND ((requisition.kind = 'ISSUE' AND document.warehouse_id = posting.leaf_warehouse_id
                AND document.to_warehouse_id = posting.bin_warehouse_id
                AND movement.movement_type = 7 AND movement.direction = 1)
            OR (requisition.kind = 'RETURN' AND document.warehouse_id = posting.bin_warehouse_id
                AND document.to_warehouse_id = posting.leaf_warehouse_id
                AND movement.movement_type = 8 AND movement.direction = -1))
          AND NOT item.is_deleted AND item.goods_id = posting.goods_id
          AND item.color_id IS NOT DISTINCT FROM posting.color_id
          AND round(item.qty * COALESCE(item.unit_rate, 1), 4) = posting.qty
          AND movement.source_doc_type = 'STOCK_DOC' AND movement.source_doc_id = document.id
          AND movement.source_item_id = item.id AND movement.warehouse_id = posting.bin_warehouse_id
          AND movement.goods_id = posting.goods_id AND movement.color_id IS NOT DISTINCT FROM posting.color_id
          AND movement.qty = posting.qty) THEN
        RAISE EXCEPTION '内料仓的发料或退回必须对应本次登记、已审核的调拨单'
            USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_posting_source_guard';
    END IF;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_assert_wm_posting_source AFTER INSERT ON workshop_material_requisition_postings
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_assert_wm_posting_source();

-- 其它耗用的来源核对: 提交时必须有本次登记、已审核的其它出库单与内料仓一侧的 12 型出库流水。
CREATE FUNCTION fn_assert_wm_other_issue_source() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM workshop_material_other_issues other
        JOIN stock_document_items item ON item.id = other.stock_document_item_id
        JOIN stock_documents document ON document.id = item.doc_id
        JOIN workshop_material_stock_documents registration
          ON registration.stock_document_id = document.id AND registration.kind = 'OTHER_ISSUE'
         AND registration.other_issue_id = other.id AND registration.bin_warehouse_id = other.bin_warehouse_id
        JOIN stock_movements movement ON movement.id = other.movement_id
        WHERE other.id = NEW.id
          AND document.doc_type = 'OTHER_OUT' AND document.status = 1 AND NOT document.is_deleted
          AND document.warehouse_id = other.bin_warehouse_id
          AND NOT item.is_deleted AND item.goods_id = other.goods_id
          AND item.color_id IS NOT DISTINCT FROM other.color_id
          AND round(item.qty * COALESCE(item.unit_rate, 1), 4) = other.qty
          AND movement.movement_type = 12 AND movement.direction = -1
          AND movement.source_doc_type = 'STOCK_DOC' AND movement.source_doc_id = document.id
          AND movement.source_item_id = item.id AND movement.warehouse_id = other.bin_warehouse_id
          AND movement.goods_id = other.goods_id AND movement.color_id IS NOT DISTINCT FROM other.color_id
          AND movement.qty = other.qty) THEN
        RAISE EXCEPTION '其它耗用必须对应本次登记、已审核的其它出库单'
            USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_other_issue_source_guard';
    END IF;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_assert_wm_other_issue_source AFTER INSERT OR UPDATE ON workshop_material_other_issues
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_assert_wm_other_issue_source();

-- 每个 (内料仓, 料, 颜色) 的流水视图合计 = 库存余额。
CREATE FUNCTION fn_assert_wm_ledger_balance() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF COALESCE((SELECT sum(ledger.signed_qty) FROM v_workshop_material_bin_ledger ledger
                 WHERE ledger.bin_warehouse_id = NEW.bin_warehouse_id AND ledger.goods_id = NEW.goods_id
                   AND ledger.color_id IS NOT DISTINCT FROM NEW.color_id), 0)
       <> COALESCE((SELECT balance.qty FROM stock_balances balance
                    WHERE balance.warehouse_id = NEW.bin_warehouse_id AND balance.goods_id = NEW.goods_id
                      AND balance.color_id IS NOT DISTINCT FROM NEW.color_id), 0) THEN
        RAISE EXCEPTION '车间内料仓的进出记录合计与库存余额对不上'
            USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_ledger_balance_guard';
    END IF;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_assert_wm_posting_balance AFTER INSERT ON workshop_material_requisition_postings
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_assert_wm_ledger_balance();
CREATE CONSTRAINT TRIGGER trg_assert_wm_other_issue_balance AFTER INSERT ON workshop_material_other_issues
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_assert_wm_ledger_balance();
CREATE CONSTRAINT TRIGGER trg_assert_wm_count_posting_balance AFTER INSERT ON workshop_material_count_postings
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_assert_wm_ledger_balance();
CREATE CONSTRAINT TRIGGER trg_assert_wm_count_posting_balance_upd AFTER UPDATE OF movement_id ON workshop_material_count_postings
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN (OLD.movement_id IS DISTINCT FROM NEW.movement_id)
    EXECUTE FUNCTION fn_assert_wm_ledger_balance();

-- 内料仓服务登记的库存单据不能红冲 (发错了做退回, 或盘点时如实盘点)。
CREATE FUNCTION fn_guard_wm_stock_document_reverse() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM workshop_material_stock_documents registration
               WHERE registration.stock_document_id = NEW.id) THEN
        RAISE EXCEPTION '车间内料仓的发料、退回和其它耗用单据不能红冲; 发错了请做退回, 或在盘点时如实盘点'
            USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_document_reverse_guard';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_wm_stock_document_reverse BEFORE UPDATE OF status ON stock_documents
    FOR EACH ROW WHEN (NEW.status = -1 AND OLD.status IS DISTINCT FROM NEW.status)
    EXECUTE FUNCTION fn_guard_wm_stock_document_reverse();

-- 6.20 期间。
CREATE FUNCTION fn_guard_wm_period() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        IF OLD.status <> 'OPEN'
           OR EXISTS (SELECT 1 FROM v_workshop_material_bin_ledger ledger WHERE ledger.period_id = OLD.id)
           OR EXISTS (SELECT 1 FROM workshop_material_counts counted WHERE counted.period_id = OLD.id) THEN
            RAISE EXCEPTION '已经有进出或盘点的期间不能删除'
                USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_period_guard';
        END IF;
        RETURN OLD;
    END IF;
    IF (NEW.bin_warehouse_id, NEW.workshop_department_id, NEW.period_no, NEW.start_date)
       IS DISTINCT FROM (OLD.bin_warehouse_id, OLD.workshop_department_id, OLD.period_no, OLD.start_date) THEN
        RAISE EXCEPTION '期间的内料仓、期号和起始日期不能改'
            USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_period_guard';
    END IF;
    IF NEW.status IS DISTINCT FROM OLD.status AND NOT (
           (OLD.status = 'OPEN' AND NEW.status = 'COUNTING')
        OR (OLD.status = 'COUNTING' AND NEW.status IN ('OPEN', 'COUNTED'))
        OR (OLD.status = 'COUNTED' AND NEW.status = 'CLOSED')
        OR (OLD.status = 'CLOSED' AND NEW.status = 'COUNTED')) THEN
        RAISE EXCEPTION '期间状态不能这样变更'
            USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_period_guard';
    END IF;
    IF NEW.end_date IS DISTINCT FROM OLD.end_date
       AND NOT ((OLD.status = 'OPEN' AND NEW.status = 'COUNTING') OR (OLD.status = 'COUNTING' AND NEW.status = 'OPEN')) THEN
        RAISE EXCEPTION '期间的截止日只能在开始盘点或撤回盘点时改'
            USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_period_guard';
    END IF;
    IF NEW.row_version <> OLD.row_version + 1 THEN
        RAISE EXCEPTION '这一期已被别人改过, 请刷新后再试'
            USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_period_version_guard';
    END IF;
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_wm_period BEFORE UPDATE OR DELETE ON workshop_material_periods
    FOR EACH ROW EXECUTE FUNCTION fn_guard_wm_period();

-- 期间链 (提交时按内料仓整体核对): 第 1 期从启用日开始, 逐期衔接, 状态沿期号不升,
-- 开启时恰好一个开着的期间且是最后一期, 停用时没有期间; 已结算的期间恰好有一次有效结算。
CREATE FUNCTION fn_assert_wm_period_chain() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    bins UUID[];
    bin UUID;
    settings workshop_material_settings%ROWTYPE;
    period RECORD;
    previous_end DATE;
    previous_rank INT;
    last_status TEXT;
    open_count INT;
    expected_no INT;
BEGIN
    IF TG_TABLE_NAME = 'workshop_material_settings' THEN
        bins := ARRAY[NEW.periodic_bin_warehouse_id];
        IF TG_OP = 'UPDATE' THEN bins := bins || OLD.periodic_bin_warehouse_id; END IF;
    ELSIF TG_OP = 'DELETE' THEN
        bins := ARRAY[OLD.bin_warehouse_id];
    ELSE
        bins := ARRAY[NEW.bin_warehouse_id];
        IF TG_OP = 'UPDATE' THEN bins := bins || OLD.bin_warehouse_id; END IF;
    END IF;
    FOREACH bin IN ARRAY bins LOOP
        CONTINUE WHEN bin IS NULL;
        SELECT * INTO settings FROM workshop_material_settings
        WHERE periodic_bin_warehouse_id = bin AND periodic_enabled;
        IF NOT FOUND THEN
            IF EXISTS (SELECT 1 FROM workshop_material_periods WHERE bin_warehouse_id = bin) THEN
                RAISE EXCEPTION '没有开启整批领料的内料仓不能有期间'
                    USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_period_chain_guard';
            END IF;
            CONTINUE;
        END IF;
        previous_end := NULL;
        previous_rank := NULL;
        last_status := NULL;
        open_count := 0;
        expected_no := 1;
        FOR period IN
            SELECT candidate.period_no, candidate.start_date, candidate.end_date, candidate.status,
                   CASE candidate.status WHEN 'CLOSED' THEN 0 WHEN 'COUNTED' THEN 1
                                         WHEN 'COUNTING' THEN 2 ELSE 3 END AS status_rank,
                   EXISTS (SELECT 1 FROM workshop_material_period_closes period_close
                           WHERE period_close.period_id = candidate.id AND period_close.status = 'ACTIVE') AS has_active_close
            FROM workshop_material_periods candidate
            WHERE candidate.bin_warehouse_id = bin
            ORDER BY candidate.period_no
        LOOP
            IF period.period_no <> expected_no
               OR (expected_no = 1 AND period.start_date <> settings.go_live_date)
               OR (expected_no > 1 AND (previous_end IS NULL OR period.start_date <> previous_end + 1
                                        OR period.status_rank < previous_rank))
               OR (period.status = 'CLOSED') <> period.has_active_close THEN
                RAISE EXCEPTION '内料仓的期间不连续或状态顺序不对'
                    USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_period_chain_guard';
            END IF;
            IF period.status = 'OPEN' THEN open_count := open_count + 1; END IF;
            previous_end := period.end_date;
            previous_rank := period.status_rank;
            last_status := period.status;
            expected_no := expected_no + 1;
        END LOOP;
        IF open_count <> 1 OR last_status IS DISTINCT FROM 'OPEN' THEN
            RAISE EXCEPTION '开启整批领料的内料仓必须恰好有一个开着的期间, 且是最后一期'
                USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_period_chain_guard';
        END IF;
    END LOOP;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_assert_wm_period_chain AFTER INSERT OR UPDATE OR DELETE ON workshop_material_periods
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_assert_wm_period_chain();
CREATE CONSTRAINT TRIGGER trg_assert_wm_settings_period_chain AFTER INSERT OR UPDATE ON workshop_material_settings
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_assert_wm_period_chain();

-- 6.21 盘点单与盘点行。
CREATE FUNCTION fn_guard_wm_count() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NOT EXISTS (SELECT 1 FROM workshop_material_periods period
                       WHERE period.id = NEW.period_id AND period.status IN ('COUNTING', 'COUNTED')) THEN
            RAISE EXCEPTION '只能盘点正在盘点或已盘点、还没结算的那一期'
                USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_count_guard';
        END IF;
        RETURN NEW;
    END IF;
    IF TG_OP = 'DELETE' THEN
        IF OLD.status <> 'DRAFT' THEN
            RAISE EXCEPTION '已提交的盘点单不能删除'
                USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_count_guard';
        END IF;
        RETURN OLD;
    END IF;
    IF (NEW.period_id, NEW.version, NEW.created_by, NEW.created_at)
       IS DISTINCT FROM (OLD.period_id, OLD.version, OLD.created_by, OLD.created_at)
       OR (NEW.status IS DISTINCT FROM OLD.status AND NOT (
              (OLD.status = 'DRAFT' AND NEW.status = 'SUBMITTED')
           OR (OLD.status = 'SUBMITTED' AND NEW.status = 'SUPERSEDED')))
       OR (OLD.status <> 'DRAFT' AND (NEW.submitted_by, NEW.submitted_at, NEW.correction_reason)
              IS DISTINCT FROM (OLD.submitted_by, OLD.submitted_at, OLD.correction_reason)) THEN
        RAISE EXCEPTION '盘点单提交后不能再改'
            USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_count_guard';
    END IF;
    IF NEW.row_version <> OLD.row_version + 1 THEN
        RAISE EXCEPTION '盘点单已被别人改过, 请刷新后再试'
            USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_count_version_guard';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_wm_count BEFORE INSERT OR UPDATE OR DELETE ON workshop_material_counts
    FOR EACH ROW EXECUTE FUNCTION fn_guard_wm_count();

CREATE FUNCTION fn_guard_wm_count_line() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE target_count UUID;
BEGIN
    IF TG_OP = 'DELETE' THEN
        target_count := OLD.count_id;
    ELSE
        target_count := NEW.count_id;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM workshop_material_counts counted
                   WHERE counted.id = target_count AND counted.status = 'DRAFT') THEN
        RAISE EXCEPTION '盘点单已提交, 不能再改盘点行'
            USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_count_line_guard';
    END IF;
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    IF NEW.goods_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM goods material WHERE material.id = NEW.goods_id AND material.issue_method = 'PERIODIC') THEN
        RAISE EXCEPTION '盘点只盘整批领料的料'
            USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_count_line_guard';
    END IF;
    IF TG_OP = 'UPDATE' THEN
        IF NEW.count_id <> OLD.count_id OR NEW.client_line_key <> OLD.client_line_key THEN
            RAISE EXCEPTION '盘点行不能挪到别的盘点单'
                USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_count_line_guard';
        END IF;
        IF NEW.row_version <> OLD.row_version + 1 THEN
            RAISE EXCEPTION '这一行已被别人改过, 请刷新后再试'
                USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_count_line_version_guard';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_wm_count_line BEFORE INSERT OR UPDATE OR DELETE ON workshop_material_count_lines
    FOR EACH ROW EXECUTE FUNCTION fn_guard_wm_count_line();

-- 6.22 期间行: 提交盘点时建, 更正或已盘点补录时改; 分摊方式取建行时货品的快照。
CREATE FUNCTION fn_guard_wm_period_line() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION '期间用量记录不能删除'
            USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_period_line_guard';
    END IF;
    IF TG_OP = 'INSERT' THEN
        IF NOT EXISTS (SELECT 1 FROM workshop_material_periods period
                       WHERE period.id = NEW.period_id AND period.status IN ('COUNTING', 'COUNTED')) THEN
            RAISE EXCEPTION '期间用量只能在盘点提交时建立'
                USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_period_line_guard';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM goods material WHERE material.id = NEW.goods_id
                       AND material.issue_method = 'PERIODIC' AND material.periodic_cost_basis = NEW.cost_basis) THEN
            RAISE EXCEPTION '期间用量的分摊方式必须取这种料当时的分摊方式'
                USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_period_line_guard';
        END IF;
        RETURN NEW;
    END IF;
    IF (NEW.period_id, NEW.goods_id, NEW.color_id, NEW.unit_id, NEW.cost_basis, NEW.created_at)
       IS DISTINCT FROM (OLD.period_id, OLD.goods_id, OLD.color_id, OLD.unit_id, OLD.cost_basis, OLD.created_at) THEN
        RAISE EXCEPTION '期间用量的料和分摊方式不能改'
            USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_period_line_guard';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM workshop_material_periods period
                   WHERE period.id = NEW.period_id AND period.status = 'COUNTED') THEN
        RAISE EXCEPTION '只有已盘点、还没结算的期间才能更正用量'
            USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_period_line_guard';
    END IF;
    IF NEW.row_version <> OLD.row_version + 1 THEN
        RAISE EXCEPTION '期间用量已被别人改过, 请刷新后再试'
            USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_period_line_version_guard';
    END IF;
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_wm_period_line BEFORE INSERT OR UPDATE OR DELETE ON workshop_material_period_lines
    FOR EACH ROW EXECUTE FUNCTION fn_guard_wm_period_line();

-- 期间行提交时核对: 期初 = 上一期期末; 领入/退回/其它 = 本期流水; 两条盘点过账净额; 截至本期账面 = 期末。
CREATE FUNCTION fn_assert_wm_period_line() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    target_line UUID;
    line RECORD;
    previous_closing NUMERIC;
    following RECORD;
    moved RECORD;
    net_consume NUMERIC;
    net_gain NUMERIC;
BEGIN
    IF TG_TABLE_NAME = 'workshop_material_period_lines' THEN
        target_line := NEW.id;
    ELSIF TG_TABLE_NAME = 'workshop_material_requisition_postings' THEN
        -- 补记进已盘点那一期的调拨: 同事务必须按更正规则改这一期的期间行。
        SELECT supplemented.id INTO target_line
        FROM workshop_material_period_lines supplemented
        WHERE supplemented.period_id = NEW.period_id AND supplemented.goods_id = NEW.goods_id
          AND supplemented.color_id IS NOT DISTINCT FROM NEW.color_id;
        IF target_line IS NULL THEN RETURN NULL; END IF;
    ELSE
        target_line := NEW.period_line_id;
    END IF;
    SELECT period_line.*, period.bin_warehouse_id, period.period_no INTO line
    FROM workshop_material_period_lines period_line
    JOIN workshop_material_periods period ON period.id = period_line.period_id
    WHERE period_line.id = target_line;
    IF NOT FOUND THEN RETURN NULL; END IF;

    SELECT previous_line.closing_qty INTO previous_closing
    FROM workshop_material_periods previous
    JOIN workshop_material_period_lines previous_line
      ON previous_line.period_id = previous.id AND previous_line.goods_id = line.goods_id
     AND previous_line.color_id IS NOT DISTINCT FROM line.color_id
    WHERE previous.bin_warehouse_id = line.bin_warehouse_id AND previous.period_no = line.period_no - 1;
    IF line.opening_qty <> COALESCE(previous_closing, 0) THEN
        RAISE EXCEPTION '这一期的期初与上一期的期末对不上'
            USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_period_line_guard';
    END IF;

    SELECT COALESCE(sum(ledger.signed_qty) FILTER (WHERE ledger.source_kind = 'ISSUE'), 0) AS transfer_in,
           COALESCE(-sum(ledger.signed_qty) FILTER (WHERE ledger.source_kind = 'RETURN'), 0) AS returned,
           COALESCE(-sum(ledger.signed_qty) FILTER (WHERE ledger.source_kind = 'OTHER_ISSUE'), 0) AS other_issue
    INTO moved
    FROM v_workshop_material_bin_ledger ledger
    WHERE ledger.period_id = line.period_id AND ledger.goods_id = line.goods_id
      AND ledger.color_id IS NOT DISTINCT FROM line.color_id;
    IF (line.transfer_in_qty, line.return_qty, line.other_issue_qty)
       IS DISTINCT FROM (moved.transfer_in, moved.returned, moved.other_issue) THEN
        RAISE EXCEPTION '这一期的领入、退回、其它耗用与进出记录对不上'
            USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_period_line_guard';
    END IF;

    SELECT COALESCE(sum(CASE posting.kind WHEN 'CONSUME' THEN posting.qty WHEN 'CONSUME_REVERSE' THEN -posting.qty ELSE 0 END), 0),
           COALESCE(sum(CASE posting.kind WHEN 'GAIN' THEN posting.qty WHEN 'GAIN_REVERSE' THEN -posting.qty ELSE 0 END), 0)
    INTO net_consume, net_gain
    FROM workshop_material_count_postings posting
    WHERE posting.period_line_id = line.id;
    IF net_consume <> GREATEST(line.actual_qty, 0) OR net_gain <> GREATEST(-line.actual_qty, 0) THEN
        RAISE EXCEPTION '盘点过账与这一期的实际用量对不上'
            USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_period_line_guard';
    END IF;

    IF fn_workshop_material_book_as_of(line.period_id, line.goods_id, line.color_id) <> line.closing_qty THEN
        RAISE EXCEPTION '截至这一期的账面与盘点期末对不上'
            USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_period_line_guard';
    END IF;

    SELECT next_line.opening_qty INTO following
    FROM workshop_material_periods next_period
    JOIN workshop_material_period_lines next_line
      ON next_line.period_id = next_period.id AND next_line.goods_id = line.goods_id
     AND next_line.color_id IS NOT DISTINCT FROM line.color_id
    WHERE next_period.bin_warehouse_id = line.bin_warehouse_id AND next_period.period_no = line.period_no + 1;
    IF FOUND AND following.opening_qty <> line.closing_qty THEN
        RAISE EXCEPTION '下一期的期初与这一期的期末对不上'
            USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_period_line_guard';
    END IF;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_assert_wm_period_line AFTER INSERT OR UPDATE ON workshop_material_period_lines
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_assert_wm_period_line();
CREATE CONSTRAINT TRIGGER trg_assert_wm_count_posting_period_line AFTER INSERT ON workshop_material_count_postings
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_assert_wm_period_line();
CREATE CONSTRAINT TRIGGER trg_assert_wm_supplement_period_line AFTER INSERT ON workshop_material_requisition_postings
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN (NEW.is_supplement) EXECUTE FUNCTION fn_assert_wm_period_line();

-- 盘点过账的流水与冲回核对: 21 型耗用 / 22 型盘盈, 冲回只冲同类且累计不超过原数。
CREATE FUNCTION fn_assert_wm_count_posting_movement() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    posting workshop_material_count_postings%ROWTYPE;
BEGIN
    SELECT * INTO posting FROM workshop_material_count_postings WHERE id = NEW.id;
    IF NOT FOUND THEN RETURN NULL; END IF;
    IF posting.movement_id IS NULL OR NOT EXISTS (
        SELECT 1 FROM stock_movements movement
        WHERE movement.id = posting.movement_id
          AND movement.source_doc_type = 'WORKSHOP_MATERIAL_COUNT'
          AND movement.source_doc_id = posting.count_id AND movement.source_item_id = posting.period_line_id
          AND movement.warehouse_id = posting.bin_warehouse_id AND movement.goods_id = posting.goods_id
          AND movement.color_id IS NOT DISTINCT FROM posting.color_id AND movement.qty = posting.qty
          AND (movement.movement_type, movement.direction) = (
              CASE posting.kind WHEN 'CONSUME' THEN 21 WHEN 'CONSUME_REVERSE' THEN 21 ELSE 22 END,
              CASE posting.kind WHEN 'CONSUME' THEN -1 WHEN 'CONSUME_REVERSE' THEN 1
                                WHEN 'GAIN' THEN 1 ELSE -1 END)) THEN
        RAISE EXCEPTION '盘点过账没有对应的库存流水'
            USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_count_posting_guard';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM workshop_material_counts counted
        JOIN workshop_material_period_lines line ON line.id = posting.period_line_id
        WHERE counted.id = posting.count_id AND counted.period_id = line.period_id AND counted.status = 'SUBMITTED') THEN
        RAISE EXCEPTION '盘点过账必须挂在那一期当前有效的盘点单上'
            USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_count_posting_guard';
    END IF;
    IF posting.reverses_posting_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM workshop_material_count_postings reversed
        WHERE reversed.id = posting.reverses_posting_id
          AND reversed.period_line_id = posting.period_line_id
          AND reversed.kind = CASE posting.kind WHEN 'CONSUME_REVERSE' THEN 'CONSUME' ELSE 'GAIN' END
          AND reversed.qty >= (SELECT sum(reversal.qty) FROM workshop_material_count_postings reversal
                               WHERE reversal.reverses_posting_id = reversed.id)) THEN
        RAISE EXCEPTION '盘点过账的冲回只能冲同一期同类的过账, 且不能超过原数量'
            USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_count_posting_guard';
    END IF;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_assert_wm_count_posting_movement AFTER INSERT ON workshop_material_count_postings
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_assert_wm_count_posting_movement();
CREATE CONSTRAINT TRIGGER trg_assert_wm_count_posting_movement_upd AFTER UPDATE OF movement_id ON workshop_material_count_postings
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN (OLD.movement_id IS DISTINCT FROM NEW.movement_id)
    EXECUTE FUNCTION fn_assert_wm_count_posting_movement();

-- 6.23 结算结果。
CREATE FUNCTION fn_guard_wm_close() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' OR OLD.status <> 'ACTIVE' OR NEW.status <> 'REVERSED'
       OR (to_jsonb(NEW) - ARRAY['status', 'reversal_event_id', 'reversed_by', 'reversed_at', 'reverse_reason'])
          IS DISTINCT FROM (to_jsonb(OLD) - ARRAY['status', 'reversal_event_id', 'reversed_by', 'reversed_at', 'reverse_reason']) THEN
        RAISE EXCEPTION '结算记录只能追加, 撤销时只写一次撤销信息'
            USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_close_guard';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_wm_close BEFORE UPDATE OR DELETE ON workshop_material_period_closes
    FOR EACH ROW EXECUTE FUNCTION fn_guard_wm_close();

-- 结算核对 (每次触发批只对同一结算做一次整体核对):
-- 分摊合计 = 计入量且恰好一行尾差; 计入 + 损失 = 实际; 分摊方式 = 期间行快照; 理论明细与理论函数双向覆盖;
-- 绑定本仓的段上已审报工都落在期间料行区间内; 有价值节点的分摊行已登记为成本投入。
CREATE FUNCTION fn_assert_wm_close() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    target_close UUID;
    close_row workshop_material_period_closes%ROWTYPE;
    period workshop_material_periods%ROWTYPE;
    marker TEXT;
BEGIN
    IF TG_TABLE_NAME = 'workshop_material_period_closes' THEN
        target_close := NEW.id;
    ELSIF TG_TABLE_NAME = 'workshop_material_close_allocations' THEN
        SELECT material.close_id INTO target_close
        FROM workshop_material_close_materials material WHERE material.id = NEW.close_material_id;
    ELSE
        target_close := NEW.close_id;
    END IF;
    marker := 'uten.wm_close_' || replace(target_close::text, '-', '');
    IF current_setting(marker, true) = statement_timestamp()::text THEN
        RETURN NULL;
    END IF;
    SELECT * INTO close_row FROM workshop_material_period_closes WHERE id = target_close;
    SELECT * INTO period FROM workshop_material_periods WHERE id = close_row.period_id;

    IF close_row.status = 'REVERSED' THEN
        IF EXISTS (
            SELECT 1 FROM workshop_material_close_allocations allocation
            JOIN workshop_material_close_materials material ON material.id = allocation.close_material_id
            WHERE material.close_id = target_close AND allocation.value_node_id IS NOT NULL
              AND allocation.reversed_at IS NULL) THEN
            RAISE EXCEPTION '撤销结算时每一笔分摊都要撤回'
                USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_close_assert';
        END IF;
        PERFORM set_config(marker, statement_timestamp()::text, true);
        RETURN NULL;
    END IF;

    IF period.status <> 'CLOSED' THEN
        RAISE EXCEPTION '有效结算所在的期间必须是已结算'
            USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_close_assert';
    END IF;
    IF (SELECT count(*) FROM workshop_material_period_lines line WHERE line.period_id = period.id)
       <> (SELECT count(*) FROM workshop_material_close_materials material WHERE material.close_id = target_close) THEN
        RAISE EXCEPTION '结算必须覆盖这一期的每一种料'
            USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_close_assert';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM workshop_material_close_materials material
        JOIN workshop_material_period_lines line ON line.id = material.period_line_id
        LEFT JOIN LATERAL (
            SELECT COALESCE(sum(allocation.allocated_qty), 0) AS allocated,
                   count(*) FILTER (WHERE allocation.is_tail) AS tails
            FROM workshop_material_close_allocations allocation
            WHERE allocation.close_material_id = material.id AND allocation.reversed_at IS NULL) allocated ON TRUE
        WHERE material.close_id = target_close
          AND (line.period_id <> period.id
               OR material.cost_basis <> line.cost_basis
               OR allocated.allocated <> material.consumed_qty
               OR (material.consumed_qty > 0 AND allocated.tails <> 1)
               OR (material.consumed_qty = 0 AND allocated.tails <> 0)
               OR (material.outcome <> 'EXPENSED'
                   AND material.consumed_qty + material.loss_qty <> GREATEST(line.actual_qty, 0)))) THEN
        RAISE EXCEPTION '结算的计入量、损失与分摊合计对不上'
            USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_close_assert';
    END IF;
    IF EXISTS (
        SELECT 1 FROM workshop_material_close_allocations allocation
        JOIN workshop_material_close_materials material ON material.id = allocation.close_material_id
        WHERE material.close_id = target_close
          AND fn_production_execution_cost_scope(allocation.cost_scope_segment_id) IS DISTINCT FROM allocation.cost_scope_segment_id) THEN
        RAISE EXCEPTION '分摊只能落到成本范围的根工单上'
            USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_close_assert';
    END IF;
    -- 前向覆盖: 零理论 (产量为 0, 例如返工补产) 且这一期没有这种料的期间料行时, 没有可挂的结算料行,
    -- 也没有要记的理论, 不要求理论明细; 其余理论行都要有明细。
    IF EXISTS (
        WITH theory AS MATERIALIZED (
            SELECT used.report_item_id, used.periodic_row_id, used.material_goods_id, used.material_color_id,
                   COALESCE(round(used.output_qty_base, 6) = 0
                            OR round(round(used.output_qty_base, 6) * round(used.unit_weight, 6), 6) = 0,
                            FALSE) AS zero_theory
            FROM fn_workshop_material_period_theory(period.bin_warehouse_id, period.start_date, period.end_date) used
        )
        SELECT 1 FROM theory
        WHERE NOT (theory.zero_theory AND NOT EXISTS (
                SELECT 1 FROM workshop_material_period_lines period_line
                WHERE period_line.period_id = period.id AND period_line.goods_id = theory.material_goods_id
                  AND period_line.color_id IS NOT DISTINCT FROM theory.material_color_id))
          AND NOT EXISTS (
            SELECT 1 FROM workshop_material_close_theory_lines theory_line
            JOIN workshop_material_close_materials material ON material.id = theory_line.close_material_id
            JOIN workshop_material_period_lines line ON line.id = material.period_line_id
            WHERE theory_line.close_id = target_close AND theory_line.report_item_id = theory.report_item_id
              AND theory_line.periodic_row_id = theory.periodic_row_id
              AND line.goods_id = theory.material_goods_id
              AND line.color_id IS NOT DISTINCT FROM theory.material_color_id)
        UNION ALL
        SELECT 1 FROM workshop_material_close_theory_lines theory_line
        WHERE theory_line.close_id = target_close
          AND NOT EXISTS (
              SELECT 1 FROM theory
              WHERE theory.report_item_id = theory_line.report_item_id
                AND theory.periodic_row_id = theory_line.periodic_row_id)) THEN
        RAISE EXCEPTION '结算的理论明细与这一期的已审报工对不上'
            USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_close_assert';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM production_daily_reports report
        JOIN production_daily_report_items item ON item.report_id = report.id AND NOT item.is_deleted
        WHERE report.status = 1 AND NOT report.is_deleted
          AND report.bill_date BETWEEN period.start_date AND period.end_date
          AND EXISTS (SELECT 1 FROM production_execution_periodic_materials bound
                      WHERE bound.execution_segment_id = item.execution_segment_id
                        AND bound.bin_warehouse_id = period.bin_warehouse_id)
          AND NOT EXISTS (SELECT 1 FROM production_execution_periodic_materials covering
                          WHERE covering.execution_segment_id = item.execution_segment_id
                            AND covering.bin_warehouse_id = period.bin_warehouse_id
                            AND report.bill_date >= covering.effective_from
                            AND (covering.effective_to IS NULL OR report.bill_date <= covering.effective_to))) THEN
        RAISE EXCEPTION '有已审报工不在任何一段用料时间内, 不能结算'
            USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_close_assert';
    END IF;
    IF EXISTS (
        SELECT 1 FROM workshop_material_close_allocations allocation
        JOIN workshop_material_close_materials material ON material.id = allocation.close_material_id
        WHERE material.close_id = target_close AND allocation.value_node_id IS NOT NULL AND allocation.reversed_at IS NULL
          AND EXISTS (SELECT 1 FROM stock_value_production_cost_objects object
                      WHERE object.execution_segment_id = allocation.cost_scope_segment_id)
          AND NOT EXISTS (SELECT 1 FROM stock_value_production_cost_inputs input
                          WHERE input.approved_posting_id = allocation.id)) THEN
        RAISE EXCEPTION '分摊到产品的整批领料成本还没有登记到产品成本里'
            USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_close_assert';
    END IF;
    PERFORM set_config(marker, statement_timestamp()::text, true);
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_assert_wm_close_status AFTER UPDATE OF status ON workshop_material_period_closes
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN (OLD.status IS DISTINCT FROM NEW.status)
    EXECUTE FUNCTION fn_assert_wm_close();
CREATE CONSTRAINT TRIGGER trg_assert_wm_close_material AFTER INSERT ON workshop_material_close_materials
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_assert_wm_close();
CREATE CONSTRAINT TRIGGER trg_assert_wm_close_allocation AFTER INSERT ON workshop_material_close_allocations
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_assert_wm_close();
CREATE CONSTRAINT TRIGGER trg_assert_wm_close_theory_line AFTER INSERT ON workshop_material_close_theory_lines
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_assert_wm_close();

-- 6.24 PERIODIC_MATERIAL 成本投入只能来自有效结算的分摊行, 分摊行也只能作为这一种投入。
CREATE FUNCTION fn_check_periodic_material_cost_input() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.input_kind = 'PERIODIC_MATERIAL' THEN
        IF NOT EXISTS (
            SELECT 1
            FROM workshop_material_close_allocations allocation
            JOIN workshop_material_close_materials material ON material.id = allocation.close_material_id
            JOIN workshop_material_period_closes close ON close.id = material.close_id AND close.status = 'ACTIVE'
            JOIN stock_value_events event
              ON event.source_event_id = allocation.id AND event.source_doc_type = 'WORKSHOP_PERIOD_ALLOCATION'
             AND event.result_node_id = NEW.input_node_id
            WHERE allocation.id = NEW.approved_posting_id AND allocation.reversed_at IS NULL
              AND allocation.cost_scope_segment_id = NEW.execution_segment_id) THEN
            RAISE EXCEPTION '整批领料的成本投入必须来自有效结算里同一成本范围、还没撤回的分摊'
                USING ERRCODE = '23514', CONSTRAINT = 'periodic_material_cost_input_guard';
        END IF;
    ELSIF EXISTS (SELECT 1 FROM workshop_material_close_allocations allocation WHERE allocation.id = NEW.approved_posting_id) THEN
        RAISE EXCEPTION '车间内料仓的分摊只能作为整批领料的成本投入'
            USING ERRCODE = '23514', CONSTRAINT = 'periodic_material_cost_input_guard';
    END IF;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_periodic_material_cost_input AFTER INSERT ON stock_value_production_cost_inputs
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_periodic_material_cost_input();
ALTER TABLE stock_value_production_cost_inputs ENABLE ALWAYS TRIGGER trg_periodic_material_cost_input;

-- 6.25 领料单/退回单全局永久占号 (只挂 INSERT 取号 + 改号拦截, 同 V674/V734)。
CREATE TRIGGER trg_business_document_workshop_material_requisitions BEFORE INSERT ON workshop_material_requisitions
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_business_document_identifier('', 'request_no', 'kind');
CREATE TRIGGER trg_business_document_workshop_material_requisitions_upd BEFORE UPDATE OF request_no, kind ON workshop_material_requisitions
    FOR EACH ROW WHEN (OLD.request_no IS DISTINCT FROM NEW.request_no OR OLD.kind IS DISTINCT FROM NEW.kind
        OR NULLIF(btrim(NEW.request_no), '') IS NULL)
    EXECUTE FUNCTION fn_guard_business_document_identifier_immutable('request_no', 'kind');

-- 6.26 库内提示文字: 线边仓改叫内料仓 (只改提示文字)。
DO $line_side_wording$
DECLARE
    target TEXT;
    definition TEXT;
BEGIN
    FOREACH target IN ARRAY ARRAY['fn_guard_procurement_iqc_pre_stock_mutation()',
                                  'fn_guard_production_finished_arrival_registration()'] LOOP
        SELECT pg_get_functiondef(target::regprocedure) INTO definition;
        IF (length(definition) - length(replace(definition, '线边仓', ''))) / length('线边仓') <> 2 THEN
            RAISE EXCEPTION 'V740 % line-side wording anchor changed', target;
        END IF;
        EXECUTE replace(definition, '线边仓', '内料仓');
    END LOOP;
END;
$line_side_wording$;

-- =====================================================================
-- 7. 数据、权限、编号、审计与业务清空登记
-- =====================================================================

-- 7.1 自动配置的线边仓改名为"{车间}内料仓"; 与运行期同一规则, 只给重名的追加" ({主仓})"。
WITH auto AS (
    SELECT warehouse.id, department.name AS dept_name, main.name AS main_name,
           row_number() OVER (PARTITION BY warehouse.workshop_department_id
                              ORDER BY warehouse.created_at, warehouse.id) AS seq_in_workshop
    FROM warehouses warehouse
    JOIN departments department ON department.id = warehouse.workshop_department_id
    LEFT JOIN warehouses main ON main.id = fn_warehouse_main_id(warehouse.id) AND main.id <> warehouse.id
    WHERE warehouse.is_line_side AND warehouse.auto_created AND NOT warehouse.is_deleted
)
UPDATE warehouses warehouse SET
    name = CASE WHEN auto.seq_in_workshop > 1 OR EXISTS (
                    SELECT 1 FROM warehouses other
                    WHERE other.id <> warehouse.id AND NOT other.is_deleted
                      AND other.name = auto.dept_name || '内料仓')
                THEN auto.dept_name || '内料仓 (' || COALESCE(auto.main_name, '主仓') || ')'
                ELSE auto.dept_name || '内料仓' END,
    remark = '系统自动配置的车间内料仓: 车间直送与整批领料的料放在这里, 不参与公共可用量与即时库存',
    updated_at = now()
FROM auto
WHERE warehouse.id = auto.id;

UPDATE permissions
SET name = replace(name, '线边仓', '内料仓'), description = replace(description, '线边仓', '内料仓')
WHERE description LIKE '%线边仓%' OR name LIKE '%线边仓%';

COMMENT ON COLUMN warehouses.is_line_side IS
    '车间内料仓 (V584 线边仓, ADR-131 改名): 车间自己的料架, 放车间直送的子件与整批领料的料; 默认不参与公共可用量与即时库存。车间归属沿用 V274 的 workshop_department_id';
COMMENT ON COLUMN stock_movements.movement_type IS
    '出入库类型：1采购入库 2采购退货 3销售出库 4销售退货 5生产领料 6生产退料 7调拨入 8调拨出 9盘盈入 10盘亏出 11其它入 12其它出 13产成品进仓 14产成品出仓 15委外材料出仓 16委外材料退回 17委外成品进仓 18委外成品退 19委外材料损耗 20销售其它出库 21内料仓盘点耗用 22内料仓盘盈';

-- 7.2 权限 (7 个)、权限面 (4 个) 与默认授予。
INSERT INTO permissions (code, name, module, category, sort_order, action_type, description, grant_policy, high_risk)
VALUES
    ('workshop_material:view', '查看车间内料仓与用量报表', '仓库管理', '车间内料仓', 320, 'VIEW',
     '查看车间内料仓里每种料的账面、本期进出、盘点与结算状态, 以及用量报表', ARRAY['NORMAL']::text[], FALSE),
    ('workshop_material:issue', '发料到车间内料仓与接收退回', '仓库管理', '车间内料仓', 321, 'EXECUTE',
     '仓库把整批领料的料直接发到车间内料仓、按车间申请发料, 并接收车间退回的料', ARRAY['NORMAL']::text[], FALSE),
    ('workshop_material:request', '车间申请领料、退回与登记其它耗用', '仓库管理', '车间内料仓', 322, 'CREATE',
     '车间申请整批领料、把用不完的料退回仓库, 登记试模、清机、报废料等其它耗用', ARRAY['NORMAL']::text[], FALSE),
    ('workshop_material:count', '车间内料仓盘点', '仓库管理', '车间内料仓', 323, 'EXECUTE',
     '开始盘点、逐台机逐袋录入实盘数、提交与更正盘点', ARRAY['NORMAL']::text[], FALSE),
    ('workshop_material:choose', '认料与换料', '仓库管理', '车间内料仓', 324, 'EXECUTE',
     '在开工确认表里为没有 BOM 单个重量的产品选择用内料仓的哪种料, 以及生产中途改用别的料', ARRAY['NORMAL']::text[], FALSE),
    ('workshop_material:setup', '车间整批领料设置、机台与上线准备', '仓库管理', '车间内料仓', 325, 'CONFIGURE',
     '开启车间整批领料、指定内料仓与启用日期, 维护机台和料斗储料桶容量, 批量填写产品单个重量', ARRAY['BULK_EXCLUDED', 'NON_DELEGABLE']::text[], FALSE),
    ('workshop_material:reopen', '撤销车间内料仓结算', '仓库管理', '车间内料仓', 326, 'EXECUTE',
     '撤销最近一期车间内料仓结算, 撤回已分到产品的用料成本, 以便更正盘点后重新结算', ARRAY['INDIVIDUAL_ONLY']::text[], TRUE);

INSERT INTO permission_surfaces (id, surface_key, name, sort_order, enabled) VALUES
    ('74000000-0000-4000-8000-000000000001', 'warehouse.workshop-material', '车间内料仓发料与盘点', 279, TRUE),
    ('74000000-0000-4000-8000-000000000002', 'warehouse.workshop-material-setup', '车间整批领料设置', 280, TRUE),
    ('74000000-0000-4000-8000-000000000003', 'production.workshop-material', '车间内料仓', 281, TRUE),
    ('74000000-0000-4000-8000-000000000004', 'report.workshop-material', '车间内料仓用量报表', 282, TRUE);

WITH mapping(surface_key, permission_code) AS (VALUES
    ('warehouse.workshop-material', 'workshop_material:view'),
    ('warehouse.workshop-material', 'workshop_material:issue'),
    ('warehouse.workshop-material', 'workshop_material:count'),
    ('warehouse.workshop-material-setup', 'workshop_material:view'),
    ('warehouse.workshop-material-setup', 'workshop_material:setup'),
    ('production.workshop-material', 'workshop_material:view'),
    ('production.workshop-material', 'workshop_material:request'),
    ('production.workshop-material', 'workshop_material:count'),
    ('production.workshop-material', 'workshop_material:choose'),
    ('report.workshop-material', 'workshop_material:view'),
    ('report.workshop-material', 'workshop_material:reopen')
)
INSERT INTO permission_surface_permissions (surface_id, permission_id)
SELECT surface.id, permission.id
FROM mapping
JOIN permission_surfaces surface ON surface.surface_key = mapping.surface_key
JOIN permissions permission ON permission.code = mapping.permission_code;

-- 撤销结算只逐人授予, 不授予任何部门。
WITH grants(department_code, permission_code) AS (VALUES
    ('DEPT_PROD', 'workshop_material:view'),
    ('DEPT_PROD', 'workshop_material:request'),
    ('DEPT_PROD', 'workshop_material:count'),
    ('DEPT_PROD', 'workshop_material:choose'),
    ('SUB_WH', 'workshop_material:view'),
    ('SUB_WH', 'workshop_material:issue'),
    ('SUB_WH', 'workshop_material:count'),
    ('SUB_WH', 'workshop_material:setup'),
    ('SUB_PLAN', 'workshop_material:view'),
    ('DEPT_FIN', 'workshop_material:view')
)
INSERT INTO department_permissions (department_id, permission_id)
SELECT department.id, permission.id
FROM grants
JOIN departments department ON department.code = grants.department_code AND NOT department.is_deleted
JOIN permissions permission ON permission.code = grants.permission_code
ON CONFLICT DO NOTHING;

-- 7.3 编号命名空间: 领料单 ZL、退回单 ZT (全局永久占号, 按上海日期日流水)。
INSERT INTO business_identifier_namespaces (namespace_key, identifier_family, fixed_prefix, source_table,
                                            identifier_column, discriminator_value)
VALUES ('WORKSHOP_MATERIAL_ISSUE', 'DOCUMENT', 'ZL', 'workshop_material_requisitions', 'request_no', 'ISSUE'),
       ('WORKSHOP_MATERIAL_RETURN', 'DOCUMENT', 'ZT', 'workshop_material_requisitions', 'request_no', 'RETURN');

-- 7.4 行级审计 (ADR-105 三清单): 理论明细是派生可复算、命令账本是幂等协调状态, 不挂行审计。
SELECT fn_audit_track_table('workshop_material_settings', 'FULL', 'data_change', false);
SELECT fn_audit_track_table('workshop_machines', 'FULL', 'data_change', false);
SELECT fn_audit_track_table('workshop_machine_containers', 'FULL', 'data_change', false);
SELECT fn_audit_track_table('goods_periodic_material_choices', 'FULL', 'data_change', false);
SELECT fn_audit_track_table('production_execution_periodic_materials', 'FULL', 'data_change', false);
SELECT fn_audit_track_table('production_execution_material_changes', 'FULL', 'data_change', false);
SELECT fn_audit_track_table('workshop_material_commands', 'NONE', 'data_change', false);
SELECT fn_audit_track_table('workshop_material_requisitions', 'FULL', 'data_change', false);
SELECT fn_audit_track_table('workshop_material_requisition_lines', 'FULL', 'data_change', false);
SELECT fn_audit_track_table('workshop_material_stock_documents', 'FULL', 'data_change', false);
SELECT fn_audit_track_table('workshop_material_requisition_postings', 'FULL', 'data_change', false);
SELECT fn_audit_track_table('workshop_material_other_issues', 'FULL', 'data_change', false);
SELECT fn_audit_track_table('workshop_material_periods', 'FULL', 'data_change', false);
SELECT fn_audit_track_table('workshop_material_counts', 'FULL', 'data_change', false);
SELECT fn_audit_track_table('workshop_material_count_lines', 'FULL', 'data_change', false);
SELECT fn_audit_track_table('workshop_material_period_lines', 'FULL', 'data_change', false);
SELECT fn_audit_track_table('workshop_material_count_postings', 'FULL', 'data_change', false);
SELECT fn_audit_track_table('workshop_material_period_closes', 'FULL', 'data_change', false);
SELECT fn_audit_track_table('workshop_material_close_materials', 'FULL', 'data_change', false);
SELECT fn_audit_track_table('workshop_material_close_theory_lines', 'NONE', 'data_change', false);
SELECT fn_audit_track_table('workshop_material_close_allocations', 'FULL', 'data_change', false);

-- 7.5 工作台「清空业务数据」孪生函数登记 21 张新表: 业务事实 18 张清空; 机台、容器、认料 3 张随主档保留。
DO $reset_policy$
DECLARE definition TEXT; anchor TEXT := '(''stock_movements'', ''CLEAR'')';
BEGIN
    SELECT pg_get_functiondef('business_data_reset()'::regprocedure) INTO definition;
    IF (length(definition) - length(replace(definition, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'V740 business_data_reset policy anchor changed';
    END IF;
    EXECUTE replace(definition, anchor, anchor
        || E',\n            (''workshop_material_settings'', ''CLEAR'')'
        || E',\n            (''production_execution_periodic_materials'', ''CLEAR'')'
        || E',\n            (''production_execution_material_changes'', ''CLEAR'')'
        || E',\n            (''workshop_material_commands'', ''CLEAR'')'
        || E',\n            (''workshop_material_requisitions'', ''CLEAR'')'
        || E',\n            (''workshop_material_requisition_lines'', ''CLEAR'')'
        || E',\n            (''workshop_material_stock_documents'', ''CLEAR'')'
        || E',\n            (''workshop_material_requisition_postings'', ''CLEAR'')'
        || E',\n            (''workshop_material_other_issues'', ''CLEAR'')'
        || E',\n            (''workshop_material_periods'', ''CLEAR'')'
        || E',\n            (''workshop_material_counts'', ''CLEAR'')'
        || E',\n            (''workshop_material_count_lines'', ''CLEAR'')'
        || E',\n            (''workshop_material_period_lines'', ''CLEAR'')'
        || E',\n            (''workshop_material_count_postings'', ''CLEAR'')'
        || E',\n            (''workshop_material_period_closes'', ''CLEAR'')'
        || E',\n            (''workshop_material_close_materials'', ''CLEAR'')'
        || E',\n            (''workshop_material_close_theory_lines'', ''CLEAR'')'
        || E',\n            (''workshop_material_close_allocations'', ''CLEAR'')'
        || E',\n            (''workshop_machines'', ''PRESERVE'')'
        || E',\n            (''workshop_machine_containers'', ''PRESERVE'')'
        || E',\n            (''goods_periodic_material_choices'', ''PRESERVE'')');
END;
$reset_policy$;
