-- =====================================================================
-- 客户主档迁移：CSV → clients（不依赖 server 启动）
-- =====================================================================
-- 用法：bash server/legacy_migration/migrate.sh --client-data
-- 前提：clients 表已存在（V36 由 server Flyway 创建）；client_categories 已迁。
-- 来源：老库 B_Client（260 条），category_id 关联 client_categories.legacy_id
--   （B_Client.ParentID → SystemItem.ItemID ItemclassID=2）。6 条 ParentID=0（未分组）
--   → category_id 置 NULL（前端"全部客户"视图可见）。字段语义见 V36。
-- staging 用真实类型，COPY csv 自动 cast + 空字段→null。
-- =====================================================================

BEGIN;
SET session_replication_role = replica;
TRUNCATE clients;
SET session_replication_role = DEFAULT;

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

INSERT INTO clients (
    legacy_id, category_id, name, code, full_name, client_rank,
    place_id, emp_id, legal_person, linkman, mobile, phone, phone2, fax, postcode, address,
    email, website, ship_via, ship_address, bank, bank_account, tax_id,
    credit, init_total, init_total2, exchange_rate, tday, price_style, zj_id,
    region, client_xz, status, remark
)
SELECT
    cs.legacy_id,
    (SELECT c.id FROM client_categories c WHERE c.legacy_id = cs.parent_legacy),
    cs.name, cs.code, cs.full_name, cs.client_rank,
    cs.place_id, cs.emp_id, cs.legal_person, cs.linkman, cs.mobile, cs.phone, cs.phone2,
    cs.fax, cs.postcode, cs.address, cs.email, cs.website, cs.ship_via, cs.ship_address,
    cs.bank, cs.bank_account, cs.tax_id, cs.credit, cs.init_total, cs.init_total2,
    cs.exchange_rate, cs.tday, cs.price_style, cs.zj_id, cs.region, cs.client_xz,
    cs.status, cs.remark
FROM client_stage cs;

COMMIT;

SELECT '✔ 客户 ' || count(*) ||
       '，已挂分类 ' || count(category_id) ||
       '，未挂分类 ' || count(*) FILTER (WHERE category_id IS NULL) ||
       '，使用 ' || count(*) FILTER (WHERE status = N'使用') ||
       '，禁用 ' || count(*) FILTER (WHERE status = N'禁用') AS 结果
FROM clients;
