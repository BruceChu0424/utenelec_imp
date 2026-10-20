-- Private related display columns share the existing account layout and immutable definition lifecycle.
ALTER TABLE platform_column_definitions ADD COLUMN relation_key varchar(80);
ALTER TABLE platform_column_definitions DROP CONSTRAINT platform_column_definitions_value_type_check;
ALTER TABLE platform_column_definitions ADD CONSTRAINT platform_column_definitions_value_type_check
    CHECK (value_type IN ('TEXT','NUMBER','CALCULATED','RELATED'));
ALTER TABLE platform_column_definitions ADD CONSTRAINT platform_column_definitions_relation_check CHECK (
    (value_type = 'RELATED') = (relation_key IS NOT NULL)
    AND (relation_key IS NULL OR (relation_key ~ '^[a-zA-Z][a-zA-Z0-9_]{0,79}$'
         AND owner_user_id <> '00000000-0000-0000-0000-000000000000'::uuid))
);
