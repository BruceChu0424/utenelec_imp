package com.uten.imp.features.production.analysis;

import java.math.BigDecimal;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;

import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;

/** Current demand and proven issued-source contexts shared by preparation and command admission. */
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

    static boolean hasOrderingContext(MaterialView material, Map<UUID,ProductView> products,
            Map<UUID,SupplyActionView> actions) {
        return !Set.of("SHIP","REFERENCE").contains(Objects.toString(material.controlStage(),""))
                && (hasResponsibility(material,products) || hasIssuedSupply(material,products,actions));
    }

    /** An issued source can explicitly append public output without regaining private demand. */
    static boolean hasIssuedSupply(MaterialView material, Map<UUID,ProductView> products,
            Map<UUID,SupplyActionView> actions) {
        UUID anchorId=material.level()==0?material.analysisLineId():material.planAnchorAnalysisLineId();
        ProductView anchor=anchorId==null?null:products.get(anchorId);
        if("MAKE".equals(material.sourceConfirmed()) && anchor!=null
                && !"AGGREGATE_MAKE".equals(anchor.sourceType()) && positive(anchor.issuedPlanQty()))return true;
        if(material.downstreamReferences()==null)return false;
        return material.downstreamReferences().stream().anyMatch(reference->{
            SupplyActionView action=reference.actionId()==null?null:actions.get(reference.actionId());
            return action!=null && !"CANCELLED".equals(reference.status()) && !"CANCELLED".equals(action.status())
                    && Objects.equals(material.sourceConfirmed(),reference.route())
                    && Objects.equals(material.sourceConfirmed(),action.route())
                    && Set.of("SUPPLY","AGGREGATE_SUPPLY").contains(Objects.toString(action.operationType(),""))
                    && (positive(action.requestedQty()) || positive(action.publicSurplusQty()) || positive(action.safetyReplenishmentQty()));
        });
    }

    static boolean isRetiredContext(MaterialView material, Map<UUID,ProductView> products,
            Map<UUID,SupplyActionView> actions) {
        return !hasOrderingContext(material,products,actions)
                && Set.of(REQUIREMENT_STATE_DELEGATED_TO_MAKE_CHILD,REQUIREMENT_STATE_INACTIVE_PARENT_COVERED,
                    REQUIREMENT_STATE_INACTIVE_PARENT_ROUTE,REQUIREMENT_STATE_INACTIVE_REFERENCE,REQUIREMENT_STATE_INACTIVE)
                    .contains(Objects.toString(material.requirementState(),""));
    }

    private static boolean positive(BigDecimal quantity) { return quantity!=null && quantity.signum()>0; }
}
