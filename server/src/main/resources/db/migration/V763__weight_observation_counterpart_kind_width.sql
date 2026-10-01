-- V743 的 CHECK 与业务接口允许 SUBCONTRACTOR (13 个字符), 原 VARCHAR(12)
-- 会使带实称重量的委外出仓审核在追加称重观测时回滚。保持原值域、历史记录与来源语义,
-- 只扩大字段宽度; 不修改已应用的 V743。
ALTER TABLE goods_weight_observations
    ALTER COLUMN counterpart_kind TYPE VARCHAR(32);
