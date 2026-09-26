package com.uten.imp.features.production.analysis;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;

import java.math.BigDecimal;
import java.math.BigInteger;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashSet;
import java.util.List;
import java.util.Objects;
import java.util.UUID;

/** Allocates one material quantity to exact sources without floating-point or per-unit loops. */
public final class AggregateQuantityAllocator {
    private static final int SCALE = 4;
    private static final BigDecimal MAX_QUANTITY = new BigDecimal("99999999999999.9999");
    private static final Comparator<SourceCapacity> ORDER = Comparator
            .comparingInt(SourceCapacity::allocationPriority)
            .thenComparing(SourceCapacity::needDate, Comparator.nullsLast(Comparator.naturalOrder()))
            // PostgreSQL UUID order is unsigned byte order, unlike UUID.compareTo.
            .thenComparing(source -> source.sourceId().toString());

    private AggregateQuantityAllocator() { }

    public record SourceCapacity(UUID sourceId, int allocationPriority, LocalDate needDate,
                                 BigDecimal remainingQty) { }
    public record Allocation(UUID sourceId, BigDecimal qty) { }
    public record Result(List<Allocation> allocations, BigDecimal publicExtraQty) {
        public Result { allocations = List.copyOf(allocations); }
    }

    /**
     * Earlier priority/date buckets are filled first. Within a bucket, distribute proportionally
     * to remaining demand and assign at most one residual tick per source in stable UUID order.
     * The caller supplies current source capacities after its authoritative coverage calculation.
     */
    public static Result allocate(BigDecimal totalQty, List<SourceCapacity> sources, boolean allowPublicExtra) {
        BigInteger requested = ticks(totalQty);
        if (sources == null) throw invalid("缺少汇总物料的来源明细");
        var ids = new HashSet<UUID>();
        List<SourceCapacity> ordered = new ArrayList<>(sources.size());
        BigInteger capacity = BigInteger.ZERO;
        for (SourceCapacity source : sources) {
            if (source == null || source.sourceId() == null || source.allocationPriority() < 0) {
                throw invalid("物料来源身份或分配优先级无效");
            }
            if (!ids.add(source.sourceId())) throw invalid("汇总物料包含重复来源，请刷新后重试");
            capacity = capacity.add(ticks(source.remainingQty()));
            ordered.add(source);
        }
        if (requested.signum() > 0 && ordered.isEmpty()) throw invalid("不能向没有来源的物料汇总行下单");
        BigInteger extra = requested.subtract(capacity).max(BigInteger.ZERO);
        if (extra.signum() > 0 && !allowPublicExtra) throw invalid("本次汇总数量超过来源待安排量，请核对超量办理权限与规则");
        ordered.sort(ORDER);
        BigInteger remaining = requested.min(capacity);
        List<Allocation> result = new ArrayList<>(ordered.size());
        for (int start = 0; start < ordered.size() && remaining.signum() > 0;) {
            int end = start + 1;
            SourceCapacity first = ordered.get(start);
            while (end < ordered.size() && sameBucket(first, ordered.get(end))) end++;
            BigInteger bucketCapacity = BigInteger.ZERO;
            for (int i = start; i < end; i++) bucketCapacity = bucketCapacity.add(ticks(ordered.get(i).remainingQty()));
            if (bucketCapacity.signum() > 0) {
                BigInteger amount = remaining.min(bucketCapacity);
                BigInteger allocated = BigInteger.ZERO;
                BigInteger[] quantities = new BigInteger[end - start];
                for (int i = start; i < end; i++) {
                    BigInteger sourceCapacity = ticks(ordered.get(i).remainingQty());
                    BigInteger share = amount.multiply(sourceCapacity).divide(bucketCapacity);
                    quantities[i - start] = share;
                    allocated = allocated.add(share);
                }
                // Sum of fractional remainders is strictly less than the number of sources.
                int remainder = amount.subtract(allocated).intValueExact();
                for (int i = start; i < end && remainder > 0; i++) {
                    int index = i - start;
                    if (quantities[index].compareTo(ticks(ordered.get(i).remainingQty())) < 0) {
                        quantities[index] = quantities[index].add(BigInteger.ONE);
                        remainder--;
                    }
                }
                if (remainder != 0) throw new IllegalStateException("Aggregate quantity conservation failed");
                for (int i = start; i < end; i++) {
                    if (quantities[i - start].signum() > 0) {
                        result.add(new Allocation(ordered.get(i).sourceId(), quantity(quantities[i - start])));
                    }
                }
                remaining = remaining.subtract(amount);
            }
            start = end;
        }
        return new Result(result, quantity(extra));
    }

    private static boolean sameBucket(SourceCapacity left, SourceCapacity right) {
        return left.allocationPriority() == right.allocationPriority() && Objects.equals(left.needDate(), right.needDate());
    }

    private static BigInteger ticks(BigDecimal value) {
        if (value == null || value.signum() < 0 || value.compareTo(MAX_QUANTITY) > 0
                || value.stripTrailingZeros().scale() > SCALE) {
            throw invalid("汇总数量和来源待安排量必须为非负数，最多 14 位整数及 4 位小数");
        }
        return value.setScale(SCALE).unscaledValue();
    }

    private static BigDecimal quantity(BigInteger ticks) { return new BigDecimal(ticks, SCALE); }
    private static ApiException invalid(String message) { return new ApiException(ErrorCode.VALIDATION_FAILED, message); }
}
