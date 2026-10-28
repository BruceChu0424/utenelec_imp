package com.uten.imp.common.report;

/** Units of the immutable workshop ledger quantities; never inferred from today's goods row. */
public final class WorkshopMaterialQuantityUnits {
    private WorkshopMaterialQuantityUnits() { }
    public static String ledgerUnitId(String ledgerAlias) {
        if(ledgerAlias==null||!ledgerAlias.matches("[a-zA-Z_][a-zA-Z0-9_]*"))throw new IllegalArgumentException("Invalid ledger alias");
        return "(CASE WHEN "+ledgerAlias+".source_kind IN ('ISSUE','RETURN') THEN ("
                +"SELECT line.unit_id FROM workshop_material_requisition_postings posting JOIN workshop_material_requisition_lines line ON line.id=posting.line_id WHERE posting.id="+ledgerAlias+".source_row_id)"
                +" WHEN "+ledgerAlias+".source_kind='OTHER_ISSUE' THEN (SELECT source.unit_id FROM workshop_material_other_issues source WHERE source.id="+ledgerAlias+".source_row_id)"
                +" WHEN "+ledgerAlias+".source_kind IN ('CONSUME','CONSUME_REVERSE','GAIN','GAIN_REVERSE') THEN ("
                +"SELECT line.unit_id FROM workshop_material_count_postings posting JOIN workshop_material_period_lines line ON line.id=posting.period_line_id WHERE posting.id="+ledgerAlias+".source_row_id)"
                +" WHEN "+ledgerAlias+".source_kind IN ('OPENING','ADJUSTMENT') THEN (SELECT source.unit_id FROM workshop_material_count_adjustment_postings source WHERE source.id="+ledgerAlias+".source_row_id)"
                +" ELSE NULL::uuid END)";
    }
}
