-- =====================================================================
-- V457：货品新增「后模镶件编号」独立字段
-- =====================================================================
-- 背景：部分模具生产不同货品时需要更换后模镶件，模具师傅经常换错。老系统里
--   该信息只写在货品备注（B_Goods.Paper → goods.paper，自由文本如
--   「换后模平镶件」「换后模45A镶件」「换后模1M仁镶件」），不结构化、
--   无法筛选/打印。新字段挂在模具编号之后，作为生产该货品时需使用的
--   后模镶件标识（模具师傅对板换件依据）。
-- 设计：
-- ① goods.rear_insert_code varchar(100)：自由文本短码（如 平 / 45A / 1M仁 / V7-012），
--    不建镶件主档（现网写法五花八门，先落结构化短码，后续如需字典再升位）。
-- ② 存量回填：从老备注 paper 里保守解析「后模」专属写法，能确定镶件标识才回填；
--    「换镶件」「换6M镶件」等未点明后模的写法保持 NULL（备注原文不动，人工补录）。
-- ③ 老库重迁移（migrate_goods_data.sql）同规则解析，保证将来从老库刷新数据口径一致。
-- =====================================================================

ALTER TABLE goods
    ADD COLUMN IF NOT EXISTS rear_insert_code varchar(100);

-- 写法一：「换后模平镶件」→ 平；「换后模45A镶件」→ 45A；「换后模1M仁镶件」→ 1M仁。
UPDATE goods
SET rear_insert_code = NULLIF(substring(paper FROM '换后模(.{1,30}?)镶件'), '')
WHERE rear_insert_code IS NULL
  AND paper IS NOT NULL
  AND paper LIKE '%换后模%';

-- 写法二：「后模镶件用V7-012」→ V7-012（前模芯 V7-0xx 系列换芯单的配套写法）。
UPDATE goods
SET rear_insert_code = NULLIF(substring(paper FROM '后模镶件用([^ \t，。;；]{1,30})'), '')
WHERE rear_insert_code IS NULL
  AND paper IS NOT NULL
  AND paper LIKE '%后模镶件用%';
