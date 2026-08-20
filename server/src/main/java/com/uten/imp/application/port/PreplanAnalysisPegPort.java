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
    record DemandSlice(UUID goodsId, UUID colorId, BigDecimal requiredQty) {
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

    /** 整份分析取消：释放该分析名下全部生效中的备料预留，库存回到公共现货池。 */
    void releaseForAnalysis(UUID analysisId, String reason);

    /** 单个备料任务撤回：释放归属于该任务外部单据明细（申请行/委外申请行）的预留。 */
    void releaseForSupplyItems(
            UUID analysisId, Collection<UUID> externalItemIds, String reason);

    /**
     * 计划包正式确认（confirm）同事务调用：把来源分析在目标仓的备料预留按需求维度
     * 释放回池（release_reason=TRANSFERRED_TO_PLAN），让随后的需求分配器为
     * production_material_demands 建行——同一事务内完成「分析备料 → 计划需求」的转移，
     * 库存事实不重复、不漂移。每个维度转移量 = min(分析剩余预留, 本次需求总量)。
     */
    void transferToPlanDemands(
            UUID analysisId, UUID warehouseId, List<DemandSlice> demands);

    /**
     * 成品入库审核同事务调用：对来源计划（携 material_analysis_id）的入库行中
     * 未被销售订单链接覆盖的产出量，建立分析归属预留（自制备料回仓绑定）。
     * 红冲由既有 {@code releaseBySourceDoc('PRODUCTION_INBOUND', docId)} 对称覆盖。
     */
    void pegFinishedInbound(
            UUID stockDocumentId,
            UUID planId,
            UUID warehouseId,
            List<FinishedInboundSlice> lines);
}
