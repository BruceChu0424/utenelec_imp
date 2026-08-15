-- Production daily-report relations are UUID authoritative.
-- plan_no / sales_order_no / source_doc_no remain historical/display snapshots;
-- no historical row is guessed or backfilled from those mutable numbers.

ALTER TABLE production_daily_report_items
    ADD CONSTRAINT fk_pdri_plan_item
    FOREIGN KEY (plan_item_id) REFERENCES production_plan_items(id)
    ON DELETE RESTRICT NOT VALID;

ALTER TABLE production_daily_report_items
    ADD CONSTRAINT fk_pdri_sales_order_item
    FOREIGN KEY (sales_order_item_id) REFERENCES sales_order_items(id)
    ON DELETE RESTRICT NOT VALID;

ALTER TABLE production_daily_report_items
    VALIDATE CONSTRAINT fk_pdri_plan_item;

ALTER TABLE production_daily_report_items
    VALIDATE CONSTRAINT fk_pdri_sales_order_item;

-- Existing imported/old online rows remain historical evidence. PostgreSQL
-- still enforces this NOT VALID constraint for every new or updated row.
ALTER TABLE production_daily_report_items
    ADD CONSTRAINT ck_pdri_number_snapshots_require_uuid
    CHECK (
        (NULLIF(BTRIM(plan_no), '') IS NULL OR plan_item_id IS NOT NULL)
        AND (
            NULLIF(BTRIM(sales_order_no), '') IS NULL
            OR sales_order_item_id IS NOT NULL
        )
    ) NOT VALID;

COMMENT ON COLUMN production_daily_report_items.plan_item_id IS
    'Authoritative production-plan-line UUID; plan_no is a creation-time snapshot only.';
COMMENT ON COLUMN production_daily_report_items.sales_order_item_id IS
    'Authoritative sales-order-line UUID; sales_order_no is a creation-time snapshot only.';
COMMENT ON COLUMN production_daily_report_items.plan_no IS
    'Plan-number snapshot only; never resolve identity, authorization or writeback from this value.';
COMMENT ON COLUMN production_daily_report_items.sales_order_no IS
    'Sales-order-number snapshot only; never resolve identity, authorization or writeback from this value.';

-- V272 had to discover the three pre-existing system roots from their
-- migration sentinel. Register the discovered UUIDs once, then make every
-- online assignment and mutation guard use only these UUID relations.
--
-- The goods/material orphan root predates V272.  V258 froze its former
-- LEGACY_ORPHAN code in legacy_code_snapshot.  Seed it only on databases that
-- have never run the explicit legacy import; discovery below remains exact and
-- migration-only, and runtime code receives only the registered UUID.
INSERT INTO material_categories (
    id,
    legacy_id,
    code,
    name,
    parent_id,
    level,
    sort_order,
    path,
    is_deleted,
    remark,
    legacy_code_snapshot,
    code_prefix,
    version
)
SELECT
    '27500000-0000-4000-8000-000000000002'::uuid,
    -1,
    'LEGACY_ORPHAN',
    '未分类（历史孤儿）',
    NULL,
    0,
    2147483647,
    '/LEGACY_ORPHAN/',
    FALSE,
    'LEGACY_ORPHAN',
    'LEGACY_ORPHAN',
    NULL,
    0
WHERE NOT EXISTS (
    SELECT 1
    FROM material_categories category
    WHERE category.legacy_id = -1
      AND category.legacy_code_snapshot = 'LEGACY_ORPHAN'
);

DO $$
BEGIN
    IF (
        SELECT COUNT(*)
        FROM material_categories category
        WHERE category.legacy_id = -1
          AND category.legacy_code_snapshot = 'LEGACY_ORPHAN'
          AND category.name = '未分类（历史孤儿）'
          AND category.parent_id IS NULL
          AND category.level = 0
          AND category.code_prefix IS NULL
          AND category.is_deleted = FALSE
          AND category.deleted_at IS NULL
    ) <> 1 THEN
        RAISE EXCEPTION
            'V275 requires exactly one valid LEGACY_ORPHAN material category root';
    END IF;
END;
$$;

CREATE TABLE system_master_category_registry (
    id                   UUID PRIMARY KEY,
    material_category_id UUID NOT NULL UNIQUE,
    client_category_id   UUID NOT NULL UNIQUE,
    mould_category_id    UUID NOT NULL UNIQUE,
    supplier_category_id UUID NOT NULL UNIQUE,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by           UUID,
    updated_by           UUID,
    CONSTRAINT ck_system_master_category_registry_singleton
        CHECK (id = '27500000-0000-4000-8000-000000000001'::uuid),
    CONSTRAINT fk_system_master_category_material
        FOREIGN KEY (material_category_id) REFERENCES material_categories(id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_system_master_category_client
        FOREIGN KEY (client_category_id) REFERENCES client_categories(id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_system_master_category_mould
        FOREIGN KEY (mould_category_id) REFERENCES mould_categories(id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_system_master_category_supplier
        FOREIGN KEY (supplier_category_id) REFERENCES supplier_categories(id)
        ON DELETE RESTRICT
);

INSERT INTO system_master_category_registry (
    id,
    material_category_id,
    client_category_id,
    mould_category_id,
    supplier_category_id
)
SELECT
    '27500000-0000-4000-8000-000000000001'::uuid,
    material.id,
    client.id,
    mould.id,
    supplier.id
FROM material_categories material
CROSS JOIN client_categories client
CROSS JOIN mould_categories mould
CROSS JOIN supplier_categories supplier
WHERE material.legacy_id = -1
  AND material.legacy_code_snapshot = 'LEGACY_ORPHAN'
  AND client.legacy_id = -1
  AND mould.legacy_id = -1
  AND supplier.legacy_id = -1;

DO $$
BEGIN
    IF (SELECT COUNT(*) FROM system_master_category_registry) <> 1 THEN
        RAISE EXCEPTION
            'V275 requires exactly one V272 system category UUID registry row';
    END IF;
END;
$$;

CREATE TRIGGER trg_audit_system_master_category_registry
    AFTER INSERT OR UPDATE OR DELETE ON system_master_category_registry
    FOR EACH ROW EXECUTE FUNCTION fn_audit();

CREATE OR REPLACE FUNCTION fn_protect_system_master_category_registry()
RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION
        'system master category UUID registry is immutable';
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_protect_system_master_category_registry
    BEFORE UPDATE OR DELETE ON system_master_category_registry
    FOR EACH ROW EXECUTE FUNCTION fn_protect_system_master_category_registry();

CREATE OR REPLACE FUNCTION fn_assign_uncategorized_master_category()
RETURNS TRIGGER AS $$
DECLARE
    v_category_id UUID;
BEGIN
    IF NEW.category_id IS NULL THEN
        SELECT CASE TG_ARGV[0]
                   WHEN 'material_categories' THEN registry.material_category_id
                   WHEN 'client_categories' THEN registry.client_category_id
                   WHEN 'mould_categories' THEN registry.mould_category_id
                   WHEN 'supplier_categories' THEN registry.supplier_category_id
               END
        INTO v_category_id
        FROM system_master_category_registry registry
        WHERE registry.id = '27500000-0000-4000-8000-000000000001'::uuid;

        IF v_category_id IS NULL THEN
            RAISE EXCEPTION
                'system uncategorized category UUID missing for %', TG_ARGV[0];
        END IF;
        NEW.category_id := v_category_id;
    ELSIF NEW.is_deleted = FALSE THEN
        EXECUTE format(
            'SELECT id FROM %I WHERE id = $1 AND is_deleted = false', TG_ARGV[0])
        INTO v_category_id USING NEW.category_id;
        IF v_category_id IS NULL THEN
            RAISE EXCEPTION 'active master requires an active category';
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

ALTER TABLE client_categories
    DROP CONSTRAINT IF EXISTS client_categories_system_uncategorized_chk;
ALTER TABLE mould_categories
    DROP CONSTRAINT IF EXISTS mould_categories_system_uncategorized_chk;
ALTER TABLE supplier_categories
    DROP CONSTRAINT IF EXISTS supplier_categories_system_uncategorized_chk;

CREATE OR REPLACE FUNCTION fn_protect_uncategorized_master_category()
RETURNS TRIGGER AS $$
DECLARE
    v_protected_id UUID;
BEGIN
    SELECT CASE TG_TABLE_NAME
               WHEN 'material_categories' THEN registry.material_category_id
               WHEN 'client_categories' THEN registry.client_category_id
               WHEN 'mould_categories' THEN registry.mould_category_id
               WHEN 'supplier_categories' THEN registry.supplier_category_id
           END
    INTO v_protected_id
    FROM system_master_category_registry registry
    WHERE registry.id = '27500000-0000-4000-8000-000000000001'::uuid;

    IF v_protected_id IS NULL THEN
        RAISE EXCEPTION
            'system uncategorized category UUID missing for %', TG_TABLE_NAME;
    END IF;
    IF OLD.id = v_protected_id THEN
        IF TG_OP = 'DELETE' THEN
            RAISE EXCEPTION 'system uncategorized category cannot be deleted';
        END IF;
        IF NEW.id IS DISTINCT FROM v_protected_id
           OR NEW.legacy_id IS DISTINCT FROM OLD.legacy_id
           OR NEW.code IS DISTINCT FROM (CASE
                  WHEN TG_TABLE_NAME = 'material_categories' THEN OLD.code
                  ELSE TG_ARGV[0]
              END)
           OR NEW.name IS DISTINCT FROM (CASE
                  WHEN TG_TABLE_NAME = 'material_categories'
                      THEN '未分类（历史孤儿）'
                  ELSE '未分类'
              END)
           OR (
               TG_TABLE_NAME = 'material_categories'
               AND (
                   NEW.legacy_code_snapshot IS DISTINCT FROM 'LEGACY_ORPHAN'
                   OR NEW.remark IS DISTINCT FROM OLD.remark
               )
           )
           OR NEW.parent_id IS NOT NULL
           OR NEW.level IS DISTINCT FROM 0
           OR NEW.code_prefix IS NOT NULL
           OR NEW.is_deleted IS DISTINCT FROM FALSE
           OR NEW.deleted_at IS NOT NULL THEN
            RAISE EXCEPTION 'system uncategorized category is immutable';
        END IF;
    END IF;
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_material_categories_protect_uncategorized
    BEFORE UPDATE OR DELETE ON material_categories
    FOR EACH ROW EXECUTE FUNCTION fn_protect_uncategorized_master_category('LEGACY_ORPHAN');

COMMENT ON TABLE system_master_category_registry IS
    'Fixed UUID registry for the protected material/client/mould/supplier uncategorized roots.';
COMMENT ON COLUMN system_master_category_registry.material_category_id IS
    'Authoritative UUID of the protected goods/material historical-orphan root.';
COMMENT ON COLUMN system_master_category_registry.client_category_id IS
    'Authoritative UUID of the protected client uncategorized root.';
COMMENT ON COLUMN system_master_category_registry.mould_category_id IS
    'Authoritative UUID of the protected mould uncategorized root.';
COMMENT ON COLUMN system_master_category_registry.supplier_category_id IS
    'Authoritative UUID of the protected supplier uncategorized root.';
COMMENT ON COLUMN clients.category_id IS
    'Authoritative client-category UUID; raw missing values bind through system_master_category_registry.';
COMMENT ON COLUMN moulds.category_id IS
    'Authoritative mould-category UUID; raw missing values bind through system_master_category_registry.';
COMMENT ON COLUMN suppliers.category_id IS
    'Authoritative supplier-category UUID; raw missing values bind through system_master_category_registry.';

-- Authorized stock-balance adjustments used to overload source_doc_no with a
-- private marker plus a retry key.  That mutable display column then decided
-- idempotency, edit/delete protection and approval/reversal authorization.
-- Preserve the old text as evidence, but move the command identity and its
-- stock-document relation into a UUID-keyed table.
CREATE TABLE stock_balance_adjustment_requests (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    request_key       VARCHAR(128) NOT NULL,
    stock_document_id UUID NOT NULL,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by        UUID,
    updated_by        UUID,
    CONSTRAINT uq_stock_balance_adjustment_request_key
        UNIQUE (request_key),
    CONSTRAINT uq_stock_balance_adjustment_request_document
        UNIQUE (stock_document_id),
    CONSTRAINT fk_stock_balance_adjustment_request_document
        FOREIGN KEY (stock_document_id) REFERENCES stock_documents(id)
        ON DELETE RESTRICT,
    CONSTRAINT ck_stock_balance_adjustment_request_key
        CHECK (
            request_key = BTRIM(request_key)
            AND CHAR_LENGTH(request_key) BETWEEN 8 AND 128
            AND request_key ~ '^[A-Za-z0-9._:-]+$'
        )
);

-- This is a deterministic migration of the service-owned marker, not a
-- bill-number lookup.  V167 already guarantees uniqueness of the full marker
-- for every active document, so any conflict must stop migration for review.
INSERT INTO stock_balance_adjustment_requests (
    id,
    request_key,
    stock_document_id,
    created_at,
    updated_at,
    created_by,
    updated_by
)
SELECT
    gen_random_uuid(),
    SUBSTRING(
        document.source_doc_no
        FROM CHAR_LENGTH('AUTHORIZED_BALANCE_ADJUSTMENT:') + 1
    ),
    document.id,
    COALESCE(document.created_at, now()),
    COALESCE(document.updated_at, document.created_at, now()),
    document.created_by,
    document.updated_by
FROM stock_documents document
WHERE document.is_deleted = FALSE
  AND document.source_doc_no LIKE 'AUTHORIZED_BALANCE_ADJUSTMENT:%'
  AND CHAR_LENGTH(
        SUBSTRING(
            document.source_doc_no
            FROM CHAR_LENGTH('AUTHORIZED_BALANCE_ADJUSTMENT:') + 1
        )
      ) BETWEEN 8 AND 128
  AND SUBSTRING(
        document.source_doc_no
        FROM CHAR_LENGTH('AUTHORIZED_BALANCE_ADJUSTMENT:') + 1
      ) ~ '^[A-Za-z0-9._:-]+$';

DO $$
DECLARE
    v_marked_documents BIGINT;
    v_registered_documents BIGINT;
BEGIN
    SELECT COUNT(*)
    INTO v_marked_documents
    FROM stock_documents document
    WHERE document.is_deleted = FALSE
      AND document.source_doc_no LIKE 'AUTHORIZED_BALANCE_ADJUSTMENT:%';

    SELECT COUNT(*)
    INTO v_registered_documents
    FROM stock_balance_adjustment_requests;

    IF v_registered_documents <> v_marked_documents THEN
        RAISE EXCEPTION
            'V275 found % authorized adjustment markers but registered %; invalid or duplicate retry keys require review',
            v_marked_documents,
            v_registered_documents;
    END IF;
END;
$$;

DROP INDEX IF EXISTS ux_stock_documents_authorized_balance_adjustment_source;

CREATE TRIGGER trg_audit_stock_balance_adjustment_requests
    AFTER INSERT OR UPDATE OR DELETE ON stock_balance_adjustment_requests
    FOR EACH ROW EXECUTE FUNCTION fn_audit();

COMMENT ON TABLE stock_balance_adjustment_requests IS
    'UUID command identity for privileged stock-balance adjustments; request_key is retry metadata and stock_document_id is the authoritative relation.';
COMMENT ON COLUMN stock_balance_adjustment_requests.request_key IS
    'Opaque retry key only; never use it as a document relation or authorization marker.';
COMMENT ON COLUMN stock_balance_adjustment_requests.stock_document_id IS
    'Authoritative UUID relation to the generated CHECK stock document.';
COMMENT ON COLUMN stock_documents.source_doc_no IS
    'Historical/display source-number snapshot only; never use for identity, idempotency, authorization or deletion policy.';
