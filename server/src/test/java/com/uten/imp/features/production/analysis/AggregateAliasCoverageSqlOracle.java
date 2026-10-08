package com.uten.imp.features.production.analysis;

/** Frozen detailed database projection is the independent oracle for the narrower production read. */
public final class AggregateAliasCoverageSqlOracle {
    private AggregateAliasCoverageSqlOracle() { }
    public static final String SQL="""
            WITH coverage AS MATERIALIZED(SELECT * FROM fn_preplan_aggregate_alias_coverage(:analysisId))
            SELECT 'IN',analysis_material_id,NULL::uuid,inherited_pending_qty FROM coverage WHERE inherited_pending_qty>0
            UNION ALL
            SELECT 'OUT',CAST(source->>'sourceMaterialId' AS uuid),NULL::uuid,SUM(CAST(source->>'pendingQuantity' AS numeric))
            FROM coverage CROSS JOIN LATERAL jsonb_array_elements(coverage.source_aliases) source
            GROUP BY CAST(source->>'sourceMaterialId' AS uuid)
            UNION ALL
            SELECT 'COVERED',coverage.analysis_material_id,CAST(source->>'sourceMaterialId' AS uuid),SUM(CAST(source->>'inheritedQuantity' AS numeric))
            FROM coverage CROSS JOIN LATERAL jsonb_array_elements(coverage.source_aliases) source
            GROUP BY coverage.analysis_material_id,CAST(source->>'sourceMaterialId' AS uuid)
            """;
}
