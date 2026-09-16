-- V594: 修生产日报审核/红冲 500。
--
-- V583 让日报审核在同一事务里先 INSERT 结算事件行、再回填
-- production_material_settlement_events.daily_report_id（红冲反查依据），
-- 但 V161 的只增不改守卫对四张 ledger 表的一切 UPDATE 无差别 RAISE，
-- 于是「审核带实际用料的日报」在补链那一步必然 500。
--
-- 放宽口径（唯一放行形态）：UPDATE 仅当 daily_report_id 从 NULL 首次回填、
-- 其余列逐列不变。这是给同事务内刚插入的事件行补来源，不改写任何已过账
-- 事实；DELETE、改已回填的来源、顺带改其它列，以及另外三张没有该列的
-- ledger 表（stock_events/stock_postings/settlement_postings）的一切
-- UPDATE/DELETE，仍按 V161 原样拒绝。比较用 to_jsonb(行) 去掉
-- daily_report_id 键后整行 IS NOT DISTINCT FROM，未来加列自动纳入约束。

CREATE OR REPLACE FUNCTION fn_reject_production_material_ledger_mutation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'UPDATE'
       AND to_jsonb(NEW) ? 'daily_report_id'
       AND to_jsonb(OLD) ->> 'daily_report_id' IS NULL
       AND to_jsonb(NEW) ->> 'daily_report_id' IS NOT NULL
       AND to_jsonb(NEW) - 'daily_report_id' IS NOT DISTINCT FROM
           to_jsonb(OLD) - 'daily_report_id'
    THEN
        RETURN NEW;
    END IF;
    RAISE EXCEPTION USING
        ERRCODE = '55000',
        MESSAGE = format(
            '%s is an append-only production material ledger; %s is forbidden',
            TG_TABLE_NAME,
            TG_OP
        ),
        DETAIL = 'Accepted production material events and postings are immutable.',
        HINT = 'Append the matching reversal event and posting instead.',
        CONSTRAINT = TG_TABLE_NAME || '_append_only_guard';
    RETURN NULL;
END;
$$;

COMMENT ON FUNCTION fn_reject_production_material_ledger_mutation() IS
    'Reject UPDATE/DELETE on production material ledgers; corrections append reversal facts. V594 唯一放行：settlement_events.daily_report_id 的 NULL→值 首次回填（日报审核/红冲同事务补链），其余一切 UPDATE/DELETE 仍拒绝。';
