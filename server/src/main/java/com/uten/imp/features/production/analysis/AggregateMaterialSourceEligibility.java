package com.uten.imp.features.production.analysis;

import java.math.BigDecimal;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;

import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;

/** One responsibility predicate for preparation selection and aggregate command admission. */
final class AggregateMaterialSourceEligibility {
    private AggregateMaterialSourceEligibility() { }

    static boolean hasResponsibility(MaterialView material, Map<UUID,ProductView> products) {
        ProductView anchor=material.planAnchorAnalysisLineId()==null?null:products.get(material.planAnchorAnalysisLineId());
        return material.actionable() || positive(material.requiredQty()) || positive(material.planningUncoveredQty())
                || positive(material.priorityMakeSupplementQty())
                || anchor!=null && !"AGGREGATE_MAKE".equals(anchor.sourceType()) && positive(anchor.remainingQty())
                || Set.of(REQUIREMENT_STATE_ACTIVE,REQUIREMENT_STATE_TRANSFERRED_TO_PLAN)
                    .contains(Objects.toString(material.requirementState(),""));
    }

    static boolean isRetiredContext(MaterialView material, Map<UUID,ProductView> products) {
        return !hasResponsibility(material,products)
                && Set.of(REQUIREMENT_STATE_DELEGATED_TO_MAKE_CHILD,REQUIREMENT_STATE_INACTIVE_PARENT_COVERED,
                    REQUIREMENT_STATE_INACTIVE_PARENT_ROUTE,REQUIREMENT_STATE_INACTIVE_REFERENCE,REQUIREMENT_STATE_INACTIVE)
                    .contains(Objects.toString(material.requirementState(),""));
    }

    private static boolean positive(BigDecimal quantity) { return quantity!=null && quantity.signum()>0; }
}
