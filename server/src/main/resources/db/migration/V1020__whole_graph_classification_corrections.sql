-- Metadata-only corrections: every changed source and every actual reference share one immutable receipt.
CREATE TABLE finance_classification_corrections (
 id uuid PRIMARY KEY,request_id uuid NOT NULL UNIQUE,created_by uuid NOT NULL REFERENCES users(id),
 direction text NOT NULL CHECK(direction IN('AP','AR')),party_id uuid NOT NULL,currency_id uuid NOT NULL REFERENCES currencies(id),
 reason text NOT NULL CHECK(length(btrim(reason)) BETWEEN 1 AND 2000),
 graph_fingerprint text NOT NULL CHECK(graph_fingerprint~'^[0-9a-f]{64}$'),
 command_hash text NOT NULL CHECK(command_hash~'^[0-9a-f]{64}$'),command jsonb NOT NULL,
 status text NOT NULL CHECK(status IN('BUILDING','APPLIED')),result jsonb,
 created_tx xid8 NOT NULL DEFAULT pg_current_xact_id(),created_at timestamptz NOT NULL DEFAULT now(),
 CHECK((status='APPLIED')=(result IS NOT NULL))
);
CREATE TABLE finance_classification_correction_nodes (
 correction_id uuid NOT NULL REFERENCES finance_classification_corrections(id),
 kind text NOT NULL CHECK(kind IN('SOURCE','AP_PAYMENT','AR_RECEIPT','AP_OFFSET','AR_OFFSET','AP_ADVANCE_TARGET')),
 object_id uuid NOT NULL,old_batch_id uuid,new_batch_id uuid NOT NULL UNIQUE,
 fact jsonb NOT NULL,PRIMARY KEY(correction_id,kind,object_id)
);
-- A terminal receipt seals the request UUID, including a delayed POST that has not reached the family lock yet.
CREATE TABLE finance_classification_request_receipts (
 request_id uuid PRIMARY KEY,created_by uuid NOT NULL REFERENCES users(id),command_hash text NOT NULL CHECK(command_hash~'^[0-9a-f]{64}$'),
 status text NOT NULL CHECK(status IN('APPLIED','ABANDONED')),correction_id uuid UNIQUE REFERENCES finance_classification_corrections(id),
 reason text,created_tx xid8 NOT NULL DEFAULT pg_current_xact_id(),created_at timestamptz NOT NULL DEFAULT now(),
 CHECK((status='APPLIED')=(correction_id IS NOT NULL)),CHECK(status<>'ABANDONED' OR length(btrim(reason)) BETWEEN 1 AND 2000)
);
CREATE FUNCTION fn_finance_classification_request_receipt_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF TG_OP<>'INSERT' THEN RAISE EXCEPTION 'Classification request outcomes are terminal and immutable' USING ERRCODE='23514';END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('uten:open-item-classification',0));
 IF NEW.created_tx<>pg_current_xact_id() OR NEW.created_by IS DISTINCT FROM NULLIF(current_setting('app.actor_id',true),'')::uuid
 OR (NEW.status='APPLIED' AND NOT EXISTS(SELECT 1 FROM finance_classification_corrections c WHERE c.id=NEW.correction_id AND c.request_id=NEW.request_id AND c.command_hash=NEW.command_hash AND c.created_by=NEW.created_by AND c.created_tx=NEW.created_tx AND c.status='APPLIED'))
 OR (NEW.status='ABANDONED' AND EXISTS(SELECT 1 FROM finance_classification_corrections c WHERE c.request_id=NEW.request_id)) THEN
 RAISE EXCEPTION 'Request receipt must match this actor, complete command and terminal actual outcome' USING ERRCODE='23514';END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER classification_request_receipt_guard BEFORE INSERT OR UPDATE OR DELETE ON finance_classification_request_receipts FOR EACH ROW EXECUTE FUNCTION fn_finance_classification_request_receipt_guard();
CREATE TABLE finance_supplier_advance_target_classification_batches (
 id uuid PRIMARY KEY,application_id uuid NOT NULL REFERENCES finance_supplier_advance_applications(id),
 revision bigint NOT NULL CHECK(revision>=0),correction_id uuid NOT NULL REFERENCES finance_classification_corrections(id),
 target_classification_id uuid NOT NULL REFERENCES finance_open_item_classification_batches(id),
 created_by uuid NOT NULL REFERENCES users(id),created_tx xid8 NOT NULL DEFAULT pg_current_xact_id(),created_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(application_id,revision)
);
CREATE TABLE finance_supplier_advance_target_classification_parts (
 batch_id uuid NOT NULL REFERENCES finance_supplier_advance_target_classification_batches(id),
 category text NOT NULL CHECK(category IN('GOODS','MOULD')),
 amount_original numeric NOT NULL CHECK(amount_original>=0 AND fn_financial_amount_is_exact(amount_original)),
 target_local numeric NOT NULL CHECK(target_local>=0 AND fn_financial_book_amount_is_exact(target_local)),PRIMARY KEY(batch_id,category)
);
CREATE VIEW v_finance_supplier_advance_target_classification_current AS
 SELECT DISTINCT ON(application_id)* FROM finance_supplier_advance_target_classification_batches ORDER BY application_id,revision DESC;
CREATE VIEW v_finance_supplier_advance_target_parts_effective AS
 SELECT a.id AS application_id,c.id AS batch_id,c.correction_id,c.target_classification_id,p.category,p.amount_original,p.target_local,
 a.target_ledger_id,a.effective_date,a.status,a.reversed_at
 FROM finance_supplier_advance_applications a JOIN v_finance_supplier_advance_target_classification_current c ON c.application_id=a.id
 JOIN finance_supplier_advance_target_classification_parts p ON p.batch_id=c.id
 UNION ALL
 SELECT a.id,NULL::uuid,NULL::uuid,s.id,a.target_category,a.amount_original,a.target_local,a.target_ledger_id,a.effective_date,a.status,a.reversed_at
 FROM finance_supplier_advance_applications a LEFT JOIN v_finance_open_item_classification_current s ON s.ledger_id=a.target_ledger_id
 WHERE NOT EXISTS(SELECT 1 FROM v_finance_supplier_advance_target_classification_current c WHERE c.application_id=a.id);

CREATE FUNCTION fn_finance_classification_node_fact(k text,obj uuid) RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE fact jsonb;
BEGIN
 CASE k
 WHEN 'SOURCE' THEN SELECT to_jsonb(a) INTO fact FROM ar_ap_ledger a WHERE id=obj;
 WHEN 'AP_PAYMENT' THEN SELECT jsonb_build_object('line',to_jsonb(l),'parent',to_jsonb(p)) INTO fact FROM finance_payment_lines l JOIN finance_payments p ON p.id=l.payment_id WHERE l.id=obj;
 WHEN 'AR_RECEIPT' THEN SELECT jsonb_build_object('line',to_jsonb(l),'parent',to_jsonb(p)) INTO fact FROM finance_receipt_lines l JOIN finance_receipts p ON p.id=l.receipt_id WHERE l.id=obj;
 WHEN 'AP_OFFSET' THEN SELECT to_jsonb(a) INTO fact FROM supplier_open_item_offsets a WHERE id=obj;
 WHEN 'AR_OFFSET' THEN SELECT to_jsonb(a) INTO fact FROM customer_open_item_offsets a WHERE id=obj;
 WHEN 'AP_ADVANCE_TARGET' THEN SELECT to_jsonb(a) INTO fact FROM finance_supplier_advance_applications a WHERE id=obj;
 ELSE RAISE EXCEPTION 'Unsupported classification node' USING ERRCODE='23514';
 END CASE;
 IF fact IS NULL THEN RAISE EXCEPTION 'Missing actual classification node' USING ERRCODE='23514';END IF;
 RETURN fact;
END $$;
CREATE FUNCTION fn_finance_classification_node_batch(k text,obj uuid) RETURNS uuid LANGUAGE plpgsql STABLE AS $$
DECLARE batch uuid;
BEGIN
 CASE k
 WHEN 'SOURCE' THEN SELECT id INTO batch FROM v_finance_open_item_classification_current WHERE ledger_id=obj;
 WHEN 'AP_PAYMENT' THEN SELECT id INTO batch FROM v_finance_payment_classification_current WHERE payment_line_id=obj;
 WHEN 'AR_RECEIPT' THEN SELECT id INTO batch FROM v_finance_receipt_classification_current WHERE receipt_line_id=obj;
 WHEN 'AP_OFFSET' THEN SELECT id INTO batch FROM v_finance_supplier_offset_classification_current WHERE offset_id=obj;
 WHEN 'AR_OFFSET' THEN SELECT id INTO batch FROM v_finance_customer_offset_classification_current WHERE offset_id=obj;
 WHEN 'AP_ADVANCE_TARGET' THEN SELECT id INTO batch FROM v_finance_supplier_advance_target_classification_current WHERE application_id=obj;
 ELSE RAISE EXCEPTION 'Unsupported classification node' USING ERRCODE='23514';
 END CASE;RETURN batch;
END $$;
CREATE FUNCTION fn_finance_classification_correction_node_insert() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE head finance_classification_corrections%ROWTYPE;
BEGIN
 PERFORM pg_advisory_xact_lock(hashtextextended('uten:open-item-classification',0));
 SELECT * INTO head FROM finance_classification_corrections WHERE id=NEW.correction_id;
 IF head.status<>'BUILDING' OR head.created_tx<>pg_current_xact_id() OR head.created_by IS DISTINCT FROM NULLIF(current_setting('app.actor_id',true),'')::uuid
 OR NEW.old_batch_id IS DISTINCT FROM fn_finance_classification_node_batch(NEW.kind,NEW.object_id)
 OR (SELECT count(*) FROM finance_classification_correction_nodes WHERE correction_id=head.id)>=512 THEN
  RAISE EXCEPTION 'Correction registration requires the same actor, transaction and exact current version; graph limit is 512' USING ERRCODE='23514';END IF;
 NEW.fact:=fn_finance_classification_node_fact(NEW.kind,NEW.object_id);RETURN NEW;
END $$;
CREATE TRIGGER finance_correction_node_insert BEFORE INSERT ON finance_classification_correction_nodes FOR EACH ROW EXECUTE FUNCTION fn_finance_classification_correction_node_insert();
CREATE FUNCTION fn_finance_classification_correction_immutable() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF TG_OP='UPDATE' AND OLD.status='BUILDING' AND NEW.status='APPLIED' AND OLD.created_tx=pg_current_xact_id()
 AND OLD.created_by IS NOT DISTINCT FROM NULLIF(current_setting('app.actor_id',true),'')::uuid
 AND (to_jsonb(NEW)-ARRAY['status','result'])=(to_jsonb(OLD)-ARRAY['status','result']) THEN RETURN NEW;END IF;
 RAISE EXCEPTION 'Classification correction receipts are immutable' USING ERRCODE='23514';
END $$;
CREATE TRIGGER finance_correction_immutable BEFORE UPDATE OR DELETE ON finance_classification_corrections FOR EACH ROW EXECUTE FUNCTION fn_finance_classification_correction_immutable();
CREATE TRIGGER finance_correction_nodes_immutable BEFORE UPDATE OR DELETE ON finance_classification_correction_nodes FOR EACH ROW EXECUTE FUNCTION fn_finance_classification_immutable();

-- A registered exact new UUID is a narrow capability. A session flag cannot bypass the ordinary source guard.
CREATE OR REPLACE FUNCTION fn_finance_classification_serial() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE node record;
BEGIN
 PERFORM pg_advisory_xact_lock(hashtextextended('uten:open-item-classification',0));
 IF TG_TABLE_NAME='finance_open_item_classification_batches' THEN
  SELECT n.* INTO node FROM finance_classification_correction_nodes n JOIN finance_classification_corrections c ON c.id=n.correction_id
   WHERE n.kind='SOURCE' AND n.object_id=NEW.ledger_id AND n.new_batch_id=NEW.id AND c.status='BUILDING'
    AND c.created_tx=pg_current_xact_id() AND c.created_by=NEW.created_by
    AND c.created_by=NULLIF(current_setting('app.actor_id',true),'')::uuid
    AND n.old_batch_id IS NOT DISTINCT FROM fn_finance_classification_node_batch('SOURCE',NEW.ledger_id);
  IF FOUND THEN RETURN NEW;END IF;
  IF (EXISTS(SELECT 1 FROM finance_open_item_classification_batches prior WHERE prior.ledger_id=NEW.ledger_id) AND EXISTS(SELECT 1 FROM v_finance_classification_actual_references actual_ref WHERE actual_ref.ledger_id=NEW.ledger_id))
  OR EXISTS(SELECT 1 FROM finance_payment_classification_batches p JOIN finance_open_item_classification_batches s ON s.id=p.source_classification_id WHERE s.ledger_id=NEW.ledger_id)
  OR EXISTS(SELECT 1 FROM finance_receipt_classification_batches p JOIN finance_open_item_classification_batches s ON s.id=p.source_classification_id WHERE s.ledger_id=NEW.ledger_id)
  OR EXISTS(SELECT 1 FROM finance_supplier_offset_classification_batches p JOIN finance_open_item_classification_batches s ON s.id IN(p.source_classification_id,p.target_classification_id) WHERE s.ledger_id=NEW.ledger_id)
  OR EXISTS(SELECT 1 FROM finance_customer_offset_classification_batches p JOIN finance_open_item_classification_batches s ON s.id IN(p.source_classification_id,p.target_classification_id) WHERE s.ledger_id=NEW.ledger_id)
  OR EXISTS(SELECT 1 FROM finance_supplier_advance_applications a WHERE a.target_ledger_id=NEW.ledger_id) THEN
   RAISE EXCEPTION 'Referenced classifications require a complete registered graph correction' USING ERRCODE='23514';END IF;
 END IF;RETURN NEW;
END $$;

CREATE FUNCTION fn_finance_supplier_advance_target_reconcile() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE batch uuid;head finance_supplier_advance_target_classification_batches%ROWTYPE;actual finance_supplier_advance_applications%ROWTYPE;assigned record;
BEGIN
 IF TG_TABLE_NAME='finance_supplier_advance_target_classification_batches' THEN batch:=NEW.id;ELSE batch:=NEW.batch_id;END IF;
 SELECT * INTO head FROM finance_supplier_advance_target_classification_batches WHERE id=batch;
 SELECT * INTO actual FROM finance_supplier_advance_applications WHERE id=head.application_id;
 SELECT sum(p.amount_original) original,sum(p.target_local) local,bool_or(NOT EXISTS(SELECT 1 FROM finance_open_item_classification_parts s WHERE s.batch_id=head.target_classification_id AND s.category=p.category)) bad
  INTO assigned FROM finance_supplier_advance_target_classification_parts p WHERE p.batch_id=batch;
 IF (assigned.original,assigned.local) IS DISTINCT FROM(actual.amount_original,actual.target_local) OR COALESCE(assigned.bad,true)
 OR NOT EXISTS(SELECT 1 FROM v_finance_open_item_classification_current s JOIN finance_supplier_advances a ON a.payment_id=actual.payment_id WHERE s.id=head.target_classification_id AND s.ledger_id=actual.target_ledger_id AND s.direction='AP' AND s.party_id=a.supplier_id AND s.currency_id=a.currency_id)
 OR NOT EXISTS(SELECT 1 FROM finance_classification_corrections c JOIN finance_classification_correction_nodes n ON n.correction_id=c.id WHERE c.id=head.correction_id AND c.created_tx=head.created_tx AND c.created_by=head.created_by AND n.kind='AP_ADVANCE_TARGET' AND n.object_id=head.application_id AND n.new_batch_id=head.id) THEN
 RAISE EXCEPTION 'Advance effective target parts must preserve actual original and target book amounts and registered source identity' USING ERRCODE='23514';END IF;RETURN NULL;
END $$;
DO $$ DECLARE t text;BEGIN
 FOREACH t IN ARRAY ARRAY['finance_supplier_advance_target_classification_batches','finance_supplier_advance_target_classification_parts'] LOOP
 EXECUTE format('CREATE TRIGGER %I BEFORE UPDATE OR DELETE ON %I FOR EACH ROW EXECUTE FUNCTION fn_finance_classification_immutable()',t||'_immutable',t);
 EXECUTE format('CREATE CONSTRAINT TRIGGER %I AFTER INSERT ON %I DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_finance_supplier_advance_target_reconcile()',t||'_reconcile',t);
 END LOOP;
END $$;
CREATE TRIGGER advance_target_parts_same_tx BEFORE INSERT ON finance_supplier_advance_target_classification_parts FOR EACH ROW EXECUTE FUNCTION fn_finance_classification_parts_same_transaction();

CREATE VIEW v_finance_payable_category_consumption_events AS WITH
payment_facts AS (
                SELECT source.ledger_id,part.category,payment.bill_date,
                       (COALESCE(payment.reversed_at,payment.updated_at) AT TIME ZONE 'Asia/Shanghai')::date AS reversed_date,
                       payment.status,part.amount_original,part.book_local
                FROM v_finance_payment_classification_current classified
                JOIN finance_payment_classification_parts part ON part.batch_id=classified.id
                JOIN finance_open_item_classification_batches source ON source.id=classified.source_classification_id
                JOIN finance_payment_lines line ON line.id=classified.payment_line_id
                JOIN finance_payments payment ON payment.id=line.payment_id
                WHERE NOT line.is_deleted AND NOT payment.is_deleted AND payment.status IN(1,-1)
            ), offset_facts AS (
                SELECT source.ledger_id,part.source_category AS category,offset_row.effective_date,
                       (offset_row.reversed_at AT TIME ZONE 'Asia/Shanghai')::date AS reversed_date,
                       offset_row.status,part.amount_original,part.source_local AS book_local,offset_row.id AS offset_id
                FROM v_finance_supplier_offset_classification_current classified
                JOIN finance_supplier_offset_classification_parts part ON part.batch_id=classified.id
                JOIN finance_open_item_classification_batches source ON source.id=classified.source_classification_id
                JOIN supplier_open_item_offsets offset_row ON offset_row.id=classified.offset_id
                UNION ALL
                SELECT target.ledger_id,part.target_category,offset_row.effective_date,
                       (offset_row.reversed_at AT TIME ZONE 'Asia/Shanghai')::date,offset_row.status,part.amount_original,part.target_local,offset_row.id
                FROM v_finance_supplier_offset_classification_current classified
                JOIN finance_supplier_offset_classification_parts part ON part.batch_id=classified.id
                JOIN finance_open_item_classification_batches target ON target.id=classified.target_classification_id
                JOIN supplier_open_item_offsets offset_row ON offset_row.id=classified.offset_id
            ), events AS (
                SELECT ledger_id,category,bill_date AS event_date,amount_original,book_local,NULL::uuid AS offset_id FROM payment_facts
                UNION ALL SELECT ledger_id,category,reversed_date,-amount_original,-book_local,NULL::uuid FROM payment_facts WHERE status=-1 AND reversed_date IS NOT NULL
                UNION ALL SELECT ledger_id,category,effective_date,amount_original,book_local,offset_id FROM offset_facts
                UNION ALL SELECT ledger_id,category,reversed_date,-amount_original,-book_local,offset_id FROM offset_facts WHERE status='REVERSED' AND reversed_date IS NOT NULL
                UNION ALL SELECT target_ledger_id,category,effective_date,amount_original,target_local,NULL::uuid FROM v_finance_supplier_advance_target_parts_effective
                UNION ALL SELECT target_ledger_id,category,(reversed_at AT TIME ZONE 'Asia/Shanghai')::date,-amount_original,-target_local,NULL::uuid
                    FROM v_finance_supplier_advance_target_parts_effective WHERE status='REVERSED'
            )
             SELECT * FROM events;
CREATE FUNCTION fn_finance_payable_classification_exceeds(p_ledger uuid) RETURNS boolean LANGUAGE sql STABLE AS $$
 WITH basis AS (
 SELECT s.effective_from,p.category,abs(p.amount_original) original_capacity,abs(p.amount_local) local_capacity
 FROM v_finance_open_item_classification_current s JOIN finance_open_item_classification_parts p ON p.batch_id=s.id WHERE s.ledger_id=p_ledger AND s.direction='AP'
 ),daily AS(SELECT category,event_date,sum(amount_original) original,sum(book_local) book FROM v_finance_payable_category_consumption_events WHERE ledger_id=p_ledger GROUP BY category,event_date),
 timeline AS(SELECT category,event_date,sum(original)OVER(PARTITION BY category ORDER BY event_date)original_used,sum(book)OVER(PARTITION BY category ORDER BY event_date)local_used FROM daily)
 SELECT EXISTS(SELECT 1 FROM timeline LEFT JOIN basis USING(category) WHERE basis.category IS NULL OR(event_date<basis.effective_from AND(original_used<>0 OR local_used<>0)) OR original_used>original_capacity OR local_used>local_capacity OR original_used<0 OR local_used<0)
 $$;
 CREATE VIEW v_finance_classification_actual_references AS
 SELECT 'AP_PAYMENT'::text kind,l.id object_id,l.applied_ledger_id ledger_id FROM finance_payment_lines l JOIN finance_payments p ON p.id=l.payment_id WHERE NOT l.is_deleted AND NOT p.is_deleted AND p.status IN(1,-1)
 UNION ALL SELECT 'AR_RECEIPT',l.id,l.applied_ledger_id FROM finance_receipt_lines l JOIN finance_receipts p ON p.id=l.receipt_id WHERE NOT l.is_deleted AND NOT p.is_deleted AND p.status IN(1,-1)
 UNION ALL SELECT 'AP_OFFSET',o.id,o.source_ledger_id FROM supplier_open_item_offsets o WHERE o.status IN('APPLIED','REVERSED')
 UNION ALL SELECT 'AP_OFFSET',o.id,o.target_ledger_id FROM supplier_open_item_offsets o WHERE o.status IN('APPLIED','REVERSED')
 UNION ALL SELECT 'AR_OFFSET',o.id,o.source_ledger_id FROM customer_open_item_offsets o WHERE o.status IN('APPLIED','REVERSED')
 UNION ALL SELECT 'AR_OFFSET',o.id,o.target_ledger_id FROM customer_open_item_offsets o WHERE o.status IN('APPLIED','REVERSED')
 UNION ALL SELECT 'AP_ADVANCE_TARGET',a.id,a.target_ledger_id FROM finance_supplier_advance_applications a;
 CREATE FUNCTION fn_assert_finance_classification_correction(cid uuid) RETURNS void LANGUAGE plpgsql AS $$
 DECLARE head finance_classification_corrections%ROWTYPE;n record;b record;tbl text;objkey text;previous uuid;root record;
 BEGIN
 SELECT * INTO head FROM finance_classification_corrections WHERE id=cid;
 IF head.status<>'APPLIED' OR head.created_tx<>pg_current_xact_id() OR head.created_by IS DISTINCT FROM NULLIF(current_setting('app.actor_id',true),'')::uuid
 OR NOT EXISTS(SELECT 1 FROM finance_classification_correction_nodes WHERE correction_id=cid AND kind='SOURCE')
 OR NOT EXISTS(SELECT 1 FROM finance_classification_request_receipts r WHERE r.request_id=head.request_id AND r.status='APPLIED' AND r.correction_id=head.id AND r.command_hash=head.command_hash AND r.created_by=head.created_by AND r.created_tx=head.created_tx) THEN
 RAISE EXCEPTION 'Incomplete classification graph receipt' USING ERRCODE='23514';END IF;
 FOR n IN SELECT * FROM finance_classification_correction_nodes WHERE correction_id=cid LOOP
 IF n.fact IS DISTINCT FROM fn_finance_classification_node_fact(n.kind,n.object_id) OR fn_finance_classification_node_batch(n.kind,n.object_id) IS DISTINCT FROM n.new_batch_id THEN
 RAISE EXCEPTION 'Correction cannot alter financial facts or leave a partial current graph' USING ERRCODE='23514';END IF;
 CASE n.kind
 WHEN 'SOURCE' THEN tbl:='finance_open_item_classification_batches';objkey:='ledger_id';
 WHEN 'AP_PAYMENT' THEN tbl:='finance_payment_classification_batches';objkey:='payment_line_id';
 WHEN 'AR_RECEIPT' THEN tbl:='finance_receipt_classification_batches';objkey:='receipt_line_id';
 WHEN 'AP_OFFSET' THEN tbl:='finance_supplier_offset_classification_batches';objkey:='offset_id';
 WHEN 'AR_OFFSET' THEN tbl:='finance_customer_offset_classification_batches';objkey:='offset_id';
 WHEN 'AP_ADVANCE_TARGET' THEN tbl:='finance_supplier_advance_target_classification_batches';objkey:='application_id';
 END CASE;
 EXECUTE format('SELECT * FROM %I WHERE id=$1',tbl) INTO b USING n.new_batch_id;
 IF b.created_tx<>head.created_tx OR b.created_by<>head.created_by THEN RAISE EXCEPTION 'Every correction version must share the original actor and transaction' USING ERRCODE='23514';END IF;
 EXECUTE format('SELECT id FROM %I WHERE %I=$1 AND revision<$2 ORDER BY revision DESC LIMIT 1',tbl,objkey) INTO previous USING n.object_id,b.revision;
 IF previous IS DISTINCT FROM n.old_batch_id THEN RAISE EXCEPTION 'Correction expected version is stale' USING ERRCODE='23514';END IF;
 IF previous IS NULL THEN
 IF b.revision<>0 THEN RAISE EXCEPTION 'First classification revision must be zero' USING ERRCODE='23514';END IF;
 ELSE
 EXECUTE format('SELECT revision FROM %I WHERE id=$1',tbl) INTO root USING previous;
 IF b.revision<>root.revision+1 THEN RAISE EXCEPTION 'Correction revisions must be consecutive' USING ERRCODE='23514';END IF;
 END IF;
 IF n.kind<>'SOURCE' AND NOT EXISTS(SELECT 1 FROM v_finance_classification_actual_references r JOIN finance_classification_correction_nodes s ON s.kind='SOURCE' AND s.object_id=r.ledger_id AND s.correction_id=cid WHERE r.kind=n.kind AND r.object_id=n.object_id) THEN
 RAISE EXCEPTION 'Correction contains an unrelated settlement node' USING ERRCODE='23514';END IF;
 END LOOP;
 IF EXISTS(SELECT 1 FROM v_finance_classification_actual_references r JOIN finance_classification_correction_nodes s ON s.kind='SOURCE' AND s.object_id=r.ledger_id AND s.correction_id=cid
 WHERE NOT EXISTS(SELECT 1 FROM finance_classification_correction_nodes required_node WHERE required_node.correction_id=cid AND required_node.kind=r.kind AND required_node.object_id=r.object_id)) THEN
 RAISE EXCEPTION 'Correction omits an actual payment, receipt, offset end or advance application' USING ERRCODE='23514';END IF;
 FOR n IN SELECT * FROM finance_classification_correction_nodes WHERE correction_id=cid AND kind='SOURCE' LOOP
 SELECT * INTO root FROM v_finance_open_item_classification_current WHERE ledger_id=n.object_id;
 IF (root.direction,root.party_id,root.currency_id) IS DISTINCT FROM(head.direction,head.party_id,head.currency_id) THEN RAISE EXCEPTION 'Correction cannot mix party, direction or currency identities' USING ERRCODE='23514';END IF;
 IF EXISTS(SELECT 1 FROM v_finance_payment_classification_current p JOIN finance_payment_lines l ON l.id=p.payment_line_id WHERE l.applied_ledger_id=n.object_id AND p.source_classification_id<>n.new_batch_id)
 OR EXISTS(SELECT 1 FROM v_finance_receipt_classification_current p JOIN finance_receipt_lines l ON l.id=p.receipt_line_id WHERE l.applied_ledger_id=n.object_id AND p.source_classification_id<>n.new_batch_id)
 OR EXISTS(SELECT 1 FROM v_finance_supplier_offset_classification_current p JOIN supplier_open_item_offsets o ON o.id=p.offset_id WHERE(o.source_ledger_id=n.object_id AND p.source_classification_id<>n.new_batch_id)OR(o.target_ledger_id=n.object_id AND p.target_classification_id<>n.new_batch_id))
 OR EXISTS(SELECT 1 FROM v_finance_customer_offset_classification_current p JOIN customer_open_item_offsets o ON o.id=p.offset_id WHERE(o.source_ledger_id=n.object_id AND p.source_kind='CREDIT' AND p.source_classification_id<>n.new_batch_id)OR(o.target_ledger_id=n.object_id AND p.target_classification_id<>n.new_batch_id))
 OR EXISTS(SELECT 1 FROM v_finance_supplier_advance_target_parts_effective p WHERE p.target_ledger_id=n.object_id AND p.target_classification_id IS DISTINCT FROM n.new_batch_id)
 THEN RAISE EXCEPTION 'Correction leaves stale source references' USING ERRCODE='23514';END IF;
 IF root.direction='AP' AND fn_finance_payable_classification_exceeds(n.object_id) OR root.direction='AR' AND fn_finance_receivable_classification_exceeds(n.object_id) THEN RAISE EXCEPTION 'Correction exceeds a dated original or book category capacity' USING ERRCODE='23514';END IF;
 END LOOP;
 END $$;
 CREATE FUNCTION fn_finance_classification_correction_terminal() RETURNS trigger LANGUAGE plpgsql AS $$
 BEGIN PERFORM fn_assert_finance_classification_correction(NEW.id);RETURN NULL;END $$;
 CREATE CONSTRAINT TRIGGER finance_correction_terminal AFTER INSERT OR UPDATE ON finance_classification_corrections DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_finance_classification_correction_terminal();
 CREATE FUNCTION fn_finance_classification_correction_insert() RETURNS trigger LANGUAGE plpgsql AS $$
 BEGIN
 PERFORM pg_advisory_xact_lock(hashtextextended('uten:open-item-classification',0));
 IF NEW.status<>'BUILDING' OR NEW.created_tx<>pg_current_xact_id() OR NEW.created_by IS DISTINCT FROM NULLIF(current_setting('app.actor_id',true),'')::uuid
 OR EXISTS(SELECT 1 FROM finance_classification_request_receipts r WHERE r.request_id=NEW.request_id) THEN RAISE EXCEPTION 'Correction requires original actor and transaction' USING ERRCODE='23514';END IF;
 RETURN NEW;END $$;
 CREATE TRIGGER finance_correction_insert BEFORE INSERT ON finance_classification_corrections FOR EACH ROW EXECUTE FUNCTION fn_finance_classification_correction_insert();
 CREATE FUNCTION fn_finance_payable_category_capacity_guard() RETURNS trigger LANGUAGE plpgsql AS $$
 DECLARE affected uuid[];candidate uuid;
 BEGIN
 PERFORM pg_advisory_xact_lock(hashtextextended('uten:open-item-classification',0));
 CASE TG_TABLE_NAME
 WHEN 'finance_open_item_classification_batches' THEN affected:=ARRAY[NEW.ledger_id];
 WHEN 'finance_open_item_classification_parts' THEN SELECT ARRAY[s.ledger_id] INTO affected FROM finance_open_item_classification_batches s WHERE s.id=NEW.batch_id;
 WHEN 'finance_payment_classification_batches' THEN SELECT ARRAY[l.applied_ledger_id] INTO affected FROM finance_payment_lines l WHERE l.id=NEW.payment_line_id;
 WHEN 'finance_payment_classification_parts' THEN SELECT ARRAY[l.applied_ledger_id] INTO affected FROM finance_payment_classification_batches c JOIN finance_payment_lines l ON l.id=c.payment_line_id WHERE c.id=NEW.batch_id;
 WHEN 'finance_supplier_offset_classification_batches' THEN SELECT ARRAY[o.source_ledger_id,o.target_ledger_id] INTO affected FROM supplier_open_item_offsets o WHERE o.id=NEW.offset_id;
 WHEN 'finance_supplier_offset_classification_parts' THEN SELECT ARRAY[o.source_ledger_id,o.target_ledger_id] INTO affected FROM finance_supplier_offset_classification_batches c JOIN supplier_open_item_offsets o ON o.id=c.offset_id WHERE c.id=NEW.batch_id;
 WHEN 'finance_supplier_advance_target_classification_batches' THEN SELECT ARRAY[a.target_ledger_id] INTO affected FROM finance_supplier_advance_applications a WHERE a.id=NEW.application_id;
 WHEN 'finance_supplier_advance_target_classification_parts' THEN SELECT ARRAY[a.target_ledger_id] INTO affected FROM finance_supplier_advance_target_classification_batches c JOIN finance_supplier_advance_applications a ON a.id=c.application_id WHERE c.id=NEW.batch_id;
 WHEN 'finance_payments' THEN SELECT array_agg(l.applied_ledger_id) INTO affected FROM finance_payment_lines l WHERE l.payment_id=NEW.id;
 WHEN 'supplier_open_item_offsets' THEN affected:=ARRAY[NEW.source_ledger_id,NEW.target_ledger_id];
 WHEN 'finance_supplier_advance_applications' THEN affected:=ARRAY[NEW.target_ledger_id];
 ELSE RAISE EXCEPTION 'Unexpected payable category budget caller';
 END CASE;
 FOREACH candidate IN ARRAY COALESCE(affected,ARRAY[]::uuid[]) LOOP
 IF fn_finance_payable_classification_exceeds(candidate) THEN RAISE EXCEPTION 'Payable dated original or book category capacity exceeded' USING ERRCODE='23514';END IF;
 END LOOP;RETURN NULL;
 END $$;
 DO $$ DECLARE t text;BEGIN
 FOREACH t IN ARRAY ARRAY['finance_open_item_classification_batches','finance_open_item_classification_parts','finance_payment_classification_batches','finance_payment_classification_parts','finance_supplier_offset_classification_batches','finance_supplier_offset_classification_parts','finance_supplier_advance_target_classification_batches','finance_supplier_advance_target_classification_parts'] LOOP
 EXECUTE format('CREATE CONSTRAINT TRIGGER %I AFTER INSERT ON %I DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_finance_payable_category_capacity_guard()',t||'_payable_capacity',t);
 END LOOP;END $$;
 CREATE CONSTRAINT TRIGGER finance_payments_category_capacity AFTER UPDATE ON finance_payments DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
 WHEN(OLD.status IS DISTINCT FROM NEW.status OR OLD.reversed_at IS DISTINCT FROM NEW.reversed_at OR OLD.is_deleted IS DISTINCT FROM NEW.is_deleted) EXECUTE FUNCTION fn_finance_payable_category_capacity_guard();
 CREATE CONSTRAINT TRIGGER supplier_offsets_category_capacity AFTER UPDATE ON supplier_open_item_offsets DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
 WHEN(OLD.status IS DISTINCT FROM NEW.status OR OLD.reversed_at IS DISTINCT FROM NEW.reversed_at) EXECUTE FUNCTION fn_finance_payable_category_capacity_guard();
 CREATE CONSTRAINT TRIGGER supplier_advance_applications_category_capacity AFTER INSERT OR UPDATE ON finance_supplier_advance_applications DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_finance_payable_category_capacity_guard();
 SELECT fn_audit_track_table('finance_classification_corrections','COLUMN_SCOPED','data_change',false,
 ARRAY['id','request_id','created_by','direction','party_id','currency_id','graph_fingerprint','command_hash','status','created_at'],true,NULL);
 SELECT fn_audit_track_table('finance_classification_correction_nodes','COLUMN_SCOPED','data_change',false,
 ARRAY['correction_id','kind','object_id','old_batch_id','new_batch_id'],true,NULL);
 SELECT fn_audit_track_table('finance_supplier_advance_target_classification_batches','COLUMN_SCOPED','data_change',false,
 ARRAY['id','application_id','revision','correction_id','target_classification_id','created_by','created_at'],true,NULL);
 SELECT fn_audit_track_table('finance_supplier_advance_target_classification_parts','COLUMN_SCOPED','data_change',false,
 ARRAY['batch_id','category'],true,NULL);

 SELECT fn_audit_track_table('finance_classification_request_receipts','COLUMN_SCOPED','data_change',false,
 ARRAY['request_id','created_by','command_hash','status','correction_id','created_at'],true,NULL);
