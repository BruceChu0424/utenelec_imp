package com.uten.imp.application.port;

import java.math.BigDecimal;
import java.util.Collection;
import java.util.List;
import java.util.UUID;

/**
 * 计划前物料分析备料库存绑定（V298 pegging）跨模块端口。
 *
 * <p>语义：物料分析下达的采购/委外订货，收货 IQC 合格入库时把入库量按
 * 「订货明细 → 申请/委外明细 → 分析供应行动分摊」溯源到来源分析，写
 * {@code owner_type='PREPLAN_ANALYSIS'} 的库存软预留。该预留进入
 * {@code v_stock_available} 统一扣减口径：其它分析、销售、MRP 都看不到这批料；
 * 归属分析自己的可用量由物料分析服务加回。分析正式下达计划包时同事务转移给需求。
 *
 * <p>自制备料（成品入库单）对无销售订单链接的计划行产出，补同一形态的归属预留。
 *
 * <p>所有方法均要求调用方已持有对应库存维度 advisory 锁与单据行锁，
 * 并在来源单据状态机事务内以 {@code MANDATORY} 传播执行，保证全链对称、可回滚。
 */
public interface PreplanAnalysisPegPort {

    /** 库存维度需求片（货品+颜色+需求量，基本单位）。 */
    record DemandSlice(UUID demandId, UUID goodsId, UUID colorId,
                       BigDecimal requiredQty) {
    }

    /** In-transaction entitlement consumption prepared before stock allocation. */
    record PreparedPlanTransfer(
            UUID sourceEntitlementEventId,
            UUID sourceStockReservationId,
            UUID beneficiaryAnalysisId,
            UUID beneficiaryAnalysisMaterialId,
            UUID demandId,
            BigDecimal qty) {
    }

    /** Formal demand reservation actually persisted by the stock allocator. */
    record FormalReservationSlice(
            UUID demandId,
            UUID stockReservationId,
            BigDecimal qty) {
    }

    /** 成品入库行（计划行 + 入库基本量）。 */
    record FinishedInboundSlice(
            UUID stockDocumentItemId,
            UUID planItemId,
            UUID goodsId,
            UUID colorId,
            BigDecimal baseQty) {
    }

    /**
     * IQC 单次 PASS 放行入库后调用：为本次放行的基本量尝试建立分析归属预留。
     * 无来源分析（手工订货/计划包订货）或超出分析分摊量的部分静默跳过（留作公共现货）。
     * 幂等键按处置事件生成，重放不产生重复行。
     */
    void attributeInspectionPass(
            String receiptType,
            UUID receiptId,
            UUID inspectionItemId,
            UUID dispositionEventId,
            BigDecimal passedBaseQty,
            UUID warehouseId);

    /** 收货单红冲同事务调用：释放该收货单建立的全部分析归属预留（对称反向）。 */
    void releaseForReceipt(String receiptType, UUID receiptId);

    /**
     * FINISHED_IN reverse preflight: rejects any active formal bridge and writes
     * RELEASE events for unformalized lots. The caller must immediately perform
     * the matching physical source-document release in the same transaction.
     */
    void requireFinishedInboundReversible(UUID stockDocumentId);

    /** 整份分析取消：释放该分析名下全部生效中的备料预留，库存回到公共现货池。 */
    void releaseForAnalysis(
            UUID analysisId, String reason, String cancellationIdempotencyKey);

    /** 单个备料任务撤回：释放归属于该任务外部单据明细（申请行/委外申请行）的预留。 */
    void releaseForSupplyItems(
            UUID analysisId, Collection<UUID> externalItemIds, String reason);

    /**
     * Releases only READY-demand entitlement lots in preparation for formal
     * allocation. The returned in-transaction slices must be bound to the
     * actual formal reservations before the confirmation transaction commits.
     */
    List<PreparedPlanTransfer> transferToPlanDemands(
            UUID analysisId, UUID planId,
            UUID warehouseId, List<DemandSlice> demands);

    /** Persist FORMALIZE events after the formal demand reservations exist. */
    void formalizePlanDemandTransfers(
            UUID packageId,
            List<PreparedPlanTransfer> prepared,
            List<FormalReservationSlice> formalReservations);

    /**
     * Restore unissued formalized lots after their formal reservations have
     * been released by package cancellation or receipt-driven segment unwind.
     */
    void restorePlanDemandTransfers(
            Collection<UUID> formalReservationIds, String reason);

    /**
     * 在任何计划/计划包行锁之前，按来源物料分析预锁 active 节点与仍有效归属的
     * 全部库存维度。返回预锁时读到的来源 analysis UUID，供调用方在锁住计划后
     * 重校验，避免来源被并发替换后再反序补锁。
     */
    UUID lockPlanningPackageInventoryDimensions(UUID planId);

    /** Fail closed only for historical V298 pool transfers without an event bridge. */
    void requirePlanningPackageLifecycleReversible(UUID planId);

    /**
     * Attributes residual PREPLAN_MAKE_TASK output exactly to its source
     * analysis material allocation. Active formal MAKE supply commitments are
     * satisfied first; unproven overproduction remains public stock.
     */
    void pegFinishedInbound(
            UUID stockDocumentId,
            UUID planId,
            UUID warehouseId,
            List<FinishedInboundSlice> lines);
}
