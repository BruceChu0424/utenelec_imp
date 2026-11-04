-- One durable actor-owned result for a financial document intake request.
-- The source family retains its own authorisation and private original-file reader.
CREATE TABLE finance_document_intake_operations (
 request_id uuid PRIMARY KEY,actor_id uuid NOT NULL REFERENCES users(id),
 family text NOT NULL CHECK(family~'^[A-Z][A-Z_0-9]{0,63}$'),
 payload_hash text NOT NULL CHECK(payload_hash~'^[0-9a-f]{64}$'),
 source_document_id uuid NOT NULL,created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX finance_document_intake_actor ON finance_document_intake_operations(actor_id,family,request_id);
CREATE FUNCTION fn_guard_finance_document_intake_operation() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF TG_OP<>'INSERT' THEN RAISE EXCEPTION '原财务文件导入请求及回执不可覆盖或删除，请保留原请求核对' USING ERRCODE='23514';END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER finance_document_intake_operation_guard BEFORE INSERT OR UPDATE OR DELETE ON finance_document_intake_operations
 FOR EACH ROW EXECUTE FUNCTION fn_guard_finance_document_intake_operation();
SELECT fn_audit_track_table('finance_document_intake_operations','COLUMN_SCOPED','data_change',false,
 ARRAY['request_id','actor_id','family','source_document_id'],true,NULL);
