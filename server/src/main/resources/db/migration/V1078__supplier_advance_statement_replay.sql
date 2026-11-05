-- Native advances are assets, never synthetic negative AP.  Replay only their frozen bank/GL evidence.
CREATE FUNCTION fn_finance_supplier_advance_replayable(p_payment uuid)
RETURNS boolean LANGUAGE plpgsql STABLE AS $$
DECLARE p finance_payments%ROWTYPE;a finance_supplier_advances%ROWTYPE;o gl_vouchers%ROWTYPE;r gl_vouchers%ROWTYPE;
BEGIN
 SELECT * INTO p FROM finance_payments WHERE id=p_payment;
 SELECT * INTO a FROM finance_supplier_advances WHERE payment_id=p_payment;
 IF p.id IS NULL OR a.payment_id IS NULL OR p.amount_authority_version<>2 OR p.status NOT IN(1,-1)
   OR p.is_deleted OR p.legacy_id IS NOT NULL OR p.legacy_import_run_id IS NOT NULL
   OR (a.status='REVERSED' AND a.reversed_at IS DISTINCT FROM p.reversed_at) THEN RETURN false;END IF;
 -- These existing validators compare saved accounts/amounts, not today's default account roles.
 BEGIN
  PERFORM fn_assert_supplier_advance(p_payment);
  PERFORM fn_assert_payment_v2_terminal(p_payment);
 EXCEPTION WHEN check_violation THEN RETURN false;END;
 SELECT * INTO o FROM gl_vouchers WHERE source='AUTO' AND source_type='PAYMENT' AND source_doc_id=p.id AND status=1 AND NOT is_deleted;
 IF o.id IS NULL OR o.voucher_date IS DISTINCT FROM p.bill_date OR EXISTS(SELECT 1 FROM ar_ap_ledger WHERE source_doc_type='DIRECT_PAYMENT' AND source_doc_id=p.id) THEN RETURN false;END IF;
 IF NOT EXISTS(SELECT 1 FROM finance_gl_entry_allocations allocation JOIN gl_entries entry ON entry.id=allocation.entry_id
   WHERE entry.voucher_id=o.id AND entry.line_no=1 AND entry.style_id=a.style_id AND entry.direction=1
     AND allocation.account_code=a.account_code AND allocation.currency_id=a.accounting_currency_id
     AND allocation.original_currency_id=a.currency_id AND allocation.auxiliary_id=a.auxiliary_id
     AND (allocation.auxiliary_role,allocation.party_id_snapshot::text,allocation.source_system,allocation.source_code,allocation.source_name)
          IS NOT DISTINCT FROM(a.auxiliary_snapshot->>'role',a.auxiliary_snapshot->>'partyId',a.auxiliary_snapshot->>'sourceSystem',a.auxiliary_snapshot->>'sourceCode',a.auxiliary_snapshot->>'sourceName') AND allocation.amount_original=a.amount_original
     AND allocation.amount_local=a.amount_local) THEN RETURN false;END IF;
 IF p.status=-1 THEN
  SELECT * INTO r FROM gl_vouchers WHERE id=o.reversed_by_voucher_id AND source='AUTO' AND source_type='PAYMENT_REV'
    AND source_doc_id=p.id AND reversal_of_voucher_id=o.id AND status=1 AND NOT is_deleted;
  IF r.id IS NULL OR a.reversed_at IS NULL OR r.voucher_date IS DISTINCT FROM (a.reversed_at AT TIME ZONE 'Asia/Shanghai')::date
    OR EXISTS((SELECT line_no,style_id,-direction AS direction,amount FROM gl_entries WHERE voucher_id=o.id
       EXCEPT ALL SELECT line_no,style_id,direction,amount FROM gl_entries WHERE voucher_id=r.id)
      UNION ALL(SELECT line_no,style_id,direction,amount FROM gl_entries WHERE voucher_id=r.id
       EXCEPT ALL SELECT line_no,style_id,-direction,amount FROM gl_entries WHERE voucher_id=o.id))
    OR NOT EXISTS(SELECT 1 FROM finance_reconciliations forward JOIN finance_reconciliations backward ON backward.reversal_of_id=forward.id
       WHERE forward.source_doc_type='PAYMENT' AND forward.source_doc_id=p.id AND forward.entry_kind='POSTING' AND NOT forward.is_deleted
         AND backward.source_doc_type='PAYMENT' AND backward.source_doc_id=p.id AND backward.entry_kind='REVERSAL' AND NOT backward.is_deleted
         AND (backward.account_id,backward.account_currency_id,backward.in_amount,backward.out_amount,backward.amount_local,backward.bill_date)
          IS NOT DISTINCT FROM(forward.account_id,forward.account_currency_id,forward.out_amount,forward.in_amount,forward.amount_local,a.reversed_at))
    OR NOT EXISTS(SELECT 1 FROM finance_gl_entry_allocations allocation JOIN gl_entries entry ON entry.id=allocation.entry_id
       WHERE entry.voucher_id=r.id AND entry.line_no=1 AND entry.style_id=a.style_id AND entry.direction=-1
         AND allocation.account_code=a.account_code AND allocation.currency_id=a.accounting_currency_id
         AND allocation.original_currency_id=a.currency_id AND allocation.auxiliary_id=a.auxiliary_id
         AND (allocation.auxiliary_role,allocation.party_id_snapshot::text,allocation.source_system,allocation.source_code,allocation.source_name)
          IS NOT DISTINCT FROM(a.auxiliary_snapshot->>'role',a.auxiliary_snapshot->>'partyId',a.auxiliary_snapshot->>'sourceSystem',a.auxiliary_snapshot->>'sourceCode',a.auxiliary_snapshot->>'sourceName') AND allocation.amount_original=a.amount_original
         AND allocation.amount_local=a.amount_local) THEN RETURN false;END IF;
 END IF;
 RETURN true;
END $$;

-- The AP lane has only the target application; the source is an asset, not a second AP open item.
CREATE VIEW v_finance_supplier_advance_ap_events AS
 SELECT application.id,advance.payment_id,advance.supplier_id,advance.currency_id,application.target_ledger_id AS ledger_id,
   application.effective_date AS event_date,application.amount_original,application.target_local AS amount_local,
   application.source_reference AS remark,'预付应用'::text AS event_type,50 AS event_order
 FROM finance_supplier_advance_applications application JOIN finance_supplier_advances advance ON advance.payment_id=application.payment_id
 UNION ALL SELECT application.id,advance.payment_id,advance.supplier_id,advance.currency_id,application.target_ledger_id,
   (application.reversed_at AT TIME ZONE 'Asia/Shanghai')::date,-application.amount_original,-application.target_local,
   application.source_reference,'预付应用反转',70
 FROM finance_supplier_advance_applications application JOIN finance_supplier_advances advance ON advance.payment_id=application.payment_id
 WHERE application.status='REVERSED';

-- Positive means an increase in the unapplied asset.  Formal AP minus this stream is the original net statement.
CREATE VIEW v_finance_supplier_advance_asset_events AS
 SELECT advance.payment_id AS id,advance.payment_id,advance.supplier_id,advance.currency_id,payment.bill_no,
   advance.effective_date AS event_date,advance.amount_original,advance.amount_local,payment.remark,
   '预付资产增加'::text AS event_type,31 AS event_order
 FROM finance_supplier_advances advance JOIN finance_payments payment ON payment.id=advance.payment_id
 UNION ALL SELECT advance.payment_id,advance.payment_id,advance.supplier_id,advance.currency_id,payment.bill_no,
   (advance.reversed_at AT TIME ZONE 'Asia/Shanghai')::date,-advance.amount_original,-advance.amount_local,payment.remark,'预付资产反审',41
 FROM finance_supplier_advances advance JOIN finance_payments payment ON payment.id=advance.payment_id WHERE advance.status='REVERSED'
 UNION ALL SELECT application.id,advance.payment_id,advance.supplier_id,advance.currency_id,payment.bill_no,
   application.effective_date,-application.amount_original,-application.source_local,application.source_reference,'预付资产应用',61
 FROM finance_supplier_advance_applications application JOIN finance_supplier_advances advance ON advance.payment_id=application.payment_id
 JOIN finance_payments payment ON payment.id=advance.payment_id
 UNION ALL SELECT application.id,advance.payment_id,advance.supplier_id,advance.currency_id,payment.bill_no,
   (application.reversed_at AT TIME ZONE 'Asia/Shanghai')::date,application.amount_original,application.source_local,application.source_reference,'预付资产应用恢复',81
 FROM finance_supplier_advance_applications application JOIN finance_supplier_advances advance ON advance.payment_id=application.payment_id
 JOIN finance_payments payment ON payment.id=advance.payment_id WHERE application.status='REVERSED'
 UNION ALL SELECT refund.id,advance.payment_id,advance.supplier_id,advance.currency_id,payment.bill_no,
   refund.effective_date,-refund.amount_original,-refund.source_local,refund.source_reference,'预付资产退款',33
 FROM finance_supplier_advance_refunds refund JOIN finance_supplier_advances advance ON advance.payment_id=refund.payment_id
 JOIN finance_payments payment ON payment.id=advance.payment_id WHERE refund.status IN('APPROVED','REVERSED')
 UNION ALL SELECT refund.id,advance.payment_id,advance.supplier_id,advance.currency_id,payment.bill_no,
   (refund.reversed_at AT TIME ZONE 'Asia/Shanghai')::date,refund.amount_original,refund.source_local,refund.source_reference,'预付资产退款反审',43
 FROM finance_supplier_advance_refunds refund JOIN finance_supplier_advances advance ON advance.payment_id=refund.payment_id
 JOIN finance_payments payment ON payment.id=advance.payment_id WHERE refund.status='REVERSED';

CREATE FUNCTION fn_touch_party_summary_from_supplier_advance() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE source_id uuid;party uuid;effective date;reversed timestamptz;
BEGIN
 source_id:=COALESCE(NEW.payment_id,OLD.payment_id);
 SELECT supplier_id INTO party FROM finance_supplier_advances WHERE payment_id=source_id;
 IF TG_OP<>'INSERT' THEN
  effective:=OLD.effective_date;reversed:=OLD.reversed_at;
  PERFORM fn_touch_party_month_summary('AP',party,effective);
  PERFORM fn_touch_party_month_summary('AP',party,(reversed AT TIME ZONE 'Asia/Shanghai')::date);
 END IF;
 IF TG_OP<>'DELETE' THEN
  effective:=NEW.effective_date;reversed:=NEW.reversed_at;
  PERFORM fn_touch_party_month_summary('AP',party,effective);
  PERFORM fn_touch_party_month_summary('AP',party,(reversed AT TIME ZONE 'Asia/Shanghai')::date);
 END IF;
 RETURN NULL;
END $$;
CREATE TRIGGER trg_party_summary_supplier_advance AFTER INSERT OR UPDATE OR DELETE ON finance_supplier_advances
 FOR EACH ROW EXECUTE FUNCTION fn_touch_party_summary_from_supplier_advance();
CREATE TRIGGER trg_party_summary_supplier_advance_application AFTER INSERT OR UPDATE OR DELETE ON finance_supplier_advance_applications
 FOR EACH ROW EXECUTE FUNCTION fn_touch_party_summary_from_supplier_advance();
CREATE TRIGGER trg_party_summary_supplier_advance_refund AFTER INSERT OR UPDATE OR DELETE ON finance_supplier_advance_refunds
 FOR EACH ROW EXECUTE FUNCTION fn_touch_party_summary_from_supplier_advance();
INSERT INTO party_month_dirty(side,party_id,month_start,reason)
 SELECT DISTINCT 'AP',supplier_id,DATE '1900-01-01','NATIVE_SUPPLIER_CASH_REPLAY_V1078' FROM finance_supplier_advances
 UNION
 SELECT DISTINCT 'AP',supplier_id,DATE '1900-01-01','NATIVE_SUPPLIER_CASH_REPLAY_V1078' FROM finance_payments
 WHERE supplier_id IS NOT NULL AND status IN(1,-1) AND NOT is_deleted AND legacy_id IS NULL AND legacy_import_run_id IS NULL
   AND amount_authority_version IN(0,1)
 ON CONFLICT(side,party_id,month_start) DO UPDATE SET touched_at=clock_timestamp(),reason=EXCLUDED.reason;
CREATE INDEX idx_supplier_advance_party_date ON finance_supplier_advances(supplier_id,effective_date,payment_id);
