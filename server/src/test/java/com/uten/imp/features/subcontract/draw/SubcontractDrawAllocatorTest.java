package com.uten.imp.features.subcontract.draw;

import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

/** ADR-143 §三 正反函数与 §二.16 联合分配(纯计算)。 */
class SubcontractDrawAllocatorTest {

    private static final UUID WAREHOUSE = UUID.randomUUID();
    private static final UUID OTHER_WAREHOUSE = UUID.randomUUID();

    @Test
    void forwardAndInverseAgreeOnTheFourDecimalGrid() {
        BigDecimal b = new BigDecimal("0.00122");
        BigDecimal planned = SubcontractDrawAllocator.materialQty(new BigDecimal("2"), b);
        assertThat(planned).isEqualByComparingTo("0.0025");
        // f(S) ≤ x ⟺ S ≤ sets(x): 计划量反算回去不会少于订货量, 最后一套能领满。
        assertThat(SubcontractDrawAllocator.sets(planned, b)).isGreaterThanOrEqualTo(new BigDecimal("2"));
        assertThat(SubcontractDrawAllocator.sets(new BigDecimal("2"), new BigDecimal("3")))
                .isEqualByComparingTo("0.6666");
    }

    @Test
    void kitIsLimitedByTheShortestMaterial() {
        UUID a = UUID.randomUUID();
        UUID b = UUID.randomUUID();
        var task = task("100", null,
                line(a, "1", "100", "0", stock(WAREHOUSE, "0", "50")),
                line(b, "2", "200", "0", stock(WAREHOUSE, "0", "80")));

        var result = SubcontractDrawAllocator.allocate(List.of(task));

        assertThat(result.tasks().getFirst().batchDrawableQty()).isEqualByComparingTo("40");
        assertThat(qty(result, a)).isEqualByComparingTo("40");
        assertThat(qty(result, b)).isEqualByComparingTo("80");
    }

    @Test
    void supplierOwnMaterialShareCapsTheDrawAtQm() {
        // ADR-143 §三.4a: 订 100、已发 60 套, 财务批准委外商自带料 20 → 我方供料套数 Qm = 80;
        // 仓库物料很多, 本批也只能再领 20 套(A 20、B 40), 不是补满原计划的 40 套。
        UUID a = UUID.randomUUID();
        UUID b = UUID.randomUUID();
        var task = task("80", null,
                line(a, "1", "100", "60", stock(WAREHOUSE, "0", "1000")),
                line(b, "2", "200", "120", stock(WAREHOUSE, "0", "1000")));

        var result = SubcontractDrawAllocator.allocate(List.of(task));

        assertThat(result.tasks().getFirst().completeQty()).isEqualByComparingTo("60");
        assertThat(result.tasks().getFirst().batchDrawableQty()).isEqualByComparingTo("20");
        assertThat(qty(result, a)).isEqualByComparingTo("20");
        assertThat(qty(result, b)).isEqualByComparingTo("40");

        var over = SubcontractDrawAllocator.allocate(List.of(task("80", "21",
                line(a, "1", "100", "60", stock(WAREHOUSE, "0", "1000")),
                line(b, "2", "200", "120", stock(WAREHOUSE, "0", "1000")))));
        assertThat(over.anyExceeded()).as("超过 Qm 的领料按「本批可领已变化」拒绝").isTrue();
        assertThat(over.slices()).isEmpty();
    }

    @Test
    void laggingMaterialIsToppedUpFirstAndLeadingMaterialIsNotOverIssued() {
        UUID a = UUID.randomUUID();
        UUID b = UUID.randomUUID();
        // A 已发 40 套, B 只发了 30 套(60/2); 仓里只来了 B 20。
        var task = task("100", null,
                line(a, "1", "100", "40", stock(WAREHOUSE, "0", "0")),
                line(b, "2", "200", "60", stock(WAREHOUSE, "0", "20")));

        var result = SubcontractDrawAllocator.allocate(List.of(task));

        assertThat(result.tasks().getFirst().completeQty()).isEqualByComparingTo("30");
        assertThat(result.tasks().getFirst().batchDrawableQty()).isEqualByComparingTo("10");
        assertThat(qty(result, a)).isEqualByComparingTo("0");
        assertThat(qty(result, b)).isEqualByComparingTo("20");
    }

    @Test
    void tasksSharingPublicStockAreAllocatedInOrderAndDefaultsDoNotOverlap() {
        UUID first = UUID.randomUUID();
        UUID second = UUID.randomUUID();
        UUID goods = UUID.randomUUID();
        var t1 = new SubcontractDrawAllocator.Task(UUID.randomUUID(), UUID.randomUUID(), new BigDecimal("20"), null,
                List.of(new SubcontractDrawAllocator.Line(first, goods, null, BigDecimal.ONE,
                        new BigDecimal("20"), BigDecimal.ZERO, List.of(stock(WAREHOUSE, "0", "30")))));
        var t2 = new SubcontractDrawAllocator.Task(UUID.randomUUID(), UUID.randomUUID(), new BigDecimal("20"), null,
                List.of(new SubcontractDrawAllocator.Line(second, goods, null, BigDecimal.ONE,
                        new BigDecimal("20"), BigDecimal.ZERO, List.of(stock(WAREHOUSE, "0", "30")))));

        var result = SubcontractDrawAllocator.allocate(List.of(t1, t2));

        assertThat(result.tasks().get(0).batchDrawableQty()).isEqualByComparingTo("20");
        assertThat(result.tasks().get(1).batchDrawableQty()).isEqualByComparingTo("10");
        assertThat(result.anyExceeded()).isFalse();
        assertThat(qty(result, second)).isEqualByComparingTo("10");
    }

    @Test
    void requestAboveTheBatchDrawableIsReportedAsExceeded() {
        UUID a = UUID.randomUUID();
        var task = task("10", "6", line(a, "1", "10", "0", stock(WAREHOUSE, "0", "5")));

        var result = SubcontractDrawAllocator.allocate(List.of(task));

        assertThat(result.anyExceeded()).isTrue();
        assertThat(result.slices()).isEmpty();
    }

    @Test
    void exactLotsAreTakenBeforePublicStockAndRicherWarehouseFirst() {
        UUID a = UUID.randomUUID();
        var task = task("10", null, line(a, "1", "10", "0",
                stock(OTHER_WAREHOUSE, "0", "3"), stock(WAREHOUSE, "4", "4")));

        var result = SubcontractDrawAllocator.allocate(List.of(task));

        assertThat(result.tasks().getFirst().batchDrawableQty()).isEqualByComparingTo("10");
        assertThat(result.slices()).hasSize(2);
        assertThat(result.slices().getFirst().warehouseId()).isEqualTo(WAREHOUSE);
        assertThat(result.slices().getFirst().qty()).isEqualByComparingTo("8");
        assertThat(result.slices().get(1).qty()).isEqualByComparingTo("2");
    }

    @Test
    void ownLotsInAnotherWarehouseAreTakenBeforeSharedPublicStock() {
        UUID goods = UUID.randomUUID();
        UUID w1 = UUID.randomUUID();
        UUID w2 = UUID.randomUUID();
        UUID firstLine = UUID.randomUUID();
        UUID secondLine = UUID.randomUUID();
        // T1(交期最早)要 10: 自己的专属批次 10 在 W2(W2 没有公共库存); W1 有公共 100。
        var t1 = new SubcontractDrawAllocator.Task(UUID.randomUUID(), UUID.randomUUID(), new BigDecimal("10"), null,
                List.of(new SubcontractDrawAllocator.Line(firstLine, goods, null, BigDecimal.ONE,
                        new BigDecimal("10"), BigDecimal.ZERO,
                        List.of(stock(w1, "0", "100"), stock(w2, "10", "0")))));
        // T2 要 100: W2 的专属批次是 T1 的, 对 T2 不算; 只能用 W1 的公共 100。
        var t2 = new SubcontractDrawAllocator.Task(UUID.randomUUID(), UUID.randomUUID(), new BigDecimal("100"), null,
                List.of(new SubcontractDrawAllocator.Line(secondLine, goods, null, BigDecimal.ONE,
                        new BigDecimal("100"), BigDecimal.ZERO,
                        List.of(stock(w1, "0", "100")))));

        var result = SubcontractDrawAllocator.allocate(List.of(t1, t2));

        assertThat(result.tasks().get(0).batchDrawableQty()).isEqualByComparingTo("10");
        assertThat(result.tasks().get(1).batchDrawableQty()).isEqualByComparingTo("100");
        assertThat(result.anyExceeded()).isFalse();
        var firstSlices = result.slices().stream()
                .filter(slice -> slice.planItemId().equals(firstLine)).toList();
        assertThat(firstSlices).hasSize(1);
        assertThat(firstSlices.getFirst().warehouseId()).isEqualTo(w2);
        assertThat(firstSlices.getFirst().qty()).isEqualByComparingTo("10");
        assertThat(qty(result, secondLine)).isEqualByComparingTo("100");
    }

    @Test
    void exactAndPublicTakenFromTheSameWarehouseBecomeOneSlice() {
        UUID a = UUID.randomUUID();
        // 专属 3 + 公共 5 都在同一仓: 只出一段 8, 不拆成两段。
        var task = task("8", null, line(a, "1", "8", "0", stock(WAREHOUSE, "3", "5")));

        var result = SubcontractDrawAllocator.allocate(List.of(task));

        assertThat(result.slices()).hasSize(1);
        assertThat(result.slices().getFirst().qty()).isEqualByComparingTo("8");
        assertThat(result.slices().getFirst().warehouseAvailableQty()).isEqualByComparingTo("8");
    }

    private static SubcontractDrawAllocator.Task task(String orderQty, String requested,
                                                      SubcontractDrawAllocator.Line... lines) {
        return new SubcontractDrawAllocator.Task(UUID.randomUUID(), UUID.randomUUID(), new BigDecimal(orderQty),
                requested == null ? null : new BigDecimal(requested), List.of(lines));
    }

    private static SubcontractDrawAllocator.Line line(UUID planItemId, String perUnit, String planned,
                                                      String covered, SubcontractDrawAllocator.Stock... stocks) {
        return new SubcontractDrawAllocator.Line(planItemId, UUID.randomUUID(), null, new BigDecimal(perUnit),
                new BigDecimal(planned), new BigDecimal(covered), List.of(stocks));
    }

    private static SubcontractDrawAllocator.Stock stock(UUID warehouse, String exact, String publicQty) {
        return new SubcontractDrawAllocator.Stock(warehouse, warehouse.toString(), "仓", new BigDecimal(exact),
                new BigDecimal(publicQty));
    }

    private static BigDecimal qty(SubcontractDrawAllocator.Result result, UUID planItemId) {
        return result.slices().stream().filter(slice -> slice.planItemId().equals(planItemId))
                .map(SubcontractDrawAllocator.Slice::qty).reduce(BigDecimal.ZERO, BigDecimal::add);
    }
}
