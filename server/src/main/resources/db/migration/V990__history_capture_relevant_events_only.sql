-- V988's append-only history semantics are unchanged. Reject unrelated events
-- before invoking the trigger function, rather than paying for an empty call.
DROP TRIGGER trg_permission_record_history ON audit_log;
CREATE TRIGGER trg_permission_record_history AFTER INSERT ON audit_log
 FOR EACH ROW WHEN ((NEW.event_source<>'business'
  OR NOT fn_is_permission_history_action(NEW.action)
  OR COALESCE(NEW.status_code,200)>=400 OR NEW.after IS NULL
  OR NOT (NEW.after ? 'added' AND NEW.after ? 'removed')) IS NOT TRUE)
 EXECUTE FUNCTION fn_capture_permission_record_history();
ALTER TABLE audit_log ENABLE ALWAYS TRIGGER trg_permission_record_history;

-- The library functions compare these same public snapshots. Keep insert and
-- delete facts unconditional, and skip updates with no retained field change.
DROP TRIGGER trg_library_record_history ON company_file_nodes;
CREATE TRIGGER trg_library_record_history AFTER INSERT OR DELETE ON company_file_nodes
 FOR EACH ROW EXECUTE FUNCTION fn_capture_library_record_history();
CREATE TRIGGER trg_library_record_history_update AFTER UPDATE ON company_file_nodes
 FOR EACH ROW WHEN (fn_library_history_snapshot(to_jsonb(OLD)) IS DISTINCT FROM
  fn_library_history_snapshot(to_jsonb(NEW))) EXECUTE FUNCTION fn_capture_library_record_history();
ALTER TABLE company_file_nodes ENABLE ALWAYS TRIGGER trg_library_record_history;
ALTER TABLE company_file_nodes ENABLE ALWAYS TRIGGER trg_library_record_history_update;

DROP TRIGGER trg_library_acl_history ON company_file_acl;
CREATE TRIGGER trg_library_acl_history AFTER INSERT OR DELETE ON company_file_acl
 FOR EACH ROW EXECUTE FUNCTION fn_capture_library_record_history();
CREATE TRIGGER trg_library_acl_history_update AFTER UPDATE ON company_file_acl
 FOR EACH ROW WHEN ((to_jsonb(OLD)-'node_id') IS DISTINCT FROM (to_jsonb(NEW)-'node_id'))
 EXECUTE FUNCTION fn_capture_library_record_history();
ALTER TABLE company_file_acl ENABLE ALWAYS TRIGGER trg_library_acl_history;
ALTER TABLE company_file_acl ENABLE ALWAYS TRIGGER trg_library_acl_history_update;
