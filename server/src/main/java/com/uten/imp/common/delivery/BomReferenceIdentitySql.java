package com.uten.imp.common.delivery;

/** Shared live UUID identity diagnostics. Legacy labels never become a new live relationship. */
public final class BomReferenceIdentitySql {
    private BomReferenceIdentitySql() {}
    /** Unit/color aliases must already exclude soft-deleted rows, as the production BOM reader does. */
    public static String edgeProblems(String edge,String component,String unit,String color) {
        for(String alias:new String[]{edge,component,unit,color})
            if(alias==null||!alias.matches("[a-z][a-z_0-9]*"))throw new IllegalArgumentException("Expected a constant SQL alias");
        return """
            NULLIF(concat_ws(',',
              CASE WHEN %2$s.is_deleted THEN 'COMPONENT_DELETED' END,
              CASE WHEN %2$s.unit_id IS NULL THEN 'UNIT_MISSING' WHEN %3$s.id IS NULL THEN 'UNIT_DELETED' END,
              CASE WHEN COALESCE(%1$s.color_id,%2$s.color_id) IS NOT NULL AND %4$s.id IS NULL
                THEN CASE WHEN %1$s.color_id IS NOT NULL THEN 'ROW_COLOR_DELETED' ELSE 'COMPONENT_COLOR_DELETED' END END,
              CASE WHEN %1$s.color_id IS NULL AND NULLIF(%1$s.color_legacy_id,0) IS NOT NULL THEN 'ROW_COLOR_LEGACY' END,
              CASE WHEN %2$s.color_id IS NULL AND NULLIF(%2$s.color_legacy_id,0) IS NOT NULL THEN 'COMPONENT_COLOR_LEGACY' END),'')
            """.formatted(edge,component,unit,color);
    }
}
