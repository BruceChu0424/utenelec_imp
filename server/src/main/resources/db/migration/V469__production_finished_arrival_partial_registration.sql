-- V469: a warehouse may send selected finished-goods report lines to FQC
-- while unselected lines remain recoverable arrival-registration work.
--
-- Existing V430 registration/item/FQC rows are immutable historical facts.
-- This migration only relaxes the report-level one-shot constraint; the exact
-- report-item identity stays globally unique, append-only, audited and guarded.

ALTER TABLE production_finished_arrival_registrations
    DROP CONSTRAINT
        production_finished_arrival_registrations_source_report_id_key;

CREATE INDEX idx_finished_arrival_registration_report_created
    ON production_finished_arrival_registrations(
        source_report_id, created_at DESC, id DESC);

DROP TRIGGER trg_require_complete_production_finished_arrival
    ON production_finished_arrival_registrations;

-- Keep a deferred transaction-end guard so a registration header can never
-- survive without at least one exact line. Cross-report rows are rejected both
-- here and by the ENABLE ALWAYS V430 row guard.
CREATE OR REPLACE FUNCTION fn_require_complete_production_finished_arrival()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_report_id UUID;
BEGIN
    SELECT source_report_id INTO v_report_id
    FROM production_finished_arrival_registrations
    WHERE id = NEW.id;

    IF v_report_id IS NULL
       OR NOT EXISTS (
           SELECT 1
           FROM production_finished_arrival_registration_items arrival_item
           WHERE arrival_item.registration_id = NEW.id)
       OR EXISTS (
           SELECT 1
           FROM production_finished_arrival_registration_items arrival_item
           JOIN production_daily_report_items report_item
             ON report_item.id = arrival_item.source_report_item_id
           WHERE arrival_item.registration_id = NEW.id
             AND report_item.report_id <> v_report_id) THEN
        RAISE EXCEPTION
            'finished arrival registration must contain exact report lines'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_finished_arrival_nonempty_guard';
    END IF;

    RETURN NEW;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_require_complete_production_finished_arrival
    AFTER INSERT ON production_finished_arrival_registrations
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION
        fn_require_complete_production_finished_arrival();

COMMENT ON TABLE production_finished_arrival_registrations IS
    '生产报工审核后、FQC前的仓库送检登记批次；同一日报可分批，每批幂等且只追加';
COMMENT ON TABLE production_finished_arrival_registration_items IS
    '送检登记逐行库位快照；来源报工明细全局唯一，未登记行继续留在待办；不是库存或FQC PASS';
