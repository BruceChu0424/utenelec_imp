-- V381: post-apply fail-closed customer advance governance.
DO $$
DECLARE v_definition TEXT;
BEGIN
    IF NOT EXISTS(
        SELECT 1 FROM system_posting_style_roles role
        JOIN payment_styles style ON style.id=role.style_id
        WHERE role.role_key='CUSTOMER_ADVANCE'
          AND role.style_id='37900000-0000-4000-8100-000000000001'::UUID
          AND role.required_category='LIABILITY' AND style.category='LIABILITY'
          AND style.status='使用' AND COALESCE(style.is_deleted,FALSE)=FALSE) THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='CUSTOMER_ADVANCE role is missing, inactive, or mapped to an unreviewed UUID';
    END IF;
    SELECT pg_get_functiondef(p.oid) INTO v_definition
    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname='fn_derive_ar_ap_open_item_metadata';
    IF v_definition IS NULL OR position('CUSTOMER_PREPAYMENT' IN v_definition)=0
       OR position('DIRECT_RECEIPT' IN v_definition)=0 THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='AR open-item derivation does not classify direct receipts as customer prepayments';
    END IF;
    IF NOT EXISTS(SELECT 1 FROM pg_constraint
                  WHERE conrelid='customer_open_item_offsets'::regclass
                    AND conname='customer_offsets_fx_identity_chk' AND convalidated)
       OR NOT EXISTS(SELECT 1 FROM pg_trigger
                  WHERE tgrelid='customer_open_item_offsets'::regclass
                    AND tgname='trg_guard_customer_open_item_offset' AND tgenabled IN('O','A'))
       OR NOT EXISTS(SELECT 1 FROM pg_trigger
                  WHERE tgrelid='finance_receipt_source_allocations'::regclass
                    AND tgname='trg_receipt_source_allocation_conservation' AND tgenabled IN('O','A'))
       OR NOT EXISTS(SELECT 1 FROM pg_trigger
                  WHERE tgrelid='finance_receipt_lines'::regclass
                    AND tgname='trg_finance_receipt_lines_kind' AND tgenabled IN('O','A'))
       OR NOT EXISTS(SELECT 1 FROM pg_trigger
                  WHERE tgrelid='finance_receipt_source_allocations'::regclass
                    AND tgname='trg_receipt_source_ref_capacity' AND tgenabled IN('O','A'))
       OR NOT EXISTS(SELECT 1 FROM pg_trigger
                  WHERE tgrelid='customer_open_item_offsets'::regclass
                    AND tgname='trg_customer_offset_source_ref_capacity' AND tgenabled IN('O','A'))
       OR NOT EXISTS(SELECT 1 FROM pg_trigger
                  WHERE tgrelid='finance_receipts'::regclass
                    AND tgname='trg_guard_finance_receipt_money_fact' AND tgenabled IN('O','A'))
       OR NOT EXISTS(SELECT 1 FROM pg_trigger
                  WHERE tgrelid='customer_open_item_offset_batches'::regclass
                    AND tgname='trg_guard_customer_offset_batch_immutable' AND tgenabled IN('O','A'))
       OR NOT EXISTS(SELECT 1 FROM pg_trigger
                  WHERE tgrelid='customer_open_item_offsets'::regclass
                    AND tgname='trg_guard_customer_offset_line_immutable' AND tgenabled IN('O','A'))
       OR NOT EXISTS(SELECT 1 FROM pg_trigger
                  WHERE tgrelid='finance_receipt_source_allocations'::regclass
                    AND tgname='trg_guard_receipt_source_allocation_immutable' AND tgenabled IN('O','A')) THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='customer offset or receipt-source conservation guards are missing';
    END IF;
    IF EXISTS(
        SELECT required.relname FROM(VALUES
          ('customer_open_item_offset_batches'),('customer_open_item_offsets'),
          ('finance_receipt_source_allocations')) required(relname)
        WHERE NOT EXISTS(
          SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
          JOIN pg_trigger t ON t.tgrelid=c.oid JOIN pg_proc p ON p.oid=t.tgfoid
          WHERE n.nspname='public' AND c.relname=required.relname
            AND NOT t.tgisinternal AND t.tgname LIKE 'trg_audit%'
            AND p.proname IN('fn_audit','fn_audit_redacted') AND t.tgenabled IN('O','A'))) THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='new customer prepayment tables are missing active audit triggers';
    END IF;
END $$;
