-- New reading capabilities are opt-in. Existing action grants and all personal denies are retained.
-- Receiving alarms is an explicit duty/subscription, not a passive reading capability.
UPDATE permissions SET action_type='EXECUTE' WHERE code='server_status:alert:receive';

WITH additions(code, source_code, name, description) AS (VALUES
 ('profile_change:view','profile:review','查看员工资料变更申请','查看资料变更各状态申请与详情；不审核、不接收办理提醒，敏感字段沿用原保护'),
 ('visitor_approval:view','visitor:approve','查看访客申请','查看访客各状态申请与详情；不批准、拒绝或转交，不接收办理提醒'),
 ('visitor:host_view','visitor:host_confirm','查看本人接待的访客','只查看本人作为接待人的各状态来访；不确认或拒绝接待'),
 ('expense:view','expense:approve','查看报销单','查看本人及可查看数据中授权申请人的各状态报销单；不申请、审批、付款，不接收办理提醒'),
 ('expense:view:all','finance:view:all','查看全部报销数据','配合查看报销单权限浏览全部申请人的各状态报销单；不授予任何报销操作权'),
 ('suggestion:view','suggestion:submit','查看意见建议','查看意见建议及回复，保留匿名和作者范围；不提交、点赞或回复'),
 ('stock:count:finance_view','stock:count:finance_review','查看财务盘点申请','只查看财务审核范围的各状态盘点申请；不审核、不接收办理提醒'),
 ('stock:count:warehouse_view','stock:count:warehouse_review','查看仓库盘点申请','只查看本人仓库范围的各状态盘点申请；不审核、不接收办理提醒')
)
INSERT INTO permissions(code,name,module,category,sort_order,action_type,description,grant_policy,
                        high_risk,baseline,baseline_pinned,explicit_grant_required)
SELECT a.code,a.name,p.module,p.category,p.sort_order,'VIEW',a.description,p.grant_policy,
       p.high_risk,FALSE,FALSE,TRUE
FROM additions a JOIN permissions p ON p.code=a.source_code;

WITH bindings(code, source_code) AS (VALUES
 ('profile_change:view','profile:review'), ('visitor_approval:view','visitor:approve'),
 ('visitor:host_view','visitor:host_confirm'), ('expense:view','expense:approve'),
 ('expense:view:all','expense:approve'), ('suggestion:view','suggestion:submit'),
 ('stock:count:finance_view','stock:count:finance_review'),
 ('stock:count:warehouse_view','stock:count:warehouse_review'))
INSERT INTO permission_surface_permissions(surface_id,permission_id)
SELECT existing.surface_id,new_permission.id FROM bindings b
JOIN permissions old_permission ON old_permission.code=b.source_code
JOIN permissions new_permission ON new_permission.code=b.code
JOIN permission_surface_permissions existing ON existing.permission_id=old_permission.id
ON CONFLICT DO NOTHING;

ALTER TABLE user_data_scopes DROP CONSTRAINT user_data_scopes_scope_check;
ALTER TABLE user_data_scopes ADD CONSTRAINT user_data_scopes_scope_check
 CHECK(scope IN('goods','client','sales','finance','purchase','subcontract','production_plan','stock_doc','expense'));

-- Observer grants participate in the same publication/revocation fence as existing owner scopes.
DO $$ DECLARE previous_check text; BEGIN
 SELECT pg_get_constraintdef(oid) INTO STRICT previous_check FROM pg_constraint
 WHERE conrelid='read_scope_domains'::regclass AND conname='read_scope_domains_domain_check';
 IF previous_check NOT LIKE 'CHECK (%' THEN RAISE EXCEPTION 'Unknown read scope domain constraint'; END IF;
 ALTER TABLE read_scope_domains DROP CONSTRAINT read_scope_domains_domain_check;
 EXECUTE 'ALTER TABLE read_scope_domains ADD CONSTRAINT read_scope_domains_domain_check '
     ||replace(previous_check,'CHECK (','CHECK (domain=''expense'' OR ');
END $$;
INSERT INTO read_scope_domains(domain) VALUES ('expense');
CREATE FUNCTION fn_mark_expense_read_grants() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE old_row jsonb:=CASE WHEN TG_OP<>'INSERT' THEN to_jsonb(OLD) ELSE '{}'::jsonb END;
        new_row jsonb:=CASE WHEN TG_OP<>'DELETE' THEN to_jsonb(NEW) ELSE '{}'::jsonb END;
BEGIN
 IF old_row->>'scope'='expense' OR new_row->>'scope'='expense' THEN
   IF TG_OP<>'UPDATE' OR old_row IS DISTINCT FROM new_row THEN PERFORM public.fn_record_read_scope_change('expense'); END IF;
 END IF;
 RETURN NULL;
END $$;
CREATE TRIGGER trg_expense_read_grants AFTER INSERT OR UPDATE OR DELETE ON user_data_scopes
FOR EACH ROW EXECUTE FUNCTION fn_mark_expense_read_grants();
ALTER TABLE user_data_scopes ENABLE ALWAYS TRIGGER trg_expense_read_grants;
CREATE TRIGGER trg_expense_read_owner AFTER UPDATE OF applicant_id ON expense_claims
FOR EACH ROW WHEN(OLD.applicant_id IS DISTINCT FROM NEW.applicant_id) EXECUTE FUNCTION fn_mark_read_scope_domains('expense');
ALTER TABLE expense_claims ENABLE ALWAYS TRIGGER trg_expense_read_owner;
CREATE TRIGGER trg_expense_read_employment AFTER INSERT OR UPDATE OR DELETE ON employment_history
FOR EACH ROW EXECUTE FUNCTION fn_mark_read_scope_domains('expense');
ALTER TABLE employment_history ENABLE ALWAYS TRIGGER trg_expense_read_employment;

-- The JVM resolves its single participation catalog against actual current grants once per read.
-- SQL applies it before paging/counting, including old workflow receipts. No history is deleted.
CREATE FUNCTION fn_notice_participation_visible(p_route text,p_event text,p_rules text,
 p_type text DEFAULT NULL,p_title text DEFAULT NULL,p_content text DEFAULT NULL,
 p_audience_user uuid DEFAULT NULL,p_audience_scope text DEFAULT NULL,p_audience_summary text DEFAULT NULL,
 p_audience_count integer DEFAULT NULL,p_interaction text DEFAULT NULL,p_kind text DEFAULT NULL,
 p_aggregate_kind text DEFAULT NULL,p_aggregate_id uuid DEFAULT NULL,p_source_revision bigint DEFAULT NULL,
 p_due_at timestamptz DEFAULT NULL,p_top_priority boolean DEFAULT NULL,p_priority text DEFAULT NULL,
 p_attachments text DEFAULT NULL,p_target_departments text DEFAULT NULL,p_target_employees text DEFAULT NULL)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE rules jsonb:=COALESCE(NULLIF(p_rules,''),'{}')::jsonb; candidate jsonb;
        legacy_profile_result jsonb:=rules->'legacyProfileResult';
BEGIN
 -- The old producer has no source batch metadata. Classify only its complete, exact message
 -- shape; never map a batch from text/timestamps, rewrite history, or classify human broadcasts.
 IF p_event IS NULL AND p_route IS NULL AND p_audience_user IS NOT NULL
    AND p_aggregate_kind IS NULL AND p_aggregate_id IS NULL AND p_source_revision IS NULL
    AND p_due_at IS NULL AND p_top_priority=FALSE AND p_audience_count=1
    AND p_type=legacy_profile_result->>'type' AND p_kind=legacy_profile_result->>'kind'
    AND p_audience_scope=legacy_profile_result->>'scope' AND p_audience_summary=legacy_profile_result->>'summary'
    AND p_interaction=legacy_profile_result->>'interaction' AND p_priority=legacy_profile_result->>'priority'
    AND p_attachments=legacy_profile_result->>'emptyJson'
    AND p_target_departments=legacy_profile_result->>'emptyJson' AND p_target_employees=legacy_profile_result->>'emptyJson'
    AND p_title=legacy_profile_result->>'title' AND p_content ~ (legacy_profile_result->>'contentPattern')
 THEN RETURN COALESCE((legacy_profile_result->>'allowed')::boolean,FALSE); END IF;
 IF rules->'events' ? p_event THEN RETURN COALESCE((rules->'events'->>p_event)::boolean,FALSE); END IF;
 FOR candidate IN SELECT value FROM jsonb_array_elements(COALESCE(rules->'routes','[]'::jsonb)) LOOP
   IF COALESCE(p_route,'') ~ (candidate->>'pattern') THEN RETURN COALESCE((candidate->>'allowed')::boolean,FALSE); END IF;
 END LOOP;
 IF COALESCE(p_route,'') ~ COALESCE(rules->>'businessRoute','a^')
    OR COALESCE(p_event,'') ~ COALESCE(rules->>'businessEvent','a^') THEN RETURN FALSE; END IF;
 RETURN TRUE;
END;
$$;
