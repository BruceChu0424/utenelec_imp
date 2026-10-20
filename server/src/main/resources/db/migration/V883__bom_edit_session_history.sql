-- One explicit save is one user-owned history operation. Preview remains excluded.
ALTER TABLE goods_operation_history ADD COLUMN required_permissions text[];
COMMENT ON COLUMN goods_operation_history.required_permissions IS
    'Exact original command authorities. A MOVE requires edit, even though immutable lineage stores delete plus insert. NULL preserves the original legacy operation contract.';
DO $migration$
DECLARE definition text; anchor text;
BEGIN
    definition:=pg_get_functiondef('fn_goods_history_operation(text,text)'::regprocedure);
    anchor:=' WHEN p_path=''/api/master/goods/bom/paste'' AND p_method=''POST'' THEN ''BOM_PASTE''';
    IF length(definition)-length(replace(definition,anchor,''))<>length(anchor) THEN
        RAISE EXCEPTION 'Goods history operation anchor changed';
    END IF;
    definition:=replace(definition,anchor,
        ' WHEN p_path ~ ''^/api/master/goods/[0-9a-fA-F-]{36}/bom/edit/commit$'' AND p_method=''POST'' THEN ''BOM_EDIT'''||chr(10)||
        ' WHEN p_path=''/api/production/reports/where-used/replacement/commit'' AND p_method=''POST'' THEN ''BOM_EDIT'''||chr(10)||anchor);
    EXECUTE definition;
END
$migration$;
