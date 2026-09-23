-- V666 (ADR-112): 到货超量异常的金额快照改为精确列。
--
-- procurement_arrival_exceptions 的单价/到货金额/超量金额快照还停在 NUMERIC(18,4): 收货行金额是
-- 数量 × 单价 × 汇率的完整乘积, 超量金额按 MoneyPolicy 累计份额取到来源金额自身位数, 写进 4 位列会被
-- PostgreSQL 悄悄四舍五入, 财务审批看到的超量金额与收货事实对不上。
-- 复用 V518 的 fn_migrate_financial_amount_columns: 改成无精度 NUMERIC 并挂精确性检查(实际金额 24 位 /
-- 本币账面 30 位); 依赖视图、列触发器、属主与授权原样重建。已有值都是 4 位以内, 不改写任何数据。
SELECT fn_migrate_financial_amount_columns('[
  {"table":"procurement_arrival_exceptions","column":"unit_price_snapshot"},
  {"table":"procurement_arrival_exceptions","column":"declared_amount_original_snapshot"},
  {"table":"procurement_arrival_exceptions","column":"declared_amount_local_snapshot","kind":"book"},
  {"table":"procurement_arrival_exceptions","column":"excess_amount_local_snapshot","kind":"book"}
]'::jsonb);
