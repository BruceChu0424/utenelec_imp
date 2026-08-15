-- V279: global business identifier and prefix authority.
--
-- UUID remains the relational identity. Human-readable document numbers and
-- master codes are audited display labels that may change, while every old
-- normalized value and prefix token ever used is reserved for life. Historical conflicts are
-- retained as evidence; only future ownership is rejected.

CREATE TABLE business_identifier_namespaces (
    namespace_key      TEXT PRIMARY KEY,
    id                 UUID NOT NULL DEFAULT gen_random_uuid() UNIQUE,
    identifier_family  TEXT NOT NULL,
    fixed_prefix       TEXT NOT NULL,
    source_table       TEXT NOT NULL,
    identifier_column  TEXT NOT NULL,
    discriminator_value TEXT,
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT business_identifier_namespaces_key_chk
        CHECK (namespace_key ~ '^[A-Z][A-Z0-9_]*$'),
    CONSTRAINT business_identifier_namespaces_family_chk
        CHECK (identifier_family IN ('DOCUMENT', 'MASTER', 'SYSTEM')),
    CONSTRAINT business_identifier_namespaces_prefix_chk
        CHECK (fixed_prefix = upper(btrim(fixed_prefix))
               AND fixed_prefix ~ '^[A-Z][A-Z0-9]{0,7}$'),
    CONSTRAINT business_identifier_namespaces_source_chk
        CHECK (source_table ~ '^[a-z][a-z0-9_]*$'
               AND identifier_column ~ '^[a-z][a-z0-9_]*$')
);

CREATE TABLE business_document_sequences (
    namespace_key TEXT NOT NULL
        REFERENCES business_identifier_namespaces(namespace_key) ON DELETE RESTRICT,
    sequence_date DATE NOT NULL,
    last_seq      BIGINT NOT NULL,
    CONSTRAINT business_document_sequences_pk
        PRIMARY KEY (namespace_key, sequence_date),
    CONSTRAINT business_document_sequences_range_chk
        CHECK (last_seq BETWEEN 1 AND 999999)
);

CREATE TABLE production_product_no_sequences (
    plan_id  UUID PRIMARY KEY
        REFERENCES production_plans(id) ON DELETE CASCADE,
    last_seq BIGINT NOT NULL,
    CONSTRAINT production_product_no_sequences_range_chk
        CHECK (last_seq BETWEEN 1 AND 999999)
);

-- A source column may legitimately host several prefix-routed namespaces
-- (production_plans uses the non-null route markers PREFIX:SJ and PREFIX:SZ).
-- A default route is singular, while discriminator/prefix routes are singular
-- per source value.
CREATE UNIQUE INDEX business_identifier_namespaces_source_default_uq
    ON business_identifier_namespaces(source_table, identifier_column)
    WHERE discriminator_value IS NULL;
CREATE UNIQUE INDEX business_identifier_namespaces_source_discriminator_uq
    ON business_identifier_namespaces(
        source_table, identifier_column, discriminator_value)
    WHERE discriminator_value IS NOT NULL;

CREATE TABLE business_prefix_reservations (
    normalized_prefix    TEXT PRIMARY KEY,
    id                   UUID NOT NULL DEFAULT gen_random_uuid() UNIQUE,
    first_prefix_snapshot TEXT NOT NULL,
    first_owner_kind     TEXT NOT NULL,
    first_owner_key      TEXT NOT NULL,
    reserved_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT business_prefix_reservations_normalized_chk
        CHECK (normalized_prefix = upper(btrim(normalized_prefix))
               AND normalized_prefix <> '')
);

CREATE TABLE business_prefix_reservation_members (
    id                UUID NOT NULL DEFAULT gen_random_uuid() UNIQUE,
    normalized_prefix TEXT NOT NULL
        REFERENCES business_prefix_reservations(normalized_prefix) ON DELETE RESTRICT,
    owner_kind        TEXT NOT NULL,
    owner_key         TEXT NOT NULL,
    entity_id         UUID,
    legacy_identity   TEXT,
    prefix_snapshot   TEXT NOT NULL,
    member_kind       TEXT NOT NULL,
    acquired_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT business_prefix_reservation_members_pk
        PRIMARY KEY (normalized_prefix, owner_kind, owner_key),
    CONSTRAINT business_prefix_reservation_members_kind_chk
        CHECK (member_kind IN ('FIXED', 'CATEGORY', 'HISTORICAL'))
);

CREATE INDEX business_prefix_reservation_members_entity_idx
    ON business_prefix_reservation_members(owner_kind, entity_id)
    WHERE entity_id IS NOT NULL;
CREATE INDEX business_prefix_reservation_members_legacy_idx
    ON business_prefix_reservation_members(owner_kind, legacy_identity)
    WHERE legacy_identity IS NOT NULL;

CREATE TABLE business_identifier_reservations (
    normalized_identifier     TEXT PRIMARY KEY,
    id                        UUID NOT NULL DEFAULT gen_random_uuid() UNIQUE,
    first_identifier_snapshot TEXT NOT NULL,
    first_owner_domain        TEXT NOT NULL,
    first_entity_id           UUID NOT NULL,
    first_legacy_identity     TEXT,
    reserved_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT business_identifier_reservations_normalized_chk
        CHECK (normalized_identifier = upper(btrim(normalized_identifier))
               AND normalized_identifier <> '')
);

CREATE TABLE business_identifier_reservation_members (
    id                    UUID NOT NULL DEFAULT gen_random_uuid() UNIQUE,
    normalized_identifier TEXT NOT NULL
        REFERENCES business_identifier_reservations(normalized_identifier)
        ON DELETE RESTRICT,
    owner_domain          TEXT NOT NULL,
    entity_id             UUID NOT NULL,
    legacy_identity       TEXT,
    identifier_snapshot   TEXT NOT NULL,
    source_table          TEXT NOT NULL,
    acquired_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT business_identifier_reservation_members_pk
        PRIMARY KEY (normalized_identifier, owner_domain, entity_id)
);

CREATE INDEX business_identifier_reservation_members_entity_idx
    ON business_identifier_reservation_members(owner_domain, entity_id);
CREATE INDEX business_identifier_reservation_members_legacy_idx
    ON business_identifier_reservation_members(owner_domain, legacy_identity)
    WHERE legacy_identity IS NOT NULL;

CREATE TABLE business_identifier_conflicts (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    conflict_kind    TEXT NOT NULL,
    normalized_value TEXT,
    owner_kind       TEXT,
    owner_key        TEXT,
    source_table     TEXT,
    entity_id        UUID,
    legacy_identity  TEXT,
    evidence         JSONB NOT NULL DEFAULT '{}'::JSONB,
    detected_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT business_identifier_conflicts_kind_chk
        CHECK (conflict_kind IN (
            'IDENTIFIER_DUPLICATE', 'PREFIX_DUPLICATE', 'FORMAT_ANOMALY'))
);

-- Document namespaces use DocNumberPrefix.name() as their immutable key.
INSERT INTO business_identifier_namespaces (
    namespace_key, identifier_family, fixed_prefix,
    source_table, identifier_column, discriminator_value)
VALUES
    ('SALES_ORDER',             'DOCUMENT', 'XD', 'sales_orders',                   'bill_no', NULL),
    ('SALES_SHIPMENT',          'DOCUMENT', 'XC', 'sales_shipments',                'bill_no', NULL),
    ('SALES_OTHER_SHIPMENT',    'DOCUMENT', 'OC', 'sales_other_shipments',          'bill_no', NULL),
    ('SALES_RETURN',            'DOCUMENT', 'XT', 'sales_returns',                  'bill_no', NULL),
    ('SALES_QUOTE',             'DOCUMENT', 'XB', 'sales_quotes',                   'bill_no', NULL),
    ('PURCHASE_REQUEST',        'DOCUMENT', 'CS', 'purchase_requests',              'bill_no', NULL),
    ('PURCHASE_ORDER',          'DOCUMENT', 'CD', 'purchase_orders',                'bill_no', NULL),
    ('PURCHASE_RECEIPT',        'DOCUMENT', 'CJ', 'purchase_receipts',              'bill_no', NULL),
    ('PURCHASE_RETURN',         'DOCUMENT', 'CT', 'purchase_returns',               'bill_no', NULL),
    ('STOCK_TRANSFER',          'DOCUMENT', 'CB', 'stock_documents',                'bill_no', 'TRANSFER'),
    ('STOCK_OTHER_IN',          'DOCUMENT', 'QR', 'stock_documents',                'bill_no', 'OTHER_IN'),
    ('STOCK_OTHER_OUT',         'DOCUMENT', 'QC', 'stock_documents',                'bill_no', 'OTHER_OUT'),
    ('STOCK_DRAW',              'DOCUMENT', 'SL', 'stock_documents',                'bill_no', 'DRAW'),
    ('STOCK_WDRAW',             'DOCUMENT', 'ST', 'stock_documents',                'bill_no', 'WDRAW'),
    ('STOCK_FINISHED_OUT',      'DOCUMENT', 'CC', 'stock_documents',                'bill_no', 'FINISHED_OUT'),
    ('STOCK_FINISHED_IN',       'DOCUMENT', 'CR', 'stock_documents',                'bill_no', 'FINISHED_IN'),
    ('STOCK_CHECK',             'DOCUMENT', 'PQ', 'stock_documents',                'bill_no', 'CHECK'),
    ('STOCK_WASTE',             'DOCUMENT', 'QW', 'stock_documents',                'bill_no', 'WASTE'),
    ('SUB_INQUIRY',             'DOCUMENT', 'EA', 'subcontract_inquiries',           'bill_no', NULL),
    ('SUB_APPLICATION',         'DOCUMENT', 'EB', 'subcontract_applications',        'bill_no', NULL),
    ('SUB_ORDER',               'DOCUMENT', 'EO', 'subcontract_orders',              'bill_no', NULL),
    ('SUB_MATERIAL_ISSUE',      'DOCUMENT', 'EC', 'subcontract_material_issues',     'bill_no', NULL),
    ('SUB_RECEIPT',             'DOCUMENT', 'EJ', 'subcontract_receipts',            'bill_no', NULL),
    ('SUB_RETURN',              'DOCUMENT', 'ET', 'subcontract_returns',             'bill_no', NULL),
    ('SUB_MATERIAL_RETURN',     'DOCUMENT', 'ER', 'subcontract_material_returns',    'bill_no', NULL),
    ('SUB_WASTE',               'DOCUMENT', 'EW', 'subcontract_wastes',              'bill_no', NULL),
    ('FIN_RECEIPT',             'DOCUMENT', 'XS', 'finance_receipts',                'bill_no', NULL),
    ('FIN_PAYMENT',             'DOCUMENT', 'CF', 'finance_payments',                'bill_no', NULL),
    ('FIN_EXPENSE',             'DOCUMENT', 'YF', 'finance_expenses',                'bill_no', NULL),
    ('FIN_OTHER_INCOME',        'DOCUMENT', 'QS', 'finance_other_incomes',           'bill_no', NULL),
    ('FIN_BANK_TRANSFER',       'DOCUMENT', 'YC', 'finance_bank_transfers',          'bill_no', NULL),
    ('FIXED_ASSET',             'DOCUMENT', 'FA', 'fixed_assets',                    'code',    NULL),
    ('DEFERRED_EXPENSE',        'DOCUMENT', 'DA', 'deferred_expenses',               'code',    NULL),
    ('PRODUCTION_PLAN',         'DOCUMENT', 'SJ', 'production_plans',                'bill_no', 'PREFIX:SJ'),
    ('PRODUCTION_SUBPLAN',      'DOCUMENT', 'SZ', 'production_plans',                'bill_no', 'PREFIX:SZ'),
    ('PRODUCTION_DAILY_REPORT', 'DOCUMENT', 'SR', 'production_daily_reports',        'bill_no', NULL),
    ('RD_TASK',                 'DOCUMENT', 'RD', 'rd_tasks',                        'task_no', NULL),
    ('VISITOR_ACCOUNT',         'SYSTEM',   'V',  'visitor_accounts',                'visitor_no', NULL),
    ('PRODUCTION_EXECUTION_SEGMENT', 'SYSTEM', 'ZX', 'production_execution_segments', 'segment_code', NULL),
    -- MasterCodePrefix defaults. Category-specific overrides are registered below.
    ('MASTER_GOODS',            'MASTER', 'HP', 'goods',                'code', NULL),
    ('MASTER_MOULD',            'MASTER', 'MJ', 'moulds',               'code', NULL),
    ('MASTER_CLIENT',           'MASTER', 'KH', 'clients',              'code', NULL),
    ('MASTER_SUPPLIER',         'MASTER', 'GY', 'suppliers',            'code', NULL),
    ('MASTER_COLOR',            'MASTER', 'YS', 'colors',               'code', NULL),
    ('MASTER_UNIT',             'MASTER', 'DW', 'units',                'code', NULL),
    ('MASTER_CURRENCY',         'MASTER', 'BZ', 'currencies',           'code', NULL),
    ('MASTER_WAREHOUSE',        'MASTER', 'WH', 'warehouses',           'code', NULL),
    ('MASTER_ACCOUNT',          'MASTER', 'ZH', 'accounts',             'code', NULL),
    ('MASTER_PAYMENT_STYLE',    'MASTER', 'SK', 'payment_styles',       'code', NULL),
    ('MASTER_CATEGORY',         'MASTER', 'FL', 'material_categories',  'code', NULL),
    ('MASTER_MOULD_CATEGORY',   'MASTER', 'MF', 'mould_categories',     'code', NULL),
    ('MASTER_CLIENT_CATEGORY',  'MASTER', 'KF', 'client_categories',    'code', NULL),
    ('MASTER_SUPPLIER_CATEGORY','MASTER', 'GF', 'supplier_categories',  'code', NULL),
    ('MASTER_EMPLOYEE',         'MASTER', 'UT', 'employees',            'code', NULL),
    ('MASTER_POSITION',         'MASTER', 'ZW', 'positions',            'code', NULL);

-- Fixed namespace prefixes are globally reserved. Exact token equality is the
-- only conflict rule: V and V6 may coexist, while V and v cannot.
INSERT INTO business_prefix_reservations (
    normalized_prefix, first_prefix_snapshot, first_owner_kind, first_owner_key)
SELECT DISTINCT ON (upper(btrim(fixed_prefix)))
       upper(btrim(fixed_prefix)), fixed_prefix, 'NAMESPACE', namespace_key
FROM business_identifier_namespaces
ORDER BY upper(btrim(fixed_prefix)),
         CASE identifier_family WHEN 'DOCUMENT' THEN 0 WHEN 'SYSTEM' THEN 1 ELSE 2 END,
         namespace_key;

INSERT INTO business_prefix_reservation_members (
    normalized_prefix, owner_kind, owner_key, prefix_snapshot, member_kind)
SELECT upper(btrim(fixed_prefix)), 'NAMESPACE', namespace_key,
       fixed_prefix, 'FIXED'
FROM business_identifier_namespaces;

-- Preserve every explicit category prefix, including soft-deleted categories.
CREATE TEMP TABLE tmp_business_category_prefix_seed ON COMMIT DROP AS
SELECT 'material_categories'::TEXT source_table, id entity_id,
       legacy_id::TEXT legacy_identity, code_prefix prefix_snapshot,
       upper(btrim(code_prefix)) normalized_prefix
FROM material_categories WHERE NULLIF(btrim(code_prefix), '') IS NOT NULL
UNION ALL
SELECT 'mould_categories', id, legacy_id::TEXT, code_prefix, upper(btrim(code_prefix))
FROM mould_categories WHERE NULLIF(btrim(code_prefix), '') IS NOT NULL
UNION ALL
SELECT 'client_categories', id, legacy_id::TEXT, code_prefix, upper(btrim(code_prefix))
FROM client_categories WHERE NULLIF(btrim(code_prefix), '') IS NOT NULL
UNION ALL
SELECT 'supplier_categories', id, legacy_id::TEXT, code_prefix, upper(btrim(code_prefix))
FROM supplier_categories WHERE NULLIF(btrim(code_prefix), '') IS NOT NULL;

INSERT INTO business_prefix_reservations (
    normalized_prefix, first_prefix_snapshot, first_owner_kind, first_owner_key)
SELECT DISTINCT ON (normalized_prefix)
       normalized_prefix, prefix_snapshot, 'CATEGORY', source_table || '/' || entity_id::TEXT
FROM tmp_business_category_prefix_seed
ORDER BY normalized_prefix, source_table, entity_id
ON CONFLICT DO NOTHING;

INSERT INTO business_prefix_reservation_members (
    normalized_prefix, owner_kind, owner_key, entity_id, legacy_identity,
    prefix_snapshot, member_kind)
SELECT normalized_prefix, 'CATEGORY', source_table || '/' || entity_id::TEXT,
       entity_id, legacy_identity, prefix_snapshot, 'CATEGORY'
FROM tmp_business_category_prefix_seed
ON CONFLICT DO NOTHING;

-- Snapshot every authoritative header. Detail copies, AR/AP projections, GL
-- vouchers and external reference numbers are intentionally excluded.
CREATE TEMP TABLE tmp_business_header_identifier_seed ON COMMIT DROP AS
SELECT 'SALES_ORDER'::TEXT owner_domain, 'sales_orders'::TEXT source_table,
       id entity_id, legacy_id::TEXT legacy_identity, bill_no identifier_snapshot,
       upper(btrim(bill_no)) normalized_identifier
FROM sales_orders WHERE NULLIF(btrim(bill_no), '') IS NOT NULL
UNION ALL SELECT 'SALES_SHIPMENT', 'sales_shipments', id, legacy_id::TEXT, bill_no, upper(btrim(bill_no))
FROM sales_shipments WHERE NULLIF(btrim(bill_no), '') IS NOT NULL
UNION ALL SELECT 'SALES_OTHER_SHIPMENT', 'sales_other_shipments', id, legacy_id::TEXT, bill_no, upper(btrim(bill_no))
FROM sales_other_shipments WHERE NULLIF(btrim(bill_no), '') IS NOT NULL
UNION ALL SELECT 'SALES_RETURN', 'sales_returns', id, legacy_id::TEXT, bill_no, upper(btrim(bill_no))
FROM sales_returns WHERE NULLIF(btrim(bill_no), '') IS NOT NULL
UNION ALL SELECT 'SALES_QUOTE', 'sales_quotes', id, legacy_id::TEXT, bill_no, upper(btrim(bill_no))
FROM sales_quotes WHERE NULLIF(btrim(bill_no), '') IS NOT NULL
UNION ALL SELECT 'PURCHASE_REQUEST', 'purchase_requests', id, legacy_id::TEXT, bill_no, upper(btrim(bill_no))
FROM purchase_requests WHERE NULLIF(btrim(bill_no), '') IS NOT NULL
UNION ALL SELECT 'PURCHASE_ORDER', 'purchase_orders', id, legacy_id::TEXT, bill_no, upper(btrim(bill_no))
FROM purchase_orders WHERE NULLIF(btrim(bill_no), '') IS NOT NULL
UNION ALL SELECT 'PURCHASE_RECEIPT', 'purchase_receipts', id, legacy_id::TEXT, bill_no, upper(btrim(bill_no))
FROM purchase_receipts WHERE NULLIF(btrim(bill_no), '') IS NOT NULL
UNION ALL SELECT 'PURCHASE_RETURN', 'purchase_returns', id, legacy_id::TEXT, bill_no, upper(btrim(bill_no))
FROM purchase_returns WHERE NULLIF(btrim(bill_no), '') IS NOT NULL
UNION ALL
SELECT CASE doc_type
           WHEN 'TRANSFER' THEN 'STOCK_TRANSFER'
           WHEN 'OTHER_IN' THEN 'STOCK_OTHER_IN'
           WHEN 'OTHER_OUT' THEN 'STOCK_OTHER_OUT'
           WHEN 'DRAW' THEN 'STOCK_DRAW'
           WHEN 'WDRAW' THEN 'STOCK_WDRAW'
           WHEN 'FINISHED_OUT' THEN 'STOCK_FINISHED_OUT'
           WHEN 'FINISHED_IN' THEN 'STOCK_FINISHED_IN'
           WHEN 'CHECK' THEN 'STOCK_CHECK'
           WHEN 'WASTE' THEN 'STOCK_WASTE'
           ELSE 'STOCK_UNKNOWN/' || COALESCE(doc_type, '<NULL>')
       END,
       'stock_documents', id, legacy_id::TEXT, bill_no, upper(btrim(bill_no))
FROM stock_documents WHERE NULLIF(btrim(bill_no), '') IS NOT NULL
UNION ALL SELECT 'SUB_INQUIRY', 'subcontract_inquiries', id, legacy_id::TEXT, bill_no, upper(btrim(bill_no))
FROM subcontract_inquiries WHERE NULLIF(btrim(bill_no), '') IS NOT NULL
UNION ALL SELECT 'SUB_APPLICATION', 'subcontract_applications', id, legacy_id::TEXT, bill_no, upper(btrim(bill_no))
FROM subcontract_applications WHERE NULLIF(btrim(bill_no), '') IS NOT NULL
UNION ALL SELECT 'SUB_ORDER', 'subcontract_orders', id, legacy_id::TEXT, bill_no, upper(btrim(bill_no))
FROM subcontract_orders WHERE NULLIF(btrim(bill_no), '') IS NOT NULL
UNION ALL SELECT 'SUB_MATERIAL_ISSUE', 'subcontract_material_issues', id, legacy_id::TEXT, bill_no, upper(btrim(bill_no))
FROM subcontract_material_issues WHERE NULLIF(btrim(bill_no), '') IS NOT NULL
UNION ALL SELECT 'SUB_RECEIPT', 'subcontract_receipts', id, legacy_id::TEXT, bill_no, upper(btrim(bill_no))
FROM subcontract_receipts WHERE NULLIF(btrim(bill_no), '') IS NOT NULL
UNION ALL SELECT 'SUB_RETURN', 'subcontract_returns', id, legacy_id::TEXT, bill_no, upper(btrim(bill_no))
FROM subcontract_returns WHERE NULLIF(btrim(bill_no), '') IS NOT NULL
UNION ALL SELECT 'SUB_MATERIAL_RETURN', 'subcontract_material_returns', id, legacy_id::TEXT, bill_no, upper(btrim(bill_no))
FROM subcontract_material_returns WHERE NULLIF(btrim(bill_no), '') IS NOT NULL
UNION ALL SELECT 'SUB_WASTE', 'subcontract_wastes', id, legacy_id::TEXT, bill_no, upper(btrim(bill_no))
FROM subcontract_wastes WHERE NULLIF(btrim(bill_no), '') IS NOT NULL
UNION ALL SELECT 'FIN_RECEIPT', 'finance_receipts', id, legacy_id::TEXT, bill_no, upper(btrim(bill_no))
FROM finance_receipts WHERE NULLIF(btrim(bill_no), '') IS NOT NULL
UNION ALL SELECT 'FIN_PAYMENT', 'finance_payments', id, legacy_id::TEXT, bill_no, upper(btrim(bill_no))
FROM finance_payments WHERE NULLIF(btrim(bill_no), '') IS NOT NULL
UNION ALL SELECT 'FIN_EXPENSE', 'finance_expenses', id, legacy_id::TEXT, bill_no, upper(btrim(bill_no))
FROM finance_expenses WHERE NULLIF(btrim(bill_no), '') IS NOT NULL
UNION ALL SELECT 'FIN_OTHER_INCOME', 'finance_other_incomes', id, legacy_id::TEXT, bill_no, upper(btrim(bill_no))
FROM finance_other_incomes WHERE NULLIF(btrim(bill_no), '') IS NOT NULL
UNION ALL SELECT 'FIN_BANK_TRANSFER', 'finance_bank_transfers', id, legacy_id::TEXT, bill_no, upper(btrim(bill_no))
FROM finance_bank_transfers WHERE NULLIF(btrim(bill_no), '') IS NOT NULL
UNION ALL SELECT 'FIXED_ASSET', 'fixed_assets', id, NULL, code, upper(btrim(code))
FROM fixed_assets WHERE NULLIF(btrim(code), '') IS NOT NULL
UNION ALL SELECT 'DEFERRED_EXPENSE', 'deferred_expenses', id, NULL, code, upper(btrim(code))
FROM deferred_expenses WHERE NULLIF(btrim(code), '') IS NOT NULL
UNION ALL
SELECT CASE WHEN upper(btrim(bill_no)) ~ '^SZ[0-9]'
            THEN 'PRODUCTION_SUBPLAN' ELSE 'PRODUCTION_PLAN' END,
       'production_plans', id, legacy_id::TEXT, bill_no, upper(btrim(bill_no))
FROM production_plans WHERE NULLIF(btrim(bill_no), '') IS NOT NULL
UNION ALL SELECT 'PRODUCTION_DAILY_REPORT', 'production_daily_reports', id, legacy_id::TEXT, bill_no, upper(btrim(bill_no))
FROM production_daily_reports WHERE NULLIF(btrim(bill_no), '') IS NOT NULL
UNION ALL SELECT 'RD_TASK', 'rd_tasks', id, NULL, task_no, upper(btrim(task_no))
FROM rd_tasks WHERE NULLIF(btrim(task_no), '') IS NOT NULL
UNION ALL SELECT 'VISITOR_ACCOUNT', 'visitor_accounts', id, NULL, visitor_no, upper(btrim(visitor_no))
FROM visitor_accounts WHERE NULLIF(btrim(visitor_no), '') IS NOT NULL
UNION ALL SELECT 'PRODUCTION_EXECUTION_SEGMENT', 'production_execution_segments',
       id, NULL, segment_code, upper(btrim(segment_code))
FROM production_execution_segments
WHERE NULLIF(btrim(segment_code), '') IS NOT NULL;

-- V276 already classified every authoritative master code, including scoped
-- position and asset-category domains. Reuse that identity evidence verbatim.
CREATE TEMP TABLE tmp_business_identifier_seed ON COMMIT DROP AS
SELECT member.master_domain owner_domain,
       'master_code_reservation_members'::TEXT source_table,
       member.entity_id, member.legacy_identity,
       member.code_snapshot identifier_snapshot,
       member.normalized_code normalized_identifier
FROM master_code_reservation_members member
WHERE member.master_domain NOT IN ('FIXED_ASSET', 'DEFERRED_EXPENSE')
UNION ALL
SELECT 'PRODUCTION_PLAN_ITEM', 'production_plan_items', plan_id, NULL,
       product_no, upper(btrim(product_no))
FROM production_plan_items
WHERE NULLIF(btrim(product_no), '') IS NOT NULL
UNION ALL
SELECT owner_domain, source_table, entity_id, legacy_identity,
       identifier_snapshot, normalized_identifier
FROM tmp_business_header_identifier_seed;

-- Existing plan-derived product numbers advance the per-plan allocator. Custom
-- historical numbers stay globally reserved but do not need to fit this shape.
INSERT INTO production_product_no_sequences (plan_id, last_seq)
SELECT item.plan_id, max(parsed.suffix::BIGINT)
FROM production_plan_items item
JOIN production_plans plan ON plan.id = item.plan_id
CROSS JOIN LATERAL (
    SELECT upper(btrim(plan.bill_no)) AS plan_no,
           upper(btrim(item.product_no)) AS product_no
) normalized
CROSS JOIN LATERAL (
    SELECT substring(
        normalized.product_no
        FROM char_length(normalized.plan_no) + 2) AS suffix
) parsed
WHERE left(normalized.product_no, char_length(normalized.plan_no) + 1)
          = normalized.plan_no || '-'
  AND char_length(parsed.suffix) BETWEEN 1 AND 6
  AND parsed.suffix ~ '^[0-9]+$'
GROUP BY item.plan_id
ON CONFLICT (plan_id) DO UPDATE
    SET last_seq = GREATEST(
        production_product_no_sequences.last_seq, EXCLUDED.last_seq);

INSERT INTO business_identifier_reservations (
    normalized_identifier, first_identifier_snapshot, first_owner_domain,
    first_entity_id, first_legacy_identity)
SELECT DISTINCT ON (normalized_identifier)
       normalized_identifier, identifier_snapshot, owner_domain,
       entity_id, legacy_identity
FROM tmp_business_identifier_seed
ORDER BY normalized_identifier, source_table, owner_domain, entity_id;

INSERT INTO business_identifier_reservation_members (
    normalized_identifier, owner_domain, entity_id, legacy_identity,
    identifier_snapshot, source_table)
SELECT normalized_identifier, owner_domain, entity_id, legacy_identity,
       identifier_snapshot, source_table
FROM tmp_business_identifier_seed
ON CONFLICT DO NOTHING;

INSERT INTO business_identifier_conflicts (
    conflict_kind, normalized_value, owner_kind, owner_key, evidence)
SELECT 'IDENTIFIER_DUPLICATE', normalized_identifier,
       'GLOBAL_IDENTIFIER', normalized_identifier,
       jsonb_build_object(
           'member_count', count(*),
           'members', jsonb_agg(jsonb_build_object(
               'ownerDomain', owner_domain,
               'sourceTable', source_table,
               'entityId', entity_id,
               'legacyIdentity', legacy_identity,
               'snapshot', identifier_snapshot)
               ORDER BY source_table, owner_domain, entity_id))
FROM tmp_business_identifier_seed
GROUP BY normalized_identifier
HAVING count(DISTINCT owner_domain || '/' || entity_id::TEXT) > 1;

-- Infer only an unambiguous alphabetic leading token followed immediately by
-- digits, or by one conventional separator and digits. Never guess otherwise.
CREATE TEMP TABLE tmp_business_header_prefix_seed ON COMMIT DROP AS
SELECT seed.*,
       COALESCE(
           substring(normalized_identifier FROM '^([A-Z]+)[0-9]'),
           substring(normalized_identifier FROM '^([A-Z]+)[-_/][0-9]'))
           AS normalized_prefix
FROM tmp_business_header_identifier_seed seed;

INSERT INTO business_prefix_reservations (
    normalized_prefix, first_prefix_snapshot, first_owner_kind, first_owner_key)
SELECT DISTINCT ON (normalized_prefix)
       normalized_prefix, normalized_prefix, 'NAMESPACE', owner_domain
FROM tmp_business_header_prefix_seed
WHERE normalized_prefix IS NOT NULL
ORDER BY normalized_prefix, owner_domain, entity_id
ON CONFLICT DO NOTHING;

INSERT INTO business_prefix_reservation_members (
    normalized_prefix, owner_kind, owner_key, legacy_identity,
    prefix_snapshot, member_kind)
SELECT DISTINCT normalized_prefix, 'NAMESPACE', owner_domain, legacy_identity,
       normalized_prefix, 'HISTORICAL'
FROM tmp_business_header_prefix_seed
WHERE normalized_prefix IS NOT NULL
ON CONFLICT DO NOTHING;

INSERT INTO business_identifier_conflicts (
    conflict_kind, normalized_value, owner_kind, owner_key,
    source_table, entity_id, legacy_identity, evidence)
SELECT 'FORMAT_ANOMALY', normalized_identifier, 'NAMESPACE', owner_domain,
       source_table, entity_id, legacy_identity,
       jsonb_build_object('snapshot', identifier_snapshot,
                          'reason', 'leading prefix token cannot be determined safely')
FROM tmp_business_header_prefix_seed
WHERE normalized_prefix IS NULL;

INSERT INTO business_identifier_conflicts (
    conflict_kind, normalized_value, owner_kind, owner_key, evidence)
SELECT 'PREFIX_DUPLICATE', normalized_prefix, 'GLOBAL_PREFIX', normalized_prefix,
       jsonb_build_object(
           'member_count', count(*),
           'members', jsonb_agg(jsonb_build_object(
               'ownerKind', owner_kind,
               'ownerKey', owner_key,
               'entityId', entity_id,
               'legacyIdentity', legacy_identity,
               'snapshot', prefix_snapshot)
               ORDER BY owner_kind, owner_key))
FROM business_prefix_reservation_members
GROUP BY normalized_prefix
HAVING count(DISTINCT owner_kind || '/' || owner_key) > 1;

-- Resume a V2 daily sequence after already-imported V2 identifiers. Invalid
-- calendar dates remain historical values and are reported instead of parsed.
DO $$
DECLARE
    row_record RECORD;
    parsed_date DATE;
    date_text TEXT;
    parsed_seq BIGINT;
BEGIN
    FOR row_record IN
        SELECT seed.owner_domain namespace_key,
               namespace.fixed_prefix,
               seed.normalized_identifier,
               seed.source_table,
               seed.entity_id,
               seed.legacy_identity
        FROM tmp_business_header_identifier_seed seed
        JOIN business_identifier_namespaces namespace
          ON namespace.namespace_key = seed.owner_domain
        WHERE namespace.identifier_family = 'DOCUMENT'
          AND seed.normalized_identifier ~
              ('^' || namespace.fixed_prefix || '[0-9]{14}$')
    LOOP
        date_text := substring(
            row_record.normalized_identifier
            FROM char_length(row_record.fixed_prefix) + 1 FOR 8);
        BEGIN
            parsed_date := to_date(date_text, 'YYYYMMDD');
            IF to_char(parsed_date, 'YYYYMMDD') <> date_text THEN
                RAISE EXCEPTION 'normalized date mismatch';
            END IF;
            parsed_seq := right(row_record.normalized_identifier, 6)::BIGINT;
            IF parsed_seq NOT BETWEEN 1 AND 999999 THEN
                RAISE EXCEPTION 'sequence outside supported range';
            END IF;
            INSERT INTO business_document_sequences (
                namespace_key, sequence_date, last_seq)
            VALUES (row_record.namespace_key, parsed_date, parsed_seq)
            ON CONFLICT (namespace_key, sequence_date) DO UPDATE
                SET last_seq = GREATEST(
                    business_document_sequences.last_seq, EXCLUDED.last_seq);
        EXCEPTION WHEN OTHERS THEN
            INSERT INTO business_identifier_conflicts (
                conflict_kind, normalized_value, owner_kind, owner_key,
                source_table, entity_id, legacy_identity, evidence)
            VALUES (
                'FORMAT_ANOMALY', row_record.normalized_identifier,
                'NAMESPACE', row_record.namespace_key, row_record.source_table,
                row_record.entity_id, row_record.legacy_identity,
                jsonb_build_object('reason', 'invalid V2 document date or sequence'));
        END;
    END LOOP;
END $$;

-- Resume every fixed master/system allocator after the greatest already used
-- canonical suffix. The global scan also covers a cross-domain historical value
-- that happens to occupy a future generated candidate. Longer/custom values are
-- still skipped by the service reservation loop rather than cast unsafely.
INSERT INTO master_code_sequences (prefix, last_seq)
SELECT namespace.fixed_prefix,
       max(substring(
           reservation.normalized_identifier
           FROM char_length(namespace.fixed_prefix) + 1)::INTEGER)
FROM business_identifier_namespaces namespace
JOIN business_identifier_reservations reservation
  ON reservation.normalized_identifier ~
     ('^' || namespace.fixed_prefix || '[0-9]{1,9}$')
WHERE namespace.identifier_family IN ('MASTER', 'SYSTEM')
GROUP BY namespace.fixed_prefix
ON CONFLICT (prefix) DO UPDATE
    SET last_seq = GREATEST(master_code_sequences.last_seq, EXCLUDED.last_seq);

CREATE OR REPLACE FUNCTION fn_claim_global_business_prefix(
    p_prefix TEXT,
    p_owner_kind TEXT,
    p_owner_key TEXT,
    p_entity_id UUID,
    p_legacy_identity TEXT,
    p_prefix_snapshot TEXT,
    p_member_kind TEXT,
    p_current_normalized TEXT DEFAULT NULL,
    p_allow_historical_collision BOOLEAN DEFAULT FALSE)
RETURNS VOID AS $$
DECLARE
    normalized_value TEXT := upper(NULLIF(btrim(p_prefix), ''));
    any_member BOOLEAN;
    self_member BOOLEAN;
    same_legacy_member BOOLEAN;
    other_member BOOLEAN;
BEGIN
    IF normalized_value IS NULL THEN
        RAISE EXCEPTION USING ERRCODE = '23514',
            MESSAGE = 'business prefix must not be blank';
    END IF;

    INSERT INTO business_prefix_reservations (
        normalized_prefix, first_prefix_snapshot, first_owner_kind, first_owner_key)
    VALUES (normalized_value, p_prefix_snapshot, p_owner_kind, p_owner_key)
    ON CONFLICT DO NOTHING;

    PERFORM 1 FROM business_prefix_reservations
    WHERE normalized_prefix = normalized_value
    FOR UPDATE;

    SELECT EXISTS (
               SELECT 1 FROM business_prefix_reservation_members member
               WHERE member.normalized_prefix = normalized_value),
           EXISTS (
               SELECT 1 FROM business_prefix_reservation_members member
               WHERE member.normalized_prefix = normalized_value
                 AND member.owner_kind = p_owner_kind
                 AND member.owner_key = p_owner_key),
           EXISTS (
               SELECT 1 FROM business_prefix_reservation_members member
               WHERE member.normalized_prefix = normalized_value
                 AND member.owner_kind = p_owner_kind
                 AND p_legacy_identity IS NOT NULL
                 AND member.legacy_identity = p_legacy_identity
                 AND (member.owner_key = p_owner_key
                      OR (p_owner_kind = 'CATEGORY'
                          AND split_part(member.owner_key, '/', 1)
                              = split_part(p_owner_key, '/', 1)))),
           EXISTS (
               SELECT 1 FROM business_prefix_reservation_members member
               WHERE member.normalized_prefix = normalized_value
                 AND NOT (member.owner_kind = p_owner_kind
                          AND member.owner_key = p_owner_key))
    INTO any_member, self_member, same_legacy_member, other_member;

    IF any_member
       AND NOT (
           (self_member AND (
               p_current_normalized = normalized_value OR NOT other_member))
            OR p_allow_historical_collision) THEN
        RAISE EXCEPTION USING ERRCODE = '23505',
            CONSTRAINT = 'business_prefix_reservations_pkey',
            MESSAGE = format(
                'business prefix is reserved for another owner: prefix=%s owner=%s/%s',
                p_prefix_snapshot, p_owner_kind, p_owner_key);
    END IF;

    IF p_allow_historical_collision AND other_member
       AND NOT self_member AND NOT same_legacy_member THEN
        INSERT INTO business_identifier_conflicts (
            conflict_kind, normalized_value, owner_kind, owner_key,
            entity_id, legacy_identity, evidence)
        VALUES (
            'PREFIX_DUPLICATE', normalized_value, p_owner_kind, p_owner_key,
            p_entity_id, p_legacy_identity,
            jsonb_build_object('snapshot', p_prefix_snapshot,
                               'reason', 'legacy import joined a reserved prefix'));
    END IF;

    INSERT INTO business_prefix_reservation_members (
        normalized_prefix, owner_kind, owner_key, entity_id, legacy_identity,
        prefix_snapshot, member_kind)
    VALUES (
        normalized_value, p_owner_kind, p_owner_key, p_entity_id,
        p_legacy_identity, p_prefix_snapshot, p_member_kind)
    ON CONFLICT DO NOTHING;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION fn_reserve_business_namespace_prefix()
RETURNS TRIGGER AS $$
BEGIN
    PERFORM fn_claim_global_business_prefix(
        NEW.fixed_prefix, 'NAMESPACE', NEW.namespace_key, NEW.id, NULL,
        NEW.fixed_prefix, 'FIXED', NULL, FALSE);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_business_namespace_prefix
    BEFORE INSERT ON business_identifier_namespaces
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_business_namespace_prefix();

CREATE OR REPLACE FUNCTION fn_claim_global_business_identifier(
    p_identifier TEXT,
    p_owner_domain TEXT,
    p_entity_id UUID,
    p_legacy_identity TEXT,
    p_source_table TEXT,
    p_current_normalized TEXT DEFAULT NULL,
    p_allow_historical_collision BOOLEAN DEFAULT FALSE,
    p_allow_same_logical_owner BOOLEAN DEFAULT FALSE)
RETURNS VOID AS $$
DECLARE
    normalized_value TEXT := upper(NULLIF(btrim(p_identifier), ''));
    any_member BOOLEAN;
    self_member BOOLEAN;
    same_legacy_member BOOLEAN;
    other_member BOOLEAN;
BEGIN
    IF normalized_value IS NULL THEN
        RAISE EXCEPTION USING ERRCODE = '23514',
            MESSAGE = p_source_table || ' business identifier must not be blank';
    END IF;
    IF p_entity_id IS NULL THEN
        RAISE EXCEPTION USING ERRCODE = '23514',
            MESSAGE = p_source_table || ' id is required before reserving an identifier';
    END IF;

    INSERT INTO business_identifier_reservations (
        normalized_identifier, first_identifier_snapshot, first_owner_domain,
        first_entity_id, first_legacy_identity)
    VALUES (
        normalized_value, p_identifier, p_owner_domain,
        p_entity_id, p_legacy_identity)
    ON CONFLICT DO NOTHING;

    PERFORM 1 FROM business_identifier_reservations
    WHERE normalized_identifier = normalized_value
    FOR UPDATE;

    SELECT EXISTS (
               SELECT 1 FROM business_identifier_reservation_members member
               WHERE member.normalized_identifier = normalized_value),
           EXISTS (
               SELECT 1 FROM business_identifier_reservation_members member
               WHERE member.normalized_identifier = normalized_value
                 AND member.owner_domain = p_owner_domain
                 AND member.entity_id = p_entity_id),
           EXISTS (
               SELECT 1 FROM business_identifier_reservation_members member
               WHERE member.normalized_identifier = normalized_value
                 AND member.owner_domain = p_owner_domain
                 AND p_legacy_identity IS NOT NULL
                 AND member.legacy_identity = p_legacy_identity),
           EXISTS (
               SELECT 1 FROM business_identifier_reservation_members member
               WHERE member.normalized_identifier = normalized_value
                 AND NOT (member.owner_domain = p_owner_domain
                          AND member.entity_id = p_entity_id))
    INTO any_member, self_member, same_legacy_member, other_member;

    IF any_member
       AND NOT (
           (self_member AND (
               p_current_normalized = normalized_value OR NOT other_member))
            OR (p_allow_same_logical_owner AND same_legacy_member)
            OR p_allow_historical_collision) THEN
        RAISE EXCEPTION USING ERRCODE = '23505',
            CONSTRAINT = 'business_identifier_reservations_pkey',
            MESSAGE = format(
                'business identifier is reserved for another identity: code=%s owner=%s',
                p_identifier, p_owner_domain);
    END IF;

    IF p_allow_historical_collision AND other_member
       AND NOT self_member AND NOT same_legacy_member THEN
        INSERT INTO business_identifier_conflicts (
            conflict_kind, normalized_value, owner_kind, owner_key,
            source_table, entity_id, legacy_identity, evidence)
        VALUES (
            'IDENTIFIER_DUPLICATE', normalized_value,
            'LEGACY_IMPORT', p_owner_domain, p_source_table,
            p_entity_id, p_legacy_identity,
            jsonb_build_object('snapshot', p_identifier,
                               'reason', 'legacy import joined a reserved identifier'));
    END IF;

    INSERT INTO business_identifier_reservation_members (
        normalized_identifier, owner_domain, entity_id, legacy_identity,
        identifier_snapshot, source_table)
    VALUES (
        normalized_value, p_owner_domain, p_entity_id, p_legacy_identity,
        p_identifier, p_source_table)
    ON CONFLICT DO NOTHING;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION fn_allocate_production_product_no(
    p_plan_id UUID)
RETURNS TEXT AS $$
DECLARE
    v_plan_no TEXT;
    v_sequence BIGINT;
    v_candidate TEXT;
BEGIN
    SELECT upper(NULLIF(btrim(plan.bill_no), ''))
    INTO v_plan_no
    FROM production_plans plan
    WHERE plan.id = p_plan_id
      AND COALESCE(plan.is_deleted, FALSE) = FALSE
    FOR SHARE;
    IF NOT FOUND OR v_plan_no IS NULL THEN
        RAISE EXCEPTION USING ERRCODE = '23514',
            MESSAGE = 'an active production plan with a bill number is required';
    END IF;

    LOOP
        INSERT INTO production_product_no_sequences (plan_id, last_seq)
        VALUES (p_plan_id, 1)
        ON CONFLICT (plan_id) DO UPDATE
            SET last_seq = production_product_no_sequences.last_seq + 1
            WHERE production_product_no_sequences.last_seq < 999999
        RETURNING last_seq INTO v_sequence;
        IF NOT FOUND THEN
            RAISE EXCEPTION USING ERRCODE = '54000',
                MESSAGE = format(
                    'production product number sequence exhausted for plan %s',
                    p_plan_id);
        END IF;

        v_candidate := v_plan_no || '-'
            || repeat('0', greatest(3 - char_length(v_sequence::TEXT), 0))
            || v_sequence::TEXT;
        BEGIN
            PERFORM fn_claim_global_business_identifier(
                v_candidate, 'PRODUCTION_PLAN_ITEM', p_plan_id, NULL,
                'production_plan_items', NULL, FALSE);
            RETURN v_candidate;
        EXCEPTION WHEN unique_violation THEN
            -- A custom or historical identifier already owns this candidate.
            -- The counter increment remains in the outer transaction; try next.
        END;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION fn_reserve_business_category_prefix()
RETURNS TRIGGER AS $$
DECLARE
    row_value JSONB := to_jsonb(NEW);
    entity_id UUID := NULLIF(row_value ->> 'id', '')::UUID;
    legacy_identity TEXT := NULLIF(btrim(row_value ->> 'legacy_id'), '');
    prefix_snapshot TEXT := NULLIF(btrim(row_value ->> 'code_prefix'), '');
    current_normalized TEXT;
    legacy_import_mode BOOLEAN :=
        lower(COALESCE(
            current_setting('app.business_identifier_legacy_import', TRUE),
            'off')) IN ('on', 'true', '1')
        OR COALESCE(
            current_setting('uten.legacy_reference_import', TRUE), '') <> '';
BEGIN
    IF prefix_snapshot IS NULL THEN
        RETURN NEW;
    END IF;
    IF TG_OP = 'UPDATE' THEN
        current_normalized := upper(NULLIF(btrim(to_jsonb(OLD) ->> 'code_prefix'), ''));
    END IF;

    PERFORM fn_claim_global_business_prefix(
        prefix_snapshot,
        'CATEGORY',
        TG_TABLE_NAME || '/' || entity_id::TEXT,
        entity_id,
        legacy_identity,
        prefix_snapshot,
        'CATEGORY',
        current_normalized,
        TG_OP = 'INSERT' AND legacy_import_mode);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_business_prefix_material_categories
    BEFORE INSERT OR UPDATE OF code_prefix ON material_categories
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_business_category_prefix();
CREATE TRIGGER trg_business_prefix_mould_categories
    BEFORE INSERT OR UPDATE OF code_prefix ON mould_categories
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_business_category_prefix();
CREATE TRIGGER trg_business_prefix_client_categories
    BEFORE INSERT OR UPDATE OF code_prefix ON client_categories
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_business_category_prefix();
CREATE TRIGGER trg_business_prefix_supplier_categories
    BEFORE INSERT OR UPDATE OF code_prefix ON supplier_categories
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_business_category_prefix();

CREATE OR REPLACE FUNCTION fn_reserve_global_master_identifier()
RETURNS TRIGGER AS $$
DECLARE
    base_domain TEXT := TG_ARGV[0];
    scope_column TEXT := NULLIF(TG_ARGV[1], '');
    legacy_column TEXT := NULLIF(TG_ARGV[2], '');
    row_value JSONB := to_jsonb(NEW);
    owner_domain TEXT;
    entity_id UUID;
    legacy_identity TEXT;
    identifier_snapshot TEXT;
    current_normalized TEXT;
    scope_value TEXT;
    sequence_value BIGINT;
    default_prefix TEXT;
    legacy_import_mode BOOLEAN :=
        lower(COALESCE(
            current_setting('app.business_identifier_legacy_import', TRUE),
            'off')) IN ('on', 'true', '1')
        OR COALESCE(
            current_setting('uten.legacy_reference_import', TRUE), '') <> '';
BEGIN
    -- CategoryDrivenCodeService uses temporary non-business placeholders while
    -- swapping active unique values. Only the final stage is reserved/audited.
    IF current_setting('app.master_code_audit_stage', TRUE) = 'temporary' THEN
        RETURN NEW;
    END IF;

    entity_id := NULLIF(row_value ->> 'id', '')::UUID;
    identifier_snapshot := NULLIF(btrim(row_value ->> 'code'), '');
    IF identifier_snapshot IS NULL THEN
        RAISE EXCEPTION USING ERRCODE = '23514',
            MESSAGE = TG_TABLE_NAME || '.code must not be blank';
    END IF;
    owner_domain := base_domain;
    IF scope_column IS NOT NULL THEN
        scope_value := NULLIF(btrim(row_value ->> scope_column), '');
        IF scope_value IS NULL THEN
            RAISE EXCEPTION USING ERRCODE = '23514',
                MESSAGE = TG_TABLE_NAME || '.' || scope_column
                    || ' is required for scoped identifier ownership';
        END IF;
        owner_domain := owner_domain || '/' || scope_value;
    END IF;
    IF legacy_column IS NOT NULL THEN
        legacy_identity := NULLIF(btrim(row_value ->> legacy_column), '');
    END IF;
    IF TG_OP = 'UPDATE' THEN
        current_normalized := upper(NULLIF(btrim(to_jsonb(OLD) ->> 'code'), ''));
    END IF;

    PERFORM fn_claim_global_business_identifier(
        identifier_snapshot, owner_domain, entity_id, legacy_identity,
        TG_TABLE_NAME, current_normalized,
        TG_OP = 'INSERT' AND legacy_import_mode,
        base_domain = 'FINANCE_ASSET_CATEGORY' AND TG_OP = 'INSERT');

    -- Direct legacy imports must also advance the allocator metadata. Global
    -- reservation checks remain the liveness fallback for sparse/custom data.
    IF base_domain IN ('GOODS', 'MOULD', 'CLIENT', 'SUPPLIER')
       AND NULLIF(row_value ->> 'code_sequence', '') IS NOT NULL THEN
        sequence_value := (row_value ->> 'code_sequence')::BIGINT;
        INSERT INTO category_master_code_sequences (master_type, last_seq)
        VALUES (base_domain, sequence_value)
        ON CONFLICT (master_type) DO UPDATE
            SET last_seq = GREATEST(
                category_master_code_sequences.last_seq, EXCLUDED.last_seq);
    END IF;

    SELECT namespace.fixed_prefix INTO default_prefix
    FROM business_identifier_namespaces namespace
    WHERE namespace.identifier_family = 'MASTER'
      AND namespace.source_table = TG_TABLE_NAME
      AND namespace.identifier_column = 'code'
    ORDER BY namespace.namespace_key
    LIMIT 1;
    IF default_prefix IS NOT NULL
       AND upper(identifier_snapshot) ~ ('^' || default_prefix || '[0-9]{1,18}$') THEN
        sequence_value := substring(
            upper(identifier_snapshot)
            FROM char_length(default_prefix) + 1)::BIGINT;
        IF sequence_value BETWEEN 1 AND 2147483647 THEN
            INSERT INTO master_code_sequences (prefix, last_seq)
            VALUES (default_prefix, sequence_value::INTEGER)
            ON CONFLICT (prefix) DO UPDATE
                SET last_seq = GREATEST(
                    master_code_sequences.last_seq, EXCLUDED.last_seq);
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Mirror every V276 domain, adding one global exact-code boundary on top of
-- V276's domain-specific lifetime ownership.
CREATE TRIGGER trg_global_identifier_goods BEFORE INSERT OR UPDATE OF code ON goods
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_global_master_identifier('GOODS', '', 'legacy_id');
CREATE TRIGGER trg_global_identifier_moulds BEFORE INSERT OR UPDATE OF code ON moulds
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_global_master_identifier('MOULD', '', 'legacy_id');
CREATE TRIGGER trg_global_identifier_clients BEFORE INSERT OR UPDATE OF code ON clients
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_global_master_identifier('CLIENT', '', 'legacy_id');
CREATE TRIGGER trg_global_identifier_suppliers BEFORE INSERT OR UPDATE OF code ON suppliers
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_global_master_identifier('SUPPLIER', '', 'legacy_id');
CREATE TRIGGER trg_global_identifier_colors BEFORE INSERT OR UPDATE OF code ON colors
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_global_master_identifier('COLOR', '', 'legacy_id');
CREATE TRIGGER trg_global_identifier_units BEFORE INSERT OR UPDATE OF code ON units
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_global_master_identifier('UNIT', '', 'legacy_id');
CREATE TRIGGER trg_global_identifier_currencies BEFORE INSERT OR UPDATE OF code ON currencies
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_global_master_identifier('CURRENCY', '', 'legacy_id');
CREATE TRIGGER trg_global_identifier_warehouses BEFORE INSERT OR UPDATE OF code ON warehouses
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_global_master_identifier('WAREHOUSE', '', 'legacy_id');
CREATE TRIGGER trg_global_identifier_accounts BEFORE INSERT OR UPDATE OF code ON accounts
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_global_master_identifier('ACCOUNT', '', 'legacy_id');
CREATE TRIGGER trg_global_identifier_payment_styles BEFORE INSERT OR UPDATE OF code ON payment_styles
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_global_master_identifier('PAYMENT_STYLE', '', 'legacy_id');
CREATE TRIGGER trg_global_identifier_settlement_methods BEFORE INSERT OR UPDATE OF code ON settlement_methods
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_global_master_identifier('SETTLEMENT_METHOD', '', 'legacy_id');
CREATE TRIGGER trg_global_identifier_finance_payment_methods BEFORE INSERT OR UPDATE OF code ON finance_payment_methods
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_global_master_identifier('FINANCE_PAYMENT_METHOD', '', 'legacy_id');
CREATE TRIGGER trg_global_identifier_material_categories BEFORE INSERT OR UPDATE OF code ON material_categories
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_global_master_identifier('MATERIAL_CATEGORY_INTERNAL', '', 'legacy_id');
CREATE TRIGGER trg_global_identifier_mould_categories BEFORE INSERT OR UPDATE OF code ON mould_categories
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_global_master_identifier('MOULD_CATEGORY_INTERNAL', '', 'legacy_id');
CREATE TRIGGER trg_global_identifier_client_categories BEFORE INSERT OR UPDATE OF code ON client_categories
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_global_master_identifier('CLIENT_CATEGORY_INTERNAL', '', 'legacy_id');
CREATE TRIGGER trg_global_identifier_supplier_categories BEFORE INSERT OR UPDATE OF code ON supplier_categories
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_global_master_identifier('SUPPLIER_CATEGORY_INTERNAL', '', 'legacy_id');
CREATE TRIGGER trg_global_identifier_employees BEFORE INSERT OR UPDATE OF code ON employees
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_global_master_identifier('EMPLOYEE', '', 'legacy_id');
CREATE TRIGGER trg_global_identifier_departments BEFORE INSERT OR UPDATE OF code ON departments
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_global_master_identifier('DEPARTMENT', '', '');
CREATE TRIGGER trg_global_identifier_positions BEFORE INSERT OR UPDATE OF code, department_id ON positions
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_global_master_identifier('POSITION', 'department_id', '');
CREATE TRIGGER trg_global_identifier_finance_asset_categories
    BEFORE INSERT OR UPDATE OF code, object_type ON finance_asset_categories
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_global_master_identifier(
        'FINANCE_ASSET_CATEGORY', 'object_type', 'code');

-- product_no is a user-facing production-line identity. Draft edits rebuild
-- rows, so the stable owner is the plan UUID rather than the disposable item UUID.
CREATE OR REPLACE FUNCTION fn_reserve_production_plan_item_product_no()
RETURNS TRIGGER AS $$
DECLARE
    row_value JSONB := to_jsonb(NEW);
    plan_owner_id UUID := NULLIF(row_value ->> 'plan_id', '')::UUID;
    identifier_snapshot TEXT := NULLIF(btrim(row_value ->> 'product_no'), '');
    current_normalized TEXT;
    plan_number TEXT;
    sequence_text TEXT;
    sequence_value BIGINT;
    legacy_import_mode BOOLEAN :=
        lower(COALESCE(
            current_setting('app.business_identifier_legacy_import', TRUE),
            'off')) IN ('on', 'true', '1')
        OR COALESCE(
            current_setting('uten.legacy_reference_import', TRUE), '') <> '';
BEGIN
    IF identifier_snapshot IS NULL THEN
        RAISE EXCEPTION USING ERRCODE = '23514',
            MESSAGE = 'production_plan_items.product_no must not be blank';
    END IF;
    IF plan_owner_id IS NULL THEN
        RAISE EXCEPTION USING ERRCODE = '23514',
            MESSAGE = 'production_plan_items.plan_id is required before reserving product_no';
    END IF;
    IF TG_OP = 'UPDATE' THEN
        current_normalized := upper(NULLIF(
            btrim(to_jsonb(OLD) ->> 'product_no'), ''));
    END IF;

    PERFORM fn_claim_global_business_identifier(
        identifier_snapshot, 'PRODUCTION_PLAN_ITEM', plan_owner_id, NULL,
        TG_TABLE_NAME, current_normalized,
        TG_OP = 'INSERT' AND legacy_import_mode);

    -- Explicit user numbers that follow the system plan-line shape must advance
    -- the same counter, otherwise a later blank line could allocate an active
    -- duplicate owned by the same plan.
    SELECT upper(NULLIF(btrim(plan.bill_no), ''))
    INTO plan_number
    FROM production_plans plan
    WHERE plan.id = plan_owner_id;
    IF plan_number IS NOT NULL
       AND left(upper(identifier_snapshot), char_length(plan_number) + 1)
             = plan_number || '-' THEN
        sequence_text := substring(
            upper(identifier_snapshot) FROM char_length(plan_number) + 2);
        IF char_length(sequence_text) BETWEEN 1 AND 6
           AND sequence_text ~ '^[0-9]+$' THEN
            sequence_value := sequence_text::BIGINT;
            IF sequence_value BETWEEN 1 AND 999999 THEN
                INSERT INTO production_product_no_sequences (plan_id, last_seq)
                VALUES (plan_owner_id, sequence_value)
                ON CONFLICT (plan_id) DO UPDATE
                    SET last_seq = GREATEST(
                        production_product_no_sequences.last_seq,
                        EXCLUDED.last_seq);
            END IF;
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_global_identifier_production_plan_items
    BEFORE INSERT OR UPDATE OF product_no, plan_id ON production_plan_items
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_production_plan_item_product_no();

CREATE OR REPLACE FUNCTION fn_reserve_business_document_identifier()
RETURNS TRIGGER AS $$
DECLARE
    v_default_namespace TEXT := NULLIF(TG_ARGV[0], '');
    v_identifier_column TEXT := TG_ARGV[1];
    v_discriminator_column TEXT := NULLIF(TG_ARGV[2], '');
    v_row_value JSONB := to_jsonb(NEW);
    v_old_value JSONB;
    v_entity_id UUID := NULLIF(v_row_value ->> 'id', '')::UUID;
    v_legacy_identity TEXT := NULLIF(btrim(v_row_value ->> 'legacy_id'), '');
    v_raw_identifier_snapshot TEXT := v_row_value ->> v_identifier_column;
    v_identifier_snapshot TEXT := NULLIF(btrim(v_raw_identifier_snapshot), '');
    v_normalized_identifier TEXT;
    v_namespace_record RECORD;
    v_discriminator_value TEXT;
    v_leading_prefix TEXT;
    v_date_text TEXT;
    v_sequence_date DATE;
    v_sequence_value BIGINT;
    v_legacy_import_mode BOOLEAN;
    v_standard_format BOOLEAN := FALSE;
BEGIN
    IF v_identifier_snapshot IS NULL THEN
        RAISE EXCEPTION USING ERRCODE = '23514',
            MESSAGE = TG_TABLE_NAME || '.' || v_identifier_column
                || ' must not be blank';
    END IF;
    v_normalized_identifier := upper(v_identifier_snapshot);
    v_legacy_import_mode := lower(COALESCE(
            current_setting('app.business_identifier_legacy_import', TRUE),
            'off')) IN ('on', 'true', '1')
        OR COALESCE(
            current_setting('uten.legacy_reference_import', TRUE), '') <> '';

    IF TG_OP = 'UPDATE' THEN
        v_old_value := to_jsonb(OLD);
        IF v_row_value ->> v_identifier_column
                IS DISTINCT FROM v_old_value ->> v_identifier_column THEN
            RAISE EXCEPTION USING ERRCODE = '23514',
                MESSAGE = TG_TABLE_NAME || '.' || v_identifier_column
                    || ' is immutable after creation';
        END IF;
        IF v_discriminator_column IS NOT NULL
           AND v_row_value ->> v_discriminator_column
                IS DISTINCT FROM v_old_value ->> v_discriminator_column THEN
            RAISE EXCEPTION USING ERRCODE = '23514',
                MESSAGE = TG_TABLE_NAME || '.' || v_discriminator_column
                    || ' is immutable after identifier creation';
        END IF;
        RETURN NEW;
    END IF;

    -- New online identifiers must persist the canonical representation. A
    -- syntactically valid lowercase or padded value must not reserve its
    -- normalized form while leaving a different display value in the header.
    -- The UPDATE branch returns first so unchanged non-canonical history remains
    -- editable, and controlled legacy imports retain their exact snapshot.
    IF NOT v_legacy_import_mode
       AND v_raw_identifier_snapshot IS DISTINCT FROM v_normalized_identifier THEN
        RAISE EXCEPTION USING ERRCODE = '23514',
            MESSAGE = TG_TABLE_NAME || '.' || v_identifier_column
                || ' must equal upper(btrim(value))';
    END IF;

    IF v_discriminator_column IS NOT NULL THEN
        v_discriminator_value := NULLIF(
            btrim(v_row_value ->> v_discriminator_column), '');
        SELECT namespace.* INTO v_namespace_record
        FROM business_identifier_namespaces namespace
        WHERE namespace.source_table = TG_TABLE_NAME
          AND namespace.identifier_column = v_identifier_column
          AND namespace.discriminator_value = v_discriminator_value;
    ELSE
        -- production_plans contains both SJ plans and SZ execution subplans.
        -- Longest exact leading prefix wins; default handles historical custom ids.
        SELECT namespace.* INTO v_namespace_record
        FROM business_identifier_namespaces namespace
        WHERE namespace.source_table = TG_TABLE_NAME
          AND namespace.identifier_column = v_identifier_column
          AND namespace.identifier_family IN ('DOCUMENT', 'SYSTEM')
          AND left(v_normalized_identifier, char_length(namespace.fixed_prefix))
                = namespace.fixed_prefix
        ORDER BY char_length(namespace.fixed_prefix) DESC, namespace.namespace_key
        LIMIT 1;
        IF NOT FOUND AND v_default_namespace IS NOT NULL THEN
            SELECT namespace.* INTO v_namespace_record
            FROM business_identifier_namespaces namespace
            WHERE namespace.namespace_key = v_default_namespace;
        END IF;
    END IF;

    IF v_namespace_record.namespace_key IS NULL THEN
        RAISE EXCEPTION USING ERRCODE = '23514',
            MESSAGE = format(
                'no business identifier namespace for %s.%s discriminator=%s',
                TG_TABLE_NAME, v_identifier_column, v_discriminator_value);
    END IF;

    PERFORM fn_claim_global_business_identifier(
        CASE WHEN v_legacy_import_mode
             THEN v_raw_identifier_snapshot ELSE v_identifier_snapshot END,
        v_namespace_record.namespace_key, v_entity_id,
        v_legacy_identity, TG_TABLE_NAME, NULL,
        v_legacy_import_mode);

    -- A legacy loader may insert a valid V2 number directly. Bump the daily
    -- counter in the same transaction so the next online allocation cannot
    -- restart below it. Migration/import and online creation are operationally
    -- mutually exclusive, but the global reservation remains the final guard.
    IF v_namespace_record.identifier_family = 'DOCUMENT'
       AND v_normalized_identifier ~
           ('^' || v_namespace_record.fixed_prefix || '[0-9]{14}$') THEN
        v_date_text := substring(
            v_normalized_identifier
            FROM char_length(v_namespace_record.fixed_prefix) + 1 FOR 8);
        BEGIN
            v_sequence_date := to_date(v_date_text, 'YYYYMMDD');
            v_sequence_value := right(v_normalized_identifier, 6)::BIGINT;
            IF to_char(v_sequence_date, 'YYYYMMDD') <> v_date_text
               OR v_sequence_value NOT BETWEEN 1 AND 999999 THEN
                RAISE EXCEPTION 'invalid V2 date or sequence';
            END IF;
            v_standard_format := TRUE;
            INSERT INTO business_document_sequences (
                namespace_key, sequence_date, last_seq)
            VALUES (
                v_namespace_record.namespace_key, v_sequence_date, v_sequence_value)
            ON CONFLICT (namespace_key, sequence_date) DO UPDATE
                SET last_seq = GREATEST(
                    business_document_sequences.last_seq, EXCLUDED.last_seq);
        EXCEPTION WHEN OTHERS THEN
            IF NOT v_legacy_import_mode THEN
                RAISE EXCEPTION USING ERRCODE = '23514',
                    MESSAGE = 'invalid allocated business document number: '
                        || v_identifier_snapshot;
            END IF;
            INSERT INTO business_identifier_conflicts (
                    conflict_kind, normalized_value, owner_kind, owner_key,
                    source_table, entity_id, legacy_identity, evidence)
                VALUES (
                    'FORMAT_ANOMALY', v_normalized_identifier, 'NAMESPACE',
                    v_namespace_record.namespace_key, TG_TABLE_NAME, v_entity_id,
                    v_legacy_identity,
                    jsonb_build_object('snapshot', v_raw_identifier_snapshot,
                                       'reason', 'invalid V2 document date or sequence'));
        END;
    ELSIF v_namespace_record.identifier_family = 'SYSTEM'
          AND v_normalized_identifier ~
              ('^' || v_namespace_record.fixed_prefix || '[0-9]{8}$') THEN
        v_sequence_value := substring(
            v_normalized_identifier
            FROM char_length(v_namespace_record.fixed_prefix) + 1)::BIGINT;
        IF v_sequence_value BETWEEN 1 AND 99999999 THEN
            v_standard_format := TRUE;
            INSERT INTO master_code_sequences (prefix, last_seq)
            VALUES (v_namespace_record.fixed_prefix, v_sequence_value::INTEGER)
            ON CONFLICT (prefix) DO UPDATE
                SET last_seq = GREATEST(
                    master_code_sequences.last_seq, EXCLUDED.last_seq);
        ELSIF NOT v_legacy_import_mode THEN
            RAISE EXCEPTION USING ERRCODE = '23514',
                MESSAGE = 'invalid allocated system identifier: '
                    || v_identifier_snapshot;
        ELSE
            INSERT INTO business_identifier_conflicts (
                    conflict_kind, normalized_value, owner_kind, owner_key,
                    source_table, entity_id, legacy_identity, evidence)
                VALUES (
                    'FORMAT_ANOMALY', v_normalized_identifier, 'NAMESPACE',
                    v_namespace_record.namespace_key, TG_TABLE_NAME, v_entity_id,
                    v_legacy_identity,
                    jsonb_build_object('snapshot', v_raw_identifier_snapshot,
                        'reason', 'system sequence outside supported range 1..99999999'));
        END IF;
    END IF;

    IF NOT v_standard_format THEN
        IF NOT v_legacy_import_mode THEN
            RAISE EXCEPTION USING ERRCODE = '23514',
                MESSAGE = format(
                    'non-standard %s identifier rejected; expected its registered format',
                    v_namespace_record.namespace_key);
        END IF;
        IF left(v_normalized_identifier, char_length(v_namespace_record.fixed_prefix))
                <> v_namespace_record.fixed_prefix THEN
            v_leading_prefix := COALESCE(
                substring(v_normalized_identifier FROM '^([A-Z]+)[0-9]'),
                substring(v_normalized_identifier FROM '^([A-Z]+)[-_/][0-9]'));
            IF v_leading_prefix IS NOT NULL THEN
                PERFORM fn_claim_global_business_prefix(
                    v_leading_prefix, 'NAMESPACE', v_namespace_record.namespace_key,
                    v_entity_id, v_legacy_identity, v_leading_prefix, 'HISTORICAL',
                    NULL, TRUE);
            ELSE
                INSERT INTO business_identifier_conflicts (
                    conflict_kind, normalized_value, owner_kind, owner_key,
                    source_table, entity_id, legacy_identity, evidence)
                VALUES (
                    'FORMAT_ANOMALY', v_normalized_identifier, 'NAMESPACE',
                    v_namespace_record.namespace_key, TG_TABLE_NAME, v_entity_id,
                    v_legacy_identity,
                    jsonb_build_object('snapshot', v_raw_identifier_snapshot,
                        'reason', 'legacy leading prefix token cannot be determined safely'));
            END IF;
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_business_document_sales_orders
    BEFORE INSERT OR UPDATE OF bill_no ON sales_orders
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_business_document_identifier('SALES_ORDER', 'bill_no', '');
CREATE TRIGGER trg_business_document_sales_shipments
    BEFORE INSERT OR UPDATE OF bill_no ON sales_shipments
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_business_document_identifier('SALES_SHIPMENT', 'bill_no', '');
CREATE TRIGGER trg_business_document_sales_other_shipments
    BEFORE INSERT OR UPDATE OF bill_no ON sales_other_shipments
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_business_document_identifier('SALES_OTHER_SHIPMENT', 'bill_no', '');
CREATE TRIGGER trg_business_document_sales_returns
    BEFORE INSERT OR UPDATE OF bill_no ON sales_returns
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_business_document_identifier('SALES_RETURN', 'bill_no', '');
CREATE TRIGGER trg_business_document_sales_quotes
    BEFORE INSERT OR UPDATE OF bill_no ON sales_quotes
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_business_document_identifier('SALES_QUOTE', 'bill_no', '');
CREATE TRIGGER trg_business_document_purchase_requests
    BEFORE INSERT OR UPDATE OF bill_no ON purchase_requests
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_business_document_identifier('PURCHASE_REQUEST', 'bill_no', '');
CREATE TRIGGER trg_business_document_purchase_orders
    BEFORE INSERT OR UPDATE OF bill_no ON purchase_orders
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_business_document_identifier('PURCHASE_ORDER', 'bill_no', '');
CREATE TRIGGER trg_business_document_purchase_receipts
    BEFORE INSERT OR UPDATE OF bill_no ON purchase_receipts
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_business_document_identifier('PURCHASE_RECEIPT', 'bill_no', '');
CREATE TRIGGER trg_business_document_purchase_returns
    BEFORE INSERT OR UPDATE OF bill_no ON purchase_returns
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_business_document_identifier('PURCHASE_RETURN', 'bill_no', '');
CREATE TRIGGER trg_business_document_stock_documents
    BEFORE INSERT OR UPDATE OF bill_no, doc_type ON stock_documents
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_business_document_identifier('', 'bill_no', 'doc_type');
CREATE TRIGGER trg_business_document_subcontract_inquiries
    BEFORE INSERT OR UPDATE OF bill_no ON subcontract_inquiries
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_business_document_identifier('SUB_INQUIRY', 'bill_no', '');
CREATE TRIGGER trg_business_document_subcontract_applications
    BEFORE INSERT OR UPDATE OF bill_no ON subcontract_applications
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_business_document_identifier('SUB_APPLICATION', 'bill_no', '');
CREATE TRIGGER trg_business_document_subcontract_orders
    BEFORE INSERT OR UPDATE OF bill_no ON subcontract_orders
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_business_document_identifier('SUB_ORDER', 'bill_no', '');
CREATE TRIGGER trg_business_document_subcontract_material_issues
    BEFORE INSERT OR UPDATE OF bill_no ON subcontract_material_issues
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_business_document_identifier('SUB_MATERIAL_ISSUE', 'bill_no', '');
CREATE TRIGGER trg_business_document_subcontract_receipts
    BEFORE INSERT OR UPDATE OF bill_no ON subcontract_receipts
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_business_document_identifier('SUB_RECEIPT', 'bill_no', '');
CREATE TRIGGER trg_business_document_subcontract_returns
    BEFORE INSERT OR UPDATE OF bill_no ON subcontract_returns
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_business_document_identifier('SUB_RETURN', 'bill_no', '');
CREATE TRIGGER trg_business_document_subcontract_material_returns
    BEFORE INSERT OR UPDATE OF bill_no ON subcontract_material_returns
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_business_document_identifier('SUB_MATERIAL_RETURN', 'bill_no', '');
CREATE TRIGGER trg_business_document_subcontract_wastes
    BEFORE INSERT OR UPDATE OF bill_no ON subcontract_wastes
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_business_document_identifier('SUB_WASTE', 'bill_no', '');
CREATE TRIGGER trg_business_document_finance_receipts
    BEFORE INSERT OR UPDATE OF bill_no ON finance_receipts
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_business_document_identifier('FIN_RECEIPT', 'bill_no', '');
CREATE TRIGGER trg_business_document_finance_payments
    BEFORE INSERT OR UPDATE OF bill_no ON finance_payments
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_business_document_identifier('FIN_PAYMENT', 'bill_no', '');
CREATE TRIGGER trg_business_document_finance_expenses
    BEFORE INSERT OR UPDATE OF bill_no ON finance_expenses
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_business_document_identifier('FIN_EXPENSE', 'bill_no', '');
CREATE TRIGGER trg_business_document_finance_other_incomes
    BEFORE INSERT OR UPDATE OF bill_no ON finance_other_incomes
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_business_document_identifier('FIN_OTHER_INCOME', 'bill_no', '');
CREATE TRIGGER trg_business_document_finance_bank_transfers
    BEFORE INSERT OR UPDATE OF bill_no ON finance_bank_transfers
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_business_document_identifier('FIN_BANK_TRANSFER', 'bill_no', '');
CREATE TRIGGER trg_business_document_fixed_assets
    BEFORE INSERT OR UPDATE OF code ON fixed_assets
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_business_document_identifier('FIXED_ASSET', 'code', '');
CREATE TRIGGER trg_business_document_deferred_expenses
    BEFORE INSERT OR UPDATE OF code ON deferred_expenses
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_business_document_identifier('DEFERRED_EXPENSE', 'code', '');
CREATE TRIGGER trg_business_document_production_plans
    BEFORE INSERT OR UPDATE OF bill_no ON production_plans
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_business_document_identifier('PRODUCTION_PLAN', 'bill_no', '');
CREATE TRIGGER trg_business_document_production_daily_reports
    BEFORE INSERT OR UPDATE OF bill_no ON production_daily_reports
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_business_document_identifier('PRODUCTION_DAILY_REPORT', 'bill_no', '');
CREATE TRIGGER trg_business_document_rd_tasks
    BEFORE INSERT OR UPDATE OF task_no ON rd_tasks
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_business_document_identifier('RD_TASK', 'task_no', '');
CREATE TRIGGER trg_business_document_visitor_accounts
    BEFORE INSERT OR UPDATE OF visitor_no ON visitor_accounts
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_business_document_identifier('VISITOR_ACCOUNT', 'visitor_no', '');
CREATE TRIGGER trg_business_document_production_execution_segments
    BEFORE INSERT OR UPDATE OF segment_code ON production_execution_segments
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_business_document_identifier(
        'PRODUCTION_EXECUTION_SEGMENT', 'segment_code', '');

CREATE OR REPLACE FUNCTION fn_guard_business_identifier_append_only()
RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION USING ERRCODE = '55000',
        MESSAGE = TG_TABLE_NAME
            || ' is append-only; business identifier ownership never expires';
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_guard_business_identifier_namespaces_append_only
    BEFORE UPDATE OR DELETE ON business_identifier_namespaces
    FOR EACH ROW EXECUTE FUNCTION fn_guard_business_identifier_append_only();
CREATE TRIGGER trg_guard_business_prefix_reservations_append_only
    BEFORE UPDATE OR DELETE ON business_prefix_reservations
    FOR EACH ROW EXECUTE FUNCTION fn_guard_business_identifier_append_only();
CREATE TRIGGER trg_guard_business_prefix_reservation_members_append_only
    BEFORE UPDATE OR DELETE ON business_prefix_reservation_members
    FOR EACH ROW EXECUTE FUNCTION fn_guard_business_identifier_append_only();
CREATE TRIGGER trg_guard_business_identifier_reservations_append_only
    BEFORE UPDATE OR DELETE ON business_identifier_reservations
    FOR EACH ROW EXECUTE FUNCTION fn_guard_business_identifier_append_only();
CREATE TRIGGER trg_guard_business_identifier_reservation_members_append_only
    BEFORE UPDATE OR DELETE ON business_identifier_reservation_members
    FOR EACH ROW EXECUTE FUNCTION fn_guard_business_identifier_append_only();
CREATE TRIGGER trg_guard_business_identifier_conflicts_append_only
    BEFORE UPDATE OR DELETE ON business_identifier_conflicts
    FOR EACH ROW EXECUTE FUNCTION fn_guard_business_identifier_append_only();

CREATE TRIGGER trg_audit_business_identifier_namespaces
    AFTER INSERT OR UPDATE OR DELETE ON business_identifier_namespaces
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_business_prefix_reservations
    AFTER INSERT OR UPDATE OR DELETE ON business_prefix_reservations
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_business_prefix_reservation_members
    AFTER INSERT OR UPDATE OR DELETE ON business_prefix_reservation_members
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_business_identifier_reservations
    AFTER INSERT OR UPDATE OR DELETE ON business_identifier_reservations
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_business_identifier_reservation_members
    AFTER INSERT OR UPDATE OR DELETE ON business_identifier_reservation_members
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_business_identifier_conflicts
    AFTER INSERT OR UPDATE OR DELETE ON business_identifier_conflicts
    FOR EACH ROW EXECUTE FUNCTION fn_audit();

COMMENT ON TABLE business_identifier_namespaces IS
    'Append-only namespace to fixed business prefix authority; Java uses namespace_key, never a hard-coded runtime prefix.';
COMMENT ON TABLE business_document_sequences IS
    'Technical Asia/Shanghai daily atomic counter keyed by immutable namespace; intentionally excluded from row-image audit.';
COMMENT ON TABLE production_product_no_sequences IS
    'Technical per-plan atomic suffix counter for system-generated product_no values; intentionally excluded from row-image audit.';
COMMENT ON TABLE business_prefix_reservations IS
    'Lifetime exact-token prefix reservation. Prefix containment is allowed; normalized equality is not.';
COMMENT ON TABLE business_prefix_reservation_members IS
    'Append-only fixed, category and historical owners of every globally reserved prefix token.';
COMMENT ON TABLE business_identifier_reservations IS
    'Lifetime global upper(btrim(identifier)) reservation; UUID remains the relational identity.';
COMMENT ON TABLE business_identifier_reservation_members IS
    'Append-only current and historical identities, including preserved legacy duplicates.';
COMMENT ON TABLE business_identifier_conflicts IS
    'Audited append-only evidence for historical duplicates and unparseable legacy formats.';

-- Refresh complete future-write audit coverage. Only the high-churn atomic
-- counter is added to the technical allowlist; every registry/evidence table
-- above must have exactly one valid audit trigger.
DO $$
DECLARE
    table_record RECORD;
    prefixed_trigger_count INTEGER;
    valid_trigger_count INTEGER;
    missing_tables TEXT;
BEGIN
    FOR table_record IN
        SELECT c.oid, c.relname
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public'
          AND c.relkind IN ('r', 'p')
          AND NOT c.relispartition
          AND c.relname NOT IN (
              'audit_log', 'audit_log_archive', 'flyway_schema_history', 'spatial_ref_sys',
              'authorization_state', 'doc_number_sequences', 'master_code_sequences',
              'category_master_code_sequences', 'business_document_sequences',
              'production_product_no_sequences',
              'report_materialized_view_refresh_state', 'password_history',
              'refresh_tokens', 'visitor_refresh_tokens', 'visitor_sms_codes')
          AND c.relname NOT LIKE 'legacy_migration_%'
        ORDER BY c.relname
    LOOP
        SELECT count(*),
               count(*) FILTER (WHERE
                   audit_trigger.tgenabled IN ('O', 'A')
                   AND (audit_trigger.tgtype::INTEGER & 1) = 1
                   AND (audit_trigger.tgtype::INTEGER & 2) = 0
                   AND (audit_trigger.tgtype::INTEGER & 4) = 4
                   AND (audit_trigger.tgtype::INTEGER & 8) = 8
                   AND (audit_trigger.tgtype::INTEGER & 16) = 16
                   AND function_schema.nspname = 'public'
                   AND audit_function.proname IN ('fn_audit', 'fn_audit_redacted'))
        INTO prefixed_trigger_count, valid_trigger_count
        FROM pg_trigger audit_trigger
        JOIN pg_proc audit_function ON audit_function.oid = audit_trigger.tgfoid
        JOIN pg_namespace function_schema ON function_schema.oid = audit_function.pronamespace
        WHERE audit_trigger.tgrelid = table_record.oid
          AND NOT audit_trigger.tgisinternal
          AND audit_trigger.tgname LIKE 'trg_audit%';

        IF prefixed_trigger_count = 1 AND valid_trigger_count = 1 THEN
            CONTINUE;
        END IF;
        IF prefixed_trigger_count > 0 THEN
            RAISE EXCEPTION
                'public.% has % trg_audit* triggers but exactly one valid enabled AFTER ROW INSERT/UPDATE/DELETE audit trigger is required (valid=%)',
                table_record.relname, prefixed_trigger_count, valid_trigger_count
                USING ERRCODE = '55000';
        END IF;
        EXECUTE format(
            'CREATE TRIGGER trg_audit_%1$I AFTER INSERT OR UPDATE OR DELETE ON %1$I '
            'FOR EACH ROW EXECUTE FUNCTION fn_audit()', table_record.relname);
    END LOOP;

    SELECT string_agg(c.relname, ', ' ORDER BY c.relname)
    INTO missing_tables
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relkind IN ('r', 'p')
      AND NOT c.relispartition
      AND c.relname NOT IN (
          'audit_log', 'audit_log_archive', 'flyway_schema_history', 'spatial_ref_sys',
          'authorization_state', 'doc_number_sequences', 'master_code_sequences',
          'category_master_code_sequences', 'business_document_sequences',
          'production_product_no_sequences',
          'report_materialized_view_refresh_state', 'password_history',
          'refresh_tokens', 'visitor_refresh_tokens', 'visitor_sms_codes')
      AND c.relname NOT LIKE 'legacy_migration_%'
      AND (
          (SELECT count(*) FROM pg_trigger audit_trigger
           WHERE audit_trigger.tgrelid = c.oid AND NOT audit_trigger.tgisinternal
             AND audit_trigger.tgname LIKE 'trg_audit%') <> 1
          OR
          (SELECT count(*)
           FROM pg_trigger audit_trigger
           JOIN pg_proc audit_function ON audit_function.oid = audit_trigger.tgfoid
           JOIN pg_namespace function_schema ON function_schema.oid = audit_function.pronamespace
           WHERE audit_trigger.tgrelid = c.oid AND NOT audit_trigger.tgisinternal
             AND audit_trigger.tgname LIKE 'trg_audit%'
             AND audit_trigger.tgenabled IN ('O', 'A')
             AND (audit_trigger.tgtype::INTEGER & 1) = 1
             AND (audit_trigger.tgtype::INTEGER & 2) = 0
             AND (audit_trigger.tgtype::INTEGER & 4) = 4
             AND (audit_trigger.tgtype::INTEGER & 8) = 8
             AND (audit_trigger.tgtype::INTEGER & 16) = 16
             AND function_schema.nspname = 'public'
             AND audit_function.proname IN ('fn_audit', 'fn_audit_redacted')) <> 1);

    IF missing_tables IS NOT NULL THEN
        RAISE EXCEPTION 'Audit trigger coverage remains invalid for: %', missing_tables
            USING ERRCODE = '55000';
    END IF;
END $$;
