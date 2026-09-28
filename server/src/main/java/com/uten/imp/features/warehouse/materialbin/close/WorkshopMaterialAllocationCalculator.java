package com.uten.imp.features.warehouse.materialbin.close;

import com.uten.imp.common.finance.MoneyPolicy;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * 一种料一期实际用量按成本范围分摊 (ADR-131 §5.8, 纯函数)。
 *
 * <p>每个成本范围 {@code allocated = MoneyPolicy.quantityShare(consumed, T_s, T)} (数量 4 位); 理论最大的一行
 * (并列取成本范围 id 最小, 按 id 文字比较, 与库里 uuid 排序一致) 承担尾差 = consumed - 其余之和, 所以合计恒等于
 * consumed。极小用量分给很多成本范围时, 其余各行按 4 位取整之和可能超过 consumed; 这时从理论最小的行起逐行
 * 让出 0.0001, 直到尾差行不为负。本类不自己写舍入, 数量取位一律经 {@link MoneyPolicy}。
 */
public final class WorkshopMaterialAllocationCalculator {

    private static final BigDecimal STEP = new BigDecimal("0.0001");

    private WorkshopMaterialAllocationCalculator() {}

    /** 一个成本范围的分摊基数 (本期理论用量)。 */
    public record Basis(UUID costScopeSegmentId, BigDecimal basisQty) {}

    /** 分摊结果; tail 为承担尾差的那一行。 */
    public record Share(UUID costScopeSegmentId, BigDecimal basisQty, BigDecimal allocatedQty, boolean tail) {}

    /**
     * @param consumed 要分摊的实际用量 (大于 0, 4 位)
     * @param bases    各成本范围的理论用量; 同一成本范围出现多次时合并, 不大于 0 的忽略
     * @return 每个理论大于 0 的成本范围一行, 按成本范围 id 排序; 没有可分的基数时为空
     */
    public static List<Share> allocate(BigDecimal consumed, List<Basis> bases) {
        if (consumed == null || consumed.signum() <= 0) {
            throw new IllegalArgumentException("consumed must be positive");
        }
        BigDecimal total = MoneyPolicy.quantity(consumed);
        Map<UUID, BigDecimal> merged = new LinkedHashMap<>();
        for (Basis basis : bases == null ? List.<Basis>of() : bases) {
            if (basis == null || basis.costScopeSegmentId() == null || basis.basisQty() == null) continue;
            if (basis.basisQty().signum() <= 0) continue;
            merged.merge(basis.costScopeSegmentId(), basis.basisQty(), BigDecimal::add);
        }
        if (merged.isEmpty()) return List.of();
        List<Map.Entry<UUID, BigDecimal>> rows = new ArrayList<>(merged.entrySet());
        rows.sort(Comparator.comparing(entry -> entry.getKey().toString()));
        BigDecimal whole = rows.stream().map(Map.Entry::getValue).reduce(BigDecimal.ZERO, BigDecimal::add);

        int tailIndex = 0;
        for (int index = 1; index < rows.size(); index++) {
            int compared = rows.get(index).getValue().compareTo(rows.get(tailIndex).getValue());
            if (compared > 0) tailIndex = index;
        }

        BigDecimal[] allocated = new BigDecimal[rows.size()];
        BigDecimal others = BigDecimal.ZERO;
        for (int index = 0; index < rows.size(); index++) {
            if (index == tailIndex) continue;
            allocated[index] = MoneyPolicy.quantityShare(total, rows.get(index).getValue(), whole);
            others = others.add(allocated[index]);
        }
        if (others.compareTo(total) > 0) {
            List<Integer> smallestFirst = new ArrayList<>();
            for (int index = 0; index < rows.size(); index++) if (index != tailIndex) smallestFirst.add(index);
            smallestFirst.sort(Comparator.<Integer, BigDecimal>comparing(index -> rows.get(index).getValue())
                    .thenComparing(index -> rows.get(index).getKey().toString()));
            while (others.compareTo(total) > 0) {
                boolean reduced = false;
                for (int index : smallestFirst) {
                    if (others.compareTo(total) <= 0) break;
                    if (allocated[index].compareTo(STEP) >= 0) {
                        allocated[index] = allocated[index].subtract(STEP);
                        others = others.subtract(STEP);
                        reduced = true;
                    }
                }
                if (!reduced) break;
            }
        }
        allocated[tailIndex] = total.subtract(others);

        List<Share> out = new ArrayList<>(rows.size());
        for (int index = 0; index < rows.size(); index++) {
            out.add(new Share(rows.get(index).getKey(), rows.get(index).getValue(), allocated[index],
                    index == tailIndex));
        }
        return out;
    }
}
