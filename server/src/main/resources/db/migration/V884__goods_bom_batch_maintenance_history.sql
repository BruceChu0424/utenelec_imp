-- Top-level batch maintenance is one explicit, permission-bound BOM history operation.
DO $migration$
DECLARE definition text; anchor text;
BEGIN
    definition:=pg_get_functiondef('fn_goods_history_operation(text,text)'::regprocedure);
    anchor:=' WHEN p_path=''/api/master/goods/bom/paste'' AND p_method=''POST'' THEN ''BOM_PASTE''';
    IF length(definition)-length(replace(definition,anchor,''))<>length(anchor) THEN
        RAISE EXCEPTION 'Goods history batch-maintenance route anchor changed';
    END IF;
    EXECUTE replace(definition,anchor,
        ' WHEN p_path=''/api/master/goods/bom/batch-maintenance/commit'' AND p_method=''POST'' THEN ''BOM_EDIT'''||chr(10)||anchor);
END
$migration$;
