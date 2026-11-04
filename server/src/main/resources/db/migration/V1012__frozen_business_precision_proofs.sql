-- Keep existing frozen arithmetic proofs verifiable. New business calculations
-- have an explicit policy snapshot; historic rows remain NULL and retain v1.
CREATE FUNCTION fn_guard_business_precision_policy() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE changed boolean;
BEGIN
 IF TG_OP='INSERT' THEN
  IF NEW.business_precision_policy IS NOT NULL
    AND NEW.business_precision_policy<>fn_business_precision_snapshot() THEN
   RAISE EXCEPTION 'precision policy must come from the current business operation' USING ERRCODE='23514';END IF;
  NEW.business_precision_policy:=fn_business_precision_snapshot();
 ELSE
  IF NEW.business_precision_policy IS DISTINCT FROM OLD.business_precision_policy THEN
   RAISE EXCEPTION 'frozen precision policy cannot be independently edited' USING ERRCODE='55000';END IF;
  -- A draft may be edited before posting. A state/confirmation/reversal change
  -- alone does not retag an old immutable amount with a new user's choices.
  SELECT EXISTS(SELECT 1 FROM pg_attribute a WHERE a.attrelid=TG_RELID
    AND a.attnum>0 AND NOT a.attisdropped AND a.atttypid='numeric'::regtype
    AND (to_jsonb(NEW)->a.attname) IS DISTINCT FROM (to_jsonb(OLD)->a.attname)) INTO changed;
  IF changed THEN NEW.business_precision_policy:=fn_business_precision_snapshot();END IF;
 END IF;
 RETURN NEW;
END $$;

DO $frozen_row_precision$
DECLARE target text;
BEGIN
 FOREACH target IN ARRAY ARRAY['finance_receipt_lines','finance_payment_lines',
   'finance_receipt_source_allocations','customer_open_item_offsets','supplier_open_item_offsets'] LOOP
  EXECUTE format('ALTER TABLE public.%I ADD COLUMN business_precision_policy jsonb',target);
  EXECUTE format('CREATE TRIGGER trg_00_business_precision_policy BEFORE INSERT OR UPDATE ON public.%I FOR EACH ROW EXECUTE FUNCTION fn_guard_business_precision_policy()',target);
  EXECUTE format('ALTER TABLE public.%I ENABLE ALWAYS TRIGGER trg_00_business_precision_policy',target);
 END LOOP;
END; $frozen_row_precision$;

-- Replace only verification calls. Creation still uses the current operation's
-- exact calculation and cannot borrow the historic v1 truncation algorithm.
DO $frozen_precision_verification$
DECLARE definition text;changed text;old_call text;new_call text;item record;
BEGIN
 FOR item IN SELECT * FROM (VALUES
   ('fn_assert_finance_receipt_v1_lines(uuid)',
    'fn_financial_book_part(l.amount_original,bank_a,bank_b)',
    'fn_financial_book_part_proof(l.amount_original,bank_a,bank_b,l.business_precision_policy)'),
   ('fn_assert_finance_receipt_v1_lines(uuid)',
    'fn_financial_book_part(l.amount_original,l.balance_before_original,l.book_balance_before_local)',
    'fn_financial_book_part_proof(l.amount_original,l.balance_before_original,l.book_balance_before_local,l.business_precision_policy)'),
   ('fn_assert_payment_v2_terminal(uuid)',
    'fn_financial_book_part(l.amount_original,a,b)',
    'fn_financial_book_part_proof(l.amount_original,a,b,l.business_precision_policy)'),
   ('fn_assert_payment_v2_terminal(uuid)',
    'fn_financial_book_part(l.amount_original,l.balance_before_original,l.book_balance_before_local)',
    'fn_financial_book_part_proof(l.amount_original,l.balance_before_original,l.book_balance_before_local,l.business_precision_policy)'),
   ('fn_guard_receipt_v2_source_book_basis()',
    'fn_financial_book_part(allocated,before_a,before_b)',
    'fn_financial_book_part_proof(allocated,before_a,before_b,NEW.business_precision_policy)'),
   ('fn_assert_procurement_credit_book_plan(uuid)',
    'fn_financial_book_part((b->>''allocatedOriginal'')::numeric,(b->>''beforeOriginal'')::numeric,(b->>''beforeLocal'')::numeric)',
    'fn_financial_book_part_proof((b->>''allocatedOriginal'')::numeric,(b->>''beforeOriginal'')::numeric,(b->>''beforeLocal'')::numeric,p->''precisionPolicy'')')
 ) v(signature,old_call,new_call) LOOP
  SELECT pg_get_functiondef(item.signature::regprocedure) INTO definition;
  IF position(item.old_call IN definition)=0 THEN
   IF position(item.new_call IN definition)>0 THEN CONTINUE;END IF;
   RAISE EXCEPTION 'Review changed precision proof function: %',item.signature;END IF;
  EXECUTE replace(definition,item.old_call,item.new_call);
 END LOOP;

 SELECT pg_get_functiondef('fn_plan_procurement_credit_book(uuid,numeric)'::regprocedure) INTO definition;
 IF position('''precisionPolicy''' IN definition)=0 THEN
  old_call:='''basis'',basis)';
  new_call:='''basis'',basis,''precisionPolicy'',fn_business_precision_snapshot())';
  IF position(old_call IN definition)=0 THEN RAISE EXCEPTION 'Review changed procurement credit precision snapshot';END IF;
  EXECUTE replace(definition,old_call,new_call);
 END IF;

 SELECT pg_get_constraintdef(oid) INTO definition FROM pg_constraint
   WHERE conrelid='customer_open_item_offsets'::regclass AND conname='customer_offsets_rate_identity_chk';
 IF definition IS NULL THEN RAISE EXCEPTION 'Customer allocation precision proof constraint missing';END IF;
 changed:=replace(definition,
   'fn_financial_book_part(amount_original, abs(source_balance_before_original), abs(source_balance_before_local))',
   'fn_financial_book_part_proof(amount_original, abs(source_balance_before_original), abs(source_balance_before_local),business_precision_policy)');
 changed:=replace(changed,
   'fn_financial_book_part(amount_original, target_ref_balance_before_original, target_ref_balance_before_local)',
   'fn_financial_book_part_proof(amount_original, target_ref_balance_before_original, target_ref_balance_before_local,business_precision_policy)');
 IF changed=definition OR position('fn_financial_book_part(' IN changed)>0 THEN
  RAISE EXCEPTION 'Review changed customer allocation precision proof';END IF;
 ALTER TABLE customer_open_item_offsets DROP CONSTRAINT customer_offsets_rate_identity_chk;
 EXECUTE 'ALTER TABLE customer_open_item_offsets ADD CONSTRAINT customer_offsets_rate_identity_chk '||changed;
END; $frozen_precision_verification$;
