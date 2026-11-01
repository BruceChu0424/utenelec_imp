-- Reuse the existing native_feature registry and append-only generation ledger.
-- A task-owner or exception binding change must retire a late owner-scoped
-- response; ordinary quantity/progress edits are not authorization changes.
DO $$ BEGIN
    IF NOT EXISTS(SELECT 1 FROM public.read_scope_domains WHERE domain='native_feature') THEN
        RAISE EXCEPTION 'V984 requires the registered native_feature read scope';
    END IF;
END $$;

CREATE TRIGGER trg_supplier_return_read_set
AFTER INSERT OR DELETE ON public.supplier_return_tasks
FOR EACH ROW EXECUTE FUNCTION public.fn_mark_read_scope_domains('native_feature');

CREATE TRIGGER trg_supplier_return_read_owner
AFTER UPDATE OF owner_user_id,owner_employee_id,arrival_exception_id ON public.supplier_return_tasks
FOR EACH ROW WHEN (
    OLD.owner_user_id IS DISTINCT FROM NEW.owner_user_id
    OR OLD.owner_employee_id IS DISTINCT FROM NEW.owner_employee_id
    OR OLD.arrival_exception_id IS DISTINCT FROM NEW.arrival_exception_id)
EXECUTE FUNCTION public.fn_mark_read_scope_domains('native_feature');

ALTER TABLE public.supplier_return_tasks ENABLE ALWAYS TRIGGER trg_supplier_return_read_set;
ALTER TABLE public.supplier_return_tasks ENABLE ALWAYS TRIGGER trg_supplier_return_read_owner;

-- Neither this task table nor its exception has logical deletion in the read
-- predicates. Their relationship and the joined goods are protected by RESTRICT
-- FKs, so removal of a readable task already passes through the DELETE source.
-- No task identity, original owner, notification receipt or business row changes.
