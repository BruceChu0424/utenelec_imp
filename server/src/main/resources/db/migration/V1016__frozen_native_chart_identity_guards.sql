-- A native approval may freeze its account before its GL is generated. It is
-- already a used accounting identity; absence of a GL allocation is not consent
-- to retag the approved source's book currency or remove its actual style.
CREATE VIEW v_finance_native_frozen_accounts AS
 SELECT account_snapshot AS account FROM finance_native_debt_accounts
 UNION ALL SELECT counterpart_snapshot FROM finance_native_debt_accounts WHERE counterpart_snapshot IS NOT NULL
 UNION ALL SELECT account_snapshot FROM finance_native_cash_debt_parts
 UNION ALL SELECT account_snapshot FROM finance_native_cash_accounts
 UNION ALL SELECT source_account FROM finance_native_supplier_offset_journals
 UNION ALL SELECT target_account FROM finance_native_supplier_offset_journals
 UNION ALL SELECT source_account FROM finance_native_customer_offset_accounts
 UNION ALL SELECT target_account FROM finance_native_customer_offset_accounts;

CREATE FUNCTION fn_guard_finance_used_chart_currency()RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF NEW.currency_id IS NOT DISTINCT FROM OLD.currency_id THEN RETURN NEW;END IF;
 IF EXISTS(SELECT 1 FROM finance_gl_entry_allocations allocation
       WHERE allocation.account_code=OLD.code AND allocation.currency_id IS DISTINCT FROM NEW.currency_id)
   OR EXISTS(SELECT 1 FROM v_finance_native_frozen_accounts source
       WHERE source.account->>'accountCode'=OLD.code
         AND source.account->>'accountingCurrencyId' IS NOT NULL
         AND source.account->>'accountingCurrencyId' IS DISTINCT FROM NEW.currency_id::text) THEN
  RAISE EXCEPTION '该代码已被正式来源或原业务审核冻结币别属性；请保留原身份，另建明确科目明细或按原来源受控更正'
    USING ERRCODE='23514';END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER trg_finance_used_chart_currency BEFORE UPDATE OF currency_id ON finance_chart_codes
 FOR EACH ROW EXECUTE FUNCTION fn_guard_finance_used_chart_currency();

CREATE FUNCTION fn_guard_finance_used_chart_style()RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF EXISTS(SELECT 1 FROM finance_gl_entry_allocations allocation JOIN gl_entries entry ON entry.id=allocation.entry_id
       WHERE allocation.account_code=OLD.code AND entry.style_id=OLD.style_id)
   OR EXISTS(SELECT 1 FROM v_finance_native_frozen_accounts source
       WHERE source.account->>'accountCode'=OLD.code AND source.account->>'styleId'=OLD.style_id::text) THEN
  RAISE EXCEPTION '该系统科目与代码的关系已有明确来源，不能直接移除；请保留原对应并从原来源受控更正'
    USING ERRCODE='23514';END IF;
 RETURN OLD;
END $$;
CREATE TRIGGER trg_finance_used_chart_style BEFORE DELETE ON finance_chart_code_styles
 FOR EACH ROW EXECUTE FUNCTION fn_guard_finance_used_chart_style();
