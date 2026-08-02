package com.uten.imp.features.production.mrp;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.UUID;

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

    @Test
    void directMakeRequirementsAggregateOnlyCurrentLayerCandidateShortage() {
        UUID makeGoodsId = UUID.randomUUID();
        UUID makeUnitId = UUID.randomUUID();
        UUID coveredGoodsId = UUID.randomUUID();
        UUID coveredUnitId = UUID.randomUUID();
        CompleteKitAllocator.Allocation allocation =
                new CompleteKitAllocator.Allocation(List.of(
                        new CompleteKitAllocator.SegmentAllocation(
                                "S1", null, "WAITING", BigDecimal.ONE,
                                List.of(
                                        material(makeGoodsId, makeUnitId,
                                                "4", "0", "MAKE"),
                                        material(UUID.randomUUID(),
                                                UUID.randomUUID(),
                                                "2", "2", "BUY"))),
                        new CompleteKitAllocator.SegmentAllocation(
                                "S2", null, "WAITING", BigDecimal.ONE,
                                List.of(
                                        material(makeGoodsId, makeUnitId,
                                                "6", "3", "MAKE"),
                                        material(coveredGoodsId, coveredUnitId,
                                                "2", "0", "MAKE")))),
                        Map.of());

        List<MrpService.DirectMakeRequirement> requirements =
                ProductionExecutionPackageCommandService
                        .directMakeRequirements(allocation);

        assertThat(requirements).hasSize(1);
        MrpService.DirectMakeRequirement requirement = requirements.getFirst();
        assertThat(requirement.goodsId()).isEqualTo(makeGoodsId);
        assertThat(requirement.unitId()).isEqualTo(makeUnitId);
        assertThat(requirement.requiredQty()).isEqualByComparingTo("10");
        assertThat(requirement.shortageQty()).isEqualByComparingTo("3");
    }

    @Test
    void currentResultLocksTheConfirmedPackageAgainstConcurrentLifecycleChanges()
            throws NoSuchMethodException {
        var method = com.uten.imp.features.production.fulfillment
                .ProductionPlanningPackageRepository.class.getMethod(
                        "findFirstByPlanIdAndStatusAndExecutionModelVersionAndDeletedFalseOrderByCreatedAtDesc",
                        UUID.class, String.class, Short.class);
        var lock = method.getAnnotation(
                org.springframework.data.jpa.repository.Lock.class);

        assertThat(lock).isNotNull();
        assertThat(lock.value())
                .isEqualTo(jakarta.persistence.LockModeType.PESSIMISTIC_READ);

        var serviceMethod = ProductionPlanningPackageService.class.getMethod(
                "currentResult", UUID.class);
        var transaction = serviceMethod.getAnnotation(
                org.springframework.transaction.annotation.Transactional.class);
        assertThat(transaction).isNotNull();
        assertThat(transaction.readOnly()).isFalse();
    }

    private static CompleteKitAllocator.MaterialAllocation material(
            UUID goodsId,
            UUID unitId,
            String required,
            String shortage,
            String route) {
        return new CompleteKitAllocator.MaterialAllocation(
                goodsId, null, unitId, BigDecimal.ONE,
                new BigDecimal(required), BigDecimal.ZERO,
                BigDecimal.ZERO, new BigDecimal(shortage), route);
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
