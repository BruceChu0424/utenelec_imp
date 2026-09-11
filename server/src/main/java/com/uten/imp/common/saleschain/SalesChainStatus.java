package com.uten.imp.common.saleschain;

import java.math.BigDecimal;

/**
 * {@link SalesOrderChainSql} 的 Java 镜像：Service 里已经把订单行读进内存、要在 Java 侧算
 * 新 chain_status 的写点（订单审核预留 / 改量 / 退货重算）用本类，避免再手写第二套规则。
 * 粘性语义与 SQL 默认值一致：原值 5 只在"未排=0、未入库、仍有未完工计划量"时保留；
 * 原值 3 落回已排产时保留 3，其余 4。
 */
public final class SalesChainStatus {

    public static final short PARTIAL_RESERVED = 1;
    public static final short PENDING_PLAN = 2;
    public static final short WAIT_MATERIAL = 3;
    public static final short PLANNED = 4;
    public static final short PRODUCING = 5;
    public static final short PARTIAL_COMPLETED = 6;
    public static final short SHIPPABLE = 7;
    public static final short PARTIAL_SHIPPED = 8;
    public static final short SHIPPED = 9;
    public static final short CANCELED = -1;

    private SalesChainStatus() {}

    /** 未交付量：qty − shipped + returned − flag。 */
    public static BigDecimal outstanding(
            BigDecimal qty, BigDecimal shipped, BigDecimal returned, BigDecimal flagged) {
        return nz(qty).subtract(nz(shipped)).add(nz(returned)).subtract(nz(flagged));
    }

    /** 未完工计划量：max(planned − produced, 0)。 */
    public static BigDecimal unfinishedPlan(BigDecimal planned, BigDecimal produced) {
        return nz(planned).subtract(nz(produced)).max(BigDecimal.ZERO);
    }

    /** 剩余未排量：max(未交付 − 预留 − 未完工计划量, 0)，镜像 {@link SalesOrderChainSql#unplannedQtySql}。 */
    public static BigDecimal unplannedQty(
            BigDecimal qty, BigDecimal shipped, BigDecimal returned, BigDecimal flagged,
            BigDecimal reserved, BigDecimal planned, BigDecimal produced) {
        return outstanding(qty, shipped, returned, flagged)
                .subtract(nz(reserved))
                .subtract(unfinishedPlan(planned, produced))
                .max(BigDecimal.ZERO);
    }

    /**
     * 按当前行数量派生 chain_status；{@code current ≤ 0}（未上链 / 已取消）原样返回。
     * 镜像 {@link SalesOrderChainSql#chainStatusCaseSql} 的默认粘性输入。
     */
    public static short derive(
            short current,
            BigDecimal qty, BigDecimal shipped, BigDecimal returned, BigDecimal flagged,
            BigDecimal reserved, BigDecimal planned, BigDecimal produced) {
        if (current <= 0) return current;
        return deriveOnChain(current, qty, shipped, returned, flagged, reserved, planned, produced);
    }

    /**
     * 行刚上链（订单审核）时无"原值"可粘，按数量直接派生；{@code current} 只用于 3/5 粘性判定，
     * 传 0 表示无粘性。
     */
    public static short deriveOnChain(
            short current,
            BigDecimal qty, BigDecimal shipped, BigDecimal returned, BigDecimal flagged,
            BigDecimal reserved, BigDecimal planned, BigDecimal produced) {
        BigDecimal outstanding = outstanding(qty, shipped, returned, flagged);
        BigDecimal reservedQty = nz(reserved);
        if (outstanding.signum() <= 0) return SHIPPED;
        if (reservedQty.compareTo(outstanding) >= 0) return SHIPPABLE;
        if (nz(shipped).signum() > 0) return PARTIAL_SHIPPED;
        BigDecimal unfinished = unfinishedPlan(planned, produced);
        if (outstanding.subtract(reservedQty).subtract(unfinished).signum() > 0) {
            return reservedQty.signum() > 0 ? PARTIAL_RESERVED : PENDING_PLAN;
        }
        if (nz(produced).signum() > 0) return PARTIAL_COMPLETED;
        if (current == PRODUCING) return PRODUCING;
        if (unfinished.signum() > 0) return current == WAIT_MATERIAL ? WAIT_MATERIAL : PLANNED;
        return PENDING_PLAN;
    }

    private static BigDecimal nz(BigDecimal value) {
        return value == null ? BigDecimal.ZERO : value;
    }
}
