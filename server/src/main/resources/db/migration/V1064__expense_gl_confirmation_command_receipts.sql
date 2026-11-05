-- Extend only the new expense confirmation command; preserve every existing operation/hash/receipt.
DO $$
DECLARE definition text;
BEGIN
 SELECT pg_get_constraintdef(oid) INTO definition FROM pg_constraint
 WHERE conrelid='finance_application_operations'::regclass AND conname='ck_finance_application_operation_scope';
 IF definition IS NULL OR left(definition,7)<>'CHECK (' THEN
  RAISE EXCEPTION 'Review original finance operation scope before expense confirmation extension';
 END IF;
 ALTER TABLE finance_application_operations DROP CONSTRAINT ck_finance_application_operation_scope;
 EXECUTE 'ALTER TABLE finance_application_operations ADD CONSTRAINT ck_finance_application_operation_scope CHECK ('
   ||substring(definition FROM 8 FOR length(definition)-8)||' OR operation=''FINANCE_DOCUMENT_GL_CONFIRM'')';
END $$;
