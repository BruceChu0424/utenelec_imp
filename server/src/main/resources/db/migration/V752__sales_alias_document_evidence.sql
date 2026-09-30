-- Preserve legacy counters as unattributed history; do not invent document evidence
-- from last_source_doc_id, which remembers only the most recent writer.
ALTER TABLE client_goods_aliases
    ADD COLUMN legacy_confirm_count integer NOT NULL DEFAULT 0 CHECK (legacy_confirm_count >= 0),
    ADD COLUMN legacy_explicit_count integer NOT NULL DEFAULT 0 CHECK (legacy_explicit_count >= 0),
    ADD COLUMN legacy_source_doc_type varchar(16),
    ADD COLUMN legacy_source_doc_id uuid;
UPDATE client_goods_aliases SET legacy_confirm_count=confirm_count,legacy_explicit_count=explicit_count,
    legacy_source_doc_type=last_source_doc_type,legacy_source_doc_id=last_source_doc_id;

CREATE TABLE sales_alias_document_evidence (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    doc_type varchar(16) NOT NULL CHECK (doc_type IN ('quote','order')),
    doc_id uuid NOT NULL,
    alias_identity varchar(64) NOT NULL CHECK (alias_identity ~ '^[0-9a-f]{64}$'),
    alias_id uuid NOT NULL,
    client_id uuid,
    alias_kind varchar(16) NOT NULL CHECK (alias_kind IN ('PART_NO','DESCRIPTION')),
    alias_text varchar(500) NOT NULL,
    alias_norm varchar(500) NOT NULL,
    context_norm varchar(200) NOT NULL DEFAULT '',
    goods_id uuid NOT NULL,
    active boolean NOT NULL DEFAULT true,
    explicit_confirmed boolean NOT NULL DEFAULT false,
    first_confirmed_at timestamptz NOT NULL DEFAULT now(),
    last_confirmed_at timestamptz NOT NULL DEFAULT now(),
    last_confirmed_by uuid,
    retracted_at timestamptz,
    retracted_by uuid,
    retraction_reason varchar(40),
    UNIQUE(doc_type,doc_id,alias_identity),
    CHECK (active = (retracted_at IS NULL)),
    CHECK (last_confirmed_at >= first_confirmed_at)
);
CREATE INDEX idx_sales_alias_evidence_active_alias ON sales_alias_document_evidence(alias_id) WHERE active;

CREATE FUNCTION fn_guard_sales_alias_evidence_identity()
RETURNS TRIGGER LANGUAGE plpgsql AS $function$
BEGIN
    IF TG_OP='DELETE' THEN RAISE EXCEPTION 'Alias evidence history cannot be deleted' USING ERRCODE='23514'; END IF;
    IF ROW(NEW.doc_type,NEW.doc_id,NEW.alias_identity,NEW.client_id,NEW.alias_kind,NEW.alias_norm,NEW.context_norm,NEW.goods_id,NEW.first_confirmed_at)
        IS DISTINCT FROM ROW(OLD.doc_type,OLD.doc_id,OLD.alias_identity,OLD.client_id,OLD.alias_kind,OLD.alias_norm,OLD.context_norm,OLD.goods_id,OLD.first_confirmed_at) THEN
        RAISE EXCEPTION 'Alias evidence source identity is immutable' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END
$function$;
CREATE TRIGGER trg_sales_alias_evidence_identity
BEFORE UPDATE OR DELETE ON sales_alias_document_evidence FOR EACH ROW
EXECUTE FUNCTION fn_guard_sales_alias_evidence_identity();

CREATE FUNCTION fn_retract_deleted_sales_alias_evidence()
RETURNS TRIGGER LANGUAGE plpgsql AS $function$
BEGIN
    UPDATE sales_alias_document_evidence SET active=false,retracted_at=now(),retraction_reason='ALIAS_DELETED',
        retracted_by=NULLIF(current_setting('app.actor_id',true),'')::uuid
    WHERE alias_id=OLD.id AND active;
    RETURN OLD;
END
$function$;
CREATE TRIGGER trg_retract_deleted_sales_alias_evidence
BEFORE DELETE ON client_goods_aliases FOR EACH ROW
EXECUTE FUNCTION fn_retract_deleted_sales_alias_evidence();

SELECT fn_audit_track_table('sales_alias_document_evidence','FULL','data_change',false);
COMMENT ON COLUMN client_goods_aliases.legacy_confirm_count IS
    'Unattributed pre-V752 history; client confidence uses greatest(legacy baseline,active distinct-document evidence), never their sum';
COMMENT ON TABLE sales_alias_document_evidence IS
    'Per-document learning facts with active retraction and immutable source identity; historical counts are never attributed to invented source documents';

DO $reset_policy$
DECLARE definition text; anchor text := '(''stock_movements'', ''CLEAR'')';
BEGIN
    SELECT pg_get_functiondef('business_data_reset()'::regprocedure) INTO definition;
    IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor) <> 1 THEN
        RAISE EXCEPTION 'V752 cannot extend alias-evidence reset policy safely';
    END IF;
    EXECUTE replace(definition,anchor,anchor || E',\n            (''sales_alias_document_evidence'', ''PRESERVE'')');
END
$reset_policy$;
