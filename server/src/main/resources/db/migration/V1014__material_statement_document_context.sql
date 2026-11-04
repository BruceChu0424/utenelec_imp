-- The original source group and its book property stay distinct from the actual
-- paper currency. Existing frozen records retain their original nullable scope.
ALTER TABLE finance_statement_document_reviews
 ADD COLUMN material_context_id uuid REFERENCES finance_material_contexts(id),
 ADD COLUMN material_all_contexts boolean NOT NULL DEFAULT false,
 ADD CONSTRAINT ck_finance_statement_material_context
 CHECK((material_context_id IS NULL OR template_key='otherReceivableStatement')
   AND (NOT material_all_contexts OR material_context_id IS NOT NULL));
CREATE INDEX idx_finance_statement_material_review
 ON finance_statement_document_reviews(material_context_id,date_from,date_to,id)
 WHERE material_context_id IS NOT NULL;
