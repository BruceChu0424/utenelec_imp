-- 恢复 AuditTriggerCoveragePostgresTest 钉住的终止核算台账守卫契约(V923/V929)：
-- V1011 的全目录 numeric 存储加宽在 procurement_order_termination_sources /
-- procurement_order_termination_peg_changes 两张冻结台账上额外加挂了五条
-- ck_financial_exact_* CHECK 约束（released_qty、released_gift_qty、
-- retained_physical_qty、unit_rate、qty_base），使 V928 之后真库的非审计
-- 触发器/约束集合偏离已审核的 V923 形态（「immutable/quantity/deferred
-- triggers and constraints must retain their exact definitions and enabled
-- state」）。V1011 已应用不可回改；两张表的行级守卫触发器经该迁移的
-- 原定义/原启用状态重建，内容未变，这里只需按确定性名称拆掉这五条
-- 未经终止台账评审的附加约束，回到 V923 守卫集。数量纪律仍由 V923 的
-- fn_guard_procurement_termination_source_fact 守恒核对与闭包余量比对承担；
-- 约束名按 fn_migrate_financial_amount_columns 的 md5 规则重算并逐一核对
-- 定义后才删除，绝不触碰其它任何约束或触发器。
DO $restore_termination_ledger_guards$
DECLARE
    spec record;
    constraint_name text;
    definition text;
BEGIN
    FOR spec IN SELECT * FROM (VALUES
        ('procurement_order_termination_sources','released_qty'),
        ('procurement_order_termination_sources','released_gift_qty'),
        ('procurement_order_termination_sources','retained_physical_qty'),
        ('procurement_order_termination_sources','unit_rate'),
        ('procurement_order_termination_peg_changes','qty_base'))
        AS target(table_name, column_name) LOOP
        constraint_name := 'ck_financial_exact_' || substr(md5('public.' || spec.table_name || '.' || spec.column_name), 1, 24);
        SELECT pg_get_constraintdef(oid) INTO definition
        FROM pg_constraint
        WHERE conrelid = format('public.%I', spec.table_name)::regclass
          AND conname = constraint_name AND contype = 'c';
        IF definition IS NULL THEN
            RAISE EXCEPTION 'termination ledger extra guard % not found on %', constraint_name, spec.table_name
                USING ERRCODE = '42P01';
        END IF;
        IF definition <> format('CHECK (fn_financial_amount_is_exact(%I))', spec.column_name) THEN
            RAISE EXCEPTION 'termination ledger constraint % differs from the V1011 exactness shape: %',
                constraint_name, definition USING ERRCODE = '42883';
        END IF;
        EXECUTE format('ALTER TABLE public.%I DROP CONSTRAINT %I', spec.table_name, constraint_name);
    END LOOP;
END;
$restore_termination_ledger_guards$;
