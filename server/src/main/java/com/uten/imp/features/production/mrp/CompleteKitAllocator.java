package com.uten.imp.features.production.mrp;

import com.uten.imp.features.production.fulfillment.ProductionExecutionSegment;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;

/**
 * Deterministic complete-kit splitter.
 *
 * <p>READY quantities are physically allocated for every product line first.
 * WAITING quantities hold zero physical material. A separate virtual
 * availability ledger nets their purchase shortages in stable priority order,
 * so the same unreserved stock is not counted for several waiting segments.
 * All material quantities are base-unit quantities.
 */
public final class CompleteKitAllocator {

    public static final int PRODUCT_SCALE = 4;
    public static final int MATERIAL_SCALE = 4;
    public static final int USAGE_SCALE = 6;

    private static final BigDecimal PRODUCT_STEP =
            BigDecimal.ONE.movePointLeft(PRODUCT_SCALE);

    public Allocation allocate(
            List<ProductLine> rawLines,
            Map<MaterialKey, BigDecimal> rawAvailable) {
        List<ProductLine> lines = normalizeLines(rawLines);
        Map<MaterialKey, BigDecimal> remaining = normalizeAvailable(rawAvailable);
        List<SegmentAllocation> ready = new ArrayList<>();
        List<PendingLine> waiting = new ArrayList<>();

        for (ProductLine line : lines) {
            BigDecimal readyQty = maxReadyQty(line, remaining);
            if (readyQty.signum() > 0) {
                List<MaterialAllocation> materials =
                        takeFullMaterials(line, readyQty, remaining);
                ready.add(new SegmentAllocation(
                        line.sourcePlanItemId() + ":READY",
                        line,
                        ProductionExecutionSegment.STATUS_READY,
                        readyQty,
                        materials));
            }
            BigDecimal residual = line.plannedQty().subtract(readyQty);
            if (residual.signum() > 0) {
                waiting.add(new PendingLine(line, residual));
            }
        }

        List<SegmentAllocation> result = new ArrayList<>(ready);
        Map<MaterialKey, BigDecimal> virtualRemaining =
                new LinkedHashMap<>(remaining);
        for (PendingLine pending : waiting) {
            ProductLine line = pending.line();
            result.add(new SegmentAllocation(
                    line.sourcePlanItemId() + ":WAITING",
                    line,
                    ProductionExecutionSegment.STATUS_WAITING,
                    pending.qty(),
                    netWaitingMaterials(
                            line, pending.qty(), virtualRemaining)));
        }
        return new Allocation(List.copyOf(result), Map.copyOf(remaining));
    }

    /**
     * Applies user-edited segment quantities. READY requests are processed
     * before WAITING requests; exact source-line totals are validated by the
     * caller against the authoritative plan snapshot.
     */
    public Allocation allocateRequested(
            List<RequestedSegment> rawSegments,
            Map<MaterialKey, BigDecimal> rawAvailable) {
        if (rawSegments == null || rawSegments.isEmpty()) {
            throw new IllegalArgumentException("segments are required");
        }
        List<RequestedSegment> segments = rawSegments.stream()
                .map(CompleteKitAllocator::normalizeRequested)
                .sorted(Comparator
                        .comparingInt((RequestedSegment value) ->
                                ProductionExecutionSegment.STATUS_READY.equals(
                                        value.requestedStatus()) ? 0 : 1)
                        .thenComparing(value -> value.line().priority())
                        .thenComparing(RequestedSegment::clientSegmentKey))
                .toList();
        Map<MaterialKey, BigDecimal> remaining = normalizeAvailable(rawAvailable);
        List<SegmentAllocation> ready = new ArrayList<>(segments.size());
        List<PendingRequest> waiting = new ArrayList<>();
        for (RequestedSegment request : segments) {
            boolean mustBeReady = ProductionExecutionSegment.STATUS_READY.equals(
                    request.requestedStatus());
            boolean canBeReady = canFullyTake(
                    request.line(), request.plannedQty(), remaining);
            if (mustBeReady && !canBeReady) {
                throw new InsufficientKitException(request.clientSegmentKey());
            }
            if (mustBeReady || canBeReady) {
                ready.add(new SegmentAllocation(
                        request.clientSegmentKey(),
                        request.line(),
                        ProductionExecutionSegment.STATUS_READY,
                        request.plannedQty(),
                        takeFullMaterials(
                                request.line(),
                                request.plannedQty(),
                                remaining)));
            } else {
                waiting.add(new PendingRequest(request));
            }
        }
        List<SegmentAllocation> result = new ArrayList<>(ready);
        Map<MaterialKey, BigDecimal> virtualRemaining =
                new LinkedHashMap<>(remaining);
        for (PendingRequest pending : waiting) {
            RequestedSegment request = pending.request();
            result.add(new SegmentAllocation(
                    request.clientSegmentKey(),
                    request.line(),
                    ProductionExecutionSegment.STATUS_WAITING,
                    request.plannedQty(),
                    netWaitingMaterials(
                            request.line(),
                            request.plannedQty(),
                            virtualRemaining)));
        }
        return new Allocation(List.copyOf(result), Map.copyOf(remaining));
    }

    private static BigDecimal maxReadyQty(
            ProductLine line,
            Map<MaterialKey, BigDecimal> remaining) {
        BigDecimal maximum = line.plannedQty();
        for (MaterialUsage usage : line.materials()) {
            BigDecimal available = remaining.getOrDefault(
                    usage.materialKey(), BigDecimal.ZERO);
            BigDecimal supported = available.divide(
                    usage.perProductQty(), PRODUCT_SCALE, RoundingMode.DOWN);
            maximum = maximum.min(supported);
        }
        maximum = maximum.max(BigDecimal.ZERO).setScale(
                PRODUCT_SCALE, RoundingMode.DOWN);
        while (maximum.signum() > 0
                && !canFullyTake(line, maximum, remaining)) {
            maximum = maximum.subtract(PRODUCT_STEP);
        }
        return maximum.max(BigDecimal.ZERO);
    }

    private static boolean canFullyTake(
            ProductLine line,
            BigDecimal qty,
            Map<MaterialKey, BigDecimal> remaining) {
        return line.materials().stream().allMatch(usage ->
                required(qty, usage.perProductQty()).compareTo(
                        remaining.getOrDefault(
                                usage.materialKey(), BigDecimal.ZERO)) <= 0);
    }

    private static List<MaterialAllocation> takeFullMaterials(
            ProductLine line,
            BigDecimal segmentQty,
            Map<MaterialKey, BigDecimal> remaining) {
        List<MaterialAllocation> result = new ArrayList<>(line.materials().size());
        for (MaterialUsage usage : line.materials()) {
            BigDecimal required = required(segmentQty, usage.perProductQty());
            BigDecimal before = remaining.getOrDefault(
                    usage.materialKey(), BigDecimal.ZERO);
            if (before.compareTo(required) < 0) {
                throw new InsufficientKitException(
                        line.sourcePlanItemId().toString());
            }
            remaining.put(
                    usage.materialKey(),
                    before.subtract(required).max(BigDecimal.ZERO));
            result.add(new MaterialAllocation(
                    usage.goodsId(),
                    usage.colorId(),
                    usage.unitId(),
                    usage.perProductQty(),
                    required,
                    before,
                    required,
                    BigDecimal.ZERO.setScale(MATERIAL_SCALE),
                    usage.supplyRoute()));
        }
        return List.copyOf(result);
    }

    private static List<MaterialAllocation> netWaitingMaterials(
            ProductLine line,
            BigDecimal segmentQty,
            Map<MaterialKey, BigDecimal> virtualRemaining) {
        List<MaterialAllocation> result =
                new ArrayList<>(line.materials().size());
        for (MaterialUsage usage : line.materials()) {
            BigDecimal required = required(
                    segmentQty, usage.perProductQty());
            BigDecimal before = virtualRemaining.getOrDefault(
                    usage.materialKey(), BigDecimal.ZERO);
            BigDecimal virtuallyCovered = required.min(before);
            virtualRemaining.put(
                    usage.materialKey(),
                    before.subtract(virtuallyCovered).max(BigDecimal.ZERO));
            result.add(new MaterialAllocation(
                    usage.goodsId(),
                    usage.colorId(),
                    usage.unitId(),
                    usage.perProductQty(),
                    required,
                    before,
                    BigDecimal.ZERO.setScale(MATERIAL_SCALE),
                    required.subtract(virtuallyCovered)
                            .max(BigDecimal.ZERO),
                    usage.supplyRoute()));
        }
        return List.copyOf(result);
    }

    public static BigDecimal required(
            BigDecimal productQty,
            BigDecimal perProductQty) {
        return productQty.multiply(perProductQty)
                .setScale(MATERIAL_SCALE, RoundingMode.CEILING);
    }

    private static List<ProductLine> normalizeLines(List<ProductLine> rawLines) {
        if (rawLines == null || rawLines.isEmpty()) {
            throw new IllegalArgumentException("product lines are required");
        }
        return rawLines.stream()
                .map(CompleteKitAllocator::normalizeLine)
                .sorted(Comparator
                        .comparing(ProductLine::priority)
                        .thenComparing(line -> line.sourcePlanItemId().toString()))
                .toList();
    }

    private static ProductLine normalizeLine(ProductLine line) {
        if (line == null
                || line.sourcePlanItemId() == null
                || line.productGoodsId() == null
                || line.productUnitId() == null
                || line.productUnitRate() == null
                || line.productUnitRate().signum() <= 0
                || line.plannedQty() == null
                || line.plannedQty().signum() <= 0
                || line.materials() == null
                || line.materials().isEmpty()) {
            throw new IllegalArgumentException("invalid product line");
        }
        List<MaterialUsage> materials = line.materials().stream()
                .map(CompleteKitAllocator::normalizeUsage)
                .sorted(Comparator.comparing(MaterialUsage::materialKey))
                .toList();
        if (materials.stream().map(MaterialUsage::materialKey).distinct().count()
                != materials.size()) {
            throw new IllegalArgumentException("duplicate material dimension");
        }
        return new ProductLine(
                line.sourcePlanItemId(),
                line.lineNo(),
                line.productGoodsId(),
                line.productColorId(),
                line.productUnitId(),
                line.productUnitRate().setScale(USAGE_SCALE, RoundingMode.UNNECESSARY),
                line.plannedQty().setScale(PRODUCT_SCALE, RoundingMode.UNNECESSARY),
                line.planBeginDate(),
                line.planEndDate(),
                line.defaultWorkshopDepartmentId(),
                line.defaultTeamDepartmentId(),
                line.defaultResponsibleEmployeeId(),
                line.productCode(),
                line.productName(),
                line.priority(),
                materials,
                line.bomFingerprint());
    }

    private static MaterialUsage normalizeUsage(MaterialUsage usage) {
        if (usage == null
                || usage.goodsId() == null
                || usage.unitId() == null
                || usage.perProductQty() == null
                || usage.perProductQty().signum() <= 0
                || usage.supplyRoute() == null
                || usage.supplyRoute().isBlank()) {
            throw new IllegalArgumentException("invalid material usage");
        }
        return new MaterialUsage(
                usage.goodsId(),
                usage.colorId(),
                usage.unitId(),
                usage.perProductQty().setScale(
                        USAGE_SCALE, RoundingMode.CEILING),
                usage.supplyRoute());
    }

    private static RequestedSegment normalizeRequested(RequestedSegment value) {
        if (value == null
                || value.clientSegmentKey() == null
                || value.clientSegmentKey().isBlank()
                || value.clientSegmentKey().strip().length() > 128
                || value.plannedQty() == null
                || value.plannedQty().signum() <= 0
                || !List.of(
                                ProductionExecutionSegment.STATUS_READY,
                                ProductionExecutionSegment.STATUS_WAITING)
                        .contains(value.requestedStatus())) {
            throw new IllegalArgumentException("invalid requested segment");
        }
        return new RequestedSegment(
                value.clientSegmentKey().strip(),
                normalizeLine(value.line()),
                value.requestedStatus(),
                value.plannedQty().setScale(PRODUCT_SCALE, RoundingMode.UNNECESSARY));
    }

    private static Map<MaterialKey, BigDecimal> normalizeAvailable(
            Map<MaterialKey, BigDecimal> raw) {
        Map<MaterialKey, BigDecimal> result = new LinkedHashMap<>();
        if (raw == null) {
            return result;
        }
        raw.entrySet().stream()
                .sorted(Map.Entry.comparingByKey())
                .forEach(entry -> {
                    if (entry.getKey() == null
                            || entry.getValue() == null
                            || entry.getValue().signum() < 0) {
                        throw new IllegalArgumentException("invalid availability");
                    }
                    result.put(
                            entry.getKey(),
                            entry.getValue().setScale(
                                    MATERIAL_SCALE, RoundingMode.DOWN));
                });
        return result;
    }

    public record ProductLine(
            UUID sourcePlanItemId,
            Integer lineNo,
            UUID productGoodsId,
            UUID productColorId,
            UUID productUnitId,
            BigDecimal productUnitRate,
            BigDecimal plannedQty,
            LocalDate planBeginDate,
            LocalDate planEndDate,
            UUID defaultWorkshopDepartmentId,
            UUID defaultTeamDepartmentId,
            UUID defaultResponsibleEmployeeId,
            String productCode,
            String productName,
            Priority priority,
            List<MaterialUsage> materials,
            String bomFingerprint) {
    }

    public record MaterialUsage(
            UUID goodsId,
            UUID colorId,
            UUID unitId,
            BigDecimal perProductQty,
            String supplyRoute) {

        MaterialKey materialKey() {
            return new MaterialKey(goodsId, colorId);
        }
    }

    public record RequestedSegment(
            String clientSegmentKey,
            ProductLine line,
            String requestedStatus,
            BigDecimal plannedQty) {
    }

    public record SegmentAllocation(
            String clientSegmentKey,
            ProductLine line,
            String status,
            BigDecimal plannedQty,
            List<MaterialAllocation> materials) {
    }

    public record MaterialAllocation(
            UUID goodsId,
            UUID colorId,
            UUID unitId,
            BigDecimal perProductQty,
            BigDecimal requiredQty,
            BigDecimal availableBeforeQty,
            BigDecimal candidateAllocatedQty,
            BigDecimal shortageQty,
            String supplyRoute) {
    }

    public record Allocation(
            List<SegmentAllocation> segments,
            Map<MaterialKey, BigDecimal> remainingAvailability) {
    }

    public record MaterialKey(UUID goodsId, UUID colorId)
            implements Comparable<MaterialKey> {

        public MaterialKey {
            Objects.requireNonNull(goodsId, "goodsId");
        }

        @Override
        public int compareTo(MaterialKey other) {
            int byGoods = goodsId.toString().compareTo(other.goodsId.toString());
            if (byGoods != 0) {
                return byGoods;
            }
            return Objects.toString(colorId, "")
                    .compareTo(Objects.toString(other.colorId, ""));
        }
    }

    public record Priority(LocalDate beginDate, int lineNo, UUID stableId)
            implements Comparable<Priority> {

        public Priority {
            Objects.requireNonNull(stableId, "stableId");
        }

        @Override
        public int compareTo(Priority other) {
            LocalDate leftDate = beginDate == null ? LocalDate.MAX : beginDate;
            LocalDate rightDate =
                    other.beginDate == null ? LocalDate.MAX : other.beginDate;
            int byDate = leftDate.compareTo(rightDate);
            if (byDate != 0) return byDate;
            int byLine = Integer.compare(lineNo, other.lineNo);
            if (byLine != 0) return byLine;
            return stableId.toString().compareTo(other.stableId.toString());
        }
    }

    public static final class InsufficientKitException
            extends IllegalArgumentException {
        public InsufficientKitException(String segmentKey) {
            super("READY segment is not fully stock-backed: " + segmentKey);
        }
    }

    private record PendingLine(ProductLine line, BigDecimal qty) {
    }

    private record PendingRequest(RequestedSegment request) {
    }
}
