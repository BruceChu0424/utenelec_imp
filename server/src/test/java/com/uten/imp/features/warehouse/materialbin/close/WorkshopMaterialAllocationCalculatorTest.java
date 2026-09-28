package com.uten.imp.features.warehouse.materialbin.close;

import com.uten.imp.common.finance.MoneyPolicy;
import com.uten.imp.features.warehouse.materialbin.close.WorkshopMaterialAllocationCalculator.Basis;
import com.uten.imp.features.warehouse.materialbin.close.WorkshopMaterialAllocationCalculator.Share;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.List;
import java.util.Random;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * ADR-131 §5.8 按成本范围理论比例分摊 (包 S3, 纯单测): 每行按 MoneyPolicy.quantityShare 取 4 位,
 * 理论最大的一行 (并列取成本范围 id 最小) 承担尾差, 合计恒等于实际用量, 任何一行都不为负。
 */
class WorkshopMaterialAllocationCalculatorTest {

    private static final UUID A = UUID.fromString("00000000-0000-4000-8000-00000000000a");
    private static final UUID B = UUID.fromString("00000000-0000-4000-8000-00000000000b");
    private static final UUID C = UUID.fromString("00000000-0000-4000-8000-00000000000c");

    @Test
    void sharesFollowTheoryRatioAndTheLargestTheoryCarriesTheTail() {
        // 两个产品共用一种料: 理论 30 与 70, 实际 10.0001 → 3.0000 / 7.0001 (尾差给理论大的那一行)
        List<Share> shares = WorkshopMaterialAllocationCalculator.allocate(new BigDecimal("10.0001"), List.of(
                new Basis(A, new BigDecimal("30")), new Basis(B, new BigDecimal("70"))));
        assertEquals(2, shares.size());
        Share a = shares.get(0);
        Share b = shares.get(1);
        assertEquals(A, a.costScopeSegmentId());
        assertFalse(a.tail());
        assertEquals(0, a.allocatedQty().compareTo(MoneyPolicy.quantityShare(new BigDecimal("10.0001"),
                new BigDecimal("30"), new BigDecimal("100"))));
        assertEquals(0, new BigDecimal("3.0000").compareTo(a.allocatedQty()));
        assertTrue(b.tail());
        assertEquals(0, new BigDecimal("7.0001").compareTo(b.allocatedQty()));
        assertEquals(0, new BigDecimal("10.0001").compareTo(a.allocatedQty().add(b.allocatedQty())));
    }

    @Test
    void equalTheoryTiesGoToTheSmallestScopeIdAndSumStaysExact() {
        List<Share> shares = WorkshopMaterialAllocationCalculator.allocate(new BigDecimal("10"), List.of(
                new Basis(C, new BigDecimal("1")), new Basis(B, new BigDecimal("1")), new Basis(A, new BigDecimal("1"))));
        assertEquals(List.of(A, B, C), shares.stream().map(Share::costScopeSegmentId).toList(), "按成本范围 id 排序");
        assertTrue(shares.get(0).tail(), "理论并列时成本范围 id 最小的一行承担尾差");
        assertEquals(1, shares.stream().filter(Share::tail).count());
        assertEquals(0, new BigDecimal("3.3334").compareTo(shares.get(0).allocatedQty()));
        assertEquals(0, new BigDecimal("3.3333").compareTo(shares.get(1).allocatedQty()));
        assertEquals(0, new BigDecimal("10").compareTo(total(shares)));
    }

    @Test
    void mergesRepeatedScopesAndIgnoresNonPositiveBases() {
        List<Share> shares = WorkshopMaterialAllocationCalculator.allocate(new BigDecimal("6"), List.of(
                new Basis(A, new BigDecimal("1")), new Basis(A, new BigDecimal("2")),
                new Basis(B, BigDecimal.ZERO), new Basis(C, new BigDecimal("-1"))));
        assertEquals(1, shares.size());
        assertEquals(A, shares.getFirst().costScopeSegmentId());
        assertEquals(0, new BigDecimal("3").compareTo(shares.getFirst().basisQty()));
        assertEquals(0, new BigDecimal("6").compareTo(shares.getFirst().allocatedQty()));
        assertTrue(shares.getFirst().tail());
        assertTrue(WorkshopMaterialAllocationCalculator.allocate(BigDecimal.ONE, List.of()).isEmpty(),
                "没有理论就没有可分的基数");
        assertThrows(IllegalArgumentException.class,
                () -> WorkshopMaterialAllocationCalculator.allocate(BigDecimal.ZERO, List.of(new Basis(A, BigDecimal.ONE))));
    }

    @Test
    void tinyQuantityOverManyScopesNeverLeavesANegativeTail() {
        // 0.0003 分给 5 个理论相同的成本范围: 其余四行各取 4 位是 0.0001, 合计 0.0004 超过实际, 须让出
        List<Basis> bases = new ArrayList<>();
        for (int index = 0; index < 5; index++) {
            bases.add(new Basis(UUID.fromString(String.format("00000000-0000-4000-8000-%012d", index + 1)),
                    BigDecimal.ONE));
        }
        List<Share> shares = WorkshopMaterialAllocationCalculator.allocate(new BigDecimal("0.0003"), bases);
        assertEquals(0, new BigDecimal("0.0003").compareTo(total(shares)));
        assertTrue(shares.stream().allMatch(share -> share.allocatedQty().signum() >= 0));
        assertEquals(1, shares.stream().filter(Share::tail).count());
    }

    @Test
    void randomSplitsAlwaysConserveTheConsumedQuantity() {
        Random random = new Random(20260928L);
        for (int round = 0; round < 500; round++) {
            BigDecimal consumed = BigDecimal.valueOf(1 + random.nextInt(2_000_000), 4);
            List<Basis> bases = new ArrayList<>();
            int count = 1 + random.nextInt(8);
            for (int index = 0; index < count; index++) {
                bases.add(new Basis(UUID.randomUUID(), BigDecimal.valueOf(1 + random.nextInt(900_000), 6)));
            }
            List<Share> shares = WorkshopMaterialAllocationCalculator.allocate(consumed, bases);
            assertEquals(0, consumed.compareTo(total(shares)), "合计恒等于实际用量");
            assertEquals(1, shares.stream().filter(Share::tail).count(), "恰好一行承担尾差");
            assertTrue(shares.stream().allMatch(share -> share.allocatedQty().signum() >= 0));
            assertTrue(shares.stream().allMatch(share -> share.allocatedQty().scale() <= 4),
                    "数量按 4 位存");
            Share tail = shares.stream().filter(Share::tail).findFirst().orElseThrow();
            assertTrue(shares.stream().allMatch(share -> share.basisQty().compareTo(tail.basisQty()) <= 0),
                    "尾差给理论最大的那一行");
        }
    }

    private static BigDecimal total(List<Share> shares) {
        return shares.stream().map(Share::allocatedQty).reduce(BigDecimal.ZERO, BigDecimal::add);
    }
}
