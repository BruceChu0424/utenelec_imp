-- Public website is a separate service. No cloud writes or credentials are seeded.
ALTER TABLE website_inquiries ADD COLUMN source_context jsonb NOT NULL DEFAULT '{}'::jsonb;
ALTER TABLE website_inquiries ADD CONSTRAINT ck_website_inquiry_source_context CHECK(jsonb_typeof(source_context)='object');

CREATE TABLE website_inquiry_events (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 inquiry_id uuid NOT NULL REFERENCES website_inquiries(id),
 kind text NOT NULL CHECK(kind IN ('RECEIVED','CLAIMED','STATUS_CHANGED','FOLLOW_UP','CONVERTED','LEGACY_NOTE')),
 note varchar(1000), actor_id uuid, actor_name text, actor_employee_code text,
 created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX idx_website_inquiry_events ON website_inquiry_events(inquiry_id,created_at,id);
INSERT INTO website_inquiry_events(inquiry_id,kind,note,created_at)
 SELECT id,'LEGACY_NOTE',left(note,1000),coalesce(updated_at,received_at)
 FROM website_inquiries WHERE note IS NOT NULL AND btrim(note)<>'';
CREATE FUNCTION fn_guard_website_inquiry_events() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF TG_OP IN ('DELETE','TRUNCATE') AND public.fn_business_test_reset_active() THEN
  IF TG_OP='DELETE' THEN RETURN OLD; ELSE RETURN NULL; END IF;
 END IF;
 RAISE EXCEPTION 'Website inquiry follow-up history is append-only' USING ERRCODE='55000';
END $$;
CREATE TRIGGER trg_website_inquiry_events_immutable BEFORE UPDATE OR DELETE ON website_inquiry_events
FOR EACH ROW EXECUTE FUNCTION fn_guard_website_inquiry_events();
ALTER TABLE website_inquiry_events ENABLE ALWAYS TRIGGER trg_website_inquiry_events_immutable;
CREATE TRIGGER trg_website_inquiry_events_no_truncate BEFORE TRUNCATE ON website_inquiry_events
FOR EACH STATEMENT EXECUTE FUNCTION fn_guard_website_inquiry_events();
ALTER TABLE website_inquiry_events ENABLE ALWAYS TRIGGER trg_website_inquiry_events_no_truncate;
-- Append-only timeline carries its own actor and time. Do not duplicate private notes into generic audit.
SELECT public.fn_audit_track_table('website_inquiry_events','NONE');

CREATE TABLE website_management_settings (
 id integer PRIMARY KEY CHECK(id=1), version bigint NOT NULL DEFAULT 0 CHECK(version>=0),
 display_name varchar(80) NOT NULL DEFAULT '优腾官网', public_origin varchar(300),
 enabled boolean NOT NULL DEFAULT false,
 updated_at timestamptz NOT NULL DEFAULT now(),updated_by uuid REFERENCES users(id)
);
INSERT INTO website_management_settings(id) VALUES(1);
CREATE FUNCTION fn_guard_website_management_revision() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF TG_OP='DELETE' OR NEW.id<>OLD.id OR NEW.version<>OLD.version+1 THEN
  RAISE EXCEPTION 'Website configuration revision must advance exactly once and cannot be deleted' USING ERRCODE='23514';
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER trg_website_management_revision BEFORE UPDATE OR DELETE ON website_management_settings
FOR EACH ROW EXECUTE FUNCTION fn_guard_website_management_revision();
ALTER TABLE website_management_settings ENABLE ALWAYS TRIGGER trg_website_management_revision;
CREATE TABLE website_bridge_status (
 id integer PRIMARY KEY CHECK(id=1), last_checked_at timestamptz,last_sync_at timestamptz,
 last_error varchar(240),pending_inquiries integer,oldest_pending_at timestamptz,
 last_delivery_at timestamptz,published_revision varchar(120),ready boolean NOT NULL DEFAULT false
);
INSERT INTO website_bridge_status(id) VALUES(1);
SELECT public.fn_audit_track_table('website_bridge_status','NONE');
SELECT public.fn_audit_track_table('website_management_settings','COLUMN_SCOPED','system',false,
 ARRAY['version','display_name','public_origin','enabled'],false,NULL::text);

DO $redact_context$
DECLARE definition text; anchor text := 'ELSIF p_table_name = ''website_inquiries'' THEN[[:space:]]+v_row := v_row - ''name'';';
BEGIN
 SELECT pg_get_functiondef('public.fn_audit_redact_row(text,jsonb)'::regprocedure) INTO definition;
 IF (SELECT count(*) FROM regexp_matches(definition,anchor,'g'))<>1 THEN
  RAISE EXCEPTION 'V879 cannot extend website source-context audit redaction safely';
 END IF;
 EXECUTE regexp_replace(definition,anchor,
  E'ELSIF p_table_name = ''website_inquiries'' THEN\n        v_row := v_row - ARRAY[''name'',''source_context''];');
END $redact_context$;

INSERT INTO permissions(code,name,module,category,sort_order,action_type,description,high_risk,baseline)
VALUES
 ('website:view','查看官网管理','销售管理','官网管理',95,'VIEW','查看官网连接状态并按本人权限进入管理后台',false,false),
 ('website:content_edit','编辑官网内容','销售管理','官网管理',96,'EDIT','保存官网内容和资料草稿，不直接发布',false,false),
 ('website:product_edit','编辑官网展示产品','销售管理','官网管理',97,'EDIT','编辑展示目录，不修改 ERP 物料、库存和价格',false,false),
 ('website:publish','发布官网内容','销售管理','官网管理',98,'EXECUTE','审核并发布官网指定内容版本',true,false),
 ('website:rollback','回退官网发布版本','销售管理','官网管理',99,'EXECUTE','将已审核完整版本重新发布并留痕',true,false),
 ('website:media_manage','管理官网素材与资料','销售管理','官网管理',100,'EDIT','上传并管理经确认可公开的图片和资料文件',false,false);
INSERT INTO permission_surfaces(id,surface_key,name,sort_order,enabled)
VALUES('cb6973c1-ef0e-4d53-825c-403b9ba23c5c','website.management','官网管理',27,true);
INSERT INTO permission_surface_permissions(surface_id,permission_id)
 SELECT s.id,p.id FROM permission_surfaces s CROSS JOIN permissions p
 WHERE s.surface_key='website.management' AND p.code LIKE 'website:%';

-- Configuration and delivery diagnostics survive ordinary business-data reset.
DO $reset_policy$
DECLARE definition text; anchor text := '(''system_settings'', ''PRESERVE'')';
BEGIN
 SELECT pg_get_functiondef('public.business_data_reset()'::regprocedure) INTO definition;
 IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
  RAISE EXCEPTION 'V879 cannot extend business-data reset policy safely';
 END IF;
 EXECUTE replace(definition,anchor,anchor||E',\n            (''website_management_settings'', ''PRESERVE''),\n            (''website_bridge_status'', ''PRESERVE''),\n            (''website_inquiry_events'', ''CLEAR'')');
END $reset_policy$;
