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
    void editedWaitingSegmentPromotesOnlyWhenTheWholeKitIsAvailable() {
        CompleteKitAllocator.ProductLine line =
                line("4", usage(MATERIAL_A, "1"), usage(MATERIAL_B, "1"));
        CompleteKitAllocator.RequestedSegment request =
                new CompleteKitAllocator.RequestedSegment(
                        "manual-1",
                        line,
                        ProductionExecutionSegment.STATUS_WAITING,
                        decimal("4"));

        CompleteKitAllocator.Allocation result =
                allocator.allocateRequested(
                        List.of(request),
                        Map.of(
                                new CompleteKitAllocator.MaterialKey(
                                        MATERIAL_A, null), decimal("4"),
                                new CompleteKitAllocator.MaterialKey(
                                        MATERIAL_B, null), decimal("4")));

        assertThat(result.segments().getFirst().status())
                .isEqualTo(ProductionExecutionSegment.STATUS_READY);
        assertThat(result.segments().getFirst().materials())
                .allSatisfy(material ->
                        assertThat(material.candidateAllocatedQty())
                                .isEqualByComparingTo("4"));
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
