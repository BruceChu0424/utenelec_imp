-- =====================================================================
-- 客户主档迁移：CSV → clients（不依赖 server 启动）
-- =====================================================================
-- 用法：bash server/legacy_migration/migrate.sh --client-data
-- 前提：V443 已应用；clients/client_categories/settlement_methods 已迁。
-- 来源：老库 B_Client（260 条），category_id 关联 client_categories.legacy_id
--   （B_Client.ParentID → SystemItem.ItemID ItemclassID=2）。未分组或悬空记录
--   统一挂 V275 注册表中的系统“未分类”根。字段语义见 V36。
-- staging 用真实类型，COPY csv 自动 cast + 空字段→null。
-- emp_id 原样保留为 legacy 快照；owner_employee_id 仅按唯一 employees.legacy_id 精确写入。
-- =====================================================================

BEGIN;
SELECT set_config('app.business_identifier_legacy_import', 'on', true);
SELECT set_config('uten.legacy_reference_import', 'on', true);

DO $$
BEGIN
    IF (SELECT count(*) FROM system_master_category_registry) <> 1
       OR NOT EXISTS (
           SELECT 1
           FROM system_master_category_registry registry
           JOIN client_categories category ON category.id = registry.client_category_id
           WHERE registry.id = '27500000-0000-4000-8000-000000000001'::uuid
             AND category.legacy_id = -1
             AND category.is_deleted = FALSE
       ) THEN
        RAISE EXCEPTION 'current system client-category UUID authority is missing or invalid';
    END IF;
END;
$$;

DELETE FROM client_default_settlement_migration_issues;
-- Preserve FK and audit enforcement. Any client already used by an online
-- document makes this reviewed bootstrap reload fail before replacement rows.
DELETE FROM clients;

CREATE TEMP TABLE client_stage (
    legacy_id    int,
    parent_legacy int,
    name         text,          -- Client_Name
    code         text,          -- Number
    full_name    text,          -- Full_Name
    client_rank  text,          -- Client_Rank
    place_id     text,          -- PlaceID（地区文本）
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
    bank         text,          -- Client_Bank
    bank_account text,          -- Client_BankNo
    tax_id       text,          -- Tax_ID
    credit       numeric(18,4), -- Credit
    init_total   numeric(18,4), -- InitTotal
    init_total2  numeric(18,4), -- InitTotal2
    exchange_rate numeric(18,6),-- CRate
    tday         int,           -- TDay
    price_style  int,           -- PStyle
    zj_id        int,           -- ZJID
    region       text,          -- QYName
    client_xz    text,          -- ClientXZ
    status       text,          -- Status
    remark       text           -- Remark
);
\copy client_stage FROM '/tmp/client.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

WITH unique_employees AS (
    SELECT legacy_id, (array_agg(id ORDER BY id))[1] AS employee_id
    FROM employees
    WHERE legacy_id IS NOT NULL
    GROUP BY legacy_id
    HAVING count(*) = 1
), settlement_matches AS (
    SELECT legacy_id,
           (array_agg(id ORDER BY id))[1] AS method_id,
           (array_agg(system_role ORDER BY id))[1] AS system_role
    FROM settlement_methods
    WHERE legacy_id IS NOT NULL
      AND status = '使用'
      AND COALESCE(is_deleted, FALSE) = FALSE
    GROUP BY legacy_id
    HAVING count(*) = 1
), numbered AS (
    SELECT cs.*,
           row_number() OVER (ORDER BY cs.legacy_id) AS seq_ordinal,
           count(*) OVER ()::bigint AS allocation_count
    FROM client_stage cs
), reserved AS (
    INSERT INTO category_master_code_sequences (master_type, last_seq)
    SELECT 'CLIENT', COALESCE(max(allocation_count), 0) FROM numbered
    ON CONFLICT (master_type) DO UPDATE
    SET last_seq = category_master_code_sequences.last_seq + EXCLUDED.last_seq
    RETURNING last_seq
)
INSERT INTO clients (
    legacy_id, category_id, name, code, full_name, client_rank,
    place_id, emp_id, owner_employee_id, legal_person, linkman, mobile, phone, phone2, fax, postcode, address,
    email, website, ship_via, ship_address, bank, bank_account, tax_id,
    credit, credit_floor, init_total, init_total2, exchange_rate, tday,
    default_settlement_method_id, sales_payment_type, price_style, zj_id,
    region, client_xz, status, remark, code_managed, code_sequence
)
SELECT
    cs.legacy_id,
    COALESCE(
        (SELECT c.id FROM client_categories c WHERE c.legacy_id = cs.parent_legacy),
        (SELECT client_category_id
         FROM system_master_category_registry
         WHERE id = '27500000-0000-4000-8000-000000000001'::uuid)),
    cs.name, cs.code, cs.full_name, cs.client_rank,
    cs.place_id, cs.emp_id, employee_owner.employee_id,
    cs.legal_person, cs.linkman, cs.mobile, cs.phone, cs.phone2,
    cs.fax, cs.postcode, cs.address, cs.email, cs.website, cs.ship_via, cs.ship_address,
    cs.bank, cs.bank_account, cs.tax_id,
    cs.credit, COALESCE(cs.credit, 0), cs.init_total, cs.init_total2,
    cs.exchange_rate, cs.tday, settlement_match.method_id,
    CASE settlement_match.system_role
        WHEN 'CASH' THEN 'CASH'
        WHEN 'MONTHLY' THEN 'MONTHLY'
        ELSE NULL
    END,
    cs.price_style,
    cs.zj_id, cs.region, cs.client_xz,
    cs.status, cs.remark, FALSE,
    reserved.last_seq - cs.allocation_count + cs.seq_ordinal
FROM numbered cs
CROSS JOIN reserved
LEFT JOIN unique_employees employee_owner
  ON employee_owner.legacy_id = CASE
      WHEN btrim(cs.emp_id) ~ '^[0-9]{1,9}$'
          THEN NULLIF(btrim(cs.emp_id)::int, 0)
      ELSE NULL
  END
LEFT JOIN settlement_matches settlement_match
  ON settlement_match.legacy_id = cs.price_style;

-- Preserve every unresolved non-null legacy default as reconciliation
-- evidence.  Online services remain fail-closed until an explicit UUID is
-- chosen (or the default is explicitly cleared).
INSERT INTO client_default_settlement_migration_issues
    (client_id, legacy_price_style, issue_code, active_match_count)
SELECT client.id,
       client.price_style,
       CASE WHEN count(method.id) = 0
            THEN 'MISSING_ACTIVE_METHOD'
            ELSE 'AMBIGUOUS_ACTIVE_METHOD'
       END,
       count(method.id)::INT
FROM clients client
LEFT JOIN settlement_methods method
  ON method.legacy_id = client.price_style
 AND method.status = '使用'
 AND COALESCE(method.is_deleted, FALSE) = FALSE
WHERE client.price_style IS NOT NULL
  AND client.default_settlement_method_id IS NULL
GROUP BY client.id, client.price_style;

COMMIT;

SELECT '✔ 客户 ' || count(*) ||
       '，已挂分类 ' || count(category_id) ||
       '，未挂分类 ' || count(*) FILTER (WHERE category_id IS NULL) ||
       '，使用 ' || count(*) FILTER (WHERE status = N'使用') ||
       '，禁用 ' || count(*) FILTER (WHERE status = N'禁用') AS 结果
FROM clients;

SELECT '待人工分类客户 ' || count(*) AS 货款类型迁移结果
FROM v_client_sales_payment_type_migration_issues;
