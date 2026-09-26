package com.uten.imp.features.production.analysis;

import org.junit.jupiter.api.Test;
import java.math.BigDecimal;
import static com.uten.imp.features.production.analysis.MaterialAnalysisService.*;
import static org.assertj.core.api.Assertions.assertThat;

class AggregateMaterialProjectionMathTest {
    private static BigDecimal n(String value){return new BigDecimal(value);}
    private static NodeAllocation gap(String qty){return new NodeAllocation(BigDecimal.ZERO,n(qty));}

    @Test void fullyDelegatedParentStopsItsOldChildExplosionBeforePackageRounding() {
        BigDecimal remaining=parentPlannedOutput(gap("1"),new ParentSupplyCommitment(n("0"),n("0"),n("0"),n("1")));
        assertThat(remaining).isZero();
        assertThat(MaterialConsumptionMath.required(remaining,n("1"),"PER_PACKAGE",n("5"),false)).isZero();
        assertThat(MaterialConsumptionMath.required(n("3"),n("1"),"PER_PACKAGE",n("5"),false)).isEqualByComparingTo("1");
    }

    @Test void partialSharedProductionLeavesTheOldSourcesRemainingManufacturingResponsibility() {
        assertThat(parentPlannedOutput(gap("1500"),new ParentSupplyCommitment(n("0"),n("0"),n("0"),n("1000"))))
                .isEqualByComparingTo("500");
    }

    @Test void sharedDelegationNeverErasesASeparateExistingFrozenManufacturingPlan() {
        assertThat(parentPlannedOutput(gap("1500"),new ParentSupplyCommitment(n("0"),n("500"),n("500"),n("1000"))))
                .isEqualByComparingTo("500");
        assertThat(parentPlannedOutput(gap("500"),new ParentSupplyCommitment(n("0"),n("500"),n("500"),n("1000"))))
                .isEqualByComparingTo("500");
    }

    @Test void InheritedFinishedComponentSupplyDoesNotStartAnotherManufacturingExplosion() {
        assertThat(parentPlannedOutput(gap("3000"),new ParentSupplyCommitment(n("3000"),n("0"),n("0"),n("0"))))
                .isZero();
        assertThat(parentPlannedOutput(gap("3000"),new ParentSupplyCommitment(n("1000"),n("0"),n("0"),n("0"))))
                .isEqualByComparingTo("2000");
    }
}
