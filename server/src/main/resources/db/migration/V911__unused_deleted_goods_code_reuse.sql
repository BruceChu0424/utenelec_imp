-- Reuse is a new goods identity, never a resurrection or erasure of old UUIDs.
-- Only goods whose complete lifetime starts under these guards can prove nonuse.
CREATE TABLE goods_code_lifecycles (
    goods_id uuid PRIMARY KEY REFERENCES goods(id) ON DELETE RESTRICT,
    started_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TABLE goods_code_usage_facts (
    goods_id uuid PRIMARY KEY REFERENCES goods(id) ON DELETE RESTRICT,
    first_source text NOT NULL,
    first_seen_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TABLE goods_code_reuse_releases (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    normalized_code text NOT NULL CHECK(normalized_code=upper(btrim(normalized_code)) AND normalized_code<>''),
    old_goods_id uuid NOT NULL REFERENCES goods(id) ON DELETE RESTRICT,
    new_goods_id uuid NOT NULL REFERENCES goods(id) ON DELETE NO ACTION DEFERRABLE INITIALLY DEFERRED,
    transaction_id bigint NOT NULL DEFAULT txid_current(),
    actor_id uuid DEFAULT nullif(current_setting('app.actor_id',true),'')::uuid,
    released_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    UNIQUE(normalized_code,old_goods_id),
    CHECK(old_goods_id<>new_goods_id)
);
CREATE INDEX idx_goods_code_reuse_new_owner ON goods_code_reuse_releases(new_goods_id,normalized_code);

CREATE FUNCTION fn_goods_code_reusable_owner(p_code text) RETURNS uuid LANGUAGE sql STABLE AS $$
    WITH global_members AS (
        SELECT m.* FROM business_identifier_reservation_members m
        WHERE m.normalized_identifier=upper(btrim(p_code))
          AND NOT (m.owner_domain='GOODS' AND EXISTS(SELECT 1 FROM goods_code_reuse_releases r
              WHERE r.normalized_code=m.normalized_identifier AND r.old_goods_id=m.entity_id))
    ), domain_members AS (
        SELECT m.* FROM master_code_reservation_members m
        WHERE m.master_domain='GOODS' AND m.normalized_code=upper(btrim(p_code))
          AND NOT EXISTS(SELECT 1 FROM goods_code_reuse_releases r
              WHERE r.normalized_code=m.normalized_code AND r.old_goods_id=m.entity_id)
    )
    SELECT g.id FROM goods g
    JOIN goods_code_lifecycles life ON life.goods_id=g.id
    WHERE g.is_deleted AND NOT g.auto_created AND g.legacy_id IS NULL AND upper(btrim(g.code))=upper(btrim(p_code))
      AND NOT EXISTS(SELECT 1 FROM goods_code_usage_facts used WHERE used.goods_id=g.id)
      AND (SELECT count(*) FROM global_members)=1
      AND EXISTS(SELECT 1 FROM global_members m WHERE m.owner_domain='GOODS' AND m.source_table='goods' AND m.entity_id=g.id)
      AND (SELECT count(*) FROM domain_members)=1
      AND EXISTS(SELECT 1 FROM domain_members m WHERE m.entity_id=g.id)
$$;

CREATE FUNCTION fn_guard_goods_code_release() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE owner_id uuid;
BEGIN
    IF NEW.transaction_id<>txid_current() OR EXISTS(SELECT 1 FROM goods WHERE id=NEW.new_goods_id) THEN
        RAISE EXCEPTION '货品编号复用必须与新货品在同一创建事务内完成' USING ERRCODE='23514';
    END IF;
    SELECT fn_goods_code_reusable_owner(NEW.normalized_code) INTO owner_id;
    IF owner_id IS DISTINCT FROM NEW.old_goods_id THEN
        RAISE EXCEPTION '该编号缺少完整未使用证明，或已被业务、历史及其它资料占用，不能回用' USING ERRCODE='23514';
    END IF;
    PERFORM id FROM goods WHERE id=owner_id FOR UPDATE;
    -- The global trigger normally locks global before per-domain reservations.
    PERFORM 1 FROM business_identifier_reservations WHERE normalized_identifier=NEW.normalized_code FOR UPDATE;
    PERFORM 1 FROM master_code_reservations WHERE master_domain='GOODS' AND normalized_code=NEW.normalized_code FOR UPDATE;
    IF fn_goods_code_reusable_owner(NEW.normalized_code) IS DISTINCT FROM NEW.old_goods_id THEN
        RAISE EXCEPTION '编号或历史使用状态已变化，请重新检查后新建' USING ERRCODE='40001';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_validate_goods_code_release BEFORE INSERT ON goods_code_reuse_releases
    FOR EACH ROW EXECUTE FUNCTION fn_guard_goods_code_release();

CREATE FUNCTION fn_claim_reusable_goods_code(p_code text,p_new_goods uuid) RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE owner_id uuid;
BEGIN
    IF p_new_goods IS NULL THEN RETURN false; END IF;
    SELECT fn_goods_code_reusable_owner(p_code) INTO owner_id;
    IF owner_id IS NULL THEN RETURN false; END IF;
    INSERT INTO goods_code_reuse_releases(normalized_code,old_goods_id,new_goods_id)
        VALUES(upper(btrim(p_code)),owner_id,p_new_goods);
    RETURN true;
END $$;

-- Original claims remain append-only. A released GOODS member is archived
-- evidence, not the current owner; all other domains retain lifetime ownership.
DO $claims$
DECLARE definition text; needle text;
BEGIN
    SELECT pg_get_functiondef('fn_reserve_master_code()'::regprocedure) INTO definition;
    needle:='WHERE member.master_domain = v_domain';
    IF (length(definition)-length(replace(definition,needle,'')))/length(needle)<>4 THEN
        RAISE EXCEPTION 'V909 master claim oracle changed';
    END IF;
    definition:=replace(definition,needle,needle||E'\n AND NOT (v_domain=''GOODS'' AND EXISTS(SELECT 1 FROM goods_code_reuse_releases released WHERE released.normalized_code=member.normalized_code AND released.old_goods_id=member.entity_id))');
    EXECUTE definition;
    SELECT pg_get_functiondef('fn_claim_global_business_identifier(text,text,uuid,text,text,text,boolean,boolean)'::regprocedure) INTO definition;
    needle:='WHERE member.normalized_identifier = normalized_value';
    IF (length(definition)-length(replace(definition,needle,'')))/length(needle)<>4 THEN
        RAISE EXCEPTION 'V909 global claim oracle changed';
    END IF;
    definition:=replace(definition,needle,needle||E'\n AND NOT (member.owner_domain=''GOODS'' AND EXISTS(SELECT 1 FROM goods_code_reuse_releases released WHERE released.normalized_code=member.normalized_identifier AND released.old_goods_id=member.entity_id))');
    EXECUTE definition;
END $claims$;

CREATE FUNCTION fn_finish_goods_code_release() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS(SELECT 1 FROM goods g WHERE g.id=NEW.new_goods_id AND NOT g.is_deleted
            AND upper(btrim(g.code))=NEW.normalized_code)
       OR NOT EXISTS(SELECT 1 FROM business_identifier_reservation_members m
            WHERE m.normalized_identifier=NEW.normalized_code AND m.owner_domain='GOODS' AND m.entity_id=NEW.new_goods_id)
       OR NOT EXISTS(SELECT 1 FROM master_code_reservation_members m
            WHERE m.master_domain='GOODS' AND m.normalized_code=NEW.normalized_code AND m.entity_id=NEW.new_goods_id) THEN
        RAISE EXCEPTION '编号回用未完成新货品及双重归属登记，事务已取消' USING ERRCODE='23514';
    END IF;
    RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER trg_finish_goods_code_release AFTER INSERT ON goods_code_reuse_releases
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_finish_goods_code_release();

CREATE FUNCTION fn_track_goods_code_lifecycle() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP='INSERT' AND NOT NEW.auto_created AND NEW.legacy_id IS NULL
       AND lower(coalesce(current_setting('app.business_identifier_legacy_import',true),'off')) NOT IN ('on','true','1')
       AND coalesce(current_setting('uten.legacy_reference_import',true),'')='' THEN
        INSERT INTO goods_code_lifecycles(goods_id) VALUES(NEW.id) ON CONFLICT DO NOTHING;
    END IF;
    IF NOT NEW.is_deleted AND EXISTS(SELECT 1 FROM goods_code_reuse_releases r WHERE r.old_goods_id=NEW.id) THEN
        RAISE EXCEPTION '原货品编号已由新 UUID 的货品使用，不能直接恢复旧货品或撤回旧删除；请核对新货品后处理' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_goods_code_lifecycle AFTER INSERT OR UPDATE OF is_deleted,code ON goods
    FOR EACH ROW EXECUTE FUNCTION fn_track_goods_code_lifecycle();

CREATE FUNCTION fn_note_goods_code_use(p_goods uuid,p_source text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    IF p_goods IS NULL OR EXISTS(SELECT 1 FROM goods_code_usage_facts f WHERE f.goods_id=p_goods) THEN RETURN; END IF;
    -- This lock also covers references without a foreign key and JSON snapshots.
    PERFORM id FROM goods WHERE id=p_goods FOR KEY SHARE;
    IF NOT FOUND THEN RETURN; END IF;
    IF EXISTS(SELECT 1 FROM goods_code_reuse_releases r WHERE r.old_goods_id=p_goods) THEN
        RAISE EXCEPTION '该旧货品编号已回用于新货品，不能再给旧 UUID 新增业务引用' USING ERRCODE='23514';
    END IF;
    INSERT INTO goods_code_usage_facts(goods_id,first_source) VALUES(p_goods,p_source) ON CONFLICT DO NOTHING;
END $$;

CREATE FUNCTION fn_capture_goods_code_use() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE row_value jsonb; spec text; candidate text; value jsonb;
BEGIN
    FOR row_value IN SELECT v FROM (VALUES(CASE WHEN TG_OP<>'INSERT' THEN to_jsonb(OLD) END),
            (CASE WHEN TG_OP<>'DELETE' THEN to_jsonb(NEW) END)) rows(v) WHERE v IS NOT NULL LOOP
        FOREACH spec IN ARRAY TG_ARGV LOOP
            value:=row_value->substring(spec from 3);
            IF value IS NULL OR value='null'::jsonb THEN CONTINUE; END IF;
            IF left(spec,1)='U' THEN
                PERFORM fn_note_goods_code_use((row_value->>substring(spec from 3))::uuid,TG_TABLE_NAME||'.'||substring(spec from 3));
            ELSE
                FOR candidate IN SELECT match[1] FROM regexp_matches(value::text,
                        '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})','g') match LOOP
                    PERFORM fn_note_goods_code_use(candidate::uuid,TG_TABLE_NAME||'.'||substring(spec from 3));
                END LOOP;
            END IF;
        END LOOP;
    END LOOP;
    RETURN coalesce(NEW,OLD);
END $$;

-- A maintained catalog is inspectable by tests. There is no reliance on active
-- quantity counts or audit retention to establish whether a tracked UUID was used.
CREATE FUNCTION fn_goods_code_usage_columns() RETURNS TABLE(table_name text,column_name text,kind text)
LANGUAGE sql STABLE AS $$
    SELECT c.relname::text,a.attname::text,
        CASE WHEN a.atttypid='uuid'::regtype THEN 'U' ELSE 'J' END
    FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
    JOIN pg_attribute a ON a.attrelid=c.oid AND a.attnum>0 AND NOT a.attisdropped
    WHERE n.nspname='public' AND c.relkind IN ('r','p') AND NOT c.relispartition
      AND c.relname<>'goods'
      AND c.relname !~ '^(audit_|goods_code_|goods_import_|goods_operation_history|master_operation_history|master_record_|business_identifier_|master_code_)'
      AND c.relname NOT IN ('goods_market_reference_bindings','goods_cost_templates','goods_image_references',
          'warehouse_goods_place_preferences','client_goods_aliases','goods_weight_profiles','goods_weight_estimates',
          'sales_alias_document_evidence','goods_cost_imports','goods_cost_import_mappings',
          'platform_record_fields','platform_record_field_versions')
      AND ((a.atttypid='uuid'::regtype AND (a.attname ~ '(^|_)goods_id$' OR EXISTS(
          SELECT 1 FROM pg_constraint fk WHERE fk.contype='f' AND fk.conrelid=c.oid
              AND fk.confrelid='goods'::regclass AND a.attnum=ANY(fk.conkey))))
          OR a.atttypid='uuid[]'::regtype AND a.attname ~ '(^|_)goods_ids$'
          OR a.atttypid='jsonb'::regtype AND (c.relname,a.attname) IN (
              ('goods_cost_sheets','input'),('goods_cost_sheets','calculation'),
              ('goods_cost_snapshots','payload'),('production_material_demands','consumption_snapshot'),
              ('production_planning_drafts','payload'),('sales_quote_revision_logs','snapshot'),
              ('production_bom_learning_samples','materials'),('production_bom_learning_samples','entry_generations'),
              ('production_material_discovery_requests','requested_materials'),
              ('production_material_increment_requests','source_snapshot'),
              ('production_material_increment_requests','before_snapshot'),('production_material_increment_requests','after_snapshot'),
              ('production_daily_report_commands','material_review_snapshot'),('production_daily_report_commands','material_decisions'),
              ('production_daily_report_items','overproduction_authorization_snapshot'),
              ('production_daily_report_target_events','overproduction_authorizations'),
              ('production_draw_issue_batches','request_snapshot'),('production_draw_issue_batches','response_snapshot'),
              ('production_execution_segment_growth_events','demand_changes'),
              ('production_execution_segments','split_material_snapshot'),
              ('production_finished_in_confirm_batches','response_snapshot'),
              ('production_material_analysis_commands','result_payload'),
              ('production_actual_output_supplement_requests','report_context'),
              ('production_overproduction_rate_requests','before_snapshot'),('production_overproduction_rate_requests','after_snapshot'),
              ('sales_order_revision_logs','before_snapshot'),('sales_order_revision_logs','after_snapshot'),
              ('sales_shipment_finance_release_events','commercial_snapshot'),
              ('sales_shipment_submission_events','commercial_snapshot'),
              ('sales_shipment_warehouse_events','line_stock_places'),('sales_shipment_warehouse_events','line_warehouses'),
              ('sales_shipment_warehouse_events','line_weights'),
              ('procurement_order_approval_cases','submission_snapshot'),('procurement_order_approval_cases','display_snapshot'),
              ('procurement_order_approval_events','event_snapshot'),('procurement_order_source_revisions','before_item'),
              ('purchase_request_qty_revisions','before_item')))
$$;

CREATE FUNCTION fn_refresh_goods_code_usage_tracking() RETURNS void LANGUAGE plpgsql AS $$
DECLARE tracked record; args text;
BEGIN
    FOR tracked IN SELECT DISTINCT table_name FROM fn_goods_code_usage_columns() LOOP
        SELECT string_agg(quote_literal(kind||':'||column_name),',' ORDER BY column_name) INTO args
            FROM fn_goods_code_usage_columns() WHERE table_name=tracked.table_name;
        EXECUTE format('DROP TRIGGER IF EXISTS trg_track_goods_code_usage ON public.%I',tracked.table_name);
        EXECUTE format('CREATE TRIGGER trg_track_goods_code_usage AFTER INSERT OR UPDATE OR DELETE ON public.%I FOR EACH ROW EXECUTE FUNCTION fn_capture_goods_code_use(%s)',tracked.table_name,args);
    END LOOP;
END $$;
SELECT fn_refresh_goods_code_usage_tracking();

-- No lifecycle rows are inferred for old goods: audit reset/retention makes
-- absence of old references insufficient proof of lifetime nonuse.
CREATE TRIGGER trg_goods_code_lifecycles_append_only BEFORE UPDATE OR DELETE ON goods_code_lifecycles
    FOR EACH ROW EXECUTE FUNCTION fn_guard_business_identifier_append_only();
CREATE TRIGGER trg_goods_code_usage_append_only BEFORE UPDATE OR DELETE ON goods_code_usage_facts
    FOR EACH ROW EXECUTE FUNCTION fn_guard_business_identifier_append_only();
CREATE TRIGGER trg_goods_code_releases_append_only BEFORE UPDATE OR DELETE ON goods_code_reuse_releases
    FOR EACH ROW EXECUTE FUNCTION fn_guard_business_identifier_append_only();
SELECT fn_audit_track_table('goods_code_lifecycles','FULL','data_change',false);
SELECT fn_audit_track_table('goods_code_usage_facts','FULL','data_change',false);
SELECT fn_audit_track_table('goods_code_reuse_releases','FULL','data_change',false);
DO $reset_policy$
DECLARE definition text; anchor text:='(''goods'', ''PRESERVE'')';
BEGIN
    SELECT pg_get_functiondef('business_data_reset()'::regprocedure) INTO definition;
    IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN RAISE EXCEPTION 'V909 reset oracle changed'; END IF;
    EXECUTE replace(definition,anchor,anchor||E',\n (''goods_code_lifecycles'', ''PRESERVE''),\n (''goods_code_usage_facts'', ''PRESERVE''),\n (''goods_code_reuse_releases'', ''PRESERVE'')');
END $reset_policy$;
