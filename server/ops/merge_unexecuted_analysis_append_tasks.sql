-- Repair reviewed V645 APPEND pairs after V646, without erasing their history.
-- Requires a verified backup and rehearsal on a restored copy first.
-- Stop application writers/background workers for the reviewed database first.
-- psql -X -v ON_ERROR_STOP=1 -v analysis_id=<uuid> -v actor_id=<uuid>
--      -v expected_database=<database> -v expected_pairs=<reviewed count>
--      -v apply=false -f <this file>
-- Default is a full rehearsal followed by ROLLBACK. Set apply=true only for the
-- reviewed local target. No trigger is disabled, no applied migration is changed.
-- Retired task/demand rows remain soft-deleted with their original quantities;
-- fn_audit records the same transaction/request as the target growth event.
\set ON_ERROR_STOP on
\if :{?analysis_id}
\else
  \echo 'analysis_id is required'
  \quit 1
\endif
\if :{?actor_id}
\else
  \echo 'actor_id is required'
  \quit 1
\endif
\if :{?expected_pairs}
\else
  \echo 'expected_pairs is required'
  \quit 1
\endif
\if :{?expected_database}
\else
  \echo 'expected_database is required'
  \quit 1
\endif
\if :{?apply}
\else
  \set apply false
\endif

BEGIN;
SET LOCAL lock_timeout='10s';
SET LOCAL statement_timeout='60s';
SELECT set_config('app.actor_id', :'actor_id', true),
       set_config('app.actor_account', 'maintenance:approved-workshop-append-merge', true),
       set_config('app.request_id', gen_random_uuid()::text, true),
       set_config('app.append_repair_analysis_id', :'analysis_id', true),
       set_config('app.append_repair_expected_database', :'expected_database', true),
       set_config('app.append_repair_expected_pairs', :'expected_pairs', true);

CREATE TEMP TABLE append_task_repair_results (
    plan_id UUID, plan_no TEXT, original_task_id UUID, original_task_no TEXT,
    retired_task_id UUID, retired_task_no TEXT, before_qty NUMERIC,
    added_qty NUMERIC, after_qty NUMERIC, growth_event_id UUID
) ON COMMIT DROP;

DO $repair$
DECLARE analysis UUID:=current_setting('app.append_repair_analysis_id')::uuid;
        expected INTEGER:=current_setting('app.append_repair_expected_pairs')::integer;
        actor UUID:=current_setting('app.actor_id')::uuid;
        pair RECORD; source production_execution_segments%ROWTYPE;
        target production_execution_segments%ROWTYPE;
        pairs INTEGER; allocated NUMERIC; growth UUID; target_rules JSONB; source_rules JSONB;
        reference RECORD; linked BOOLEAN; demand_ids UUID[];
BEGIN
    IF current_database()<>current_setting('app.append_repair_expected_database') THEN
        RAISE EXCEPTION 'Unexpected target database';
    END IF;
    IF expected<=0 OR NOT EXISTS(SELECT 1 FROM users WHERE id=actor AND NOT is_deleted) THEN
        RAISE EXCEPTION 'Repair requires a real actor and a positive reviewed pair count';
    END IF;
    PERFORM 1 FROM production_material_analyses WHERE id=analysis AND NOT is_deleted FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Analysis is unavailable'; END IF;
    PERFORM 1 FROM production_plans WHERE material_analysis_id=analysis ORDER BY id FOR UPDATE;
    PERFORM 1 FROM production_planning_packages WHERE plan_id IN
        (SELECT id FROM production_plans WHERE material_analysis_id=analysis) ORDER BY id FOR UPDATE;
    PERFORM 1 FROM production_execution_segments WHERE plan_id IN
        (SELECT id FROM production_plans WHERE material_analysis_id=analysis) ORDER BY id FOR UPDATE;
    SELECT COUNT(*) INTO pairs FROM production_execution_segments s JOIN production_plans p ON p.id=s.plan_id
    WHERE p.material_analysis_id=analysis AND NOT p.is_deleted AND NOT s.is_deleted
      AND s.client_segment_key LIKE 'APPEND:%';
    IF pairs<>expected THEN RAISE EXCEPTION 'Reviewed pair count changed: expected %, found %',expected,pairs; END IF;

    FOR pair IN SELECT s.id,p.bill_no FROM production_execution_segments s JOIN production_plans p ON p.id=s.plan_id
        WHERE p.material_analysis_id=analysis AND NOT p.is_deleted AND NOT s.is_deleted
          AND s.client_segment_key LIKE 'APPEND:%' ORDER BY p.id,s.id
    LOOP
        SELECT * INTO source FROM production_execution_segments WHERE id=pair.id;
        IF (SELECT COUNT(*) FROM production_execution_segments WHERE plan_id=source.plan_id AND NOT is_deleted)<>2
           OR NOT fn_material_analysis_plan_growable(source.plan_id) THEN
            RAISE EXCEPTION 'Plan % is no longer an untouched two-task APPEND pair',pair.bill_no;
        END IF;
        SELECT * INTO STRICT target FROM production_execution_segments
        WHERE plan_id=source.plan_id AND NOT is_deleted AND id<>source.id
          AND client_segment_key NOT LIKE 'APPEND:%';
        IF ROW(source.package_id,source.source_plan_item_id,source.product_goods_id,source.product_color_id,
               source.product_unit_id,source.product_unit_rate,source.workshop_department_id,
               source.team_department_id,source.responsible_employee_id,source.plan_begin_date,source.plan_end_date,
               source.material_requirement_mode,source.zero_material_reason,source.zero_material_analysis_id,
               source.continuous_supply,source.auto_promote_when_ready)
           IS DISTINCT FROM
           ROW(target.package_id,target.source_plan_item_id,target.product_goods_id,target.product_color_id,
               target.product_unit_id,target.product_unit_rate,target.workshop_department_id,
               target.team_department_id,target.responsible_employee_id,target.plan_begin_date,target.plan_end_date,
               target.material_requirement_mode,target.zero_material_reason,target.zero_material_analysis_id,
               target.continuous_supply,target.auto_promote_when_ready)
           OR source.start_route IS NOT NULL OR target.start_route IS NOT NULL
           OR source.route_confirmed_at IS NOT NULL OR target.route_confirmed_at IS NOT NULL
           OR source.segment_no<=target.segment_no THEN
            RAISE EXCEPTION 'Plan % task identity, assignment or route differs; manual review required',pair.bill_no;
        END IF;
        -- Every linkage is checked, including inactive history: this operation is
        -- intentionally narrower than normal ongoing production lifecycle repair.
        IF EXISTS(SELECT 1 FROM production_execution_segment_events WHERE execution_segment_id IN(source.id,target.id))
           OR EXISTS(SELECT 1 FROM production_execution_segment_growth_events WHERE execution_segment_id IN(source.id,target.id))
           OR EXISTS(SELECT 1 FROM production_planning_package_documents WHERE execution_segment_id IN(source.id,target.id))
           OR EXISTS(SELECT 1 FROM production_execution_segment_splits
                     WHERE source_segment_id IN(source.id,target.id) OR batch_segment_id IN(source.id,target.id)
                        OR remaining_segment_id IN(source.id,target.id))
           OR EXISTS(SELECT 1 FROM production_daily_report_items WHERE execution_segment_id IN(source.id,target.id))
           OR EXISTS(SELECT 1 FROM production_workshop_direct_transfer_items WHERE to_execution_segment_id IN(source.id,target.id))
           OR EXISTS(SELECT 1 FROM production_material_demands d JOIN stock_reservations r ON r.demand_id=d.id
                     WHERE d.execution_segment_id IN(source.id,target.id))
           OR EXISTS(SELECT 1 FROM production_material_demands d JOIN production_material_supply_pegs p ON p.demand_id=d.id
                     WHERE d.execution_segment_id IN(source.id,target.id))
           OR EXISTS(SELECT 1 FROM production_material_demands d JOIN production_material_stock_postings p ON p.demand_id=d.id
                     WHERE d.execution_segment_id IN(source.id,target.id))
           OR EXISTS(SELECT 1 FROM production_material_demands d JOIN production_material_settlement_postings p ON p.demand_id=d.id
                     WHERE d.execution_segment_id IN(source.id,target.id)) THEN
            RAISE EXCEPTION 'Plan % has execution or material history; repair refused',pair.bill_no;
        END IF;
        SELECT array_agg(id) INTO demand_ids FROM production_material_demands
        WHERE execution_segment_id IN(source.id,target.id);
        FOR reference IN
            SELECT constraint_row.conrelid::regclass AS relation,attribute.attname AS column_name,
                   constraint_row.confrelid,cardinality(constraint_row.conkey) AS key_size
            FROM pg_constraint constraint_row
            JOIN pg_attribute attribute ON attribute.attrelid=constraint_row.conrelid
                 AND attribute.attnum=constraint_row.conkey[1]
            WHERE constraint_row.contype='f' AND constraint_row.confrelid IN
                 ('production_execution_segments'::regclass,'production_material_demands'::regclass)
              AND NOT (constraint_row.confrelid='production_execution_segments'::regclass
                       AND attribute.attname='execution_segment_id'
                       AND constraint_row.conrelid IN
                       ('production_material_demands'::regclass,'execution_segment_sales_allocations'::regclass))
        LOOP
            IF reference.key_size<>1 THEN RAISE EXCEPTION 'Unreviewed composite execution foreign key'; END IF;
            EXECUTE format('SELECT EXISTS(SELECT 1 FROM %s WHERE %I=ANY($1))',
                           reference.relation,reference.column_name)
                INTO linked USING CASE WHEN reference.confrelid='production_execution_segments'::regclass
                    THEN ARRAY[source.id,target.id] ELSE demand_ids END;
            IF linked THEN RAISE EXCEPTION 'Plan % has unreviewed reference %.%; repair refused',
                pair.bill_no,reference.relation,reference.column_name; END IF;
        END LOOP;
        SELECT COALESCE(jsonb_agg(rule ORDER BY rule::text),'[]'::jsonb) INTO target_rules FROM (
          SELECT jsonb_build_array(goods_id,color_id,unit_id,warehouse_id,need_date,direct_supply,supply_route,
                 per_product_qty,requirement_mode,requirement_fingerprint,consumption_snapshot) AS rule
          FROM production_material_demands WHERE execution_segment_id=target.id AND NOT is_deleted) rules;
        SELECT COALESCE(jsonb_agg(rule ORDER BY rule::text),'[]'::jsonb) INTO source_rules FROM (
          SELECT jsonb_build_array(goods_id,color_id,unit_id,warehouse_id,need_date,direct_supply,supply_route,
                 per_product_qty,requirement_mode,requirement_fingerprint,consumption_snapshot) AS rule
          FROM production_material_demands WHERE execution_segment_id=source.id AND NOT is_deleted) rules;
        IF source_rules IS DISTINCT FROM target_rules THEN
            RAISE EXCEPTION 'Plan % frozen material rules differ; repair refused',pair.bill_no;
        END IF;
        SELECT COALESCE(SUM(allocated_qty),0) INTO allocated FROM execution_segment_sales_allocations
        WHERE execution_segment_id=source.id;
        UPDATE production_execution_segments SET status='CANCELLED',is_deleted=true,deleted_at=now(),
            lock_version=lock_version+1,updated_at=now(),updated_by=actor WHERE id=source.id;
        UPDATE production_material_demands SET status='RELEASED',released_qty=required_qty,is_deleted=true,
            deleted_at=now(),lock_version=lock_version+1,updated_at=now(),updated_by=actor
        WHERE execution_segment_id=source.id AND NOT is_deleted;
        growth:=fn_grow_material_analysis_execution_segment(target.id,source.planned_qty,allocated);
        UPDATE production_material_demands SET status=fn_production_material_demand_status(id),
            lock_version=lock_version+1,updated_at=now(),updated_by=actor
        WHERE execution_segment_id=target.id AND NOT is_deleted;
        INSERT INTO append_task_repair_results VALUES(source.plan_id,pair.bill_no,target.id,target.segment_code,
            source.id,source.segment_code,target.planned_qty,source.planned_qty,target.planned_qty+source.planned_qty,growth);
    END LOOP;
END;
$repair$;
SET CONSTRAINTS ALL IMMEDIATE;
SELECT * FROM append_task_repair_results ORDER BY plan_no;
\if :apply
  COMMIT;
\else
  ROLLBACK;
\endif
