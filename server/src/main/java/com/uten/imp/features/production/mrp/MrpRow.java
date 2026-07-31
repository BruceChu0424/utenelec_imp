package com.uten.imp.features.production.mrp;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

/**
 * MRP 物料齐套预览行。
 *
 * <p>旧字段 {@code onhand/openPo/net} 保持兼容，分别映射到账面库存、全部在途和采购总净缺口。
 * 新字段显式区分销售预留、安全库存和需求日前能到的在途，排产判断一律使用
 * {@code timelyShortage}。{@code goods.min_qty} 目前是货品级安全库存，没有颜色维度；
 * 对同一货品的每个颜色分别应用是有意采用的保守口径，避免不同颜色之间错误共用保底库存。
 */
public record MrpRow(
        UUID goodsId, String goodsCode, String goodsName, String spec,
        UUID colorId, BigDecimal gross, BigDecimal onhand, BigDecimal openPo,
        BigDecimal net, boolean selfMade, UUID unitId,
        BigDecimal bookStock, BigDecimal salesReserved, BigDecimal safetyStock,
        BigDecimal availableNow, BigDecimal openPoTotal, BigDecimal openPoOnTime,
        LocalDate needDate, LocalDate earliestArrivalDate,
        BigDecimal purchaseNetShortage, BigDecimal timelyShortage,
        String materialStatus,
        boolean allocationBacked,
        boolean planningWriteReady,
        String sourceType) {

    public static final String READY_NOW = "READY_NOW";
    public static final String READY_BY_DATE = "READY_BY_DATE";
    /** 全部有效在途最终可覆盖，但无法在需求日前到达；应催交/改配，不应重复采购。 */
    public static final String INBOUND_LATE = "INBOUND_LATE";
    public static final String PARTIAL_SHORTAGE = "PARTIAL_SHORTAGE";
    public static final String SHORTAGE = "SHORTAGE";

    /**
     * 从数据库事实量构造派生口径。数量均为基本单位：
     * <ul>
     *   <li>当前可用 = max(账面 - 生效销售预留 - 安全库存, 0)</li>
     *   <li>采购总净缺口 = max(毛需求 - 当前可用 - 全部在途, 0)</li>
     *   <li>及时缺口 = max(毛需求 - 当前可用 - 需求日前可到在途, 0)</li>
     * </ul>
     */
    public static MrpRow fromAvailability(
            UUID goodsId, String goodsCode, String goodsName, String spec,
            UUID colorId, BigDecimal gross, boolean selfMade, UUID unitId,
            BigDecimal bookStock, BigDecimal salesReserved, BigDecimal safetyStock,
            BigDecimal openPoTotal, BigDecimal openPoOnTime,
            LocalDate needDate, LocalDate earliestArrivalDate,
            String sourceType) {
        BigDecimal normalizedGross = nonNegative(gross);
        BigDecimal normalizedBook = zeroIfNull(bookStock);
        BigDecimal normalizedReserved = nonNegative(salesReserved);
        BigDecimal normalizedSafety = nonNegative(safetyStock);
        BigDecimal available = normalizedBook
                .subtract(normalizedReserved)
                .subtract(normalizedSafety)
                .max(BigDecimal.ZERO);
        BigDecimal totalPo = nonNegative(openPoTotal);
        BigDecimal onTimePo = nonNegative(openPoOnTime).min(totalPo);
        BigDecimal purchaseShortage = normalizedGross
                .subtract(available)
                .subtract(totalPo)
                .max(BigDecimal.ZERO);
        BigDecimal timely = normalizedGross
                .subtract(available)
                .subtract(onTimePo)
                .max(BigDecimal.ZERO);
        BigDecimal coveredOnTime = normalizedGross.subtract(timely).max(BigDecimal.ZERO);
        String status;
        if (normalizedGross.compareTo(available) <= 0) {
            status = READY_NOW;
        } else if (timely.signum() <= 0) {
            status = READY_BY_DATE;
        } else if (purchaseShortage.signum() <= 0) {
            status = INBOUND_LATE;
        } else {
            status = coveredOnTime.signum() > 0 ? PARTIAL_SHORTAGE : SHORTAGE;
        }
        return new MrpRow(
                goodsId, goodsCode, goodsName, spec, colorId, normalizedGross,
                normalizedBook, totalPo, purchaseShortage, selfMade, unitId,
                normalizedBook, normalizedReserved, normalizedSafety, available,
                totalPo, onTimePo, needDate, earliestArrivalDate,
                purchaseShortage, timely, status,
                false, false, sourceType);
    }

    /** 兼容旧单元测试/内部调用；新代码应使用 {@link #fromAvailability}. */
    public MrpRow(
            UUID goodsId, String goodsCode, String goodsName, String spec,
            UUID colorId, BigDecimal gross, BigDecimal onhand, BigDecimal openPo,
            BigDecimal net, boolean selfMade, UUID unitId) {
        this(
                goodsId, goodsCode, goodsName, spec, colorId,
                nonNegative(gross), zeroIfNull(onhand), nonNegative(openPo),
                nonNegative(net), selfMade, unitId,
                zeroIfNull(onhand), BigDecimal.ZERO, BigDecimal.ZERO,
                zeroIfNull(onhand).max(BigDecimal.ZERO),
                nonNegative(openPo), nonNegative(openPo),
                null, null, nonNegative(net), nonNegative(net),
                statusFor(nonNegative(gross), zeroIfNull(onhand), nonNegative(net)),
                false, false, null);
    }

    public MrpRow withCapabilities(boolean backed, boolean writeReady) {
        return new MrpRow(
                goodsId, goodsCode, goodsName, spec, colorId,
                gross, onhand, openPo, net, selfMade, unitId,
                bookStock, salesReserved, safetyStock, availableNow,
                openPoTotal, openPoOnTime, needDate, earliestArrivalDate,
                purchaseNetShortage, timelyShortage, materialStatus,
                backed, writeReady, sourceType);
    }

    private static String statusFor(BigDecimal gross, BigDecimal covered, BigDecimal shortage) {
        if (shortage.signum() <= 0) {
            return gross.compareTo(covered) <= 0 ? READY_NOW : READY_BY_DATE;
        }
        return gross.subtract(shortage).max(covered).signum() > 0 ? PARTIAL_SHORTAGE : SHORTAGE;
    }

    private static BigDecimal zeroIfNull(BigDecimal value) {
        return value == null ? BigDecimal.ZERO : value;
    }

    private static BigDecimal nonNegative(BigDecimal value) {
        return zeroIfNull(value).max(BigDecimal.ZERO);
    }
}
