package com.uten.imp.common.inventory;
/** One candidate eligibility definition; source/prefill and command guards retain their own policies. */
public final class PeriodicMaterialCandidateSql {
    private PeriodicMaterialCandidateSql() { }
    public static final String FROM="""
            FROM goods material
            LEFT JOIN colors color ON color.id=material.color_id
            LEFT JOIN units unit ON unit.id=material.unit_id AND NOT unit.is_deleted
            WHERE material.issue_method='PERIODIC' AND material.periodic_cost_basis='OWN' AND NOT material.is_deleted
            """;
}
