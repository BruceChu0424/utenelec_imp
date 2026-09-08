-- V511: one customer-dispatch ledger for order-backed and explicit direct shipments.
-- Forward-only: old other-shipment rows and their movement/financial facts stay in place.
-- This candidate is under implementation; do not apply it to a persistent clone until frozen.

ALTER TABLE sales_shipment_items ADD COLUMN deleted_at TIMESTAMPTZ;

ALTER TABLE sales_shipments
    ADD COLUMN shipment_kind VARCHAR(32) NOT NULL DEFAULT 'ORDER',
    ADD COLUMN billing_mode VARCHAR(16) NOT NULL DEFAULT 'CHARGED',
    ADD COLUMN direct_purpose VARCHAR(32),
    ADD COLUMN free_reason TEXT,
    ADD COLUMN review_revision BIGINT NOT NULL DEFAULT 0,
    ADD COLUMN sales_confirmed_revision BIGINT,
    ADD COLUMN sales_confirmed_at TIMESTAMPTZ,
    ADD COLUMN sales_confirmed_by UUID REFERENCES employees(id),
    ADD COLUMN finance_release_event_id UUID REFERENCES sales_shipment_finance_release_events(id) DEFERRABLE INITIALLY DEFERRED,
    ADD COLUMN finance_rejected BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN finance_rejection_reason TEXT;

-- Missing order lineage is historical uncertainty, not proof of a new DIRECT or FREE shipment.
UPDATE sales_shipments shipment SET shipment_kind='LEGACY'
WHERE NOT EXISTS(SELECT 1 FROM sales_shipment_items item WHERE item.shipment_id=shipment.id AND NOT item.is_deleted)
   OR EXISTS(SELECT 1 FROM sales_shipment_items item WHERE item.shipment_id=shipment.id AND NOT item.is_deleted AND item.order_item_id IS NULL);

ALTER TABLE sales_shipments
    ADD CONSTRAINT sales_shipments_kind_chk CHECK(shipment_kind IN ('ORDER','DIRECT_CUSTOMER','LEGACY')),
    ADD CONSTRAINT sales_shipments_billing_mode_chk CHECK(billing_mode IN ('CHARGED','FREE')),
    ADD CONSTRAINT sales_shipments_review_revision_chk CHECK(review_revision>=0),
    ADD CONSTRAINT sales_shipments_direct_identity_chk CHECK(shipment_kind<>'DIRECT_CUSTOMER' OR
        (client_id IS NOT NULL AND source_order_id IS NULL AND direct_purpose IN ('SAMPLE','GIFT','OTHER')
         AND (billing_mode<>'FREE' OR NULLIF(btrim(free_reason),'') IS NOT NULL))),
    ADD CONSTRAINT sales_shipments_free_mode_chk CHECK(billing_mode<>'FREE' OR shipment_kind='DIRECT_CUSTOMER');

ALTER TABLE sales_shipments DROP CONSTRAINT sales_shipments_finance_gate_version_chk;
ALTER TABLE sales_shipments ADD CONSTRAINT sales_shipments_finance_gate_version_chk CHECK(finance_gate_version IN (0,1,2));
ALTER TABLE sales_shipments ALTER COLUMN finance_gate_version SET DEFAULT 2;

-- Preserve the V443 history gate, permit an explicit forward upgrade, never a downgrade.
CREATE OR REPLACE FUNCTION fn_guard_sales_shipment_finance_release()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP='UPDATE' AND OLD.finance_gate_version=0 AND OLD.status=0 AND OLD.warehouse_work_status='LEGACY_PENDING'
       AND (NEW.status IS DISTINCT FROM OLD.status OR NEW.finance_gate_version IS DISTINCT FROM OLD.finance_gate_version
            OR NEW.finance_audit IS DISTINCT FROM OLD.finance_audit OR NEW.finance_auditor_id IS DISTINCT FROM OLD.finance_auditor_id
            OR NEW.finance_audited_at IS DISTINCT FROM OLD.finance_audited_at OR NEW.warehouse_work_status IS DISTINCT FROM OLD.warehouse_work_status) THEN
        RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='legacy pending sales shipment is read-only and must be manually rebuilt';
    END IF;
    IF TG_OP='INSERT' AND NEW.finance_gate_version<>2
       AND COALESCE(current_setting('uten.legacy_reference_import',TRUE),'')='' THEN
        RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='new customer shipments require the current confirmation workflow';
    END IF;
    IF TG_OP='UPDATE' AND NEW.finance_gate_version<OLD.finance_gate_version THEN
        RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='sales shipment finance gate version cannot be downgraded';
    END IF;
    IF NEW.finance_gate_version>=1 THEN
        IF NEW.finance_audit NOT IN (0,1)
           OR (NEW.finance_audit=0 AND (NEW.finance_auditor_id IS NOT NULL OR NEW.finance_audited_at IS NOT NULL))
           OR (NEW.finance_audit=1 AND (NEW.finance_auditor_id IS NULL OR NEW.finance_audited_at IS NULL)) THEN
            RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='sales shipment finance audit facts are incomplete';
        END IF;
        IF NEW.warehouse_work_status IN ('PICKING','PICKED','SHIPPED') AND NEW.finance_audit<>1 THEN
            RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='finance approval is required before warehouse picking or shipment';
        END IF;
    END IF;
    RETURN NEW;
END $$;

UPDATE permissions SET name='新增客户零星发货',description='新增有真实客户的收费或免费发货草稿；不直接扣库存'
WHERE code='sales_other_shipment:create';
UPDATE permissions SET name='编辑客户零星发货',description='修改尚未开始仓库作业的客户零星发货；有效财审认领期间禁止修改'
WHERE code='sales_other_shipment:edit';
UPDATE permissions SET name='销售确认客户零星发货',description='确认本次客户发货内容并提交财务；不代替财审和仓库交接'
WHERE code='sales_other_shipment:approve';
UPDATE permissions SET name='取消客户零星发货草稿',description='取消尚未出库且无有效财审认领和拣货占用的客户零星发货'
WHERE code='sales_other_shipment:delete';
UPDATE permission_surfaces SET name='客户零星发货与历史其它出货' WHERE surface_key='sales.other-shipment';

CREATE TABLE sales_shipment_submission_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    shipment_id UUID NOT NULL REFERENCES sales_shipments(id) ON DELETE RESTRICT,
    review_revision BIGINT NOT NULL CHECK(review_revision>=0),
    content_hash CHAR(64) NOT NULL CHECK(content_hash ~ '^[a-f0-9]{64}$'),
    commercial_snapshot JSONB NOT NULL,
    actor_user_id UUID NOT NULL REFERENCES users(id),
    actor_employee_id UUID NOT NULL REFERENCES employees(id),
    occurred_at TIMESTAMPTZ NOT NULL,
    UNIQUE(shipment_id,review_revision)
);
CREATE TRIGGER trg_audit_sales_shipment_submission_events
    AFTER INSERT OR UPDATE OR DELETE ON sales_shipment_submission_events
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_guard_sales_shipment_submission_events_append_only
    BEFORE UPDATE OR DELETE ON sales_shipment_submission_events
    FOR EACH ROW EXECUTE FUNCTION fn_guard_sales_shipment_finance_release_event_append_only();
ALTER TABLE sales_shipment_submission_events ENABLE ALWAYS TRIGGER trg_guard_sales_shipment_submission_events_append_only;

ALTER TABLE sales_shipment_finance_release_events
    ADD COLUMN review_revision BIGINT,
    ADD COLUMN claim_id UUID REFERENCES task_claims(id),
    ADD COLUMN content_hash CHAR(64),
    ADD COLUMN commercial_snapshot JSONB,
    ADD COLUMN billing_mode VARCHAR(16),
    ADD COLUMN reverses_event_id UUID REFERENCES sales_shipment_finance_release_events(id),
    ADD COLUMN decision_reason TEXT;
ALTER TABLE sales_shipment_finance_release_events DROP CONSTRAINT sales_shipment_finance_release_event_type_chk;
ALTER TABLE sales_shipment_finance_release_events ADD CONSTRAINT sales_shipment_finance_release_event_type_chk
    CHECK(event_type IN ('RELEASED','REVOKED','REJECTED'));
ALTER TABLE sales_shipment_finance_release_events DROP CONSTRAINT sales_shipment_finance_release_event_released_type_chk;
ALTER TABLE sales_shipment_finance_release_events ADD CONSTRAINT sales_shipment_finance_release_event_released_type_chk
    CHECK(event_type<>'RELEASED' OR sales_payment_type IS NOT NULL OR billing_mode IS NOT DISTINCT FROM 'FREE');
CREATE UNIQUE INDEX uq_shipment_review_claim_decision ON sales_shipment_finance_release_events(claim_id)
    WHERE claim_id IS NOT NULL AND event_type IN ('RELEASED','REJECTED');
CREATE INDEX idx_customer_shipment_pending_finance ON sales_shipments(finance_audit,bill_date,id)
    WHERE status=0 AND NOT is_deleted AND NOT rejected AND NOT finance_rejected
      AND warehouse_work_status='PENDING_PICK' AND sales_confirmed_at IS NOT NULL;
CREATE INDEX idx_direct_customer_shipment_list ON sales_shipments(shipment_kind,status,bill_date,id)
    WHERE NOT is_deleted;

ALTER TABLE stock_reservations
    DROP CONSTRAINT stock_reservations_owner_type_chk,
    DROP CONSTRAINT stock_reservations_purpose_chk,
    DROP CONSTRAINT stock_reservations_owner_shape_chk;

ALTER TABLE stock_reservations
    ADD CONSTRAINT stock_reservations_owner_type_chk CHECK (
        owner_type IN (
            'SALES_ORDER_ITEM', 'PRODUCTION_MATERIAL_DEMAND',
            'PREPLAN_ANALYSIS', 'SUBCONTRACT_OUTBOUND',
            'SUBCONTRACT_PREPARE_TASK', 'CUSTOMER_SHIPMENT_ITEM'
        )
    ),
    ADD CONSTRAINT stock_reservations_purpose_chk CHECK (
        purpose IN (
            'SALES_FULFILLMENT', 'PRODUCTION_MATERIAL',
            'PREPLAN_MATERIAL', 'SUBCONTRACT_OUTBOUND',
            'SUBCONTRACT_PREPARE_TASK', 'CUSTOMER_SHIPMENT_ITEM'
        )
    ),
    ADD CONSTRAINT stock_reservations_owner_shape_chk CHECK (
        (
            owner_type = 'SALES_ORDER_ITEM'
            AND purpose = 'SALES_FULFILLMENT'
            AND order_item_id IS NOT NULL
            AND owner_id = order_item_id
            AND demand_id IS NULL
        )
        OR
        (
            owner_type = 'PRODUCTION_MATERIAL_DEMAND'
            AND purpose = 'PRODUCTION_MATERIAL'
            AND order_item_id IS NULL
            AND demand_id IS NOT NULL
            AND owner_id = demand_id
            AND warehouse_id IS NOT NULL
            AND supply_type = 'STOCK_BALANCE'
            AND supply_id IS NOT NULL
            AND idempotency_key IS NOT NULL
        )
        OR
        (
            owner_type = 'PREPLAN_ANALYSIS'
            AND purpose = 'PREPLAN_MATERIAL'
            AND order_item_id IS NULL
            AND demand_id IS NULL
            AND owner_id IS NOT NULL
            AND warehouse_id IS NOT NULL
            AND supply_type IN (
                'PURCHASE_REQUEST_ITEM',
                'SUBCONTRACT_APPLICATION_ITEM',
                'PRODUCTION_PLAN_ITEM',
                'MATERIAL_REALLOCATION_PRIORITY'
            )
            AND supply_id IS NOT NULL
            AND idempotency_key IS NOT NULL
        )
        OR
        (
            owner_type = 'SUBCONTRACT_OUTBOUND'
            AND purpose = 'SUBCONTRACT_OUTBOUND'
            AND order_item_id IS NULL
            AND demand_id IS NULL
            AND owner_id IS NOT NULL
            AND warehouse_id IS NOT NULL
            AND supply_type IN ('STOCK_BALANCE', 'PRODUCTION_FINISHED_IN')
            AND supply_id IS NOT NULL
            AND idempotency_key IS NOT NULL
        )
        OR
        (
            owner_type = 'SUBCONTRACT_PREPARE_TASK'
            AND purpose = 'SUBCONTRACT_PREPARE_TASK'
            AND order_item_id IS NULL
            AND demand_id IS NULL
            AND owner_id IS NOT NULL
            AND warehouse_id IS NOT NULL
            AND supply_type = 'PRODUCTION_FINISHED_IN'
            AND supply_id IS NOT NULL
            AND idempotency_key IS NOT NULL
        )
        OR
        (
            owner_type='CUSTOMER_SHIPMENT_ITEM' AND purpose='CUSTOMER_SHIPMENT_ITEM'
            AND order_item_id IS NULL AND demand_id IS NULL AND owner_id IS NOT NULL
            AND warehouse_id IS NOT NULL AND supply_type='STOCK_BALANCE'
            AND supply_id IS NOT NULL AND idempotency_key IS NOT NULL
            AND source_doc_type='SALES_SHIPMENT' AND source_doc_id IS NOT NULL
        )
    );


CREATE UNIQUE INDEX uq_customer_shipment_item_active_reservation ON stock_reservations(owner_id)
    WHERE owner_type='CUSTOMER_SHIPMENT_ITEM' AND status=0 AND NOT is_deleted;

CREATE FUNCTION fn_customer_shipment_commercial_snapshot(p_shipment_id UUID)
RETURNS TEXT LANGUAGE sql STABLE AS $snapshot$
SELECT jsonb_build_object('header',jsonb_build_object(
                    'clientId',document.client_id,'warehouseId',document.warehouse_id,'currencyId',document.currency_id,
                    'taxRate',trim_scale(document.tax_rate)::text,'settlementMethodId',document.settlement_method_id,'billDate',document.bill_date,
                    'shipmentKind',document.shipment_kind,'billingMode',document.billing_mode,'purpose',document.direct_purpose,
                    'freeReason',document.free_reason,'shipAddr',document.ship_addr,'linkPhone',document.link_phone,'remark',document.remark,
                    'sellerId',document.seller_id,'senderId',document.sender_id,'parcelCount',document.parcel_count,'logisticsNo',document.logistics_no),
                    'items',COALESCE((SELECT jsonb_agg(jsonb_build_object('id',item.id,'lineNo',item.line_no,
                        'orderItemId',item.order_item_id,'goodsId',item.goods_id,'colorId',item.color_id,'unitId',item.unit_id,
                        'unitRate',trim_scale(item.unit_rate)::text,'qty',trim_scale(item.qty)::text,'price',trim_scale(item.price)::text,'discount',trim_scale(item.discount)::text,
                        'amountOriginal',trim_scale(item.amount_original)::text,'weight',trim_scale(item.weight)::text,'remark',item.remark,'parcelQty',trim_scale(item.parcel_qty)::text,
                        'cartonCount',trim_scale(item.carton_count)::text,'clientNo',item.client_no,'clientModel',item.client_model,'materialPrice',trim_scale(item.material_price)::text,
                        'dieCastPrice',trim_scale(item.die_cast_price)::text,'machiningPrice',trim_scale(item.machining_price)::text,'circumference',trim_scale(item.circumference)::text)
                        ORDER BY item.line_no,item.id) FROM sales_shipment_items item
                        WHERE item.shipment_id=document.id AND NOT item.is_deleted),'[]'::jsonb))::text
                FROM sales_shipments document WHERE document.id=p_shipment_id
$snapshot$;

CREATE FUNCTION fn_customer_shipment_snapshot_hash(p_snapshot TEXT)
RETURNS TEXT LANGUAGE sql IMMUTABLE STRICT AS $$
    SELECT encode(digest(octet_length(convert_to(p_snapshot,'UTF8'))::text||':'||p_snapshot||E'\n','sha256'),'hex')
$$;

CREATE FUNCTION fn_guard_customer_shipment_review_event()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE document sales_shipments%ROWTYPE; frozen TEXT;
BEGIN
    SELECT * INTO document FROM sales_shipments WHERE id=NEW.shipment_id FOR UPDATE;
    IF document.finance_gate_version<2 THEN RETURN NEW; END IF;
    frozen:=fn_customer_shipment_commercial_snapshot(document.id);
    IF NEW.review_revision IS DISTINCT FROM document.review_revision
       OR NEW.content_hash IS DISTINCT FROM fn_customer_shipment_snapshot_hash(frozen)
       OR NEW.commercial_snapshot IS DISTINCT FROM frozen::jsonb THEN
        RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='shipment review content does not match the current revision';
    END IF;
    IF TG_TABLE_NAME='sales_shipment_submission_events' THEN
        IF document.status<>0 OR document.warehouse_work_status<>'PENDING_PICK'
           OR document.is_deleted OR document.rejected
           OR NOT EXISTS(SELECT 1 FROM users WHERE id=NEW.actor_user_id AND employee_id=NEW.actor_employee_id) THEN
            RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='shipment submission requires a current sales task and its actual employee';
        END IF;
    ELSIF NEW.event_type IN ('RELEASED','REJECTED') THEN
        IF NOT EXISTS(SELECT 1 FROM sales_shipment_submission_events submission
                      WHERE submission.shipment_id=document.id AND submission.review_revision=document.review_revision
                        AND submission.content_hash=NEW.content_hash AND submission.commercial_snapshot=NEW.commercial_snapshot)
           OR NOT EXISTS(SELECT 1 FROM task_claims claim JOIN users actor ON actor.employee_id=claim.claimed_by
                         WHERE claim.id=NEW.claim_id AND actor.id=NEW.actor_user_id
                           AND claim.target_type='SALES_SHIPMENT_FINANCE_AUDIT' AND claim.target_key=document.id::text
                           AND claim.released_at IS NULL AND claim.lease_until>clock_timestamp()) THEN
            RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='shipment finance decision requires the submitted revision and the reviewers active claim';
        END IF;
        IF NEW.billing_mode IS DISTINCT FROM document.billing_mode
           OR (NEW.event_type='REJECTED' AND NULLIF(btrim(NEW.decision_reason),'') IS NULL) THEN
            RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='shipment finance decision metadata is incomplete';
        END IF;
    ELSIF NEW.event_type='REVOKED' AND NOT EXISTS(
        SELECT 1 FROM sales_shipment_finance_release_events original WHERE original.id=NEW.reverses_event_id
          AND original.shipment_id=document.id AND original.review_revision=document.review_revision AND original.event_type='RELEASED') THEN
        RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='shipment revoke must identify the original release';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_guard_customer_shipment_submission BEFORE INSERT ON sales_shipment_submission_events
    FOR EACH ROW EXECUTE FUNCTION fn_guard_customer_shipment_review_event();
CREATE TRIGGER trg_guard_customer_shipment_finance_event BEFORE INSERT ON sales_shipment_finance_release_events
    FOR EACH ROW EXECUTE FUNCTION fn_guard_customer_shipment_review_event();
ALTER TABLE sales_shipment_submission_events ENABLE ALWAYS TRIGGER trg_guard_customer_shipment_submission;
ALTER TABLE sales_shipment_finance_release_events ENABLE ALWAYS TRIGGER trg_guard_customer_shipment_finance_event;

CREATE FUNCTION fn_assert_customer_shipment_confirmation(p_shipment UUID)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE document sales_shipments%ROWTYPE; frozen JSONB; submitted sales_shipment_submission_events%ROWTYPE;
        approved sales_shipment_finance_release_events%ROWTYPE;
BEGIN
    SELECT * INTO document FROM sales_shipments WHERE id=p_shipment;
    IF NOT FOUND OR document.finance_gate_version<2 THEN RETURN; END IF;
    IF document.shipment_kind='LEGACY' OR document.client_id IS NULL THEN
        RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='current customer shipments require a real client and an explicit source kind';
    END IF;
    IF NOT EXISTS(SELECT 1 FROM sales_shipment_items WHERE shipment_id=p_shipment AND NOT is_deleted)
       OR EXISTS(SELECT 1 FROM sales_shipment_items item WHERE item.shipment_id=p_shipment AND NOT item.is_deleted
          AND (item.qty<=0 OR item.unit_rate IS NULL OR item.unit_rate<=0
               OR (document.shipment_kind='ORDER' AND item.order_item_id IS NULL)
               OR (document.shipment_kind='DIRECT_CUSTOMER' AND item.order_item_id IS NOT NULL)
               OR (document.billing_mode='FREE' AND (item.price IS DISTINCT FROM 0 OR item.amount_original IS DISTINCT FROM 0)))) THEN
        RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='current customer shipment items do not match the declared workflow';
    END IF;
    IF document.billing_mode='FREE' AND (document.total_original IS DISTINCT FROM 0 OR document.ar_posted) THEN
        RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='free customer shipments cannot create a customer receivable';
    END IF;
    frozen:=fn_customer_shipment_commercial_snapshot(p_shipment)::jsonb;
    IF document.sales_confirmed_revision IS NOT NULL OR document.sales_confirmed_at IS NOT NULL OR document.sales_confirmed_by IS NOT NULL THEN
        SELECT * INTO submitted FROM sales_shipment_submission_events
          WHERE shipment_id=p_shipment AND review_revision=document.review_revision;
        IF NOT FOUND OR document.sales_confirmed_revision IS DISTINCT FROM document.review_revision
           OR document.sales_confirmed_at IS DISTINCT FROM submitted.occurred_at OR document.sales_confirmed_by IS DISTINCT FROM submitted.actor_employee_id THEN
            RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='shipment sales confirmation has no matching immutable submission';
        END IF;
        -- Effective settlement and exchange rates are frozen by the existing SHIPPED recognition contract.
        IF (CASE WHEN document.warehouse_work_status='SHIPPED' THEN frozen#-'{header,settlementMethodId}' ELSE frozen END)
           IS DISTINCT FROM (CASE WHEN document.warehouse_work_status='SHIPPED' THEN submitted.commercial_snapshot#-'{header,settlementMethodId}' ELSE submitted.commercial_snapshot END) THEN
            RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='shipment content changed after sales confirmation';
        END IF;
    END IF;
    IF document.finance_audit=1 THEN
        SELECT * INTO approved FROM sales_shipment_finance_release_events WHERE id=document.finance_release_event_id;
        IF NOT FOUND OR approved.shipment_id<>p_shipment OR approved.event_type<>'RELEASED'
           OR approved.review_revision IS DISTINCT FROM document.review_revision OR submitted.id IS NULL
           OR approved.commercial_snapshot IS DISTINCT FROM submitted.commercial_snapshot
           OR approved.actor_user_id IS DISTINCT FROM document.finance_auditor_id
           OR approved.occurred_at IS DISTINCT FROM document.finance_audited_at
           OR EXISTS(SELECT 1 FROM sales_shipment_finance_release_events WHERE reverses_event_id=approved.id AND event_type='REVOKED') THEN
            RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='shipment finance release has no matching current decision';
        END IF;
    ELSIF document.finance_release_event_id IS NOT NULL THEN
        RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='unapproved shipment cannot retain a finance release';
    END IF;
END $$;

CREATE FUNCTION fn_guard_customer_shipment_confirmation()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF TG_TABLE_NAME='sales_shipments' THEN PERFORM fn_assert_customer_shipment_confirmation(NEW.id);
    ELSE PERFORM fn_assert_customer_shipment_confirmation(CASE WHEN TG_OP='DELETE' THEN OLD.shipment_id ELSE NEW.shipment_id END);
    END IF;
    RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER trg_customer_shipment_confirmation AFTER INSERT OR UPDATE ON sales_shipments
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_guard_customer_shipment_confirmation();
CREATE CONSTRAINT TRIGGER trg_customer_shipment_item_confirmation AFTER INSERT OR UPDATE OR DELETE ON sales_shipment_items
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_guard_customer_shipment_confirmation();
ALTER TABLE sales_shipments ENABLE ALWAYS TRIGGER trg_customer_shipment_confirmation;
ALTER TABLE sales_shipment_items ENABLE ALWAYS TRIGGER trg_customer_shipment_item_confirmation;

CREATE FUNCTION fn_guard_customer_shipment_immutable_facts()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE document sales_shipments%ROWTYPE; changed BOOLEAN;
BEGIN
    IF TG_TABLE_NAME='sales_shipments' THEN
        IF TG_OP='INSERT' THEN
            IF NEW.finance_gate_version>=2 AND NEW.shipment_kind NOT IN ('ORDER','DIRECT_CUSTOMER') THEN
                RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='historical shipment kind cannot be used for a new dispatch';
            END IF;
            RETURN NEW;
        END IF;
        IF OLD.shipment_kind='LEGACY' THEN
            IF (to_jsonb(NEW)-ARRAY['owner_employee_id','updated_at','updated_by'])
                IS DISTINCT FROM (to_jsonb(OLD)-ARRAY['owner_employee_id','updated_at','updated_by']) THEN
                RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='unreconciled historical shipments are read-only';
            END IF;
            RETURN NEW;
        END IF;
        IF OLD.finance_gate_version<2 THEN RETURN NEW; END IF;
        IF NEW.shipment_kind IS DISTINCT FROM OLD.shipment_kind THEN
            RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='shipment source kind is immutable';
        END IF;
        changed:=ROW(NEW.client_id,NEW.warehouse_id,NEW.currency_id,NEW.tax_rate,NEW.bill_date,NEW.billing_mode,
                    NEW.direct_purpose,NEW.free_reason,NEW.ship_addr,NEW.link_phone,NEW.remark,NEW.seller_id,NEW.sender_id,
                    NEW.parcel_count,NEW.logistics_no,NEW.source_order_id,NEW.total_original)
              IS DISTINCT FROM ROW(OLD.client_id,OLD.warehouse_id,OLD.currency_id,OLD.tax_rate,OLD.bill_date,OLD.billing_mode,
                    OLD.direct_purpose,OLD.free_reason,OLD.ship_addr,OLD.link_phone,OLD.remark,OLD.seller_id,OLD.sender_id,
                    OLD.parcel_count,OLD.logistics_no,OLD.source_order_id,OLD.total_original);
        IF OLD.warehouse_work_status='SHIPPED' AND (changed OR NEW.status IS DISTINCT FROM OLD.status
           OR NEW.warehouse_work_status IS DISTINCT FROM OLD.warehouse_work_status OR NEW.is_deleted IS DISTINCT FROM OLD.is_deleted
           OR NEW.exchange_rate IS DISTINCT FROM OLD.exchange_rate OR NEW.total_local IS DISTINCT FROM OLD.total_local
           OR NEW.settlement_method_id IS DISTINCT FROM OLD.settlement_method_id OR NEW.finance_audit IS DISTINCT FROM OLD.finance_audit
           OR NEW.finance_release_event_id IS DISTINCT FROM OLD.finance_release_event_id) THEN
            RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='shipped customer facts are immutable; physical returns and financial adjustments require their own facts';
        END IF;
        document:=OLD;
        changed:=changed OR NEW.review_revision IS DISTINCT FROM OLD.review_revision OR NEW.is_deleted IS DISTINCT FROM OLD.is_deleted
            OR (NEW.settlement_method_id IS DISTINCT FROM OLD.settlement_method_id AND NEW.warehouse_work_status<>'SHIPPED');
    ELSE
        SELECT * INTO document FROM sales_shipments WHERE id=CASE WHEN TG_OP='DELETE' THEN OLD.shipment_id ELSE NEW.shipment_id END FOR UPDATE;
        IF document.shipment_kind='LEGACY' THEN
            IF TG_OP='UPDATE' AND (to_jsonb(NEW)-ARRAY['returned_qty','returned_amount','updated_at','updated_by'])
                IS NOT DISTINCT FROM (to_jsonb(OLD)-ARRAY['returned_qty','returned_amount','updated_at','updated_by']) THEN RETURN NEW; END IF;
            RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='unreconciled historical shipment commercial items are read-only';
        END IF;
        IF document.finance_gate_version<2 THEN RETURN CASE WHEN TG_OP='DELETE' THEN OLD ELSE NEW END; END IF;
        IF TG_OP='DELETE' THEN
            RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='current shipment items retain their historical identity';
        END IF;
        IF TG_OP='INSERT' THEN changed:=TRUE;
        ELSE
            changed:=(to_jsonb(NEW)-ARRAY['returned_qty','returned_amount','updated_at','updated_by','goods_code_snapshot','goods_name_snapshot','goods_snapshot_source','goods_snapshot_locked_at','amount_local','cost_amount'])
                IS DISTINCT FROM (to_jsonb(OLD)-ARRAY['returned_qty','returned_amount','updated_at','updated_by','goods_code_snapshot','goods_name_snapshot','goods_snapshot_source','goods_snapshot_locked_at','amount_local','cost_amount']);
            IF NEW.shipment_id IS DISTINCT FROM OLD.shipment_id THEN
                RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='shipment item cannot change its parent';
            END IF;
        END IF;
        IF document.warehouse_work_status='SHIPPED' AND (changed OR (TG_OP='UPDATE' AND NEW.amount_local IS DISTINCT FROM OLD.amount_local)) THEN
            RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='shipped item commercial facts are immutable';
        END IF;
    END IF;
    IF changed AND EXISTS(SELECT 1 FROM task_claims WHERE target_type='SALES_SHIPMENT_FINANCE_AUDIT'
        AND target_key=document.id::text AND released_at IS NULL AND lease_until>clock_timestamp()) THEN
        RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='shipment content cannot change while finance review is claimed';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_guard_customer_shipment_immutable BEFORE INSERT OR UPDATE ON sales_shipments
    FOR EACH ROW EXECUTE FUNCTION fn_guard_customer_shipment_immutable_facts();
CREATE TRIGGER trg_guard_customer_shipment_item_immutable BEFORE INSERT OR UPDATE OR DELETE ON sales_shipment_items
    FOR EACH ROW EXECUTE FUNCTION fn_guard_customer_shipment_immutable_facts();
ALTER TABLE sales_shipments ENABLE ALWAYS TRIGGER trg_guard_customer_shipment_immutable;
ALTER TABLE sales_shipment_items ENABLE ALWAYS TRIGGER trg_guard_customer_shipment_item_immutable;

CREATE FUNCTION fn_guard_retired_sales_other_shipment_write()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP='INSERT' AND COALESCE(current_setting('uten.legacy_reference_import',TRUE),'')<>'' THEN RETURN NEW; END IF;
    IF TG_OP='UPDATE' AND (to_jsonb(NEW)-ARRAY['owner_employee_id','updated_at','updated_by'])
        IS NOT DISTINCT FROM (to_jsonb(OLD)-ARRAY['owner_employee_id','updated_at','updated_by']) THEN RETURN NEW; END IF;
    IF TG_OP='UPDATE' AND OLD.status=1 AND NEW.status=-1
       AND (to_jsonb(NEW)-ARRAY['status','updated_at','updated_by']) IS NOT DISTINCT FROM (to_jsonb(OLD)-ARRAY['status','updated_at','updated_by']) THEN RETURN NEW; END IF;
    RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='historical other shipments are read-only; create a current customer shipment for new deliveries';
END $$;
CREATE TRIGGER trg_guard_retired_sales_other_shipment BEFORE INSERT OR UPDATE OR DELETE ON sales_other_shipments
    FOR EACH ROW EXECUTE FUNCTION fn_guard_retired_sales_other_shipment_write();
ALTER TABLE sales_other_shipments ENABLE ALWAYS TRIGGER trg_guard_retired_sales_other_shipment;

-- This is an exact dispatch identity, not a blanket exemption for missing order links.
CREATE FUNCTION fn_is_direct_customer_shipment_ar(p_ledger UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT EXISTS(SELECT 1 FROM ar_ap_ledger ledger
        JOIN sales_shipments shipment ON shipment.id=ledger.source_doc_id AND ledger.source_doc_type='SALES_SHIPMENT'
        JOIN sales_shipment_finance_release_events decision ON decision.id=shipment.finance_release_event_id
        WHERE ledger.id=p_ledger AND ledger.direction='AR' AND ledger.open_item_kind='RECEIVABLE'
          AND ledger.status=1 AND NOT ledger.is_deleted AND shipment.status=1 AND NOT shipment.is_deleted
          AND shipment.shipment_kind='DIRECT_CUSTOMER' AND shipment.billing_mode='CHARGED'
          AND shipment.finance_gate_version>=2 AND shipment.warehouse_work_status='SHIPPED'
          AND shipment.ar_posted AND shipment.finance_audit=1 AND shipment.source_order_id IS NULL
          AND decision.shipment_id=shipment.id AND decision.event_type='RELEASED' AND decision.review_revision=shipment.review_revision
          AND ledger.client_id=shipment.client_id AND ledger.currency_id=shipment.currency_id
          AND ledger.exchange_rate=shipment.exchange_rate AND ledger.amount_original=shipment.total_original
          AND ledger.amount_original_local=shipment.total_local
          AND ledger.settlement_type_id IS NOT DISTINCT FROM shipment.settlement_method_id
          AND NOT EXISTS(SELECT 1 FROM sales_shipment_items item WHERE item.shipment_id=shipment.id AND NOT item.is_deleted AND item.order_item_id IS NOT NULL)
          AND NOT EXISTS(SELECT 1 FROM ar_ap_source_refs WHERE ledger_id=ledger.id))
$$;

CREATE OR REPLACE FUNCTION fn_assert_receipt_source_conservation(v_line_id UUID)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE v_cash NUMERIC(18,4); v_writeoff NUMERIC(18,4); v_book NUMERIC(18,4);
        v_alloc_cash NUMERIC(18,4); v_alloc_writeoff NUMERIC(18,4); v_alloc_book NUMERIC(18,4);
        v_ledger UUID; v_client UUID; v_currency UUID; v_line_client UUID; v_line_currency UUID;
        v_ledger_row ar_ap_ledger%ROWTYPE;
BEGIN
    SELECT line.amount_original,line.write_off_amount,line.applied_amount_local,line.applied_ledger_id,
           receipt.client_id,receipt.currency_id,line.client_id,line.currency_id
      INTO v_cash,v_writeoff,v_book,v_ledger,v_client,v_currency,v_line_client,v_line_currency
    FROM finance_receipt_lines line JOIN finance_receipts receipt ON receipt.id=line.receipt_id
    WHERE line.id=v_line_id AND receipt.status=1 AND receipt.receipt_kind='AR_SETTLEMENT';
    IF v_cash IS NULL THEN RETURN; END IF;
    IF fn_is_direct_customer_shipment_ar(v_ledger) THEN
        SELECT * INTO v_ledger_row FROM ar_ap_ledger WHERE id=v_ledger;
        IF v_client IS DISTINCT FROM v_ledger_row.client_id OR v_currency IS DISTINCT FROM v_ledger_row.currency_id
           OR v_line_client IS DISTINCT FROM v_client OR v_line_currency IS DISTINCT FROM v_currency
           OR EXISTS(SELECT 1 FROM finance_receipt_source_allocations WHERE receipt_line_id=v_line_id) THEN
            RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='direct shipment receipt must retain its actual AR identity without invented orders';
        END IF;
        SELECT COALESCE(SUM(line.amount_original),0),COALESCE(SUM(line.write_off_amount),0),COALESCE(SUM(line.applied_amount_local),0)
          INTO v_alloc_cash,v_alloc_writeoff,v_alloc_book
        FROM finance_receipt_lines line JOIN finance_receipts receipt ON receipt.id=line.receipt_id
        WHERE line.applied_ledger_id=v_ledger AND receipt.status=1 AND NOT receipt.is_deleted AND NOT line.is_deleted;
        IF v_alloc_cash IS DISTINCT FROM v_ledger_row.amount_received_original
           OR v_alloc_writeoff IS DISTINCT FROM v_ledger_row.amount_write_off_original
           OR v_alloc_book IS DISTINCT FROM v_ledger_row.amount_settled THEN
            RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='direct shipment receipts do not conserve actual AR settlement snapshots',
                CONSTRAINT='finance_receipt_source_allocation_conservation_guard';
        END IF;
        RETURN;
    END IF;
    -- Original V379 order allocation guard remains intact for order and unresolved historical sources.
    SELECT COALESCE(SUM(cash_original),0),COALESCE(SUM(write_off_original),0),COALESCE(SUM(applied_book_local),0)
      INTO v_alloc_cash,v_alloc_writeoff,v_alloc_book
    FROM finance_receipt_source_allocations WHERE receipt_line_id=v_line_id AND status='APPLIED';
    IF v_alloc_cash<>v_cash OR v_alloc_writeoff<>v_writeoff OR v_alloc_book<>v_book THEN
        RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='finance receipt source allocations do not conserve the approved line snapshots',
            CONSTRAINT='finance_receipt_source_allocation_conservation_guard';
    END IF;
END $$;
