-- Goods/tooling/material classifications assign existing facts; no second payable or cash amount is created.
ALTER TABLE finance_payments ADD COLUMN settlement_approved_tx xid8;
ALTER TABLE supplier_open_item_offsets ADD COLUMN settlement_created_tx xid8 NOT NULL DEFAULT pg_current_xact_id();
CREATE OR REPLACE FUNCTION fn_finance_payment_settlement_approved_tx()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.status=0 AND NEW.status=1 THEN NEW.settlement_approved_tx:=pg_current_xact_id();END IF;
    RETURN NEW;
END;$$;
CREATE TRIGGER trg_payment_settlement_approved_tx BEFORE UPDATE ON finance_payments
    FOR EACH ROW EXECUTE FUNCTION fn_finance_payment_settlement_approved_tx();
CREATE TABLE finance_supplier_settlement_dependencies (
    payment_line_id uuid NOT NULL REFERENCES finance_payment_lines(id),offset_id uuid NOT NULL REFERENCES supplier_open_item_offsets(id),
    ledger_id uuid NOT NULL REFERENCES ar_ap_ledger(id),relation text NOT NULL CHECK(relation IN('PAYMENT_BEFORE_OFFSET','OFFSET_BEFORE_PAYMENT')),
    source_snapshot jsonb NOT NULL,created_at timestamptz NOT NULL DEFAULT now(),created_by uuid NOT NULL REFERENCES users(id),
    PRIMARY KEY(payment_line_id,offset_id,ledger_id)
);
CREATE INDEX idx_finance_settlement_dependency_offset ON finance_supplier_settlement_dependencies(offset_id,relation);
CREATE TABLE finance_open_item_classification_batches (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),request_id uuid NOT NULL UNIQUE,
    ledger_id uuid NOT NULL REFERENCES ar_ap_ledger(id),revision bigint NOT NULL CHECK(revision>=0),
    direction text NOT NULL CHECK(direction IN('AR','AP')),party_id uuid NOT NULL,currency_id uuid NOT NULL REFERENCES currencies(id),
    effective_from date NOT NULL,amount_original numeric NOT NULL CHECK(fn_financial_amount_is_exact(amount_original)),
    amount_local numeric NOT NULL CHECK(fn_financial_book_amount_is_exact(amount_local)),
    source_reference text NOT NULL CHECK(length(btrim(source_reference)) BETWEEN 1 AND 2000),
    fingerprint text NOT NULL CHECK(fingerprint~'^[0-9a-f]{64}$'),
    created_at timestamptz NOT NULL DEFAULT now(),created_by uuid NOT NULL REFERENCES users(id),created_tx xid8 NOT NULL DEFAULT pg_current_xact_id(),
    UNIQUE(ledger_id,revision)
);
CREATE TABLE finance_open_item_classification_parts (
    batch_id uuid NOT NULL REFERENCES finance_open_item_classification_batches(id),
    category text NOT NULL CHECK(category IN('GOODS','MOULD','MATERIAL')),
    amount_original numeric NOT NULL CHECK(fn_financial_amount_is_exact(amount_original)),
    amount_local numeric NOT NULL CHECK(fn_financial_book_amount_is_exact(amount_local)),PRIMARY KEY(batch_id,category)
);
CREATE TABLE finance_payment_classification_batches (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),request_id uuid NOT NULL UNIQUE,
    payment_line_id uuid NOT NULL REFERENCES finance_payment_lines(id),revision bigint NOT NULL CHECK(revision>=0),
    source_classification_id uuid NOT NULL REFERENCES finance_open_item_classification_batches(id),
    currency_id uuid NOT NULL REFERENCES currencies(id),amount_original numeric NOT NULL CHECK(fn_financial_amount_is_exact(amount_original)),
    cash_local numeric NOT NULL CHECK(fn_financial_book_amount_is_exact(cash_local)),
    book_local numeric NOT NULL CHECK(fn_financial_book_amount_is_exact(book_local)),
    source_reference text NOT NULL CHECK(length(btrim(source_reference)) BETWEEN 1 AND 2000),
    fingerprint text NOT NULL CHECK(fingerprint~'^[0-9a-f]{64}$'),
    created_at timestamptz NOT NULL DEFAULT now(),created_by uuid NOT NULL REFERENCES users(id),created_tx xid8 NOT NULL DEFAULT pg_current_xact_id(),UNIQUE(payment_line_id,revision)
);
CREATE TABLE finance_payment_classification_parts (
    batch_id uuid NOT NULL REFERENCES finance_payment_classification_batches(id),
    category text NOT NULL CHECK(category IN('GOODS','MOULD')),amount_original numeric NOT NULL CHECK(amount_original>=0 AND fn_financial_amount_is_exact(amount_original)),
    cash_local numeric NOT NULL CHECK(cash_local>=0 AND fn_financial_book_amount_is_exact(cash_local)),
    book_local numeric NOT NULL CHECK(book_local>=0 AND fn_financial_book_amount_is_exact(book_local)),
    PRIMARY KEY(batch_id,category)
);
CREATE TABLE finance_supplier_offset_classification_batches (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),request_id uuid NOT NULL UNIQUE,
    offset_id uuid NOT NULL REFERENCES supplier_open_item_offsets(id),revision bigint NOT NULL CHECK(revision>=0),
    source_classification_id uuid NOT NULL REFERENCES finance_open_item_classification_batches(id),
    target_classification_id uuid NOT NULL REFERENCES finance_open_item_classification_batches(id),
    amount_original numeric NOT NULL CHECK(fn_financial_amount_is_exact(amount_original)),
    source_local numeric NOT NULL CHECK(fn_financial_book_amount_is_exact(source_local)),
    target_local numeric NOT NULL CHECK(fn_financial_book_amount_is_exact(target_local)),
    source_reference text NOT NULL CHECK(length(btrim(source_reference)) BETWEEN 1 AND 2000),
    fingerprint text NOT NULL CHECK(fingerprint~'^[0-9a-f]{64}$'),
    created_at timestamptz NOT NULL DEFAULT now(),created_by uuid NOT NULL REFERENCES users(id),created_tx xid8 NOT NULL DEFAULT pg_current_xact_id(),UNIQUE(offset_id,revision)
);
CREATE TABLE finance_supplier_offset_classification_parts (
    batch_id uuid NOT NULL REFERENCES finance_supplier_offset_classification_batches(id),
    source_category text NOT NULL CHECK(source_category IN('GOODS','MOULD')),target_category text NOT NULL CHECK(target_category IN('GOODS','MOULD')),
    amount_original numeric NOT NULL CHECK(amount_original>=0 AND fn_financial_amount_is_exact(amount_original)),
    source_local numeric NOT NULL CHECK(source_local>=0 AND fn_financial_book_amount_is_exact(source_local)),
    target_local numeric NOT NULL CHECK(target_local>=0 AND fn_financial_book_amount_is_exact(target_local)),PRIMARY KEY(batch_id,source_category,target_category)
);

CREATE VIEW v_finance_open_item_classification_current AS
SELECT DISTINCT ON(ledger_id) * FROM finance_open_item_classification_batches ORDER BY ledger_id,revision DESC;
CREATE VIEW v_finance_payment_classification_current AS
SELECT DISTINCT ON(payment_line_id) * FROM finance_payment_classification_batches ORDER BY payment_line_id,revision DESC;
CREATE VIEW v_finance_supplier_offset_classification_current AS
SELECT DISTINCT ON(offset_id) * FROM finance_supplier_offset_classification_batches ORDER BY offset_id,revision DESC;

CREATE OR REPLACE FUNCTION fn_finance_classification_serial()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    PERFORM pg_advisory_xact_lock(hashtextextended('uten:open-item-classification',0));
    IF TG_TABLE_NAME='finance_open_item_classification_batches' THEN
      IF (
        EXISTS(SELECT 1 FROM finance_payment_classification_batches pay JOIN finance_open_item_classification_batches source ON source.id=pay.source_classification_id WHERE source.ledger_id=NEW.ledger_id)
        OR EXISTS(SELECT 1 FROM finance_supplier_offset_classification_batches off JOIN finance_open_item_classification_batches source ON source.id IN(off.source_classification_id,off.target_classification_id) WHERE source.ledger_id=NEW.ledger_id)) THEN
        RAISE EXCEPTION '该往来分类已被付款或抵销分配引用，不能独立改变来源分类；须受控更正' USING ERRCODE='23514';
      END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION fn_finance_source_classification_reconcile()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE batch uuid; head finance_open_item_classification_batches%ROWTYPE; source_original numeric;source_local numeric;source_party uuid;source_currency uuid;source_direction text;source_date date;sum_original numeric;sum_local numeric;bad boolean;
BEGIN
    IF TG_TABLE_NAME='finance_open_item_classification_batches' THEN batch:=NEW.id;ELSE batch:=NEW.batch_id;END IF;
    SELECT * INTO head FROM finance_open_item_classification_batches WHERE id=batch;
    SELECT CASE WHEN ledger.legacy_import_run_id IS NULL THEN ledger.amount_original ELSE (proof.initial_state->>'amount_balance_original')::numeric END,
           CASE WHEN ledger.legacy_import_run_id IS NULL THEN ledger.amount_original_local ELSE (proof.initial_state->>'amount_balance')::numeric END,
           CASE WHEN ledger.direction='AP' THEN ledger.supplier_id ELSE ledger.client_id END,ledger.currency_id,ledger.direction,
           CASE WHEN ledger.legacy_import_run_id IS NULL THEN ledger.bill_date ELSE ((ledger.legacy_source_resolution->>'snapshotAsOfUtc')::timestamptz AT TIME ZONE 'Asia/Shanghai')::date END
      INTO source_original,source_local,source_party,source_currency,source_direction,source_date
      FROM ar_ap_ledger ledger LEFT JOIN legacy_finance_import_sources proof ON proof.run_id=ledger.legacy_import_run_id AND proof.target_id=ledger.id AND proof.target_table='ar_ap_ledger'
      WHERE ledger.id=head.ledger_id AND ledger.status IN(1,-1) AND (ledger.legacy_id IS NULL OR ledger.legacy_import_run_id IS NOT NULL)
        AND (ledger.open_item_kind NOT IN('PREPAYMENT','CUSTOMER_PREPAYMENT') OR ledger.legacy_import_run_id IS NOT NULL);
    IF source_original IS NULL OR source_local IS NULL OR
       (head.amount_original,head.amount_local,head.party_id,head.currency_id,head.direction,head.effective_from)
       IS DISTINCT FROM(source_original,source_local,source_party,source_currency,source_direction,source_date) THEN
        RAISE EXCEPTION '分类批次必须保留已核验原往来项目、本币、原币、对象及日期' USING ERRCODE='23514';
    END IF;
    SELECT sum(amount_original),sum(amount_local),bool_or(
        (head.direction='AP' AND category NOT IN('GOODS','MOULD')) OR (head.direction='AR' AND category NOT IN('GOODS','MATERIAL'))
        OR(amount_original<>0 AND sign(amount_original)<>sign(source_original)) OR(amount_local<>0 AND sign(amount_local)<>sign(source_local)))
       INTO sum_original,sum_local,bad FROM finance_open_item_classification_parts WHERE batch_id=batch;
    IF sum_original IS DISTINCT FROM source_original OR sum_local IS DISTINCT FROM source_local OR COALESCE(bad,false) THEN
        RAISE EXCEPTION '往来分类原币与本币必须分别完整守恒且同向' USING ERRCODE='23514';
    END IF;
    RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION fn_finance_payment_classification_reconcile()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE batch uuid;head finance_payment_classification_batches%ROWTYPE;source_original numeric;cash numeric;book numeric;source_currency uuid;source_ledger uuid;source_party uuid;sum_original numeric;sum_cash numeric;sum_book numeric;bad boolean;
BEGIN
    IF TG_TABLE_NAME='finance_payment_classification_batches' THEN batch:=NEW.id;ELSE batch:=NEW.batch_id;END IF;
    SELECT * INTO head FROM finance_payment_classification_batches WHERE id=batch;
    SELECT line.amount_original,line.amount_local,COALESCE(line.applied_amount_local,CASE WHEN line.amount_local IS NOT NULL AND line.exchange_diff IS NOT NULL THEN line.amount_local-line.exchange_diff END),payment.currency_id,line.applied_ledger_id,payment.supplier_id
       INTO source_original,cash,book,source_currency,source_ledger,source_party FROM finance_payment_lines line JOIN finance_payments payment ON payment.id=line.payment_id
       WHERE line.id=head.payment_line_id AND NOT line.is_deleted AND payment.status IN(1,-1) AND NOT payment.is_deleted AND payment.amount_authority_version>0;
    IF source_original IS NULL OR cash IS NULL OR book IS NULL OR
       (head.amount_original,head.cash_local,head.book_local,head.currency_id) IS DISTINCT FROM(source_original,cash,book,source_currency)
       OR NOT EXISTS(SELECT 1 FROM v_finance_open_item_classification_current current WHERE current.id=head.source_classification_id AND current.ledger_id=source_ledger AND current.direction='AP' AND current.currency_id=source_currency AND current.party_id=source_party) THEN
        RAISE EXCEPTION '付款分类必须引用原付款行及当前已确认的应付分类；原币、实付和账面核销不得换算重写' USING ERRCODE='23514';
    END IF;
    SELECT sum(part.amount_original),sum(part.cash_local),sum(part.book_local),bool_or(NOT EXISTS(
        SELECT 1 FROM finance_open_item_classification_parts source WHERE source.batch_id=head.source_classification_id AND source.category=part.category))
        INTO sum_original,sum_cash,sum_book,bad FROM finance_payment_classification_parts part WHERE part.batch_id=batch;
    IF sum_original IS DISTINCT FROM source_original OR sum_cash IS DISTINCT FROM cash OR sum_book IS DISTINCT FROM book OR COALESCE(bad,false) THEN
        RAISE EXCEPTION '同一付款行的原币、实际现金本币与账面核销本币必须分别完整守恒' USING ERRCODE='23514';
    END IF;
    RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION fn_finance_offset_classification_reconcile()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE batch uuid;head finance_supplier_offset_classification_batches%ROWTYPE;source supplier_open_item_offsets%ROWTYPE;a numeric;b numeric;c numeric;bad boolean;
BEGIN
    IF TG_TABLE_NAME='finance_supplier_offset_classification_batches' THEN batch:=NEW.id;ELSE batch:=NEW.batch_id;END IF;
    SELECT * INTO head FROM finance_supplier_offset_classification_batches WHERE id=batch;
    SELECT * INTO source FROM supplier_open_item_offsets WHERE id=head.offset_id;
    IF (head.amount_original,head.source_local,head.target_local) IS DISTINCT FROM(source.amount_original,source.source_amount_local,source.target_amount_local)
       OR NOT EXISTS(SELECT 1 FROM v_finance_open_item_classification_current current WHERE current.id=head.source_classification_id AND current.ledger_id=source.source_ledger_id AND current.direction='AP' AND current.currency_id=source.currency_id AND current.party_id=source.supplier_id)
       OR NOT EXISTS(SELECT 1 FROM v_finance_open_item_classification_current current WHERE current.id=head.target_classification_id AND current.ledger_id=source.target_ledger_id AND current.direction='AP' AND current.currency_id=source.currency_id AND current.party_id=source.supplier_id) THEN
        RAISE EXCEPTION '抵销分类必须引用原抵销记录两端的明确应付项目及当前分类，金额不能重写' USING ERRCODE='23514';
    END IF;
    SELECT sum(part.amount_original),sum(part.source_local),sum(part.target_local),bool_or(
        NOT EXISTS(SELECT 1 FROM finance_open_item_classification_parts p WHERE p.batch_id=head.source_classification_id AND p.category=part.source_category)
        OR NOT EXISTS(SELECT 1 FROM finance_open_item_classification_parts p WHERE p.batch_id=head.target_classification_id AND p.category=part.target_category))
       INTO a,b,c,bad FROM finance_supplier_offset_classification_parts part WHERE part.batch_id=batch;
    IF a IS DISTINCT FROM source.amount_original OR b IS DISTINCT FROM source.source_amount_local OR c IS DISTINCT FROM source.target_amount_local OR COALESCE(bad,false) THEN
        RAISE EXCEPTION '同一抵销的原币、贷项账面本币、应付账面本币必须分别完整守恒' USING ERRCODE='23514';
    END IF;
    RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION fn_finance_classification_immutable()
RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION '分类及付款分摊批次保留历史，不得覆盖；请提交新版本' USING ERRCODE='23514';END;$$;
CREATE TRIGGER trg_finance_settlement_dependencies_immutable BEFORE UPDATE OR DELETE ON finance_supplier_settlement_dependencies
    FOR EACH ROW EXECUTE FUNCTION fn_finance_classification_immutable();
CREATE TRIGGER trg_finance_settlement_dependencies_audit AFTER INSERT ON finance_supplier_settlement_dependencies
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
ALTER TABLE finance_supplier_settlement_dependencies ENABLE ALWAYS TRIGGER trg_finance_settlement_dependencies_audit;
CREATE OR REPLACE FUNCTION fn_finance_classification_parts_same_transaction()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE owning_table text;source_transaction xid8;
BEGIN
    owning_table:=regexp_replace(TG_TABLE_NAME,'_parts$','_batches');
    EXECUTE format('SELECT created_tx FROM %I WHERE id=$1',owning_table) INTO source_transaction USING NEW.batch_id;
    IF source_transaction IS DISTINCT FROM pg_current_xact_id() THEN
        RAISE EXCEPTION '分类批次须在同一事务完整提交，不能追加修改已保存的历史批次' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END;$$;
CREATE OR REPLACE FUNCTION fn_finance_classification_source_basis_immutable()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_TABLE_NAME='ar_ap_ledger' THEN
      IF (NEW.direction,NEW.source_doc_type,NEW.source_doc_id,NEW.bill_date,NEW.client_id,NEW.supplier_id,NEW.currency_id,NEW.amount_original,NEW.amount_original_local,NEW.legacy_import_run_id,NEW.legacy_source_resolution)
          IS DISTINCT FROM(OLD.direction,OLD.source_doc_type,OLD.source_doc_id,OLD.bill_date,OLD.client_id,OLD.supplier_id,OLD.currency_id,OLD.amount_original,OLD.amount_original_local,OLD.legacy_import_run_id,OLD.legacy_source_resolution) THEN
        PERFORM pg_advisory_xact_lock(hashtextextended('uten:open-item-classification',0));
        IF EXISTS(SELECT 1 FROM finance_open_item_classification_batches WHERE ledger_id=OLD.id) THEN
          RAISE EXCEPTION '已分类往来的原金额、币别、来源及证明不可覆盖，须受控更正' USING ERRCODE='23514';
        END IF;
      END IF;
    ELSE
      IF (NEW.payment_id,NEW.applied_ledger_id,NEW.amount_original,NEW.amount_local,NEW.applied_amount_local,NEW.exchange_diff)
          IS DISTINCT FROM(OLD.payment_id,OLD.applied_ledger_id,OLD.amount_original,OLD.amount_local,OLD.applied_amount_local,OLD.exchange_diff) THEN
        PERFORM pg_advisory_xact_lock(hashtextextended('uten:open-item-classification',0));
        IF EXISTS(SELECT 1 FROM finance_payment_classification_batches WHERE payment_line_id=OLD.id) THEN
          RAISE EXCEPTION '已分摊付款行的原现金及核销金额不可覆盖，须受控更正' USING ERRCODE='23514';
        END IF;
      END IF;
    END IF;
    RETURN NEW;
END;$$;
CREATE TRIGGER trg_finance_classified_open_item_basis BEFORE UPDATE ON ar_ap_ledger FOR EACH ROW EXECUTE FUNCTION fn_finance_classification_source_basis_immutable();
CREATE TRIGGER trg_finance_classified_payment_line_basis BEFORE UPDATE ON finance_payment_lines FOR EACH ROW EXECUTE FUNCTION fn_finance_classification_source_basis_immutable();
DO $$
DECLARE pair text[];table_name text;
BEGIN
    FOREACH pair SLICE 1 IN ARRAY ARRAY[
      ['finance_open_item_classification_batches','fn_finance_source_classification_reconcile'],['finance_open_item_classification_parts','fn_finance_source_classification_reconcile'],
      ['finance_payment_classification_batches','fn_finance_payment_classification_reconcile'],['finance_payment_classification_parts','fn_finance_payment_classification_reconcile'],
      ['finance_supplier_offset_classification_batches','fn_finance_offset_classification_reconcile'],['finance_supplier_offset_classification_parts','fn_finance_offset_classification_reconcile']]
    LOOP
      table_name:=pair[1];
      EXECUTE format('CREATE TRIGGER %I BEFORE UPDATE OR DELETE ON %I FOR EACH ROW EXECUTE FUNCTION fn_finance_classification_immutable()',table_name||'_immutable',table_name);
      EXECUTE format('CREATE CONSTRAINT TRIGGER %I AFTER INSERT ON %I DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION %I()',table_name||'_reconcile',table_name,pair[2]);
      EXECUTE format('CREATE TRIGGER %I AFTER INSERT ON %I FOR EACH ROW EXECUTE FUNCTION fn_audit()',table_name||'_audit',table_name);
      EXECUTE format('ALTER TABLE %I ENABLE ALWAYS TRIGGER %I',table_name,table_name||'_audit');
      IF table_name LIKE '%batches' THEN
        EXECUTE format('CREATE TRIGGER %I BEFORE INSERT ON %I FOR EACH ROW EXECUTE FUNCTION fn_finance_classification_serial()',table_name||'_serial',table_name);
      ELSE
        EXECUTE format('CREATE TRIGGER %I BEFORE INSERT ON %I FOR EACH ROW EXECUTE FUNCTION fn_finance_classification_parts_same_transaction()',table_name||'_same_tx',table_name);
      END IF;
    END LOOP;
END;$$;
