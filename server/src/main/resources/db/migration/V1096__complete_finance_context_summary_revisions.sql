-- Version-independent forward proposal. Backend assigns a fresh integer version after current Main/reservation review.
-- No existing committed migration is changed. Current-period selection has no total result cap.
INSERT INTO summary_read_domains(domain) VALUES('finance-plastic-bin-contexts');
CREATE TRIGGER trg_summary_plastic_context_insert AFTER INSERT ON warehouses REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('finance-plastic-bin-contexts');
CREATE TRIGGER trg_summary_plastic_context_update AFTER UPDATE ON warehouses REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('finance-plastic-bin-contexts');
CREATE TRIGGER trg_summary_plastic_context_delete AFTER DELETE ON warehouses REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('finance-plastic-bin-contexts');
CREATE TRIGGER trg_summary_plastic_context_truncate AFTER TRUNCATE ON warehouses FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('finance-plastic-bin-contexts');
CREATE TRIGGER trg_summary_plastic_context_insert AFTER INSERT ON workshop_material_periods REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('finance-plastic-bin-contexts');
CREATE TRIGGER trg_summary_plastic_context_update AFTER UPDATE ON workshop_material_periods REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('finance-plastic-bin-contexts');
CREATE TRIGGER trg_summary_plastic_context_delete AFTER DELETE ON workshop_material_periods REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('finance-plastic-bin-contexts');
CREATE TRIGGER trg_summary_plastic_context_truncate AFTER TRUNCATE ON workshop_material_periods FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('finance-plastic-bin-contexts');
CREATE TRIGGER trg_summary_plastic_context_insert AFTER INSERT ON workshop_material_period_lines REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('finance-plastic-bin-contexts');
CREATE TRIGGER trg_summary_plastic_context_update AFTER UPDATE ON workshop_material_period_lines REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('finance-plastic-bin-contexts');
CREATE TRIGGER trg_summary_plastic_context_delete AFTER DELETE ON workshop_material_period_lines REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('finance-plastic-bin-contexts');
CREATE TRIGGER trg_summary_plastic_context_truncate AFTER TRUNCATE ON workshop_material_period_lines FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('finance-plastic-bin-contexts');
CREATE TRIGGER trg_summary_plastic_context_insert AFTER INSERT ON workshop_material_period_closes REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('finance-plastic-bin-contexts');
CREATE TRIGGER trg_summary_plastic_context_update AFTER UPDATE ON workshop_material_period_closes REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('finance-plastic-bin-contexts');
CREATE TRIGGER trg_summary_plastic_context_delete AFTER DELETE ON workshop_material_period_closes REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('finance-plastic-bin-contexts');
CREATE TRIGGER trg_summary_plastic_context_truncate AFTER TRUNCATE ON workshop_material_period_closes FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('finance-plastic-bin-contexts');

-- Append to the next fresh forward migration, retaining all prior committed SQL.
INSERT INTO summary_read_domains(domain) VALUES('finance-expense-note-imports');
CREATE TRIGGER trg_summary_expense_note_imports_insert AFTER INSERT ON finance_expense_note_imports REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('finance-expense-note-imports');
CREATE TRIGGER trg_summary_expense_note_imports_update AFTER UPDATE ON finance_expense_note_imports REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('finance-expense-note-imports');
CREATE TRIGGER trg_summary_expense_note_imports_delete AFTER DELETE ON finance_expense_note_imports REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('finance-expense-note-imports');
CREATE TRIGGER trg_summary_expense_note_imports_truncate AFTER TRUNCATE ON finance_expense_note_imports FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain('finance-expense-note-imports');
