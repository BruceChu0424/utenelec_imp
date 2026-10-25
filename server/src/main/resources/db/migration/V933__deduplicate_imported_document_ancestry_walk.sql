-- Native provenance is a graph reachability question. A path-local recursive
-- walk repeats shared ancestors (including FK + typed references to the same
-- row) exponentially. Visit each identity once per invocation instead.
-- All state below is private call-local memory, never a caller-set GUC or a
-- persisted native cache. The same real FK and typed source rules remain.
CREATE OR REPLACE FUNCTION public.fn_imported_business_document_row_internal(
    p_table text,p_row jsonb,p_path text[])
RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=pg_catalog,public AS $walk$
DECLARE
    tables text[]:=ARRAY[p_table];
    ids uuid[]:=ARRAY[NULL::uuid];
    row_images jsonb[]:=ARRAY[p_row];
    depths integer[]:=ARRAY[cardinality(COALESCE(p_path,ARRAY[]::text[]))];
    seen text[]:=COALESCE(p_path,ARRAY[]::text[]);
    roots text[]:=public.fn_imported_business_document_roots();
    table_membership jsonb:='{}'::jsonb;
    foreign_keys jsonb:='{}'::jsonb;
    next_node integer:=1;
    node_table text; node_id uuid; node_row jsonb; node_depth integer;
    row_key text; target regclass; reference record; parent_refs jsonb;
    parent_table text; source_id text; pair text[]; scope_name text;
    is_document boolean; edge_list jsonb;
BEGIN
    IF p_row IS NULL OR p_table IS NULL THEN RETURN false; END IF;
    WHILE next_node<=cardinality(tables) LOOP
        node_table:=tables[next_node]; node_id:=ids[next_node];
        node_row:=row_images[next_node]; node_depth:=depths[next_node];
        next_node:=next_node+1;
        IF NOT table_membership ? node_table THEN
            table_membership:=jsonb_set(table_membership,ARRAY[node_table],
                to_jsonb(public.fn_imported_business_document_table(node_table)),true);
        END IF;
        IF NOT (table_membership->>node_table)::boolean THEN CONTINUE; END IF;
        row_key:=node_table||':'||COALESCE(node_row->>'id',node_row->>'record_id',node_id::text,'new');
        IF row_key=ANY(seen) THEN CONTINUE; END IF;
        IF node_row IS NULL THEN
            EXECUTE format('SELECT to_jsonb(parent) FROM public.%I parent WHERE id=$1',node_table)
                INTO node_row USING node_id;
            IF node_row IS NULL THEN CONTINUE; END IF;
        END IF;
        IF node_depth>64 THEN
            RAISE EXCEPTION 'Business document source graph exceeds the supported depth' USING ERRCODE='54001';
        END IF;
        seen:=array_append(seen,row_key);
        IF node_table=ANY(roots) OR node_row ? 'legacy_id' OR node_row ? 'legacy_import_run_id' THEN
            IF node_row->>'legacy_id' IS NOT NULL
                OR NULLIF(node_row->>'legacy_import_run_id','') IS NOT NULL THEN
                RETURN true;
            END IF;
        END IF;
        parent_refs:='[]'::jsonb;
        IF NOT foreign_keys ? node_table THEN
            target:=to_regclass(format('public.%I',node_table));
            SELECT COALESCE(jsonb_agg(jsonb_build_object(
                'parent_table',parent.relname::text,'child_column',child_column.attname::text)
                ORDER BY key.oid,position.index),'[]'::jsonb)
            INTO edge_list
            FROM pg_constraint key JOIN pg_class parent ON parent.oid=key.confrelid
            JOIN pg_namespace ns ON ns.oid=parent.relnamespace
            CROSS JOIN LATERAL generate_subscripts(key.conkey,1) position(index)
            JOIN pg_attribute child_column ON child_column.attrelid=key.conrelid
                AND child_column.attnum=key.conkey[position.index]
            JOIN pg_attribute parent_column ON parent_column.attrelid=key.confrelid
                AND parent_column.attnum=key.confkey[position.index]
            WHERE key.contype='f' AND key.conrelid=target AND ns.nspname='public'
                AND parent_column.attname='id' AND parent_column.atttypid='uuid'::regtype;
            foreign_keys:=jsonb_set(foreign_keys,ARRAY[node_table],edge_list,true);
        END IF;
        FOR reference IN SELECT * FROM jsonb_to_recordset(foreign_keys->node_table)
            AS edge(parent_table text,child_column text)
        LOOP
            source_id:=node_row->>reference.child_column;
            IF source_id IS NOT NULL THEN
                parent_refs:=parent_refs||jsonb_build_array(jsonb_build_object(
                    'parent_table',reference.parent_table,'source_id',source_id));
            END IF;
        END LOOP;
        FOREACH pair SLICE 1 IN ARRAY ARRAY[
            ['source_doc_type','source_doc_id'],['source_table','source_id'],
            ['parent_table','parent_id'],['owner_type','owner_id'],
            ['document_type','document_id'],['record_type','document_id'],['family','document_id'],
            ['receipt_type','receipt_id'],['receipt_type','receipt_item_id'],
            ['order_type','order_id'],['order_type','order_item_id']]
        LOOP
            source_id:=node_row->>pair[2];
            IF source_id ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
                IF pair[1]='receipt_type' THEN
                    parent_table:=CASE upper(node_row->>pair[1])
                        WHEN 'PURCHASE' THEN CASE pair[2] WHEN 'receipt_item_id' THEN 'purchase_receipt_items' ELSE 'purchase_receipts' END
                        WHEN 'SUBCONTRACT' THEN CASE pair[2] WHEN 'receipt_item_id' THEN 'subcontract_receipt_items' ELSE 'subcontract_receipts' END END;
                ELSIF pair[1]='order_type' THEN
                    parent_table:=CASE upper(node_row->>pair[1])
                        WHEN 'PURCHASE' THEN CASE pair[2] WHEN 'order_item_id' THEN 'purchase_order_items' ELSE 'purchase_orders' END
                        WHEN 'SUBCONTRACT' THEN CASE pair[2] WHEN 'order_item_id' THEN 'subcontract_order_items' ELSE 'subcontract_orders' END END;
                ELSE
                    parent_table:=public.fn_imported_business_document_scope_table(node_row->>pair[1]);
                END IF;
                IF parent_table IS NOT NULL THEN
                    parent_refs:=parent_refs||jsonb_build_array(jsonb_build_object(
                        'parent_table',parent_table,'source_id',source_id));
                END IF;
            END IF;
        END LOOP;
        IF node_table='platform_record_fields' THEN
            scope_name:=node_row->>'scope';
            parent_table:=public.fn_imported_business_document_scope_table(scope_name);
            source_id:=node_row->>'record_id';
            IF parent_table IS NOT NULL AND source_id IS NOT NULL THEN
                parent_refs:=parent_refs||jsonb_build_array(jsonb_build_object(
                    'parent_table',parent_table,'source_id',source_id));
            END IF;
            parent_table:=public.fn_imported_business_document_scope_table(
                regexp_replace(scope_name,'_(item|line)$',''));
            source_id:=node_row->>'source_document_id';
            IF parent_table IS NOT NULL AND source_id IS NOT NULL THEN
                parent_refs:=parent_refs||jsonb_build_array(jsonb_build_object(
                    'parent_table',parent_table,'source_id',source_id));
            END IF;
        END IF;
        FOR reference IN SELECT * FROM jsonb_to_recordset(parent_refs)
            AS parent(parent_table text,source_id text)
        LOOP
            parent_table:=reference.parent_table;
            IF NOT table_membership ? parent_table THEN
                table_membership:=jsonb_set(table_membership,ARRAY[parent_table],
                    to_jsonb(public.fn_imported_business_document_table(parent_table)),true);
            END IF;
            is_document:=(table_membership->>parent_table)::boolean;
            IF NOT is_document THEN CONTINUE; END IF;
            IF parent_table||':'||reference.source_id=ANY(seen) THEN CONTINUE; END IF;
            tables:=array_append(tables,parent_table);
            ids:=array_append(ids,reference.source_id::uuid);
            row_images:=array_append(row_images,NULL::jsonb);
            depths:=array_append(depths,node_depth+1);
            IF cardinality(tables)>65536 THEN
                RAISE EXCEPTION 'Business document source graph exceeds the supported size' USING ERRCODE='54001';
            END IF;
        END LOOP;
    END LOOP;
    RETURN false;
END $walk$;
