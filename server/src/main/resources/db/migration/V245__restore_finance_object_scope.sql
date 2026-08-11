-- Keep the database constraint aligned with every runtime data-scope policy.
ALTER TABLE user_data_scopes
    DROP CONSTRAINT IF EXISTS user_data_scopes_scope_check;

ALTER TABLE user_data_scopes
    ADD CONSTRAINT user_data_scopes_scope_check
    CHECK (scope IN (
        'goods',
        'client',
        'sales',
        'finance',
        'purchase',
        'subcontract',
        'production_plan',
        'stock_doc'
    ));
