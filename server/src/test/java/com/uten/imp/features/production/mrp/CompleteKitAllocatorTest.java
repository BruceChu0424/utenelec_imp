package com.uten.imp.features.production.mrp;

import com.uten.imp.features.production.fulfillment.ProductionExecutionSegment;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class CompleteKitAllocatorTest {

    private static final UUID PLAN_ITEM =
            UUID.fromString("00000000-0000-0000-0000-000000000101");
    private static final UUID PRODUCT =
            UUID.fromString("00000000-0000-0000-0000-000000000102");
    private static final UUID PRODUCT_UNIT =
            UUID.fromString("00000000-0000-0000-0000-000000000103");
    private static final UUID MATERIAL_A =
            UUID.fromString("00000000-0000-0000-0000-000000000201");
    private static final UUID MATERIAL_B =
            UUID.fromString("00000000-0000-0000-0000-000000000202");
    private static final UUID MATERIAL_UNIT =
            UUID.fromString("00000000-0000-0000-0000-000000000203");

    private final CompleteKitAllocator allocator = new CompleteKitAllocator();

    @Test
    void aTenAndBSixCreatesReadySixAndZeroHoldWaitingFour() {
        CompleteKitAllocator.Allocation result = allocator.allocate(
                List.of(line(
                        "10",
                        usage(MATERIAL_A, "1"),
                        usage(MATERIAL_B, "1"))),
                Map.of(
                        new CompleteKitAllocator.MaterialKey(
                                MATERIAL_A, null), decimal("10"),
                        new CompleteKitAllocator.MaterialKey(
                                MATERIAL_B, null), decimal("6")));

        assertThat(result.segments()).hasSize(2);
        CompleteKitAllocator.SegmentAllocation ready =
                result.segments().get(0);
        CompleteKitAllocator.SegmentAllocation waiting =
                result.segments().get(1);

        assertThat(ready.status())
                .isEqualTo(ProductionExecutionSegment.STATUS_READY);
        assertThat(ready.plannedQty()).isEqualByComparingTo("6");
        assertThat(ready.materials())
                .allSatisfy(material -> {
                    assertThat(material.requiredQty())
                            .isEqualByComparingTo("6");
                    assertThat(material.candidateAllocatedQty())
                            .isEqualByComparingTo("6");
                    assertThat(material.shortageQty()).isZero();
                });

        assertThat(waiting.status())
                .isEqualTo(ProductionExecutionSegment.STATUS_WAITING);
        assertThat(waiting.autoPromoteWhenReady()).isTrue();
        assertThat(waiting.plannedQty()).isEqualByComparingTo("4");
        assertThat(waiting.materials())
                .allSatisfy(material ->
                        assertThat(material.candidateAllocatedQty()).isZero());
        assertThat(material(waiting, MATERIAL_A).shortageQty()).isZero();
        assertThat(material(waiting, MATERIAL_B).shortageQty())
                .isEqualByComparingTo("4");
        assertThat(result.remainingAvailability()
                .get(new CompleteKitAllocator.MaterialKey(MATERIAL_A, null)))
                .isEqualByComparingTo("4");
        assertThat(result.remainingAvailability()
                .get(new CompleteKitAllocator.MaterialKey(MATERIAL_B, null)))
                .isZero();
    }

    @Test
    void waitingSegmentsDoNotDoubleCountTheSameUnreservedStock() {
        UUID secondPlanItem =
                UUID.fromString("00000000-0000-0000-0000-000000000111");
        UUID secondProduct =
                UUID.fromString("00000000-0000-0000-0000-000000000112");
        CompleteKitAllocator.Allocation result = allocator.allocate(
                List.of(
                        line(
                                PLAN_ITEM,
                                PRODUCT,
                                "4",
                                usage(MATERIAL_A, "1"),
                                usage(MATERIAL_B, "1")),
                        line(
                                secondPlanItem,
                                secondProduct,
                                "4",
                                usage(MATERIAL_A, "1"),
                                usage(MATERIAL_B, "1"))),
                Map.of(
                        new CompleteKitAllocator.MaterialKey(
                                MATERIAL_A, null), decimal("4"),
                        new CompleteKitAllocator.MaterialKey(
                                MATERIAL_B, null), decimal("0")));

        assertThat(result.segments()).hasSize(2);
        CompleteKitAllocator.SegmentAllocation first =
                result.segments().get(0);
        CompleteKitAllocator.SegmentAllocation second =
                result.segments().get(1);
        assertThat(first.status())
                .isEqualTo(ProductionExecutionSegment.STATUS_WAITING);
        assertThat(second.status())
                .isEqualTo(ProductionExecutionSegment.STATUS_WAITING);
        assertThat(material(first, MATERIAL_A).shortageQty()).isZero();
        assertThat(material(second, MATERIAL_A).shortageQty())
                .isEqualByComparingTo("4");
        assertThat(first.materials())
                .allSatisfy(value ->
                        assertThat(value.candidateAllocatedQty()).isZero());
        assertThat(second.materials())
                .allSatisfy(value ->
                        assertThat(value.candidateAllocatedQty()).isZero());
    }

    @Test
    void editedWaitingSegmentStaysDeferredEvenWhenTheWholeKitIsAvailable() {
        CompleteKitAllocator.ProductLine line =
                line("4", usage(MATERIAL_A, "1"), usage(MATERIAL_B, "1"));
        CompleteKitAllocator.RequestedSegment request =
                new CompleteKitAllocator.RequestedSegment(
                        "manual-1",
                        line,
                        ProductionExecutionSegment.STATUS_WAITING,
                        decimal("4"),
                        true);

        CompleteKitAllocator.Allocation result =
                allocator.allocateRequested(
                        List.of(request),
                        Map.of(
                                new CompleteKitAllocator.MaterialKey(
                                        MATERIAL_A, null), decimal("4"),
                                new CompleteKitAllocator.MaterialKey(
                                        MATERIAL_B, null), decimal("4")));

        assertThat(result.segments().getFirst().status())
                .isEqualTo(ProductionExecutionSegment.STATUS_WAITING);
        assertThat(result.segments().getFirst().autoPromoteWhenReady()).isFalse();
        assertThat(result.segments().getFirst().materials())
                .allSatisfy(material ->
                        assertThat(material.candidateAllocatedQty())
                                .isZero());
    }

    @Test
    void editedReadySegmentFailsClosedWhenAnyMaterialIsShort() {
        CompleteKitAllocator.ProductLine line =
                line("7", usage(MATERIAL_A, "1"), usage(MATERIAL_B, "1"));
        CompleteKitAllocator.RequestedSegment request =
                new CompleteKitAllocator.RequestedSegment(
                        "manual-ready",
                        line,
                        ProductionExecutionSegment.STATUS_READY,
                        decimal("7"));

        assertThatThrownBy(() -> allocator.allocateRequested(
                List.of(request),
                Map.of(
                        new CompleteKitAllocator.MaterialKey(
                                MATERIAL_A, null), decimal("10"),
                        new CompleteKitAllocator.MaterialKey(
                                MATERIAL_B, null), decimal("6"))))
                .isInstanceOf(
                        CompleteKitAllocator.InsufficientKitException.class)
                .hasMessageContaining("manual-ready");
    }

    @Test
    void userCanPrioritizeALaterProductAcrossSharedStock() {
        UUID laterPlanItem =
                UUID.fromString("00000000-0000-0000-0000-000000000111");
        UUID laterProduct =
                UUID.fromString("00000000-0000-0000-0000-000000000112");
        CompleteKitAllocator.ProductLine earlier = line(
                PLAN_ITEM, PRODUCT, "4", usage(MATERIAL_A, "1"));
        CompleteKitAllocator.ProductLine later = line(
                laterPlanItem, laterProduct, "4", usage(MATERIAL_A, "1"));

        CompleteKitAllocator.Allocation result = allocator.allocateRequested(
                List.of(
                        new CompleteKitAllocator.RequestedSegment(
                                "earlier-waiting",
                                earlier,
                                ProductionExecutionSegment.STATUS_WAITING,
                                decimal("4")),
                        new CompleteKitAllocator.RequestedSegment(
                                "later-ready",
                                later,
                                ProductionExecutionSegment.STATUS_READY,
                                decimal("4"))),
                Map.of(
                        new CompleteKitAllocator.MaterialKey(
                                MATERIAL_A, null), decimal("4")));

        CompleteKitAllocator.SegmentAllocation prioritized =
                result.segments().stream()
                        .filter(segment -> segment.line()
                                .sourcePlanItemId().equals(laterPlanItem))
                        .findFirst()
                        .orElseThrow();
        CompleteKitAllocator.SegmentAllocation deferred =
                result.segments().stream()
                        .filter(segment -> segment.line()
                                .sourcePlanItemId().equals(PLAN_ITEM))
                        .findFirst()
                        .orElseThrow();

        assertThat(prioritized.status())
                .isEqualTo(ProductionExecutionSegment.STATUS_READY);
        assertThat(material(prioritized, MATERIAL_A).candidateAllocatedQty())
                .isEqualByComparingTo("4");
        assertThat(deferred.status())
                .isEqualTo(ProductionExecutionSegment.STATUS_WAITING);
        assertThat(material(deferred, MATERIAL_A).candidateAllocatedQty())
                .isZero();
        assertThat(material(deferred, MATERIAL_A).shortageQty())
                .isEqualByComparingTo("4");
    }

    @Test
    void fractionalBaseUnitUsageUsesConservativeFourDecimalRounding() {
        CompleteKitAllocator.Allocation result = allocator.allocate(
                List.of(line("3", usage(MATERIAL_A, "2.500001"))),
                Map.of(
                        new CompleteKitAllocator.MaterialKey(
                                MATERIAL_A, null), decimal("5.0001")));

        assertThat(result.segments().getFirst().plannedQty())
                .isEqualByComparingTo("2");
        assertThat(result.segments().getFirst()
                .materials().getFirst().requiredQty())
                .isEqualByComparingTo("5.0001");
        assertThat(result.segments().get(1).plannedQty())
                .isEqualByComparingTo("1");
        assertThat(result.segments().get(1)
                .materials().getFirst().candidateAllocatedQty())
                .isZero();
    }

    @Test
    void authorizedZeroMaterialProductIsEntirelyReadyWithoutStockOrDrawDemand() {
        CompleteKitAllocator.ProductLine directMake = line("12");

        CompleteKitAllocator.Allocation result = allocator.allocate(
                List.of(directMake), Map.of());

        assertThat(result.segments()).hasSize(1);
        assertThat(result.segments().getFirst().status())
                .isEqualTo(ProductionExecutionSegment.STATUS_READY);
        assertThat(result.segments().getFirst().plannedQty())
                .isEqualByComparingTo("12");
        assertThat(result.segments().getFirst().materials()).isEmpty();
        assertThat(result.remainingAvailability()).isEmpty();
    }

    @Test
    void wholePackageCounterexampleUsesExactThreeFor9999Over4000() {
        CompleteKitAllocator.MaterialUsage material = exactUsage(
                MATERIAL_A, "0.000250", "PER_PACKAGE",
                "1", "4000", false);

        CompleteKitAllocator.Allocation result = allocator.allocate(
                List.of(line("9999", material)),
                Map.of(material.materialKey(), decimal("3")));

        assertThat(result.segments()).singleElement().satisfies(segment -> {
            assertThat(segment.status())
                    .isEqualTo(ProductionExecutionSegment.STATUS_READY);
            assertThat(segment.plannedQty()).isEqualByComparingTo("9999");
            assertThat(segment.materials().getFirst().requiredQty())
                    .isEqualByComparingTo("3");
            assertThat(segment.materials().getFirst().perProductQty())
                    .isEqualByComparingTo("0.000301");
            assertThat(segment.materials().getFirst().requirementMode())
                    .isEqualTo("EXACT_SNAPSHOT");
            assertThat(segment.materials().getFirst().perProductQty()
                    .multiply(segment.plannedQty()))
                    .isNotEqualByComparingTo(
                            segment.materials().getFirst().requiredQty());
        });
        assertThat(material.required(decimal("9999"), BigDecimal.ONE))
                .isEqualByComparingTo("3");
    }

    @Test
    void wholePackageAvailabilitySplitsAtTheExactPackageBoundary() {
        CompleteKitAllocator.MaterialUsage material = exactUsage(
                MATERIAL_A, "0.333334", "PER_PACKAGE",
                "2", "6", false);

        CompleteKitAllocator.Allocation result = allocator.allocate(
                List.of(line("10", material)),
                Map.of(material.materialKey(), decimal("2")));

        assertThat(result.segments()).hasSize(2);
        assertThat(result.segments().getFirst().plannedQty())
                .isEqualByComparingTo("6");
        assertThat(result.segments().getFirst().materials().getFirst()
                .requiredQty()).isEqualByComparingTo("2");
        assertThat(result.segments().get(1).plannedQty())
                .isEqualByComparingTo("4");
        assertThat(result.segments().get(1).materials().getFirst()
                .requiredQty()).isEqualByComparingTo("2");
        assertThat(result.segments().getFirst().materials().getFirst()
                .perProductQty()).isEqualByComparingTo("0.333334");
        assertThat(result.segments().get(1).materials().getFirst()
                .perProductQty()).isEqualByComparingTo("0.500000");
        BigDecimal groupedAverage = result.segments().stream()
                .flatMap(segment -> segment.materials().stream())
                .map(CompleteKitAllocator.MaterialAllocation::requiredQty)
                .reduce(BigDecimal.ZERO, BigDecimal::add)
                .divide(decimal("10"), 6, java.math.RoundingMode.CEILING);
        assertThat(groupedAverage).isEqualByComparingTo("0.400000");
    }

    @Test
    void partialPackageUsesTheProportionalTailWithoutAverageRateDrift() {
        CompleteKitAllocator.MaterialUsage material = exactUsage(
                MATERIAL_A, "0.166667", "PER_PACKAGE",
                "1", "6", true);

        CompleteKitAllocator.Allocation result = allocator.allocate(
                List.of(line("3", material)),
                Map.of(material.materialKey(), decimal("0.5")));

        assertThat(result.segments()).singleElement().satisfies(segment -> {
            assertThat(segment.status())
                    .isEqualTo(ProductionExecutionSegment.STATUS_READY);
            assertThat(segment.materials().getFirst().requiredQty())
                    .isEqualByComparingTo("0.5");
        });
    }

    @Test
    void fixedBatchChargesTheTailAsAnotherWholeBatch() {
        CompleteKitAllocator.MaterialUsage material = exactUsage(
                MATERIAL_A, "0.002500", "FIXED_BATCH",
                "0.25", "100", true);

        CompleteKitAllocator.Allocation result = allocator.allocate(
                List.of(line("101", material)),
                Map.of(material.materialKey(), decimal("0.25")));

        assertThat(result.segments()).hasSize(2);
        assertThat(result.segments().getFirst().plannedQty())
                .isEqualByComparingTo("100");
        assertThat(result.segments().getFirst().materials().getFirst()
                .requiredQty()).isEqualByComparingTo("0.25");
        assertThat(result.segments().get(1).plannedQty())
                .isEqualByComparingTo("1");
        assertThat(result.segments().get(1).materials().getFirst()
                .requiredQty()).isEqualByComparingTo("0.25");
    }

    @Test
    void repeatedMaterialDimensionSumsEveryExactBomRule() {
        CompleteKitAllocator.MaterialUsage material =
                new CompleteKitAllocator.MaterialUsage(
                        MATERIAL_A,
                        null,
                        MATERIAL_UNIT,
                        decimal("0.583334"),
                        "BUY",
                        List.of(
                                rule("PER_PACKAGE", "2", "6", false),
                                rule("PER_PACKAGE", "1", "4", true)));

        CompleteKitAllocator.Allocation result = allocator.allocate(
                List.of(line("6", material)),
                Map.of(material.materialKey(), decimal("3.5")));

        assertThat(result.segments()).singleElement().satisfies(segment ->
                assertThat(segment.materials().getFirst().requiredQty())
                        .isEqualByComparingTo("3.5"));
        assertThat(material.requirementFingerprint(BigDecimal.ONE))
                .hasSize(64);
    }

    @Test
    void manualSegmentsEachFreezeTheirOwnWholePackageRequirement() {
        CompleteKitAllocator.MaterialUsage material = exactUsage(
                MATERIAL_A, "0.333334", "PER_PACKAGE",
                "2", "6", false);
        CompleteKitAllocator.ProductLine productLine = line("10", material);

        CompleteKitAllocator.Allocation result = allocator.allocateRequested(
                List.of(
                        new CompleteKitAllocator.RequestedSegment(
                                "manual-1", productLine,
                                ProductionExecutionSegment.STATUS_READY,
                                decimal("3")),
                        new CompleteKitAllocator.RequestedSegment(
                                "manual-2", productLine,
                                ProductionExecutionSegment.STATUS_READY,
                                decimal("3")),
                        new CompleteKitAllocator.RequestedSegment(
                                "manual-3", productLine,
                                ProductionExecutionSegment.STATUS_READY,
                                decimal("4"))),
                Map.of(material.materialKey(), decimal("6")));

        assertThat(result.segments()).hasSize(3)
                .allSatisfy(segment ->
                        assertThat(segment.materials().getFirst().requiredQty())
                                .isEqualByComparingTo("2"));
        BigDecimal allocated = result.segments().stream()
                .flatMap(segment -> segment.materials().stream())
                .map(CompleteKitAllocator.MaterialAllocation
                        ::candidateAllocatedQty)
                .reduce(BigDecimal.ZERO, BigDecimal::add);
        assertThat(allocated).isEqualByComparingTo("6");
    }

    private static CompleteKitAllocator.ProductLine line(
            String quantity,
            CompleteKitAllocator.MaterialUsage... materials) {
        return line(
                PLAN_ITEM, PRODUCT, quantity, materials);
    }

    private static CompleteKitAllocator.ProductLine line(
            UUID sourcePlanItemId,
            UUID productGoodsId,
            String quantity,
            CompleteKitAllocator.MaterialUsage... materials) {
        return new CompleteKitAllocator.ProductLine(
                sourcePlanItemId,
                1,
                productGoodsId,
                null,
                PRODUCT_UNIT,
                decimal("1"),
                decimal(quantity),
                LocalDate.of(2026, 8, 1),
                LocalDate.of(2026, 8, 10),
                null,
                null,
                null,
                "P-001",
                "Product",
                new CompleteKitAllocator.Priority(
                        LocalDate.of(2026, 8, 1),
                        1, sourcePlanItemId),
                List.of(materials),
                "bom-fingerprint");
    }

    private static CompleteKitAllocator.MaterialUsage usage(
            UUID goodsId, String perProductQty) {
        return new CompleteKitAllocator.MaterialUsage(
                goodsId,
                null,
                MATERIAL_UNIT,
                decimal(perProductQty),
                "BUY");
    }

    private static CompleteKitAllocator.MaterialUsage exactUsage(
            UUID goodsId,
            String perProductQty,
            String basis,
            String bomQty,
            String basisOutputQty,
            boolean allowPartialPackage) {
        return new CompleteKitAllocator.MaterialUsage(
                goodsId,
                null,
                MATERIAL_UNIT,
                decimal(perProductQty),
                "BUY",
                List.of(rule(
                        basis, bomQty, basisOutputQty,
                        allowPartialPackage)));
    }

    private static CompleteKitAllocator.ConsumptionRule rule(
            String basis,
            String bomQty,
            String basisOutputQty,
            boolean allowPartialPackage) {
        return new CompleteKitAllocator.ConsumptionRule(
                basis,
                decimal(bomQty),
                decimal(basisOutputQty),
                allowPartialPackage);
    }

    private static CompleteKitAllocator.MaterialAllocation material(
            CompleteKitAllocator.SegmentAllocation segment,
            UUID goodsId) {
        return segment.materials().stream()
                .filter(value -> value.goodsId().equals(goodsId))
                .findFirst()
                .orElseThrow();
    }

    private static BigDecimal decimal(String value) {
        return new BigDecimal(value);
    }
}
