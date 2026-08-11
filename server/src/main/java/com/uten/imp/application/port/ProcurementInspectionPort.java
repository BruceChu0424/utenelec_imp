package com.uten.imp.application.port;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

/**
 * 采购/委外收货 IQC 待检隔离跨模块契约（V222）。
 *
 * <p>purchase / subcontract 收货服务通过本端口把收货明细送入仓库侧的待检隔离
 * （实现位于 features/warehouse/inbound/ProcurementInspectionService），避免 feature→feature
 * 直连（ADR-017）。合格放行（PASS）的库存入库与生产唤醒由仓库侧实现内部完成。
 */
public interface ProcurementInspectionPort {

    String PURCHASE = "PURCHASE";
    String SUBCONTRACT = "SUBCONTRACT";

    /** 收货审核同事务调用：建待检冻结行；不写 stock_balances。 */
    void receive(String receiptType, UUID receiptId, UUID warehouseId,
                 List<ReceivedLine> lines, OffsetDateTime receivedAt);

    /** 收货红冲前置校验：存在待检行时必须全部结案（RESOLVED）。 */
    void requireResolvedForReverse(String receiptType, UUID receiptId);

    /**
     * 收货红冲同事务调用：反向已 PASS 放行的库存并置冻结行 REVERSED。
     * 返回是否管理了该单（有冻结行）；无冻结行时调用方走历史全量反向。
     */
    boolean reverseResolvedStock(String receiptType, UUID receiptId, OffsetDateTime now);

    record ReceivedLine(UUID receiptItemId, UUID goodsId, UUID colorId,
                        UUID unitId, BigDecimal unitRate, BigDecimal qty,
                        BigDecimal amountLocal) {
    }
}
