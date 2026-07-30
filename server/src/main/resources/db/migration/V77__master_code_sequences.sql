-- =====================================================================
-- V77：主档编号自动生成序列表 + 全局唯一约束 + 状态取值域（MasterCodeService）
-- =====================================================================
-- 目的：基础资料（货品/模具/客户/供应商/颜色/单位/币种/仓库/账户/收付款类别）
--   共 10 个主档，编号(code) 改由后端 Service.create() 原子生成，格式 [2位前缀][6位顺序号]，
--   如 HP000001（货品）。前缀为拼音首字母，已验证与全部遗留 code 零碰撞（^前缀[0-9]{6}$ 计数=0）。
--
-- 全局唯一（含历史数据）：每表加**全表唯一索引** WHERE is_deleted = false ——
--   所有未软删记录（含老库遗留）code 必须唯一。PG 唯一索引允许多个 NULL，故 null-code 行不冲突。
--   历史遗留中的真实重复 code（颜色22/收付款95/账户15/模具1/客户1）在此迁移内**就地 renumber**：
--   每个 code 保留首条（MIN id），其余改成 [前缀][6位] 唯一新号；货品无非空重复（31 个 null 不影响）。
--   **引用安全**：所有跨表引用走 UUID id 或整型 legacy_id（如 goods.color_legacy_id、*_items.color_id），
--   无任何表按 code 引用主档——renumber 只改显示编号，不动 id/legacy_id，引用恒正确。
--   （code '01' 下挂 18 个不同颜色名，证明是不同色碰巧同号 → renumber 而非 merge。）
--
-- 序列播种：renumber 用掉的 [前缀][6位] 号回填 master_code_sequences.last_seq，
--   保证后续 Service 自动取号从其后继起，永不撞已 renumber 的号。
--
-- 状态取值域：每表加 CHECK(status IS NULL OR status IN ('使用','禁用'))。
--   payment_styles 老库为英文 'In Use'，先归一为 '使用' 再加约束（否则 CHECK 失败致后端起不来）。
--
-- 全仓迁移惯例：不加 GRANT。事务性 DDL，失败不留半拉。
-- 详见 plans/cuddly-booping-prism.md。
-- =====================================================================

CREATE TABLE master_code_sequences (
    prefix      TEXT NOT NULL,            -- 2 字符，如 'HP'
    last_seq    INTEGER NOT NULL DEFAULT 0,
    CONSTRAINT pk_master_code_sequences PRIMARY KEY (prefix)
);

COMMENT ON TABLE master_code_sequences IS '主档编号序列；每 prefix 一行，MasterCodeService 原子自增，格式 [prefix][6位].';

-- 10 个主档前缀（拼音首字母，已验证与遗留 code 零碰撞）。
INSERT INTO master_code_sequences (prefix, last_seq) VALUES
    ('HP', 0),  -- 货品 goods
    ('MJ', 0),  -- 模具 moulds
    ('KH', 0),  -- 客户 clients
    ('GY', 0),  -- 供应商 suppliers
    ('YS', 0),  -- 颜色 colors
    ('DW', 0),  -- 单位 units
    ('BZ', 0),  -- 币种 currencies
    ('WH', 0),  -- 仓库 warehouses
    ('ZH', 0),  -- 账户 accounts
    ('SK', 0);  -- 收付款类别 payment_styles

-- ====================== 状态归一：payment_styles 'In Use' → '使用' ======================
UPDATE payment_styles SET status = '使用' WHERE status = 'In Use';

-- ====================== 历史重复 code 就地 renumber（保留首条，其余改唯一新号） ======================
-- 模板：每个 code 保留 MIN(id) 那条，其余（prn>1）按序赋 [前缀][6位]。仅处理 is_deleted=false 且非空。
-- 引用走 id/legacy_id，不动 id，故 renumber 零引用风险。

-- 颜色 colors（前缀 YS）
WITH ranked AS (
    SELECT id, code, ROW_NUMBER() OVER (PARTITION BY code ORDER BY id) AS prn
    FROM colors WHERE is_deleted = false AND code IS NOT NULL
),
renumber AS (
    SELECT id, ROW_NUMBER() OVER (ORDER BY code, id) AS seq FROM ranked WHERE prn > 1
)
UPDATE colors SET code = 'YS' || lpad(renumber.seq::text, 6, '0')
FROM renumber WHERE colors.id = renumber.id;

-- 模具 moulds（前缀 MJ）
WITH ranked AS (
    SELECT id, code, ROW_NUMBER() OVER (PARTITION BY code ORDER BY id) AS prn
    FROM moulds WHERE is_deleted = false AND code IS NOT NULL
),
renumber AS (
    SELECT id, ROW_NUMBER() OVER (ORDER BY code, id) AS seq FROM ranked WHERE prn > 1
)
UPDATE moulds SET code = 'MJ' || lpad(renumber.seq::text, 6, '0')
FROM renumber WHERE moulds.id = renumber.id;

-- 客户 clients（前缀 KH）
WITH ranked AS (
    SELECT id, code, ROW_NUMBER() OVER (PARTITION BY code ORDER BY id) AS prn
    FROM clients WHERE is_deleted = false AND code IS NOT NULL
),
renumber AS (
    SELECT id, ROW_NUMBER() OVER (ORDER BY code, id) AS seq FROM ranked WHERE prn > 1
)
UPDATE clients SET code = 'KH' || lpad(renumber.seq::text, 6, '0')
FROM renumber WHERE clients.id = renumber.id;

-- 账户 accounts（前缀 ZH）
WITH ranked AS (
    SELECT id, code, ROW_NUMBER() OVER (PARTITION BY code ORDER BY id) AS prn
    FROM accounts WHERE is_deleted = false AND code IS NOT NULL
),
renumber AS (
    SELECT id, ROW_NUMBER() OVER (ORDER BY code, id) AS seq FROM ranked WHERE prn > 1
)
UPDATE accounts SET code = 'ZH' || lpad(renumber.seq::text, 6, '0')
FROM renumber WHERE accounts.id = renumber.id;

-- 收付款类别 payment_styles（前缀 SK）
WITH ranked AS (
    SELECT id, code, ROW_NUMBER() OVER (PARTITION BY code ORDER BY id) AS prn
    FROM payment_styles WHERE is_deleted = false AND code IS NOT NULL
),
renumber AS (
    SELECT id, ROW_NUMBER() OVER (ORDER BY code, id) AS seq FROM ranked WHERE prn > 1
)
UPDATE payment_styles SET code = 'SK' || lpad(renumber.seq::text, 6, '0')
FROM renumber WHERE payment_styles.id = renumber.id;

-- ====================== 序列播种：renumber 用掉的号回填 last_seq（自动取号从其后起） ======================
-- renumber 用 ROW_NUMBER() 产生连续 [前缀][6位]（1..N），故「该前缀 6 位号计数」= 已用最大序号；
-- 遗留数据已验证无 ^前缀[0-9]{6}$ 命中（零碰撞），故计数即 renumber 数。用 ~ 布尔匹配（无捕获组）。
UPDATE master_code_sequences SET last_seq = GREATEST(last_seq, (SELECT count(*) FROM goods          WHERE code ~ '^HP[0-9]{6}$' AND is_deleted = false)) WHERE prefix = 'HP';
UPDATE master_code_sequences SET last_seq = GREATEST(last_seq, (SELECT count(*) FROM moulds         WHERE code ~ '^MJ[0-9]{6}$' AND is_deleted = false)) WHERE prefix = 'MJ';
UPDATE master_code_sequences SET last_seq = GREATEST(last_seq, (SELECT count(*) FROM clients        WHERE code ~ '^KH[0-9]{6}$' AND is_deleted = false)) WHERE prefix = 'KH';
UPDATE master_code_sequences SET last_seq = GREATEST(last_seq, (SELECT count(*) FROM suppliers      WHERE code ~ '^GY[0-9]{6}$' AND is_deleted = false)) WHERE prefix = 'GY';
UPDATE master_code_sequences SET last_seq = GREATEST(last_seq, (SELECT count(*) FROM colors         WHERE code ~ '^YS[0-9]{6}$' AND is_deleted = false)) WHERE prefix = 'YS';
UPDATE master_code_sequences SET last_seq = GREATEST(last_seq, (SELECT count(*) FROM units          WHERE code ~ '^DW[0-9]{6}$' AND is_deleted = false)) WHERE prefix = 'DW';
UPDATE master_code_sequences SET last_seq = GREATEST(last_seq, (SELECT count(*) FROM currencies     WHERE code ~ '^BZ[0-9]{6}$' AND is_deleted = false)) WHERE prefix = 'BZ';
UPDATE master_code_sequences SET last_seq = GREATEST(last_seq, (SELECT count(*) FROM warehouses     WHERE code ~ '^WH[0-9]{6}$' AND is_deleted = false)) WHERE prefix = 'WH';
UPDATE master_code_sequences SET last_seq = GREATEST(last_seq, (SELECT count(*) FROM accounts       WHERE code ~ '^ZH[0-9]{6}$' AND is_deleted = false)) WHERE prefix = 'ZH';
UPDATE master_code_sequences SET last_seq = GREATEST(last_seq, (SELECT count(*) FROM payment_styles WHERE code ~ '^SK[0-9]{6}$' AND is_deleted = false)) WHERE prefix = 'SK';

-- ====================== 全表唯一索引（仅约束未软删记录；PG 允许多 NULL） ======================
CREATE UNIQUE INDEX goods_code_uq            ON goods(code)           WHERE is_deleted = false;
CREATE UNIQUE INDEX moulds_code_uq           ON moulds(code)          WHERE is_deleted = false;
CREATE UNIQUE INDEX clients_code_uq          ON clients(code)         WHERE is_deleted = false;
CREATE UNIQUE INDEX suppliers_code_uq        ON suppliers(code)       WHERE is_deleted = false;
CREATE UNIQUE INDEX colors_code_uq           ON colors(code)          WHERE is_deleted = false;
CREATE UNIQUE INDEX units_code_uq            ON units(code)           WHERE is_deleted = false;
CREATE UNIQUE INDEX currencies_code_uq       ON currencies(code)      WHERE is_deleted = false;
CREATE UNIQUE INDEX warehouses_code_uq       ON warehouses(code)      WHERE is_deleted = false;
CREATE UNIQUE INDEX accounts_code_uq         ON accounts(code)        WHERE is_deleted = false;
CREATE UNIQUE INDEX payment_styles_code_uq   ON payment_styles(code)  WHERE is_deleted = false;

-- ====================== 状态取值域 CHECK（NULL 放行） ======================
ALTER TABLE goods          ADD CONSTRAINT goods_status_chk          CHECK (status IS NULL OR status IN ('使用','禁用'));
ALTER TABLE moulds         ADD CONSTRAINT moulds_status_chk         CHECK (status IS NULL OR status IN ('使用','禁用'));
ALTER TABLE clients        ADD CONSTRAINT clients_status_chk        CHECK (status IS NULL OR status IN ('使用','禁用'));
ALTER TABLE suppliers      ADD CONSTRAINT suppliers_status_chk      CHECK (status IS NULL OR status IN ('使用','禁用'));
ALTER TABLE colors         ADD CONSTRAINT colors_status_chk         CHECK (status IS NULL OR status IN ('使用','禁用'));
ALTER TABLE units          ADD CONSTRAINT units_status_chk          CHECK (status IS NULL OR status IN ('使用','禁用'));
ALTER TABLE currencies     ADD CONSTRAINT currencies_status_chk     CHECK (status IS NULL OR status IN ('使用','禁用'));
ALTER TABLE warehouses     ADD CONSTRAINT warehouses_status_chk     CHECK (status IS NULL OR status IN ('使用','禁用'));
ALTER TABLE accounts       ADD CONSTRAINT accounts_status_chk       CHECK (status IS NULL OR status IN ('使用','禁用'));
ALTER TABLE payment_styles ADD CONSTRAINT payment_styles_status_chk CHECK (status IS NULL OR status IN ('使用','禁用'));
