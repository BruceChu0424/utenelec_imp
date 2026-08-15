-- =====================================================================
-- 供应商主档迁移：CSV → suppliers（不依赖 server 启动）
-- =====================================================================
-- 用法：bash server/legacy_migration/migrate.sh --supplier-data
-- 前提：suppliers 表已存在且 V261 已应用；supplier_categories 已迁。
-- 来源：老库 B_Provider（386 条），category_id 关联 supplier_categories.legacy_id
--   （B_Provider.ParentID → SystemItem.ItemID ItemclassID=3）。老库 386 条全部已分组，
--   故 category_id 无 NULL。字段语义见 V38。
-- staging 用真实类型，COPY csv 自动 cast + 空字段→null。
-- emp_id 原样保留为 legacy 快照；owner_employee_id 仅按唯一 employees.legacy_id 精确写入。
-- =====================================================================

BEGIN;
SELECT set_config('app.business_identifier_legacy_import', 'on', true);

DO $$
BEGIN
    IF (SELECT count(*) FROM system_master_category_registry) <> 1
       OR NOT EXISTS (
           SELECT 1
           FROM system_master_category_registry registry
           JOIN supplier_categories category ON category.id = registry.supplier_category_id
           WHERE registry.id = '27500000-0000-4000-8000-000000000001'::uuid
             AND category.legacy_id = -1
             AND category.is_deleted = FALSE
       ) THEN
        RAISE EXCEPTION 'current system supplier-category UUID authority is missing or invalid';
    END IF;
END;
$$;

-- Preserve FK and audit enforcement; referenced suppliers make a reload fail closed.
DELETE FROM suppliers;

CREATE TEMP TABLE supplier_stage (
    legacy_id    int,
    parent_legacy int,
    name         text,          -- Vend_Name
    code         text,          -- Number
    description  text,          -- Vend_Desc（避保留字 desc）
    place        text,          -- Vend_Place
    emp_id       text,          -- Emp_ID（业务员，文本保原值）
    legal_person text,          -- Juri_Per（法人）
    linkman      text,          -- Link_Man
    mobile       text,
    phone        text,
    phone2       text,
    fax          text,
    postcode     text,          -- Post
    address      text,          -- Link_Addr
    email        text,
    website      text,          -- Http
    ship_via     text,          -- Shipvia
    ship_address text,          -- Ship_Addr
    bank         text,          -- Vend_Bank
    bank_account text,          -- Vend_BankNo
    tax_id       text,          -- Tax_ID
    init_total   numeric(18,4), -- InitTotal
    init_total2  numeric(18,4), -- InitTotal2
    exchange_rate numeric(18,6),-- CRate
    tday         int,           -- TDay
    price_style  int,           -- PStyle
    status       text,          -- Status
    remark       text           -- Remark
);
\copy supplier_stage FROM '/tmp/supplier.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

WITH unique_employees AS (
    SELECT legacy_id, (array_agg(id ORDER BY id))[1] AS employee_id
    FROM employees
    WHERE legacy_id IS NOT NULL
    GROUP BY legacy_id
    HAVING count(*) = 1
), numbered AS (
    SELECT ss.*,
           row_number() OVER (ORDER BY ss.legacy_id) AS seq_ordinal,
           count(*) OVER ()::bigint AS allocation_count
    FROM supplier_stage ss
), reserved AS (
    INSERT INTO category_master_code_sequences (master_type, last_seq)
    SELECT 'SUPPLIER', COALESCE(max(allocation_count), 0) FROM numbered
    ON CONFLICT (master_type) DO UPDATE
    SET last_seq = category_master_code_sequences.last_seq + EXCLUDED.last_seq
    RETURNING last_seq
)
INSERT INTO suppliers (
    legacy_id, category_id, name, code, description, place,
    emp_id, owner_employee_id, legal_person, linkman, mobile, phone, phone2, fax, postcode, address,
    email, website, ship_via, ship_address, bank, bank_account, tax_id,
    init_total, init_total2, exchange_rate, tday, price_style, status, remark,
    code_managed, code_sequence
)
SELECT
    ss.legacy_id,
    COALESCE(
        (SELECT c.id FROM supplier_categories c WHERE c.legacy_id = ss.parent_legacy),
        (SELECT supplier_category_id
         FROM system_master_category_registry
         WHERE id = '27500000-0000-4000-8000-000000000001'::uuid)),
    ss.name, ss.code, ss.description, ss.place,
    ss.emp_id, employee_owner.employee_id,
    ss.legal_person, ss.linkman, ss.mobile, ss.phone, ss.phone2, ss.fax,
    ss.postcode, ss.address, ss.email, ss.website, ss.ship_via, ss.ship_address,
    ss.bank, ss.bank_account, ss.tax_id, ss.init_total, ss.init_total2, ss.exchange_rate,
    ss.tday, ss.price_style, ss.status, ss.remark, FALSE,
    reserved.last_seq - ss.allocation_count + ss.seq_ordinal
FROM numbered ss
CROSS JOIN reserved
LEFT JOIN unique_employees employee_owner
  ON employee_owner.legacy_id = CASE
      WHEN btrim(ss.emp_id) ~ '^[0-9]{1,9}$'
          THEN NULLIF(btrim(ss.emp_id)::int, 0)
      ELSE NULL
  END;

COMMIT;

SELECT '✔ 供应商 ' || count(*) ||
       '，已挂分类 ' || count(category_id) ||
       '，未挂分类 ' || count(*) FILTER (WHERE category_id IS NULL) ||
       '，使用 ' || count(*) FILTER (WHERE status = N'使用') ||
       '，禁用 ' || count(*) FILTER (WHERE status = N'禁用') AS 结果
FROM suppliers;
