package com.uten.imp.features.production.mrp;

import com.uten.imp.features.production.fulfillment.PlanningPackageFingerprint;
import com.uten.imp.features.production.fulfillment.ProductionExecutionSegment;
import com.uten.imp.features.production.fulfillment.ProductionMaterialDemand;

import java.math.BigDecimal;
import java.math.BigInteger;
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
     * caller against the authoritative plan snapshot. WAITING remains
     * auto-promotable unless the caller carries the separate, explicit user
     * defer intent; status text alone is not treated as that intent.
     */
    public Allocation allocateRequested(
            List<RequestedSegment> rawSegments,
            Map<MaterialKey, BigDecimal> rawAvailable) {
        if (rawSegments == null || rawSegments.isEmpty()) {
            throw new IllegalArgumentException("执行分段不能为空");
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
            if (mustBeReady) {
                if (!canFullyTake(
                        request.line(), request.plannedQty(), remaining)) {
                    throw new InsufficientKitException(
                            request.clientSegmentKey());
                }
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
                            virtualRemaining),
                    !request.deferUntilManualRelease()));
        }
        return new Allocation(List.copyOf(result), Map.copyOf(remaining));
    }

    private static BigDecimal maxReadyQty(
            ProductLine line,
            Map<MaterialKey, BigDecimal> remaining) {
        if (line.requiresExactSnapshot()) {
            return maxExactReadyQty(line, remaining);
        }
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

    private static BigDecimal maxExactReadyQty(
            ProductLine line,
            Map<MaterialKey, BigDecimal> remaining) {
        BigInteger low = BigInteger.ZERO;
        BigInteger high = line.plannedQty()
                .movePointRight(PRODUCT_SCALE)
                .toBigIntegerExact();
        while (low.compareTo(high) < 0) {
            BigInteger middle = low.add(high)
                    .add(BigInteger.ONE)
                    .shiftRight(1);
            BigDecimal qty = new BigDecimal(middle, PRODUCT_SCALE);
            if (canFullyTake(line, qty, remaining)) {
                low = middle;
            } else {
                high = middle.subtract(BigInteger.ONE);
            }
        }
        return new BigDecimal(low, PRODUCT_SCALE);
    }

    private static boolean canFullyTake(
            ProductLine line,
            BigDecimal qty,
            Map<MaterialKey, BigDecimal> remaining) {
        return line.materials().stream().allMatch(usage ->
                usage.required(qty, line.productUnitRate()).compareTo(
                        remaining.getOrDefault(
                                usage.materialKey(), BigDecimal.ZERO)) <= 0);
    }

    private static List<MaterialAllocation> takeFullMaterials(
            ProductLine line,
            BigDecimal segmentQty,
            Map<MaterialKey, BigDecimal> remaining) {
        List<MaterialAllocation> result = new ArrayList<>(line.materials().size());
        for (MaterialUsage usage : line.materials()) {
            BigDecimal required = usage.required(
                    segmentQty, line.productUnitRate());
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
                    displayPerProductQty(usage, required, segmentQty),
                    required,
                    before,
                    required,
                    BigDecimal.ZERO.setScale(MATERIAL_SCALE),
                    usage.supplyRoute(),
                    requirementMode(usage)));
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
            BigDecimal required = usage.required(
                    segmentQty, line.productUnitRate());
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
                    displayPerProductQty(usage, required, segmentQty),
                    required,
                    before,
                    BigDecimal.ZERO.setScale(MATERIAL_SCALE),
                    required.subtract(virtuallyCovered)
                            .max(BigDecimal.ZERO),
                    usage.supplyRoute(),
                    requirementMode(usage)));
        }
        return List.copyOf(result);
    }

    private static BigDecimal displayPerProductQty(
            MaterialUsage usage,
            BigDecimal requiredQty,
            BigDecimal segmentQty) {
        if (!usage.requiresExactSnapshot()) {
            return usage.perProductQty();
        }
        // This is a display projection only. requiredQty remains the frozen,
        // authoritative exact requirement for the segment.
        return requiredQty.divide(
                segmentQty, USAGE_SCALE, RoundingMode.CEILING);
    }

    private static String requirementMode(MaterialUsage usage) {
        return usage.requiresExactSnapshot()
                ? ProductionMaterialDemand.REQUIREMENT_MODE_EXACT_SNAPSHOT
                : ProductionMaterialDemand.REQUIREMENT_MODE_LINEAR;
    }

    public static BigDecimal required(
            BigDecimal productQty,
            BigDecimal perProductQty) {
        return productQty.multiply(perProductQty)
                .setScale(MATERIAL_SCALE, RoundingMode.CEILING);
    }

    private static String decimalText(BigDecimal value) {
        return value == null
                ? "0"
                : value.stripTrailingZeros().toPlainString();
    }

    private static List<ProductLine> normalizeLines(List<ProductLine> rawLines) {
        if (rawLines == null || rawLines.isEmpty()) {
            throw new IllegalArgumentException("产品行不能为空");
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
                || line.materials() == null) {
            throw new IllegalArgumentException("产品行数据无效");
        }
        List<MaterialUsage> materials = line.materials().stream()
                .map(CompleteKitAllocator::normalizeUsage)
                .sorted(Comparator.comparing(MaterialUsage::materialKey))
                .toList();
        if (materials.stream().map(MaterialUsage::materialKey).distinct().count()
                != materials.size()) {
            throw new IllegalArgumentException("存在重复的物料维度");
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
                line.bomFingerprint(),
                line.zeroMaterialReason(),
                line.zeroMaterialAnalysisId(),
                line.zeroMaterialExceptionReason(),
                line.zeroMaterialAuthorizedBy());
    }

    private static MaterialUsage normalizeUsage(MaterialUsage usage) {
        if (usage == null
                || usage.goodsId() == null
                || usage.unitId() == null
                || usage.perProductQty() == null
                || usage.perProductQty().signum() <= 0
                || usage.supplyRoute() == null
                || usage.supplyRoute().isBlank()
                || usage.consumptionRules() == null) {
            throw new IllegalArgumentException("物料用量数据无效");
        }
        return new MaterialUsage(
                usage.goodsId(),
                usage.colorId(),
                usage.unitId(),
                usage.perProductQty().setScale(
                        USAGE_SCALE, RoundingMode.CEILING),
                usage.supplyRoute(),
                usage.consumptionRules().stream()
                        .map(CompleteKitAllocator::normalizeRule)
                        .toList());
    }

    private static ConsumptionRule normalizeRule(ConsumptionRule rule) {
        if (rule == null
                || !ConsumptionRule.SUPPORTED_BASES.contains(
                        rule.consumptionBasis())
                || rule.bomQty() == null
                || rule.bomQty().signum() <= 0
                || rule.basisOutputQty() == null
                || rule.basisOutputQty().signum() <= 0) {
            throw new IllegalArgumentException("物料消耗规则无效");
        }
        return new ConsumptionRule(
                rule.consumptionBasis(),
                rule.bomQty().setScale(USAGE_SCALE, RoundingMode.CEILING),
                rule.basisOutputQty().setScale(
                        USAGE_SCALE, RoundingMode.CEILING),
                rule.allowPartialPackage());
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
                        .contains(value.requestedStatus())
                || (value.deferUntilManualRelease()
                    && !ProductionExecutionSegment.STATUS_WAITING.equals(
                            value.requestedStatus()))) {
            throw new IllegalArgumentException("请求的执行分段无效");
        }
        return new RequestedSegment(
                value.clientSegmentKey().strip(),
                normalizeLine(value.line()),
                value.requestedStatus(),
                value.plannedQty().setScale(PRODUCT_SCALE, RoundingMode.UNNECESSARY),
                value.deferUntilManualRelease());
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
                        throw new IllegalArgumentException("可用库存数据无效");
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
            String bomFingerprint,
            String zeroMaterialReason,
            UUID zeroMaterialAnalysisId,
            String zeroMaterialExceptionReason,
            UUID zeroMaterialAuthorizedBy) {

        public ProductLine(
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
            this(
                    sourcePlanItemId,
                    lineNo,
                    productGoodsId,
                    productColorId,
                    productUnitId,
                    productUnitRate,
                    plannedQty,
                    planBeginDate,
                    planEndDate,
                    defaultWorkshopDepartmentId,
                    defaultTeamDepartmentId,
                    defaultResponsibleEmployeeId,
                    productCode,
                    productName,
                    priority,
                    materials,
                    bomFingerprint,
                    null,
                    null,
                    null,
                    null);
        }

        public ProductLine(
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
                String bomFingerprint,
                String zeroMaterialReason) {
            this(
                    sourcePlanItemId,
                    lineNo,
                    productGoodsId,
                    productColorId,
                    productUnitId,
                    productUnitRate,
                    plannedQty,
                    planBeginDate,
                    planEndDate,
                    defaultWorkshopDepartmentId,
                    defaultTeamDepartmentId,
                    defaultResponsibleEmployeeId,
                    productCode,
                    productName,
                    priority,
                    materials,
                    bomFingerprint,
                    zeroMaterialReason,
                    null,
                    null,
                    null);
        }

        boolean requiresExactSnapshot() {
            return materials.stream().anyMatch(
                    MaterialUsage::requiresExactSnapshot);
        }
    }

    public record MaterialUsage(
            UUID goodsId,
            UUID colorId,
            UUID unitId,
            BigDecimal perProductQty,
            String supplyRoute,
            List<ConsumptionRule> consumptionRules) {

        public MaterialUsage(
                UUID goodsId,
                UUID colorId,
                UUID unitId,
                BigDecimal perProductQty,
                String supplyRoute) {
            this(
                    goodsId, colorId, unitId, perProductQty,
                    supplyRoute, List.of());
        }

        MaterialKey materialKey() {
            return new MaterialKey(goodsId, colorId);
        }

        boolean requiresExactSnapshot() {
            return consumptionRules.stream().anyMatch(rule ->
                    !ConsumptionRule.PER_UNIT.equals(
                            rule.consumptionBasis()));
        }

        BigDecimal required(
                BigDecimal productQty,
                BigDecimal productUnitRate) {
            if (!requiresExactSnapshot()) {
                return CompleteKitAllocator.required(
                        productQty, perProductQty);
            }
            BigDecimal parentOutputQty = productQty.multiply(productUnitRate);
            BigDecimal total = BigDecimal.ZERO.setScale(MATERIAL_SCALE);
            for (ConsumptionRule rule : consumptionRules) {
                total = total.add(rule.required(parentOutputQty));
            }
            return total.setScale(MATERIAL_SCALE, RoundingMode.UNNECESSARY);
        }

        String requirementFingerprint(BigDecimal productUnitRate) {
            if (!requiresExactSnapshot()) {
                throw new IllegalStateException(
                        "线性需求不需要精确快照指纹");
            }
            List<String> parts = new ArrayList<>();
            parts.add("EXACT-MATERIAL-REQUIREMENT-V1");
            parts.add("MATERIAL|" + goodsId + "|"
                    + Objects.toString(colorId, "") + "|" + unitId
                    + "|" + supplyRoute);
            parts.add("PRODUCT-UNIT-RATE|" + decimalText(productUnitRate));
            for (ConsumptionRule rule : consumptionRules) {
                parts.add(String.join("|",
                        "RULE",
                        rule.consumptionBasis(),
                        decimalText(rule.bomQty()),
                        decimalText(rule.basisOutputQty()),
                        Boolean.toString(rule.allowPartialPackage())));
            }
            return PlanningPackageFingerprint.sha256(parts);
        }
    }

    public record ConsumptionRule(
            String consumptionBasis,
            BigDecimal bomQty,
            BigDecimal basisOutputQty,
            boolean allowPartialPackage) {

        public static final String PER_UNIT = "PER_UNIT";
        public static final String PER_PACKAGE = "PER_PACKAGE";
        public static final String FIXED_BATCH = "FIXED_BATCH";
        private static final List<String> SUPPORTED_BASES = List.of(
                PER_UNIT, PER_PACKAGE, FIXED_BATCH);

        BigDecimal required(BigDecimal parentOutputQty) {
            BigDecimal raw = switch (consumptionBasis) {
                case PER_UNIT -> parentOutputQty.multiply(bomQty);
                case PER_PACKAGE -> allowPartialPackage
                        ? parentOutputQty.multiply(bomQty).divide(
                                basisOutputQty, 12, RoundingMode.CEILING)
                        : wholePackages(parentOutputQty).multiply(bomQty);
                case FIXED_BATCH ->
                        wholePackages(parentOutputQty).multiply(bomQty);
                default -> throw new IllegalStateException(
                        "不支持的物料消耗规则: " + consumptionBasis);
            };
            return raw.setScale(MATERIAL_SCALE, RoundingMode.CEILING);
        }

        private BigDecimal wholePackages(BigDecimal parentOutputQty) {
            return parentOutputQty.divide(
                    basisOutputQty, 0, RoundingMode.CEILING);
        }
    }

    public record RequestedSegment(
            String clientSegmentKey,
            ProductLine line,
            String requestedStatus,
            BigDecimal plannedQty,
            boolean deferUntilManualRelease) {

        public RequestedSegment(
                String clientSegmentKey,
                ProductLine line,
                String requestedStatus,
                BigDecimal plannedQty) {
            this(
                    clientSegmentKey,
                    line,
                    requestedStatus,
                    plannedQty,
                    false);
        }
    }

    public record SegmentAllocation(
            String clientSegmentKey,
            ProductLine line,
            String status,
            BigDecimal plannedQty,
            List<MaterialAllocation> materials,
            boolean autoPromoteWhenReady) {

        public SegmentAllocation(
                String clientSegmentKey,
                ProductLine line,
                String status,
                BigDecimal plannedQty,
                List<MaterialAllocation> materials) {
            this(
                    clientSegmentKey,
                    line,
                    status,
                    plannedQty,
                    materials,
                    true);
        }
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
            String supplyRoute,
            String requirementMode) {

        public MaterialAllocation(
                UUID goodsId,
                UUID colorId,
                UUID unitId,
                BigDecimal perProductQty,
                BigDecimal requiredQty,
                BigDecimal availableBeforeQty,
                BigDecimal candidateAllocatedQty,
                BigDecimal shortageQty,
                String supplyRoute) {
            this(
                    goodsId,
                    colorId,
                    unitId,
                    perProductQty,
                    requiredQty,
                    availableBeforeQty,
                    candidateAllocatedQty,
                    shortageQty,
                    supplyRoute,
                    ProductionMaterialDemand.REQUIREMENT_MODE_LINEAR);
        }
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
