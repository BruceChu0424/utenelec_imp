-- Existing receivable and cash facts remain authoritative. These append-only
-- category assignments never create another receivable, bank flow or GL entry.
CREATE TABLE finance_receipt_classification_batches (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),request_id uuid NOT NULL UNIQUE,
 receipt_line_id uuid NOT NULL REFERENCES finance_receipt_lines(id),revision bigint NOT NULL CHECK(revision>=0),
 source_classification_id uuid NOT NULL REFERENCES finance_open_item_classification_batches(id),
 currency_id uuid NOT NULL REFERENCES currencies(id),
 amount_original numeric NOT NULL CHECK(amount_original>=0 AND fn_financial_amount_is_exact(amount_original)),
 write_off_original numeric NOT NULL CHECK(write_off_original>=0 AND fn_financial_amount_is_exact(write_off_original)),
 cash_local numeric NOT NULL CHECK(cash_local>=0 AND fn_financial_book_amount_is_exact(cash_local)),
 write_off_local numeric NOT NULL CHECK(write_off_local>=0 AND fn_financial_book_amount_is_exact(write_off_local)),
 book_local numeric NOT NULL CHECK(book_local>=0 AND fn_financial_book_amount_is_exact(book_local)),
 source_reference text NOT NULL CHECK(length(btrim(source_reference)) BETWEEN 1 AND 2000),
 fingerprint text NOT NULL CHECK(fingerprint~'^[0-9a-f]{64}$'),
 created_at timestamptz NOT NULL DEFAULT now(),created_by uuid NOT NULL REFERENCES users(id),
 created_tx xid8 NOT NULL DEFAULT pg_current_xact_id(),UNIQUE(receipt_line_id,revision)
);
CREATE TABLE finance_receipt_classification_parts (
 batch_id uuid NOT NULL REFERENCES finance_receipt_classification_batches(id),
 category text NOT NULL CHECK(category IN('GOODS','MATERIAL')),
 amount_original numeric NOT NULL CHECK(amount_original>=0 AND fn_financial_amount_is_exact(amount_original)),
 write_off_original numeric NOT NULL CHECK(write_off_original>=0 AND fn_financial_amount_is_exact(write_off_original)),
 cash_local numeric NOT NULL CHECK(cash_local>=0 AND fn_financial_book_amount_is_exact(cash_local)),
 write_off_local numeric NOT NULL CHECK(write_off_local>=0 AND fn_financial_book_amount_is_exact(write_off_local)),
 book_local numeric NOT NULL CHECK(book_local>=0 AND fn_financial_book_amount_is_exact(book_local)),
 PRIMARY KEY(batch_id,category)
);
CREATE TABLE finance_customer_offset_classification_batches (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),request_id uuid NOT NULL UNIQUE,
 offset_id uuid NOT NULL REFERENCES customer_open_item_offsets(id),revision bigint NOT NULL CHECK(revision>=0),
 source_classification_id uuid REFERENCES finance_open_item_classification_batches(id),
 target_classification_id uuid NOT NULL REFERENCES finance_open_item_classification_batches(id),
 source_kind text NOT NULL CHECK(source_kind IN('CREDIT','PREPAYMENT')),
 amount_original numeric NOT NULL CHECK(amount_original>=0 AND fn_financial_amount_is_exact(amount_original)),
 source_local numeric NOT NULL CHECK(source_local>=0 AND fn_financial_book_amount_is_exact(source_local)),
 target_local numeric NOT NULL CHECK(target_local>=0 AND fn_financial_book_amount_is_exact(target_local)),
 source_reference text NOT NULL CHECK(length(btrim(source_reference)) BETWEEN 1 AND 2000),
 fingerprint text NOT NULL CHECK(fingerprint~'^[0-9a-f]{64}$'),
 created_at timestamptz NOT NULL DEFAULT now(),created_by uuid NOT NULL REFERENCES users(id),
 created_tx xid8 NOT NULL DEFAULT pg_current_xact_id(),UNIQUE(offset_id,revision),
 CHECK((source_kind='PREPAYMENT')=(source_classification_id IS NULL))
);
CREATE TABLE finance_customer_offset_classification_parts (
 batch_id uuid NOT NULL REFERENCES finance_customer_offset_classification_batches(id),
 source_category text NOT NULL CHECK(source_category IN('GOODS','MATERIAL','PREPAYMENT')),
 target_category text NOT NULL CHECK(target_category IN('GOODS','MATERIAL')),
 amount_original numeric NOT NULL CHECK(amount_original>=0 AND fn_financial_amount_is_exact(amount_original)),
 source_local numeric NOT NULL CHECK(source_local>=0 AND fn_financial_book_amount_is_exact(source_local)),
 target_local numeric NOT NULL CHECK(target_local>=0 AND fn_financial_book_amount_is_exact(target_local)),
 PRIMARY KEY(batch_id,source_category,target_category)
);
CREATE VIEW v_finance_receipt_classification_current AS
 SELECT DISTINCT ON(receipt_line_id)* FROM finance_receipt_classification_batches ORDER BY receipt_line_id,revision DESC;
CREATE VIEW v_finance_customer_offset_classification_current AS
 SELECT DISTINCT ON(offset_id)* FROM finance_customer_offset_classification_batches ORDER BY offset_id,revision DESC;

CREATE FUNCTION fn_finance_receipt_classification_reconcile()RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE batch uuid;head finance_receipt_classification_batches%ROWTYPE;fact record;assigned record;
BEGIN
 IF TG_TABLE_NAME='finance_receipt_classification_batches' THEN batch:=NEW.id;ELSE batch:=NEW.batch_id;END IF;
 SELECT * INTO head FROM finance_receipt_classification_batches WHERE id=batch;
 SELECT line.amount_original,line.write_off_amount AS write_off_original,line.amount_local AS cash_local,
   line.write_off_local,line.applied_amount_local AS book_local,receipt.currency_id,line.applied_ledger_id,
   receipt.client_id,receipt.bill_date INTO fact
 FROM finance_receipt_lines line JOIN finance_receipts receipt ON receipt.id=line.receipt_id
 WHERE line.id=head.receipt_line_id AND NOT line.is_deleted AND NOT receipt.is_deleted
   AND receipt.status IN(1,-1) AND receipt.receipt_kind='AR_SETTLEMENT' AND receipt.settlement_authority_version>0
   AND receipt.legacy_id IS NULL AND receipt.legacy_import_run_id IS NULL;
 IF NOT FOUND OR fact.amount_original IS NULL OR fact.write_off_original IS NULL OR fact.cash_local IS NULL
   OR fact.write_off_local IS NULL OR fact.book_local IS NULL OR
   (head.amount_original,head.write_off_original,head.cash_local,head.write_off_local,head.book_local,head.currency_id)
     IS DISTINCT FROM(fact.amount_original,fact.write_off_original,fact.cash_local,fact.write_off_local,fact.book_local,fact.currency_id)
   OR NOT EXISTS(SELECT 1 FROM v_finance_open_item_classification_current current
     WHERE current.id=head.source_classification_id AND current.ledger_id=fact.applied_ledger_id AND current.direction='AR'
       AND current.party_id=fact.client_id AND current.currency_id=fact.currency_id AND current.effective_from<=fact.bill_date) THEN
  RAISE EXCEPTION '收款归属须对应真实已核原收款行、客户、币别与有效来源，不能重写现金或账面金额' USING ERRCODE='23514';END IF;
 SELECT sum(part.amount_original) AS original,sum(part.write_off_original) AS write_original,
   sum(part.cash_local) AS cash,sum(part.write_off_local) AS write_local,sum(part.book_local) AS book,
   bool_or(NOT EXISTS(SELECT 1 FROM finance_open_item_classification_parts source
     WHERE source.batch_id=head.source_classification_id AND source.category=part.category)) AS bad
 INTO assigned FROM finance_receipt_classification_parts part WHERE part.batch_id=batch;
 IF (assigned.original,assigned.write_original,assigned.cash,assigned.write_local,assigned.book)
   IS DISTINCT FROM(head.amount_original,head.write_off_original,head.cash_local,head.write_off_local,head.book_local)
   OR COALESCE(assigned.bad,false) THEN
  RAISE EXCEPTION '收款原币、冲销原币、实际回款本币、冲销本币和账面核销须逐轴完整守恒' USING ERRCODE='23514';END IF;
 RETURN NULL;
END $$;

CREATE FUNCTION fn_finance_customer_offset_classification_reconcile()RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE batch uuid;head finance_customer_offset_classification_batches%ROWTYPE;fact record;assigned record;
BEGIN
 IF TG_TABLE_NAME='finance_customer_offset_classification_batches' THEN batch:=NEW.id;ELSE batch:=NEW.batch_id;END IF;
 SELECT * INTO head FROM finance_customer_offset_classification_batches WHERE id=batch;
 SELECT actual.*,batch_row.client_id AS actual_client_id,source.open_item_kind AS source_open_kind,
   source.legacy_import_run_id AS source_legacy_import_run_id INTO fact
 FROM customer_open_item_offsets actual JOIN customer_open_item_offset_batches batch_row ON batch_row.id=actual.offset_batch_id
 JOIN ar_ap_ledger source ON source.id=actual.source_ledger_id
 WHERE actual.id=head.offset_id AND actual.status IN('APPLIED','REVERSED');
 IF NOT FOUND OR (head.amount_original,head.source_local,head.target_local)
   IS DISTINCT FROM(fact.amount_original,fact.source_amount_local,fact.target_amount_local)
   OR NOT EXISTS(SELECT 1 FROM v_finance_open_item_classification_current target WHERE target.id=head.target_classification_id
     AND target.ledger_id=fact.target_ledger_id AND target.direction='AR' AND target.party_id=fact.actual_client_id
     AND target.currency_id=fact.currency_id AND target.effective_from<=fact.effective_date)
   OR(head.source_kind='PREPAYMENT' AND(fact.source_open_kind<>'CUSTOMER_PREPAYMENT' OR fact.source_legacy_import_run_id IS NOT NULL OR head.source_classification_id IS NOT NULL))
   OR(head.source_kind='CREDIT' AND NOT EXISTS(SELECT 1 FROM v_finance_open_item_classification_current source
     WHERE source.id=head.source_classification_id AND source.ledger_id=fact.source_ledger_id AND source.direction='AR'
       AND source.party_id=fact.actual_client_id AND source.currency_id=fact.currency_id AND source.effective_from<=fact.effective_date)) THEN
  RAISE EXCEPTION '客户抵销归属须保留原两端真实往来、币别和账面份额，预收不能伪装成新增应收' USING ERRCODE='23514';END IF;
 SELECT sum(part.amount_original) AS original,sum(part.source_local) AS source,sum(part.target_local) AS target,
   bool_or((head.source_kind='PREPAYMENT' AND part.source_category<>'PREPAYMENT')
     OR(head.source_kind='CREDIT' AND NOT EXISTS(SELECT 1 FROM finance_open_item_classification_parts source
       WHERE source.batch_id=head.source_classification_id AND source.category=part.source_category))
     OR NOT EXISTS(SELECT 1 FROM finance_open_item_classification_parts target
       WHERE target.batch_id=head.target_classification_id AND target.category=part.target_category)) AS bad
 INTO assigned FROM finance_customer_offset_classification_parts part WHERE part.batch_id=batch;
 IF (assigned.original,assigned.source,assigned.target)IS DISTINCT FROM(head.amount_original,head.source_local,head.target_local)
   OR COALESCE(assigned.bad,false) THEN
  RAISE EXCEPTION '客户抵销的原币、来源与目标本币必须分别完整归属，不自动换算或补差' USING ERRCODE='23514';END IF;
 RETURN NULL;
END $$;

DO $classification_receivable_guards$
DECLARE pair text[];definition text;anchor text;
BEGIN
 FOREACH pair SLICE 1 IN ARRAY ARRAY[
  ['finance_receipt_classification_batches','fn_finance_receipt_classification_reconcile'],
  ['finance_receipt_classification_parts','fn_finance_receipt_classification_reconcile'],
  ['finance_customer_offset_classification_batches','fn_finance_customer_offset_classification_reconcile'],
  ['finance_customer_offset_classification_parts','fn_finance_customer_offset_classification_reconcile']] LOOP
  EXECUTE format('CREATE TRIGGER %I BEFORE UPDATE OR DELETE ON %I FOR EACH ROW EXECUTE FUNCTION fn_finance_classification_immutable()',pair[1]||'_immutable',pair[1]);
  EXECUTE format('CREATE CONSTRAINT TRIGGER %I AFTER INSERT ON %I DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION %I()',pair[1]||'_reconcile',pair[1],pair[2]);
  IF pair[1] LIKE '%parts' THEN
   EXECUTE format('CREATE TRIGGER %I BEFORE INSERT ON %I FOR EACH ROW EXECUTE FUNCTION fn_finance_classification_parts_same_transaction()',pair[1]||'_same_tx',pair[1]);
  ELSE
   EXECUTE format('CREATE TRIGGER %I BEFORE INSERT ON %I FOR EACH ROW EXECUTE FUNCTION fn_finance_classification_serial()',pair[1]||'_serial',pair[1]);
  END IF;
  PERFORM fn_audit_track_table(pair[1],'COLUMN_SCOPED','data_change',false,
   CASE pair[1]
    WHEN 'finance_receipt_classification_parts' THEN ARRAY['batch_id','category']
    WHEN 'finance_customer_offset_classification_parts' THEN ARRAY['batch_id','source_category','target_category']
    WHEN 'finance_receipt_classification_batches' THEN ARRAY['id','request_id','receipt_line_id','revision','source_classification_id','currency_id','created_by','created_at']
    ELSE ARRAY['id','request_id','offset_id','revision','source_classification_id','target_classification_id','source_kind','created_by','created_at'] END,true,NULL);
 END LOOP;
 SELECT pg_get_functiondef('fn_finance_classification_serial()'::regprocedure) INTO definition;
 anchor:='IF TG_TABLE_NAME=''finance_open_item_classification_batches'' THEN';
 IF position(anchor IN definition)=0 THEN RAISE EXCEPTION 'Review changed classification dependency guard';END IF;
 EXECUTE replace(definition,anchor,anchor||E'\nIF EXISTS(SELECT 1 FROM finance_receipt_classification_batches r JOIN finance_open_item_classification_batches s ON s.id=r.source_classification_id WHERE s.ledger_id=NEW.ledger_id) OR EXISTS(SELECT 1 FROM finance_customer_offset_classification_batches r JOIN finance_open_item_classification_batches s ON s.id IN(r.source_classification_id,r.target_classification_id) WHERE s.ledger_id=NEW.ledger_id) THEN RAISE EXCEPTION ''原应收分类已被收款或抵销引用，请使用受控更正保留全部关联归属'' USING ERRCODE=''23514'';END IF;\n');
END; $classification_receivable_guards$;

-- The same dated category budget is used by the API and the deferred database
-- guard. Cash proceeds/FX are not invoice book capacity. Both ends of a credit
-- offset consume their own source share; an ordinary advance has only an AR end.
CREATE VIEW v_finance_receivable_category_consumption_events AS
 WITH receipt_facts AS (
  SELECT source.ledger_id,part.category,receipt.bill_date AS effective_date,
    (COALESCE(receipt.reversed_at,receipt.updated_at) AT TIME ZONE 'Asia/Shanghai')::date AS reversed_date,
    receipt.status=-1 AS reversed,part.amount_original+part.write_off_original AS original,part.book_local AS book
  FROM v_finance_receipt_classification_current classified
  JOIN finance_receipt_classification_parts part ON part.batch_id=classified.id
  JOIN finance_open_item_classification_batches source ON source.id=classified.source_classification_id
  JOIN finance_receipt_lines line ON line.id=classified.receipt_line_id
  JOIN finance_receipts receipt ON receipt.id=line.receipt_id
  WHERE receipt.status IN(1,-1) AND NOT receipt.is_deleted AND NOT line.is_deleted
 ), offset_facts AS (
  SELECT target.ledger_id,part.target_category AS category,actual.effective_date,
    (actual.reversed_at AT TIME ZONE 'Asia/Shanghai')::date AS reversed_date,
    actual.status='REVERSED' AS reversed,part.amount_original AS original,part.target_local AS book
  FROM v_finance_customer_offset_classification_current classified
  JOIN finance_customer_offset_classification_parts part ON part.batch_id=classified.id
  JOIN finance_open_item_classification_batches target ON target.id=classified.target_classification_id
  JOIN customer_open_item_offsets actual ON actual.id=classified.offset_id
  UNION ALL
  SELECT source.ledger_id,part.source_category,actual.effective_date,
    (actual.reversed_at AT TIME ZONE 'Asia/Shanghai')::date,actual.status='REVERSED',part.amount_original,part.source_local
  FROM v_finance_customer_offset_classification_current classified
  JOIN finance_customer_offset_classification_parts part ON part.batch_id=classified.id
  JOIN finance_open_item_classification_batches source ON source.id=classified.source_classification_id
  JOIN customer_open_item_offsets actual ON actual.id=classified.offset_id
  WHERE classified.source_kind='CREDIT'
 )
 SELECT ledger_id,category,effective_date AS event_date,original,book FROM receipt_facts
 UNION ALL SELECT ledger_id,category,reversed_date,-original,-book FROM receipt_facts WHERE reversed AND reversed_date IS NOT NULL
 UNION ALL SELECT ledger_id,category,effective_date,original,book FROM offset_facts
 UNION ALL SELECT ledger_id,category,reversed_date,-original,-book FROM offset_facts WHERE reversed AND reversed_date IS NOT NULL;

CREATE FUNCTION fn_finance_receivable_classification_exceeds(p_ledger uuid)RETURNS boolean
 LANGUAGE sql STABLE AS $$
 WITH basis AS (
  SELECT source.effective_from,part.category,abs(part.amount_original) AS original_capacity,abs(part.amount_local) AS local_capacity
  FROM v_finance_open_item_classification_current source
  JOIN finance_open_item_classification_parts part ON part.batch_id=source.id
  WHERE source.ledger_id=p_ledger AND source.direction='AR'
 ), daily AS (
  SELECT category,event_date,sum(original) AS original,sum(book) AS book
  FROM v_finance_receivable_category_consumption_events WHERE ledger_id=p_ledger GROUP BY category,event_date
 ), timeline AS (
  SELECT category,event_date,sum(original) OVER(PARTITION BY category ORDER BY event_date) AS original_used,
    sum(book) OVER(PARTITION BY category ORDER BY event_date) AS local_used FROM daily
 )
 SELECT EXISTS(SELECT 1 FROM timeline LEFT JOIN basis USING(category)
  WHERE basis.category IS NULL OR(event_date<basis.effective_from AND(original_used<>0 OR local_used<>0))
    OR original_used>original_capacity OR local_used>local_capacity OR original_used<0 OR local_used<0)
$$;

CREATE FUNCTION fn_finance_receivable_category_capacity_guard()RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE affected uuid[];candidate uuid;
BEGIN
 PERFORM pg_advisory_xact_lock(hashtextextended('uten:open-item-classification',0));
 CASE TG_TABLE_NAME
 WHEN 'finance_receipt_classification_batches' THEN
  SELECT ARRAY[source.ledger_id] INTO affected FROM finance_open_item_classification_batches source WHERE source.id=NEW.source_classification_id;
 WHEN 'finance_receipt_classification_parts' THEN
  SELECT ARRAY[source.ledger_id] INTO affected FROM finance_receipt_classification_batches head
   JOIN finance_open_item_classification_batches source ON source.id=head.source_classification_id WHERE head.id=NEW.batch_id;
 WHEN 'finance_customer_offset_classification_batches' THEN
  SELECT array_agg(source.ledger_id) INTO affected FROM finance_open_item_classification_batches source WHERE source.id IN(NEW.source_classification_id,NEW.target_classification_id);
 WHEN 'finance_customer_offset_classification_parts' THEN
  SELECT array_agg(source.ledger_id) INTO affected FROM finance_customer_offset_classification_batches head
   JOIN finance_open_item_classification_batches source ON source.id IN(head.source_classification_id,head.target_classification_id) WHERE head.id=NEW.batch_id;
 WHEN 'finance_receipts' THEN
  SELECT array_agg(DISTINCT line.applied_ledger_id) INTO affected FROM finance_receipt_lines line WHERE line.receipt_id=NEW.id;
 WHEN 'customer_open_item_offsets' THEN affected:=ARRAY[NEW.source_ledger_id,NEW.target_ledger_id];
 ELSE RAISE EXCEPTION 'Unexpected receivable category budget caller';
 END CASE;
 FOREACH candidate IN ARRAY COALESCE(affected,ARRAY[]::uuid[]) LOOP
  IF fn_finance_receivable_classification_exceeds(candidate) THEN
   RAISE EXCEPTION '某一日期的货款或物料清偿超过原币/账面份额，请核对完整关联归属' USING ERRCODE='23514';END IF;
 END LOOP;
 RETURN NULL;
END $$;
DO $receivable_category_capacity$
DECLARE relation text;
BEGIN
 FOREACH relation IN ARRAY ARRAY['finance_receipt_classification_batches','finance_receipt_classification_parts',
  'finance_customer_offset_classification_batches','finance_customer_offset_classification_parts'] LOOP
  EXECUTE format('CREATE CONSTRAINT TRIGGER %I AFTER INSERT ON %I DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_finance_receivable_category_capacity_guard()',relation||'_category_capacity',relation);
 END LOOP;
END; $receivable_category_capacity$;
CREATE CONSTRAINT TRIGGER finance_receipts_category_capacity AFTER UPDATE ON finance_receipts
 DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
 WHEN(OLD.status IS DISTINCT FROM NEW.status OR OLD.reversed_at IS DISTINCT FROM NEW.reversed_at OR OLD.is_deleted IS DISTINCT FROM NEW.is_deleted)
 EXECUTE FUNCTION fn_finance_receivable_category_capacity_guard();
CREATE CONSTRAINT TRIGGER customer_offsets_category_capacity AFTER UPDATE ON customer_open_item_offsets
 DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
 WHEN(OLD.status IS DISTINCT FROM NEW.status OR OLD.reversed_at IS DISTINCT FROM NEW.reversed_at)
 EXECUTE FUNCTION fn_finance_receivable_category_capacity_guard();
