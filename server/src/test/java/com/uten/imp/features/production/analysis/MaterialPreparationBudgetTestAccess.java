package com.uten.imp.features.production.analysis;

import jakarta.persistence.EntityManager;
import java.math.BigDecimal;
import java.util.*;

/** Test-only access to the batch read model without making its production API public. */
public final class MaterialPreparationBudgetTestAccess {
    private MaterialPreparationBudgetTestAccess(){}
    public record Facts(Map<UUID,BigDecimal> privatePending,Map<UUID,BigDecimal> outgoingPending,
                        Map<String,BigDecimal> shared,Map<UUID,String> pools){}
    public static Facts read(EntityManager em,MaterialAnalysisContracts.AnalysisView view){
        Set<UUID> warehouses=new HashSet<>(view.warehouseIds());
        for(Object id:em.createNativeQuery("""
                SELECT id FROM warehouses
                WHERE is_deleted=FALSE AND is_accountable=TRUE
                  AND fn_warehouse_same_main(id,:warehouseId)
                """).setParameter("warehouseId",view.warehouseId()).getResultList())warehouses.add((UUID)id);
        var facts=new MaterialPreparationBudgetReader(em).read(view.analysisId(),view.warehouseId(),view.flatMaterials(),warehouses);
        return new Facts(facts.privateMakePendingByMaterial(),facts.outgoingInheritedPendingByMaterial(),facts.sharedQtyByPoolKey(),facts.poolKeyByMaterial());
    }
}
