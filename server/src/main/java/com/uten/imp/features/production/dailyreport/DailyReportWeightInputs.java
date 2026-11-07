package com.uten.imp.features.production.dailyreport;

import com.uten.imp.common.finance.BusinessPrecisionRequiredException;
import com.uten.imp.common.measure.WeightUnit;
import com.uten.imp.common.production.ProductionOutputQuantity;
import com.uten.imp.common.util.FinancialExactAmount;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.production.dailyreport.dto.DailyReportItemLine;
import jakarta.persistence.EntityManager;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.util.ArrayList;
import java.util.Collection;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;

/** Goods-master basis and exact quantity adoption for production reporting. */
final class DailyReportWeightInputs {
    static final String MASTER_WEIGHT_JOINS = """
            LEFT JOIN units report_weight_unit ON report_weight_unit.id = g.m_weight_unit_id
                 AND NOT report_weight_unit.is_deleted AND report_weight_unit.status IS DISTINCT FROM '禁用'
            LEFT JOIN unit_measurement_profiles report_weight_profile ON report_weight_profile.unit_id = report_weight_unit.id
                 AND report_weight_profile.measurement_dimension = 'MASS'
            """;
    static final String QUANTITY_PURPOSE = "production.daily-report.weight-to-quantity";
    private static final BigDecimal WEIGHT_LIMIT = BigDecimal.ONE.scaleByPowerOfTen(14);

    private DailyReportWeightInputs() { }

    static BigDecimal kgPerBaseUnit(BigDecimal masterValue, String massUnitCode) {
        if (masterValue == null || masterValue.signum() <= 0) return null;
        return WeightUnit.tryParse(massUnitCode)
                .map(unit -> masterValue.multiply(unit.kgPerUnit()).stripTrailingZeros()).orElse(null);
    }

    static Map<UUID, BigDecimal> load(EntityManager em, Collection<UUID> goodsIds) {
        if (goodsIds.isEmpty()) return Map.of();
        var query = em.createNativeQuery("""
                SELECT g.id, g.m_weight, report_weight_profile.mass_unit_code
                FROM goods g
                """ + MASTER_WEIGHT_JOINS + """
                WHERE g.id IN (:ids) AND NOT g.is_deleted AND NOT g.auto_created
                  AND g.status IS DISTINCT FROM '禁用'
                ORDER BY g.id
                """).setParameter("ids", goodsIds);
        Map<UUID, BigDecimal> result = new LinkedHashMap<>();
        for (Object entry : query.getResultList()) {
            Object[] row = (Object[]) entry;
            result.put((UUID) row[0], kgPerBaseUnit((BigDecimal) row[1], (String) row[2]));
        }
        return result;
    }

    static boolean supplied(DailyReportItemLine line) {
        return line.getWeightEntryMode() != null || line.getUnitWeightKgExact() != null
                || line.getWeightQuantityScale() != null || line.getWeightQuantityRounding() != null
                || line.getWeightSourceReportItemId() != null;
    }

    /** Preserves one unchanged logical measurement from the current, CAS-checked draft. */
    static final class FrozenDraftInputs {
        private record InputKey(UUID supplement, UUID batch, UUID item) {
            static InputKey of(ProductionDailyReportItem item) {
                if (item.getSupplementProofId() != null) return new InputKey(item.getSupplementProofId(), null, null);
                if (item.getOutputBatchId() != null) return new InputKey(null, item.getOutputBatchId(), null);
                return new InputKey(null, null, item.getId());
            }
        }

        private final Map<UUID, InputKey> keyByItem = new LinkedHashMap<>();
        private final Map<InputKey, List<ProductionDailyReportItem>> itemsByKey = new LinkedHashMap<>();
        private final Set<InputKey> used = new HashSet<>();

        FrozenDraftInputs(List<ProductionDailyReportItem> previous) {
            for (ProductionDailyReportItem item : previous) {
                if (item.isDeleted()) continue;
                InputKey key = InputKey.of(item);
                keyByItem.put(item.getId(), key);
                itemsByKey.computeIfAbsent(key, ignored -> new ArrayList<>()).add(item);
            }
        }

        boolean contains(UUID itemId) {
            return keyByItem.containsKey(itemId);
        }

        boolean canReuse(DailyReportItemLine line) {
            UUID previousId = line.getWeightSourceReportItemId();
            if (previousId == null && line.getPlatformFields() != null) {
                previousId = line.getPlatformFields().sourceRecordId();
            }
            InputKey key = keyByItem.get(previousId);
            if (key == null || used.contains(key)) return false;
            List<ProductionDailyReportItem> pieces = itemsByKey.get(key);
            BigDecimal qty = BigDecimal.ZERO;
            BigDecimal kg = line.getWeight() == null ? null : BigDecimal.ZERO;
            boolean sameSource = false;
            for (ProductionDailyReportItem piece : pieces) {
                if (piece.getQty() == null || piece.getQty().signum() <= 0
                        || !Objects.equals(piece.getGoodsId(), line.getGoodsId())
                        || !Objects.equals(piece.getColorId(), line.getColorId())
                        || !Objects.equals(piece.getUnitId(), line.getUnitId())
                        || !sameDecimal(defaultRate(piece.getUnitRate()), defaultRate(line.getUnitRate()))
                        || !sameDecimal(piece.getUnitWeightKg(), line.getUnitWeightKgExact())
                        || !Objects.equals(piece.getWeightEntryMode(), line.getWeightEntryMode())
                        || !Objects.equals(piece.getWeightQuantityScale(), line.getWeightQuantityScale())
                        || !Objects.equals(piece.getWeightQuantityRounding(), line.getWeightQuantityRounding())
                        || (piece.getWeight() == null) != (kg == null)) return false;
                qty = qty.add(piece.getQty());
                if (kg != null) kg = kg.add(piece.getWeight());
                sameSource |= Objects.equals(piece.getPlanItemId(), line.getPlanItemId())
                        && Objects.equals(piece.getExecutionSegmentId(), line.getExecutionSegmentId())
                        && Objects.equals(piece.getExecutionSegmentSalesAllocationId(), line.getExecutionSegmentSalesAllocationId())
                        && Objects.equals(piece.getSalesOrderItemId(), line.getSalesOrderItemId())
                        && Objects.equals(piece.getFqcRecoveryAuthorizationId(), line.getFqcRecoveryAuthorizationId())
                        && Objects.equals(piece.getSupplementProofId(), line.getSupplementProofId());
            }
            if (key.batch() != null && pieces.stream().anyMatch(piece -> !sameDecimal(piece.getOutputBatchQty(), line.getQty()))) {
                return false;
            }
            return sameSource && sameDecimal(qty, line.getQty()) && sameDecimal(kg, line.getWeight()) && used.add(key);
        }
    }

    static boolean sameDecimal(BigDecimal left, BigDecimal right) {
        return left == null || right == null ? left == right : left.compareTo(right) == 0;
    }

    private static BigDecimal defaultRate(BigDecimal rate) {
        return rate == null ? BigDecimal.ONE : rate;
    }

    static void validate(DailyReportItemLine line, BigDecimal masterKgPerBaseUnit) {
        if (!supplied(line)) return;
        String mode = line.getWeightEntryMode();
        BigDecimal expected = line.getUnitWeightKgExact();
        if (mode == null || !Set.of("QUANTITY", "WEIGHT").contains(mode) || expected == null || expected.signum() <= 0) {
            throw invalid("请重新选择日报计量方式，并核对货品资料中的单重及单位");
        }
        FinancialExactAmount.require(expected, "货品单重");
        if (masterKgPerBaseUnit == null || expected.compareTo(masterKgPerBaseUnit) != 0) {
            throw new ApiException(ErrorCode.CONFLICT, "货品单重或重量单位已变化，请重新读取并核对本次报工数量");
        }
        BigDecimal rate = defaultRate(line.getUnitRate());
        ProductionOutputQuantity.requirePositiveBaseQuantity(line.getQty(), rate);
        Integer scale = line.getWeightQuantityScale();
        String rounding = line.getWeightQuantityRounding();
        if ("QUANTITY".equals(mode)) {
            if (scale != null || rounding != null) {
                throw invalid("按数量报工不使用称重折算的保留位数和取舍方式");
            }
            if (line.getWeight() != null) requireMeasuredKg(line.getWeight());
            return;
        }
        BigDecimal totalKg = requireMeasuredKg(line.getWeight());
        if ((scale == null) != (rounding == null) || scale != null && (scale < 0 || scale > 4
                || !Set.of("HALF_UP", "DOWN").contains(rounding))) {
            throw invalid("请核对称重折算数量的保留位数和取舍方式");
        }
        BigDecimal qty = adoptedQuantity(totalKg, masterKgPerBaseUnit.multiply(rate), scale, rounding);
        if (qty.compareTo(line.getQty()) != 0) {
            throw invalid("完工申报量与实称总重量、货品单重或所选取舍不一致，请重新核对");
        }
    }

    static BigDecimal requireMeasuredKg(BigDecimal totalKg) {
        if (totalKg == null || totalKg.signum() <= 0 || totalKg.compareTo(WEIGHT_LIMIT) >= 0
                || totalKg.stripTrailingZeros().scale() > 4) {
            throw invalid("实称总重量须大于零，以千克保存，最多14位整数和4位小数");
        }
        return totalKg;
    }

    private static BigDecimal adoptedQuantity(BigDecimal totalKg, BigDecimal kgPerReportUnit, Integer scale, String rounding) {
        String reason;
        try {
            BigDecimal exact = totalKg.divide(kgPerReportUnit).stripTrailingZeros();
            if (exact.scale() <= 4) return exact;
            reason = "PRECISION_LIMIT";
        } catch (ArithmeticException nonTerminating) {
            reason = "NON_TERMINATING";
        }
        if (scale == null) {
            throw new BusinessPrecisionRequiredException(QUANTITY_PURPOSE, "本次实称重量折算完工申报量", 4, reason);
        }
        return totalKg.divide(kgPerReportUnit, scale, RoundingMode.valueOf(rounding));
    }

    private static ApiException invalid(String message) {
        return new ApiException(ErrorCode.VALIDATION_FAILED, message);
    }
}
