-- Preserve legacy records, but prevent creating a new ambiguous category path.
-- The same hierarchy lock is used by application create, move and import writes.
CREATE OR REPLACE FUNCTION guard_category_sibling_name() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    lock_key text;
    duplicate_id uuid;
    domain text;
BEGIN
    IF NEW.is_deleted THEN RETURN NEW; END IF;
    IF TG_OP = 'UPDATE' AND NOT OLD.is_deleted
       AND NEW.name IS NOT DISTINCT FROM OLD.name
       AND NEW.parent_id IS NOT DISTINCT FROM OLD.parent_id
       AND (TG_TABLE_NAME <> 'payment_styles'
            OR to_jsonb(NEW)->>'category' IS NOT DISTINCT FROM to_jsonb(OLD)->>'category') THEN
        RETURN NEW;
    END IF;
    lock_key := CASE TG_TABLE_NAME
        WHEN 'material_categories' THEN 'MATERIAL_CATEGORY_HIERARCHY'
        WHEN 'client_categories' THEN 'CLIENT_CATEGORY_HIERARCHY'
        WHEN 'supplier_categories' THEN 'SUPPLIER_CATEGORY_HIERARCHY'
        WHEN 'mould_categories' THEN 'MOULD_CATEGORY_HIERARCHY'
        WHEN 'payment_styles' THEN 'PAYMENT_STYLE_HIERARCHY'
    END;
    PERFORM pg_advisory_xact_lock(hashtextextended(lock_key, 0));
    NEW.name := btrim(NEW.name);
    IF NEW.name = '' THEN
        RAISE EXCEPTION '请输入分类名称' USING ERRCODE = '23514';
    END IF;
    domain := CASE WHEN TG_TABLE_NAME = 'payment_styles' THEN to_jsonb(NEW)->>'category' END;
    EXECUTE format('SELECT id FROM %I WHERE NOT is_deleted AND btrim(name)=$1'
        || ' AND parent_id IS NOT DISTINCT FROM $2 AND id<>$3'
        || CASE WHEN TG_TABLE_NAME='payment_styles' THEN ' AND category=$4' ELSE '' END
        || ' LIMIT 1', TG_TABLE_NAME)
        INTO duplicate_id USING NEW.name, NEW.parent_id, NEW.id, domain;
    IF duplicate_id IS NOT NULL THEN
        RAISE EXCEPTION '同一上级下已有分类“%”，请更换名称', NEW.name
            USING ERRCODE = '23505', CONSTRAINT = 'category_sibling_name';
    END IF;
    RETURN NEW;
END;
$$;

DO $$
DECLARE table_name text;
BEGIN
    FOREACH table_name IN ARRAY ARRAY['material_categories', 'client_categories',
            'supplier_categories', 'mould_categories', 'payment_styles'] LOOP
        EXECUTE format('CREATE INDEX %I ON %I (%s) WHERE NOT is_deleted',
            'idx_' || table_name || '_sibling_name', table_name,
            CASE WHEN table_name='payment_styles' THEN 'category, btrim(name), parent_id'
                 ELSE 'btrim(name), parent_id' END);
        EXECUTE format('CREATE TRIGGER trg_category_sibling_name BEFORE INSERT OR UPDATE'
            || ' ON %I FOR EACH ROW EXECUTE FUNCTION guard_category_sibling_name()', table_name);
    END LOOP;
END;
$$;
