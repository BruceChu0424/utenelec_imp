package com.uten.imp.features.production.mrp;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class ProductionPlanningPackageServiceTest {

    @Test
    void acceptsACommonCoverageRatioAcrossDifferentBomQuantities() {
        boolean balanced = ProductionPlanningPackageService.hasCommonCoverageRatio(List.of(
                coverage("20", "10"),
                coverage("10", "5"),
                coverage("4", "2")));

        assertThat(balanced).isTrue();
    }

    @Test
    void rejectsMismatchedMaterialCoverageThatWouldCreateFalseKits() {
        boolean balanced = ProductionPlanningPackageService.hasCommonCoverageRatio(List.of(
                coverage("10", "10"),
                coverage("10", "6")));

        assertThat(balanced).isFalse();
    }

    @Test
    void treatsNoStockAcrossAllMaterialsAsBalancedWaitingDemand() {
        boolean balanced = ProductionPlanningPackageService.hasCommonCoverageRatio(List.of(
                coverage("10", "0"),
                coverage("3", "0")));

        assertThat(balanced).isTrue();
    }

    @Test
    void rejectsAllocationAboveDemand() {
        assertThatThrownBy(() ->
                ProductionPlanningPackageService.hasCommonCoverageRatio(List.of(
                        coverage("10", "11"))))
                .isInstanceOf(IllegalArgumentException.class);
    }

    @Test
    void rejectsConfirmThatLeavesBuyShortageWithoutPurchaseRequest() {
        assertThatThrownBy(() ->
                ProductionExecutionPackageCommandService
                        .requirePurchaseRequestForBuyShortage(
                                false, List.of("shortage")))
                .isInstanceOf(ApiException.class)
                .extracting(error -> ((ApiException) error).getCode())
                .isEqualTo(ErrorCode.VALIDATION_FAILED);
    }

    @Test
    void permitsNoShortageOrExplicitPurchaseGeneration() {
        ProductionExecutionPackageCommandService
                .requirePurchaseRequestForBuyShortage(false, List.of());
        ProductionExecutionPackageCommandService
                .requirePurchaseRequestForBuyShortage(
                        true, List.of("shortage"));
    }

    @Test
    void legacyDerivedWritesCannotMixWithExecutionSegments() {
        assertThatThrownBy(() ->
                MrpService.requireNoMixedExecutionModel(1, "领料单"))
                .isInstanceOf(ApiException.class)
                .extracting(error -> ((ApiException) error).getCode())
                .isEqualTo(ErrorCode.CONFLICT);
    }

    @Test
    void legacyDerivedWritesRemainAvailableForModelZeroPlans() {
        MrpService.requireNoMixedExecutionModel(0, "领料单");
    }

    @Test
    void permitsConfirmationWhenNoLegacyExecutionFactsExist() {
        ProductionExecutionPackageCommandService
                .requireNoLegacyExecutionFacts(
                        new ProductionExecutionPackageCommandService
                                .LegacyExecutionFacts(
                                        false,
                                        false,
                                        false,
                                        false,
                                        false));
    }

    @Test
    void rejectsEveryLegacyExecutionFactBeforeV1Confirmation() {
        List<ProductionExecutionPackageCommandService.LegacyExecutionFacts>
                legacyCases = List.of(
                        legacyFacts(true, false, false, false, false),
                        legacyFacts(false, true, false, false, false),
                        legacyFacts(false, false, true, false, false),
                        legacyFacts(false, false, false, true, false),
                        legacyFacts(false, false, false, false, true));

        legacyCases.forEach(facts ->
                assertThatThrownBy(() ->
                        ProductionExecutionPackageCommandService
                                .requireNoLegacyExecutionFacts(facts))
                        .isInstanceOf(ApiException.class)
                        .satisfies(error -> {
                            ApiException api = (ApiException) error;
                            assertThat(api.getCode())
                                    .isEqualTo(ErrorCode.CONFLICT);
                            assertThat(api.getMessage())
                                    .contains("先完成/反向旧链")
                                    .contains("新建生产计划");
                        }));
    }

    private static ProductionExecutionPackageCommandService
            .LegacyExecutionFacts legacyFacts(
                    boolean reported,
                    boolean purchase,
                    boolean draw,
                    boolean subplan,
                    boolean packageV0) {
        return new ProductionExecutionPackageCommandService
                .LegacyExecutionFacts(
                        reported, purchase, draw, subplan, packageV0);
    }

    private static ProductionPlanningPackageService.CoverageQuantity coverage(
            String required,
            String allocated) {
        return new ProductionPlanningPackageService.CoverageQuantity(
                new BigDecimal(required),
                new BigDecimal(allocated));
    }
}
