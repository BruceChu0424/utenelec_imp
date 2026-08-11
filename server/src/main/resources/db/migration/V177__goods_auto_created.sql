-- =====================================================================
-- V177：goods 表加 auto_created 列（迁移/运行时兜底占位货品标记）。
-- 范式同 V43__warehouse.sql:23 / currencies / accounts / payment_styles。
-- 日常识别走本列（不依赖 name 字符串）；本次回填靠 name 模式 + code 前缀（一次性）。
-- =====================================================================

ALTER TABLE goods ADD COLUMN auto_created BOOLEAN NOT NULL DEFAULT FALSE;

COMMENT ON COLUMN goods.auto_created IS '迁移/运行时自动补录（兜底占位货品；事后人工补全）';

-- 回填：老库单据明细引用了 B_Goods 不存在的货品号时，迁移脚本建的占位 stub。
--   委外 migrate_subcontract.sql:229  → name '(migration auto-stub legacy N)'
--   生产 migrate_production.sql:106    → name '（迁移自动补录 legacy N）'
--   仓库 migrate_stock_docs.sql:102    → name '（迁移自动补录 legacy N）'
--   销售 migrate_sales.sql:164         → name '（迁移自动补录）' + code 'LEGACY-G-N'（实测新库=0，保留条件）
-- 实测命中 31 条（委外 1 + 生产/仓库 30）。重跑幂等（UPDATE 命中的本就是 FALSE）。
UPDATE goods SET auto_created = TRUE
WHERE name LIKE '(migration auto-stub legacy %'
   OR name LIKE '（迁移自动补录 legacy %'
   OR (name = '（迁移自动补录）' AND code LIKE 'LEGACY-G-%');

-- 校验（日志可见）：SELECT count(*) FROM goods WHERE auto_created;  -- 期望 31
