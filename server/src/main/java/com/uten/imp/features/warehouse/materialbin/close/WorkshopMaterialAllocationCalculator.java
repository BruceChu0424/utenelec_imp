package com.uten.imp.features.warehouse.materialbin.close;

import com.uten.imp.common.finance.MoneyPolicy;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/** Actual use allocated by exact proportions. The original largest basis row
 * (UUID ascending tie break) takes the exact remainder. No hidden tick correction;
 * a user choice that over-allocates fails without changing the original amount. */
public final class WorkshopMaterialAllocationCalculator {


    private WorkshopMaterialAllocationCalculator() {}

    /** 一个成本范围的分摊基数 (本期理论用量)。 */
    public record Basis(UUID costScopeSegmentId, BigDecimal basisQty) {}

    /** 分摊结果; tail 为承担尾差的那一行。 */
    public record Share(UUID costScopeSegmentId, BigDecimal basisQty, BigDecimal allocatedQty, boolean tail) {}

    /**
     * @param consumed 要分摊的实际用量 (大于 0，支持24位小数)
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
            throw new com.uten.imp.common.finance.BusinessPrecisionRequiredException("quantity.share",
                "本次车间用量分配：上次精度超出原用量，请明确重新选择",24,"PRECISION_LIMIT",true);
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
