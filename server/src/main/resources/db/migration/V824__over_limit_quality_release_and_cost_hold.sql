-- Quality PASS is a physical fact. Planning authorization separately controls
-- whether that exact source may generate FINISHED_IN and usable inventory.
CREATE FUNCTION fn_daily_report_output_slice_rank(p_public BOOLEAN, p_actual_surplus BOOLEAN, p_over_limit BOOLEAN)
RETURNS SMALLINT LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT CASE WHEN COALESCE(p_over_limit,FALSE) THEN 3::SMALLINT
        ELSE fn_daily_report_output_slice_rank(p_public,p_actual_surplus) END
$$;

-- Preserve the lot identity and view column contract. Only the deterministic
-- waterfall ordering gains a final over-limit tier (last PASS, first FAIL).
CREATE OR REPLACE VIEW v_production_output_handoff_lots AS
SELECT item.output_lot_id AS lot_id,
       item.report_id,
       item.id AS report_item_id,
       COALESCE(item.output_batch_id,item.id) AS output_batch_key,
       item.destination,
       item.direct_transfer_demand_id,
       fn_daily_report_output_slice_rank(item.is_public_output,item.is_actual_surplus,item.is_over_limit) AS slice_rank,
       item.qty,
       item.is_public_output,
       item.is_actual_surplus,
       item.plan_item_id,
       item.execution_segment_id,
       item.goods_id,
       item.color_id,
       item.unit_id,
       COALESCE(item.unit_rate,1) AS unit_rate,
       item.line_no,
       SUM(item.qty) OVER lot AS lot_qty,
       COUNT(*) OVER lot AS lot_slice_count,
       ROW_NUMBER() OVER(lot ORDER BY fn_daily_report_output_slice_rank(
           item.is_public_output,item.is_actual_surplus,item.is_over_limit),item.line_no NULLS LAST,item.id) AS lot_position
FROM production_daily_report_items item
WHERE NOT item.is_deleted AND item.qty>0
WINDOW lot AS (PARTITION BY item.report_id,item.output_lot_id);

CREATE FUNCTION fn_guard_over_limit_finished_in_source()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_item UUID;
BEGIN
    IF TG_TABLE_NAME='production_fqc_release_commands' THEN
        v_item:=NEW.source_report_item_id;
    ELSIF NEW.bill_type='FINISHED_IN' AND NOT NEW.is_deleted THEN
        v_item:=NEW.source_daily_report_item_id;
    ELSE
        RETURN NEW;
    END IF;
    IF v_item IS NOT NULL AND EXISTS(
        SELECT 1 FROM production_daily_report_items source
        WHERE source.id=v_item AND source.is_over_limit)
       AND NOT COALESCE(fn_daily_report_output_authorized(v_item),FALSE) THEN
        RAISE EXCEPTION '超限产出尚未批准接收，不能生成或增加成品入库'
            USING ERRCODE='23514',CONSTRAINT='production_over_limit_inbound_authorization_guard';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_over_limit_fqc_release_authorization
    BEFORE INSERT ON production_fqc_release_commands
    FOR EACH ROW EXECUTE FUNCTION fn_guard_over_limit_finished_in_source();
CREATE TRIGGER trg_over_limit_finished_in_authorization
    BEFORE INSERT OR UPDATE ON stock_document_items
    FOR EACH ROW EXECUTE FUNCTION fn_guard_over_limit_finished_in_source();

-- The target remains original approved production plus ALL real audited
-- surplus, including pending output. Its unreceived share stays in COST_WIP;
-- it is neither zero-cost stock nor an expense merely because planning held it.
CREATE FUNCTION fn_production_execution_has_pending_output(p_scope UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT EXISTS(
        SELECT 1 FROM fn_production_execution_cost_members(p_scope) member
        JOIN production_daily_report_items item ON item.execution_segment_id=member.segment_id
        JOIN production_daily_reports report ON report.id=item.report_id
        WHERE report.status=1 AND NOT report.is_deleted AND NOT item.is_deleted
          AND item.is_over_limit AND NOT fn_daily_report_output_authorized(item.id))
$$;

CREATE FUNCTION fn_guard_over_limit_cost_completeness()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.scope_complete AND fn_production_execution_has_pending_output(NEW.execution_segment_id) THEN
        RAISE EXCEPTION '超限产出仍待处置，实际投入成本必须保留在原生产成本范围，不能标记成本完整'
            USING ERRCODE='23514',CONSTRAINT='production_over_limit_cost_completeness_guard';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_over_limit_cost_completeness
    BEFORE INSERT OR UPDATE ON stock_value_production_cost_revisions
    FOR EACH ROW EXECUTE FUNCTION fn_guard_over_limit_cost_completeness();

COMMENT ON FUNCTION fn_production_execution_has_pending_output(UUID) IS
    'Unresolved original excess output keeps the existing production cost scope provisional; quality and actual consumption remain independent facts.';
