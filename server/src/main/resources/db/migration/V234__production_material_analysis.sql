-- V234: persistent pre-plan production material analysis.
--
-- This is deliberately separate from the formal V150/V155 fulfilment ledger.
-- Analyses and pre-plan supply actions never create production_material_demands,
-- stock_reservations, supply pegs, execution segments or DRAW documents. Those
-- authoritative facts remain approval-time output of an ACTIVE planning draft.

-- ============================ explicit BOM intent ============================

ALTER TABLE goods
    ADD COLUMN production_bom_policy TEXT;

UPDATE goods
SET production_bom_policy = CASE
    WHEN btrim(COALESCE(source_type, '')) IN ('采购', '委外')
        THEN 'NOT_PRODUCED'
    ELSE 'BOM_REQUIRED'
END
WHERE production_bom_policy IS NULL;

ALTER TABLE goods
    ALTER COLUMN production_bom_policy SET DEFAULT 'BOM_REQUIRED',
    ALTER COLUMN production_bom_policy SET NOT NULL,
    ADD CONSTRAINT goods_production_bom_policy_chk
        CHECK (production_bom_policy IN (
            'BOM_REQUIRED', 'DIRECT_MAKE', 'NOT_PRODUCED'
        ));

COMMENT ON COLUMN goods.production_bom_policy IS
    'Explicit production intent. Missing legacy BOM never implies DIRECT_MAKE.';

-- ============================ analysis aggregate =============================

CREATE TABLE production_material_analyses (
    id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    warehouse_id       UUID REFERENCES warehouses(id) ON DELETE RESTRICT,
    status             TEXT NOT NULL DEFAULT 'ACTIVE',
    version            BIGINT NOT NULL DEFAULT 0,
    fingerprint        TEXT NOT NULL,
    preview_fingerprint TEXT,
    initial_idempotency_key TEXT NOT NULL,
    analyzed_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    maker_id           UUID NOT NULL REFERENCES employees(id) ON DELETE RESTRICT,
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by         UUID,
    updated_by         UUID,
    cancelled_by       UUID REFERENCES users(id) ON DELETE RESTRICT,
    cancelled_at       TIMESTAMPTZ,
    cancellation_reason TEXT,
    is_deleted         BOOLEAN NOT NULL DEFAULT FALSE,
    deleted_at         TIMESTAMPTZ,
    CONSTRAINT production_material_analysis_status_chk
        CHECK (status IN (
            'ACTIVE', 'PARTIALLY_PLANNED', 'COMPLETED', 'CANCELLED'
        )),
    CONSTRAINT production_material_analysis_version_chk CHECK (version >= 0),
    CONSTRAINT production_material_analysis_initial_idem_chk CHECK (
        length(btrim(initial_idempotency_key)) BETWEEN 8 AND 128
    ),
    CONSTRAINT production_material_analysis_cancel_chk CHECK (
        (status <> 'CANCELLED'
            AND cancelled_by IS NULL AND cancelled_at IS NULL
            AND cancellation_reason IS NULL)
        OR
        (status = 'CANCELLED'
            AND cancelled_by IS NOT NULL AND cancelled_at IS NOT NULL
            AND cancellation_reason IS NOT NULL
            AND length(btrim(cancellation_reason)) BETWEEN 2 AND 1000)
    ),
    CONSTRAINT production_material_analysis_fingerprint_chk CHECK (
        fingerprint ~ '^[0-9a-f]{64}$'
        AND (preview_fingerprint IS NULL
             OR preview_fingerprint ~ '^[0-9a-f]{64}$')
    )
);

CREATE INDEX idx_production_material_analysis_workbench
    ON production_material_analyses(status, analyzed_at DESC, id)
    WHERE is_deleted = FALSE;
CREATE INDEX idx_production_material_analysis_maker
    ON production_material_analyses(maker_id, analyzed_at DESC, id)
    WHERE is_deleted = FALSE;
CREATE UNIQUE INDEX uq_production_material_analysis_initial_idem
    ON production_material_analyses(maker_id, initial_idempotency_key)
    WHERE is_deleted = FALSE;

CREATE TABLE production_material_analysis_items (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    analysis_id         UUID NOT NULL
        REFERENCES production_material_analyses(id) ON DELETE CASCADE,
    source_type         TEXT NOT NULL DEFAULT 'SALES_ORDER_ITEM',
    sales_order_item_id UUID
        REFERENCES sales_order_items(id) ON DELETE RESTRICT,
    goods_id            UUID NOT NULL REFERENCES goods(id) ON DELETE RESTRICT,
    color_id            UUID REFERENCES colors(id) ON DELETE RESTRICT,
    unit_id             UUID NOT NULL REFERENCES units(id) ON DELETE RESTRICT,
    source_ref          TEXT,
    source_reason       TEXT,
    requested_qty       NUMERIC(18,4) NOT NULL,
    submitted_qty       NUMERIC(18,4) NOT NULL DEFAULT 0,
    approved_qty        NUMERIC(18,4) NOT NULL DEFAULT 0,
    ready_now_qty       NUMERIC(18,4) NOT NULL DEFAULT 0,
    ready_by_date_qty   NUMERIC(18,4) NOT NULL DEFAULT 0,
    delivery_date       DATE,
    line_priority       INTEGER NOT NULL DEFAULT 0,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by          UUID,
    updated_by          UUID,
    is_deleted          BOOLEAN NOT NULL DEFAULT FALSE,
    deleted_at          TIMESTAMPTZ,
    CONSTRAINT production_material_analysis_item_qty_chk CHECK (
        requested_qty > 0
        AND submitted_qty >= 0
        AND approved_qty >= 0
        AND submitted_qty + approved_qty <= requested_qty
        AND ready_now_qty >= 0
        AND ready_by_date_qty >= ready_now_qty
        AND ready_by_date_qty <= requested_qty - submitted_qty - approved_qty
    ),
    CONSTRAINT production_material_analysis_item_source_type_chk CHECK (
        source_type IN (
            'SALES_ORDER_ITEM', 'REWORK', 'TRIAL', 'SAMPLE',
            'STOCK', 'OTHER', 'MAKE_COMPONENT'
        )
    ),
    CONSTRAINT production_material_analysis_item_source_shape_chk CHECK (
        (source_type = 'SALES_ORDER_ITEM'
            AND sales_order_item_id IS NOT NULL
            AND source_ref IS NULL
            AND source_reason IS NULL)
        OR
        (source_type <> 'SALES_ORDER_ITEM'
            AND sales_order_item_id IS NULL
            AND source_ref IS NOT NULL
            AND length(btrim(source_ref)) BETWEEN 1 AND 200
            AND source_reason IS NOT NULL
            AND length(btrim(source_reason)) BETWEEN 2 AND 1000)
    ),
    UNIQUE (analysis_id, id)
);

CREATE UNIQUE INDEX uq_production_material_analysis_item_source
    ON production_material_analysis_items(analysis_id, sales_order_item_id)
    WHERE is_deleted = FALSE AND sales_order_item_id IS NOT NULL;
CREATE INDEX idx_production_material_analysis_item_sales
    ON production_material_analysis_items(sales_order_item_id, analysis_id)
    WHERE is_deleted = FALSE;
CREATE UNIQUE INDEX uq_production_material_analysis_manual_source_ref
    ON production_material_analysis_items(source_type, lower(btrim(source_ref)))
    WHERE is_deleted = FALSE AND source_type <> 'SALES_ORDER_ITEM';

CREATE TABLE production_material_analysis_materials (
    id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    analysis_id           UUID NOT NULL
        REFERENCES production_material_analyses(id) ON DELETE CASCADE,
    analysis_item_id      UUID NOT NULL
        REFERENCES production_material_analysis_items(id) ON DELETE CASCADE,
    node_key              TEXT NOT NULL,
    parent_node_key       TEXT,
    bom_item_id           UUID REFERENCES goods_bom_items(id) ON DELETE RESTRICT,
    goods_id              UUID NOT NULL REFERENCES goods(id) ON DELETE RESTRICT,
    color_id              UUID REFERENCES colors(id) ON DELETE RESTRICT,
    unit_id               UUID NOT NULL REFERENCES units(id) ON DELETE RESTRICT,
    depth                 INTEGER NOT NULL,
    path                  TEXT NOT NULL,
    per_product_qty       NUMERIC(18,6) NOT NULL,
    required_qty          NUMERIC(18,4) NOT NULL,
    available_qty         NUMERIC(18,4) NOT NULL DEFAULT 0,
    allocated_available_qty NUMERIC(18,4) NOT NULL DEFAULT 0,
    reserved_qty          NUMERIC(18,4) NOT NULL DEFAULT 0,
    safety_stock_qty      NUMERIC(18,4) NOT NULL DEFAULT 0,
    inbound_qty           NUMERIC(18,4) NOT NULL DEFAULT 0,
    shortage_qty          NUMERIC(18,4) NOT NULL DEFAULT 0,
    expected_ready_date   DATE,
    source_suggestion     TEXT NOT NULL,
    confirmed_route       TEXT,
    route_reason          TEXT,
    route_confirmed_by    UUID REFERENCES users(id) ON DELETE RESTRICT,
    route_confirmed_at    TIMESTAMPTZ,
    lower_level_pending   BOOLEAN NOT NULL DEFAULT FALSE,
    active                BOOLEAN NOT NULL DEFAULT TRUE,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by            UUID,
    updated_by            UUID,
    CONSTRAINT production_material_analysis_material_depth_chk
        CHECK (depth BETWEEN 1 AND 10),
    CONSTRAINT production_material_analysis_material_qty_chk CHECK (
        per_product_qty > 0 AND required_qty >= 0
        AND available_qty >= 0 AND reserved_qty >= 0
        AND allocated_available_qty >= 0
        AND allocated_available_qty <= required_qty
        AND safety_stock_qty >= 0 AND inbound_qty >= 0
        AND shortage_qty >= 0
    ),
    CONSTRAINT production_material_analysis_material_suggestion_chk
        CHECK (source_suggestion IN ('BUY', 'MAKE', 'SUBCONTRACT', 'REVIEW')),
    CONSTRAINT production_material_analysis_material_route_chk CHECK (
        confirmed_route IS NULL
        OR confirmed_route IN ('BUY', 'MAKE', 'SUBCONTRACT')
    ),
    CONSTRAINT production_material_analysis_material_route_reason_chk CHECK (
        (confirmed_route IS NULL
            AND route_reason IS NULL
            AND route_confirmed_by IS NULL
            AND route_confirmed_at IS NULL)
        OR
        (confirmed_route IS NOT NULL
            AND (
                (confirmed_route = source_suggestion
                    AND source_suggestion <> 'REVIEW'
                    AND (route_reason IS NULL OR length(btrim(route_reason)) BETWEEN 2 AND 1000))
                OR
                (confirmed_route IS DISTINCT FROM source_suggestion
                    AND route_reason IS NOT NULL
                    AND length(btrim(route_reason)) BETWEEN 2 AND 1000)
                OR
                (source_suggestion = 'REVIEW'
                    AND route_reason IS NOT NULL
                    AND length(btrim(route_reason)) BETWEEN 2 AND 1000)
            )
            AND route_confirmed_by IS NOT NULL
            AND route_confirmed_at IS NOT NULL)
    ),
    CONSTRAINT production_material_analysis_material_item_owner_fk
        FOREIGN KEY (analysis_id, analysis_item_id)
        REFERENCES production_material_analysis_items(analysis_id, id)
        ON DELETE CASCADE,
    UNIQUE (analysis_id, id)
);

CREATE UNIQUE INDEX uq_production_material_analysis_material_node
    ON production_material_analysis_materials(analysis_item_id, node_key);
CREATE INDEX idx_production_material_analysis_material_dimension
    ON production_material_analysis_materials(
        analysis_id, goods_id, color_id, unit_id, expected_ready_date
    ) WHERE active = TRUE;

ALTER TABLE production_material_analysis_items
    ADD COLUMN parent_analysis_material_id UUID
        REFERENCES production_material_analysis_materials(id) ON DELETE RESTRICT,
    ADD CONSTRAINT production_material_analysis_item_parent_owner_fk
        FOREIGN KEY (analysis_id, parent_analysis_material_id)
        REFERENCES production_material_analysis_materials(analysis_id, id)
        ON DELETE RESTRICT,
    ADD CONSTRAINT production_material_analysis_item_parent_shape_chk CHECK (
        (source_type = 'MAKE_COMPONENT'
            AND parent_analysis_material_id IS NOT NULL)
        OR
        (source_type <> 'MAKE_COMPONENT'
            AND parent_analysis_material_id IS NULL)
    );

CREATE UNIQUE INDEX uq_production_material_analysis_make_component_parent
    ON production_material_analysis_items(parent_analysis_material_id)
    WHERE source_type = 'MAKE_COMPONENT' AND is_deleted = FALSE;

CREATE OR REPLACE FUNCTION fn_validate_make_component_source_dimension()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_parent production_material_analysis_materials%ROWTYPE;
BEGIN
    IF NEW.source_type <> 'MAKE_COMPONENT' THEN
        RETURN NEW;
    END IF;
    SELECT * INTO v_parent
    FROM production_material_analysis_materials
    WHERE analysis_id = NEW.analysis_id
      AND id = NEW.parent_analysis_material_id;
    IF v_parent.id IS NULL
       OR v_parent.goods_id IS DISTINCT FROM NEW.goods_id
       OR v_parent.color_id IS DISTINCT FROM NEW.color_id
       OR v_parent.unit_id IS DISTINCT FROM NEW.unit_id THEN
        RAISE EXCEPTION 'MAKE_COMPONENT source must match its parent material dimension'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_validate_make_component_source_dimension
    BEFORE INSERT OR UPDATE OF source_type, parent_analysis_material_id,
        goods_id, color_id, unit_id
    ON production_material_analysis_items
    FOR EACH ROW EXECUTE FUNCTION
        fn_validate_make_component_source_dimension();

-- ====================== pre-plan downstream work/action ======================

CREATE TABLE preplan_supply_actions (
    id                     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    analysis_id            UUID NOT NULL
        REFERENCES production_material_analyses(id) ON DELETE RESTRICT,
    warehouse_id           UUID NOT NULL REFERENCES warehouses(id) ON DELETE RESTRICT,
    goods_id               UUID NOT NULL REFERENCES goods(id) ON DELETE RESTRICT,
    color_id               UUID REFERENCES colors(id) ON DELETE RESTRICT,
    unit_id                UUID NOT NULL REFERENCES units(id) ON DELETE RESTRICT,
    need_date              DATE,
    route                  TEXT NOT NULL,
    requested_qty          NUMERIC(18,4) NOT NULL,
    status                 TEXT NOT NULL DEFAULT 'OPEN',
    external_document_type TEXT,
    external_document_id   UUID,
    external_document_no   TEXT,
    idempotency_key        TEXT NOT NULL,
    action_group_key       TEXT NOT NULL,
    request_business_key   TEXT NOT NULL,
    generation             INTEGER NOT NULL DEFAULT 1,
    predecessor_action_id  UUID
        REFERENCES preplan_supply_actions(id) ON DELETE RESTRICT,
    request_hash           TEXT NOT NULL,
    created_by             UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    created_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    cancelled_by           UUID REFERENCES users(id) ON DELETE RESTRICT,
    cancelled_at           TIMESTAMPTZ,
    cancellation_reason    TEXT,
    CONSTRAINT preplan_supply_action_route_chk
        CHECK (route IN ('BUY', 'MAKE', 'SUBCONTRACT')),
    CONSTRAINT preplan_supply_action_qty_chk CHECK (requested_qty > 0),
    CONSTRAINT preplan_supply_action_status_chk
        CHECK (status IN ('OPEN', 'CREATED', 'IN_PROGRESS', 'DONE', 'CANCELLED')),
    CONSTRAINT preplan_supply_action_external_chk CHECK (
        (status = 'OPEN'
            AND external_document_type IS NULL
            AND external_document_id IS NULL)
        OR
        (status IN ('CREATED', 'IN_PROGRESS', 'DONE')
            AND external_document_type IN (
                'PURCHASE_REQUEST', 'SUBCONTRACT_APPLICATION', 'PREPLAN_MAKE_TASK'
            )
            AND external_document_id IS NOT NULL)
        OR status = 'CANCELLED'
    ),
    CONSTRAINT preplan_supply_action_hash_chk
        CHECK (request_hash ~ '^[0-9a-f]{64}$'
               AND action_group_key ~ '^[0-9a-f]{64}$'
               AND request_business_key ~ '^[0-9a-f]{64}$'),
    CONSTRAINT preplan_supply_action_generation_chk CHECK (generation > 0),
    CONSTRAINT preplan_supply_action_key_chk
        CHECK (length(btrim(idempotency_key)) BETWEEN 8 AND 128),
    CONSTRAINT preplan_supply_action_cancel_chk CHECK (
        (status <> 'CANCELLED'
            AND cancelled_by IS NULL AND cancelled_at IS NULL
            AND cancellation_reason IS NULL)
        OR
        (status = 'CANCELLED'
            AND cancelled_by IS NOT NULL AND cancelled_at IS NOT NULL
            AND cancellation_reason IS NOT NULL
            AND length(btrim(cancellation_reason)) >= 2)
    ),
    UNIQUE (analysis_id, id)
);

CREATE UNIQUE INDEX uq_preplan_supply_action_idempotency
    ON preplan_supply_actions(analysis_id, idempotency_key);
CREATE UNIQUE INDEX uq_preplan_supply_action_business_active
    ON preplan_supply_actions(analysis_id, request_business_key);
CREATE UNIQUE INDEX uq_preplan_supply_action_group_generation
    ON preplan_supply_actions(
        analysis_id, action_group_key, route, generation
    );
CREATE INDEX idx_preplan_supply_action_workbench
    ON preplan_supply_actions(route, status, need_date, id)
    WHERE status NOT IN ('DONE', 'CANCELLED');

CREATE TABLE preplan_supply_action_allocations (
    id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    analysis_id          UUID NOT NULL
        REFERENCES production_material_analyses(id) ON DELETE RESTRICT,
    action_id            UUID NOT NULL
        REFERENCES preplan_supply_actions(id) ON DELETE RESTRICT,
    analysis_material_id UUID NOT NULL
        REFERENCES production_material_analysis_materials(id) ON DELETE RESTRICT,
    allocated_qty        NUMERIC(18,4) NOT NULL,
    external_item_id     UUID,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by           UUID REFERENCES users(id) ON DELETE RESTRICT,
    CONSTRAINT preplan_supply_action_allocation_qty_chk
        CHECK (allocated_qty > 0),
    CONSTRAINT preplan_supply_action_allocation_action_owner_fk
        FOREIGN KEY (analysis_id, action_id)
        REFERENCES preplan_supply_actions(analysis_id, id) ON DELETE RESTRICT,
    CONSTRAINT preplan_supply_action_allocation_material_owner_fk
        FOREIGN KEY (analysis_id, analysis_material_id)
        REFERENCES production_material_analysis_materials(analysis_id, id)
        ON DELETE RESTRICT,
    UNIQUE (action_id, analysis_material_id)
);

CREATE INDEX idx_preplan_supply_action_allocation_material
    ON preplan_supply_action_allocations(analysis_material_id, action_id);

CREATE OR REPLACE FUNCTION fn_check_preplan_supply_action_allocation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_action_id UUID;
    v_requested NUMERIC(18,4);
    v_allocated NUMERIC(18,4);
BEGIN
    IF TG_TABLE_NAME = 'preplan_supply_actions' THEN
        v_action_id := COALESCE(NEW.id, OLD.id);
    ELSE
        v_action_id := COALESCE(NEW.action_id, OLD.action_id);
    END IF;
    SELECT requested_qty INTO v_requested
    FROM preplan_supply_actions
    WHERE id = v_action_id;
    IF v_requested IS NULL THEN
        RETURN NULL;
    END IF;
    SELECT COALESCE(SUM(allocated_qty), 0) INTO v_allocated
    FROM preplan_supply_action_allocations
    WHERE action_id = v_action_id;
    IF v_requested IS DISTINCT FROM v_allocated THEN
        RAISE EXCEPTION
            'preplan supply action allocation total % must equal requested quantity %',
            v_allocated, v_requested
            USING ERRCODE = '23514';
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_check_preplan_supply_action_allocation
    AFTER INSERT OR UPDATE OR DELETE ON preplan_supply_action_allocations
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_check_preplan_supply_action_allocation();

CREATE CONSTRAINT TRIGGER trg_check_preplan_supply_action_header_total
    AFTER INSERT OR UPDATE OF requested_qty ON preplan_supply_actions
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_check_preplan_supply_action_allocation();

-- Generic idempotency ledger. Stored response references make a successful
-- generate/notify replay observable without executing external side effects.
CREATE TABLE production_material_analysis_commands (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    analysis_id       UUID NOT NULL
        REFERENCES production_material_analyses(id) ON DELETE RESTRICT,
    operation         TEXT NOT NULL,
    idempotency_key   TEXT NOT NULL,
    request_hash      TEXT NOT NULL,
    result_payload    JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_by        UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT production_material_analysis_command_operation_chk
        CHECK (operation IN (
            'PREVIEW', 'ROUTE', 'REALLOCATE', 'NOTIFY', 'GENERATE_PLAN',
            'CANCEL_ANALYSIS', 'CANCEL_ACTION'
        )),
    CONSTRAINT production_material_analysis_command_hash_chk
        CHECK (request_hash ~ '^[0-9a-f]{64}$'),
    CONSTRAINT production_material_analysis_command_key_chk
        CHECK (length(btrim(idempotency_key)) BETWEEN 8 AND 128),
    CONSTRAINT production_material_analysis_command_payload_chk
        CHECK (jsonb_typeof(result_payload) = 'object'),
    UNIQUE (analysis_id, operation, idempotency_key)
);

-- ======================== formal-plan conservation ==========================

ALTER TABLE production_plans
    ADD COLUMN material_analysis_id UUID
        REFERENCES production_material_analyses(id) ON DELETE RESTRICT,
    ADD COLUMN material_analysis_item_id UUID
        REFERENCES production_material_analysis_items(id) ON DELETE RESTRICT,
    ADD COLUMN bom_override_reason TEXT,
    ADD COLUMN bom_override_by UUID REFERENCES users(id) ON DELETE RESTRICT,
    ADD CONSTRAINT production_plan_bom_override_shape_chk CHECK (
        (bom_override_reason IS NULL AND bom_override_by IS NULL)
        OR
        (bom_override_reason IS NOT NULL
            AND length(btrim(bom_override_reason)) BETWEEN 2 AND 1000
            AND bom_override_by IS NOT NULL)
    );

CREATE INDEX idx_production_plan_material_analysis
    ON production_plans(material_analysis_id, material_analysis_item_id)
    WHERE material_analysis_id IS NOT NULL;

CREATE OR REPLACE FUNCTION fn_validate_production_plan_material_analysis_source()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'UPDATE'
       AND OLD.material_analysis_id IS NOT NULL
       AND (OLD.material_analysis_id IS DISTINCT FROM NEW.material_analysis_id
            OR OLD.material_analysis_item_id IS DISTINCT FROM NEW.material_analysis_item_id) THEN
        RAISE EXCEPTION 'production plan material-analysis source is immutable'
            USING ERRCODE = '55000';
    END IF;
    IF NEW.material_analysis_id IS NULL
       AND NEW.material_analysis_item_id IS NULL THEN
        RETURN NEW;
    END IF;
    IF NEW.material_analysis_id IS NULL
       OR NEW.material_analysis_item_id IS NULL
       OR NOT EXISTS (
           SELECT 1
           FROM production_material_analysis_items i
           WHERE i.id = NEW.material_analysis_item_id
             AND i.analysis_id = NEW.material_analysis_id
             AND i.is_deleted = FALSE
       ) THEN
        RAISE EXCEPTION 'production plan analysis item does not belong to analysis'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_validate_production_plan_material_analysis_source
    BEFORE INSERT OR UPDATE OF material_analysis_id, material_analysis_item_id
    ON production_plans
    FOR EACH ROW EXECUTE FUNCTION
        fn_validate_production_plan_material_analysis_source();

CREATE OR REPLACE FUNCTION fn_guard_material_analysis_plan_item_identity()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'INSERT' AND EXISTS (
        SELECT 1 FROM production_plans p
        WHERE p.id = NEW.plan_id
          AND p.material_analysis_id IS NOT NULL
    ) THEN
        RAISE EXCEPTION 'material-analysis plan cannot accept another plan item'
            USING ERRCODE = '55000';
    END IF;
    IF TG_OP = 'DELETE' AND EXISTS (
        SELECT 1 FROM production_plans p
        WHERE p.id = OLD.plan_id
          AND p.material_analysis_id IS NOT NULL
    ) THEN
        RAISE EXCEPTION 'material-analysis plan item identity and quantity are immutable'
            USING ERRCODE = '55000';
    END IF;
    IF TG_OP = 'UPDATE' AND EXISTS (
        SELECT 1 FROM production_plans p
        WHERE p.id IN (OLD.plan_id, NEW.plan_id)
          AND p.material_analysis_id IS NOT NULL
    ) AND (
        OLD.plan_id IS DISTINCT FROM NEW.plan_id
        OR OLD.goods_id IS DISTINCT FROM NEW.goods_id
        OR OLD.color_id IS DISTINCT FROM NEW.color_id
        OR OLD.unit_id IS DISTINCT FROM NEW.unit_id
        OR COALESCE(OLD.unit_rate,1) IS DISTINCT FROM COALESCE(NEW.unit_rate,1)
        OR OLD.sales_order_item_id IS DISTINCT FROM NEW.sales_order_item_id
        OR OLD.qty IS DISTINCT FROM NEW.qty
        OR OLD.is_deleted IS DISTINCT FROM NEW.is_deleted
    ) THEN
        RAISE EXCEPTION 'material-analysis plan item identity and quantity are immutable'
            USING ERRCODE = '55000';
    END IF;
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_material_analysis_plan_item_identity
    BEFORE INSERT OR UPDATE OR DELETE ON production_plan_items
    FOR EACH ROW EXECUTE FUNCTION fn_guard_material_analysis_plan_item_identity();

CREATE TABLE production_material_analysis_plan_links (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    analysis_id       UUID NOT NULL
        REFERENCES production_material_analyses(id) ON DELETE RESTRICT,
    analysis_item_id  UUID NOT NULL
        REFERENCES production_material_analysis_items(id) ON DELETE RESTRICT,
    plan_id           UUID NOT NULL REFERENCES production_plans(id) ON DELETE RESTRICT,
    submitted_qty     NUMERIC(18,4) NOT NULL,
    allocation_status TEXT NOT NULL DEFAULT 'SUBMITTED',
    created_by        UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT production_material_analysis_plan_link_qty_chk
        CHECK (submitted_qty > 0),
    CONSTRAINT production_material_analysis_plan_link_status_chk
        CHECK (allocation_status IN (
            'SUBMITTED', 'APPROVED', 'RELEASED', 'REVERSED'
        )),
    CONSTRAINT production_material_analysis_plan_link_item_owner_fk
        FOREIGN KEY (analysis_id, analysis_item_id)
        REFERENCES production_material_analysis_items(analysis_id, id)
        ON DELETE RESTRICT,
    UNIQUE (plan_id),
    UNIQUE (analysis_item_id, plan_id)
);

CREATE INDEX idx_production_material_analysis_plan_link_item
    ON production_material_analysis_plan_links(
        analysis_item_id, allocation_status, plan_id
    );

CREATE OR REPLACE FUNCTION fn_sync_material_analysis_plan_link_qty()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_old_submitted NUMERIC(18,4) := 0;
    v_old_approved  NUMERIC(18,4) := 0;
    v_new_submitted NUMERIC(18,4) := 0;
    v_new_approved  NUMERIC(18,4) := 0;
    v_item production_material_analysis_items%ROWTYPE;
    v_remaining NUMERIC(18,4);
    v_used NUMERIC(18,4);
    v_old_claim NUMERIC(18,4);
    v_new_claim NUMERIC(18,4);
    v_claim_delta NUMERIC(18,4);
BEGIN
    PERFORM 1
    FROM production_material_analyses
    WHERE id = NEW.analysis_id
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'material analysis not found'
            USING ERRCODE = '23503';
    END IF;

    IF TG_OP = 'UPDATE' AND (
        OLD.analysis_id IS DISTINCT FROM NEW.analysis_id
        OR OLD.analysis_item_id IS DISTINCT FROM NEW.analysis_item_id
        OR OLD.plan_id IS DISTINCT FROM NEW.plan_id
        OR OLD.submitted_qty IS DISTINCT FROM NEW.submitted_qty
        OR OLD.created_by IS DISTINCT FROM NEW.created_by
        OR OLD.created_at IS DISTINCT FROM NEW.created_at
    ) THEN
        RAISE EXCEPTION 'material analysis plan-link identity is immutable'
            USING ERRCODE = '55000';
    END IF;

    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'material analysis plan links are append-only'
            USING ERRCODE = '55000';
    END IF;

    IF TG_OP = 'INSERT' THEN
        IF NOT EXISTS (
            SELECT 1 FROM production_material_analysis_items i
            WHERE i.id = NEW.analysis_item_id
              AND i.analysis_id = NEW.analysis_id
              AND i.is_deleted = FALSE
        ) THEN
            RAISE EXCEPTION 'material analysis item does not belong to analysis'
                USING ERRCODE = '23514';
        END IF;
        IF NOT EXISTS (
            SELECT 1 FROM production_plans p
            WHERE p.id = NEW.plan_id
              AND p.material_analysis_id = NEW.analysis_id
              AND p.material_analysis_item_id = NEW.analysis_item_id
              AND p.status = 0
              AND p.is_deleted = FALSE
              AND p.is_canceled = FALSE
        ) THEN
            RAISE EXCEPTION 'linked production plan is not the same active analysis draft'
                USING ERRCODE = '23514';
        END IF;
        IF (SELECT COUNT(*) FROM production_plan_items pi
            WHERE pi.plan_id = NEW.plan_id AND pi.is_deleted = FALSE) <> 1
           OR NOT EXISTS (
               SELECT 1
               FROM production_plan_items pi
               JOIN production_material_analysis_items ai
                 ON ai.id = NEW.analysis_item_id
                AND ai.analysis_id = NEW.analysis_id
                AND ai.is_deleted = FALSE
               LEFT JOIN sales_order_items soi
                 ON soi.id = ai.sales_order_item_id AND soi.is_deleted = FALSE
               WHERE pi.plan_id = NEW.plan_id
                 AND pi.is_deleted = FALSE
                 AND pi.goods_id = ai.goods_id
                 AND pi.color_id IS NOT DISTINCT FROM ai.color_id
                 AND pi.unit_id = ai.unit_id
                 AND COALESCE(pi.unit_rate,1) = COALESCE(soi.unit_rate,1)
                 AND pi.sales_order_item_id IS NOT DISTINCT FROM ai.sales_order_item_id
                 AND pi.qty = NEW.submitted_qty
           ) THEN
            RAISE EXCEPTION 'analysis demand, plan item and submitted quantity differ'
                USING ERRCODE = '23514';
        END IF;
    END IF;

    IF TG_OP = 'UPDATE' THEN
        v_old_submitted := CASE WHEN OLD.allocation_status = 'SUBMITTED'
            THEN OLD.submitted_qty ELSE 0 END;
        v_old_approved := CASE WHEN OLD.allocation_status = 'APPROVED'
            THEN OLD.submitted_qty ELSE 0 END;
    END IF;
    v_new_submitted := CASE WHEN NEW.allocation_status = 'SUBMITTED'
        THEN NEW.submitted_qty ELSE 0 END;
    v_new_approved := CASE WHEN NEW.allocation_status = 'APPROVED'
        THEN NEW.submitted_qty ELSE 0 END;
    v_old_claim := v_old_submitted + v_old_approved;
    v_new_claim := v_new_submitted + v_new_approved;
    v_claim_delta := v_new_claim - v_old_claim;

    SELECT * INTO v_item
    FROM production_material_analysis_items
    WHERE id = NEW.analysis_item_id
    FOR UPDATE;

    IF v_item.id IS NULL THEN
        RAISE EXCEPTION 'material analysis item not found'
            USING ERRCODE = '23503';
    END IF;

    UPDATE production_material_analysis_items
    SET submitted_qty = submitted_qty - v_old_submitted + v_new_submitted,
        approved_qty = approved_qty - v_old_approved + v_new_approved,
        ready_now_qty = CASE
            WHEN v_old_submitted + v_old_approved > v_new_submitted + v_new_approved
                THEN 0
            ELSE LEAST(
                ready_now_qty,
                requested_qty
                    - (submitted_qty - v_old_submitted + v_new_submitted)
                    - (approved_qty - v_old_approved + v_new_approved))
        END,
        ready_by_date_qty = CASE
            WHEN v_old_submitted + v_old_approved > v_new_submitted + v_new_approved
                THEN 0
            ELSE LEAST(
                ready_by_date_qty,
                requested_qty
                    - (submitted_qty - v_old_submitted + v_new_submitted)
                    - (approved_qty - v_old_approved + v_new_approved))
        END,
        updated_at = now()
    WHERE id = NEW.analysis_item_id;

    -- Atomically exchange a pre-plan soft allocation for the immutable formal-draft
    -- claim. This keeps cross-analysis commitments at exactly one copy even if a
    -- caller inserts the link outside the primary command service.
    IF v_claim_delta > 0 THEN
        UPDATE production_material_analysis_materials
        SET required_qty = GREATEST(
                required_qty - per_product_qty * v_claim_delta, 0),
            allocated_available_qty = CASE WHEN depth = 1 THEN GREATEST(
                allocated_available_qty - per_product_qty * v_claim_delta, 0)
                ELSE LEAST(allocated_available_qty, GREATEST(
                    required_qty - per_product_qty * v_claim_delta, 0)) END,
            shortage_qty = CASE WHEN depth = 1 THEN GREATEST(
                GREATEST(required_qty - per_product_qty * v_claim_delta, 0)
                - GREATEST(allocated_available_qty
                    - per_product_qty * v_claim_delta, 0), 0)
                ELSE GREATEST(
                    GREATEST(required_qty - per_product_qty * v_claim_delta, 0)
                    - LEAST(allocated_available_qty, GREATEST(
                        required_qty - per_product_qty * v_claim_delta, 0)), 0) END,
            updated_at = now()
        WHERE analysis_id = NEW.analysis_id
          AND analysis_item_id = NEW.analysis_item_id
          AND active = TRUE;
    ELSIF v_claim_delta < 0 THEN
        -- A release/reversal invalidates the old stock snapshot. Refresh is required
        -- before the newly available demand can be planned or notified again.
        UPDATE production_material_analysis_materials
        SET allocated_available_qty = 0,
            shortage_qty = required_qty,
            updated_at = now()
        WHERE analysis_id = NEW.analysis_id
          AND analysis_item_id = NEW.analysis_item_id
          AND active = TRUE;
    END IF;

    SELECT COALESCE(SUM(requested_qty - submitted_qty - approved_qty),0),
           COALESCE(SUM(submitted_qty + approved_qty),0)
    INTO v_remaining, v_used
    FROM production_material_analysis_items
    WHERE analysis_id = NEW.analysis_id AND is_deleted = FALSE;

    UPDATE production_material_analyses
    SET status = CASE
            WHEN v_remaining = 0 THEN 'COMPLETED'
            WHEN v_used > 0 THEN 'PARTIALLY_PLANNED'
            ELSE 'ACTIVE'
        END,
        version = version + 1,
        fingerprint = encode(digest(
            fingerprint || '|PLAN-LINK|' || NEW.id::text || '|'
                || NEW.allocation_status || '|' || version::text,
            'sha256'), 'hex'),
        preview_fingerprint = NULL,
        updated_at = now()
    WHERE id = NEW.analysis_id
      AND status <> 'CANCELLED';

    NEW.updated_at := now();
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_sync_material_analysis_plan_link_qty
    BEFORE INSERT OR UPDATE OR DELETE
    ON production_material_analysis_plan_links
    FOR EACH ROW EXECUTE FUNCTION fn_sync_material_analysis_plan_link_qty();

CREATE OR REPLACE FUNCTION fn_sync_material_analysis_plan_lifecycle()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_next_status TEXT;
BEGIN
    IF NOT (
        OLD.status IS DISTINCT FROM NEW.status
        OR OLD.is_deleted IS DISTINCT FROM NEW.is_deleted
        OR OLD.is_canceled IS DISTINCT FROM NEW.is_canceled
    ) THEN
        RETURN NEW;
    END IF;

    v_next_status := CASE
        WHEN NOT NEW.is_deleted AND NOT NEW.is_canceled AND NEW.status = 1
            THEN 'APPROVED'
        WHEN NEW.status = -1
            THEN 'REVERSED'
        WHEN OLD.status = 1
            THEN 'REVERSED'
        ELSE 'RELEASED'
    END;

    UPDATE production_material_analysis_plan_links
    SET allocation_status = v_next_status
    WHERE plan_id = NEW.id
      AND allocation_status IS DISTINCT FROM v_next_status;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_sync_material_analysis_plan_lifecycle
    AFTER UPDATE OF status, is_deleted, is_canceled ON production_plans
    FOR EACH ROW EXECUTE FUNCTION fn_sync_material_analysis_plan_lifecycle();

-- =============================== permissions =================================

INSERT INTO permissions (code, name, module, category, sort_order) VALUES
    ('production_material_analysis:view',         '查看生产物料分析', '生产管理', '物料分析', 210),
    ('production_material_analysis:manage',       '新建和刷新生产物料分析', '生产管理', '物料分析', 211),
    ('production_material_analysis:route',        '确认物料供应路线', '生产管理', '物料分析', 212),
    ('production_material_analysis:notify',       '下达计划前备料任务', '生产管理', '物料分析', 213),
    ('production_material_analysis:generate',     '从物料分析生成生产计划', '生产管理', '物料分析', 214),
    ('production_material_analysis:reallocate',   '调整跨产品物料分配', '生产管理', '物料分析', 215),
    ('production_material_analysis:bom_override', '无BOM生产例外放行', '生产管理', '物料分析', 216),
    ('production_plan:approve',                   '审核生产计划', '生产管理', '生产计划', 217)
ON CONFLICT (code) DO UPDATE
SET name = EXCLUDED.name,
    module = EXCLUDED.module,
    category = EXCLUDED.category,
    sort_order = EXCLUDED.sort_order;

INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id
FROM departments d CROSS JOIN permissions p
WHERE d.code IN ('GM', 'DEPT_PROD', 'DEPT_ENG', 'DEPT_PMC', 'SUB_PLAN')
  AND d.is_deleted = FALSE
  AND p.code = 'production_material_analysis:view'
ON CONFLICT DO NOTHING;

INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id
FROM departments d CROSS JOIN permissions p
WHERE d.code IN ('GM', 'DEPT_PMC', 'SUB_PLAN')
  AND d.is_deleted = FALSE
  AND p.code IN (
      'production_material_analysis:manage',
      'production_material_analysis:route',
      'production_material_analysis:notify',
      'production_material_analysis:generate',
      'production_material_analysis:reallocate'
  )
ON CONFLICT DO NOTHING;

INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id
FROM departments d CROSS JOIN permissions p
WHERE d.code IN ('GM', 'SUB_PLAN')
  AND d.is_deleted = FALSE
  AND p.code = 'production_plan:approve'
ON CONFLICT DO NOTHING;

-- ================================ audit ======================================

CREATE TRIGGER trg_audit_production_material_analyses
    AFTER INSERT OR UPDATE OR DELETE ON production_material_analyses
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_production_material_analysis_items
    AFTER INSERT OR UPDATE OR DELETE ON production_material_analysis_items
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_production_material_analysis_materials
    AFTER INSERT OR UPDATE OR DELETE ON production_material_analysis_materials
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_preplan_supply_actions
    AFTER INSERT OR UPDATE OR DELETE ON preplan_supply_actions
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_preplan_supply_action_allocations
    AFTER INSERT OR UPDATE OR DELETE ON preplan_supply_action_allocations
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_production_material_analysis_commands
    AFTER INSERT OR UPDATE OR DELETE ON production_material_analysis_commands
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_production_material_analysis_plan_links
    AFTER INSERT OR UPDATE OR DELETE ON production_material_analysis_plan_links
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
