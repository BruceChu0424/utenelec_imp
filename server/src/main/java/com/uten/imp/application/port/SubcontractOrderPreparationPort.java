package com.uten.imp.application.port;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.Collection;
import java.util.UUID;

/**
 * 委外订货（直接下单）有子层目标件的「先发单给计划」端口（2026-09-05 委外收敛）。
 *
 * <p>委外模块不再有自己的准备中心/物料分析入口；有子层委外件由本端口在生产侧
 * 创建前置生产分析（计划部在自己的物料分析工作台安排车间），生产完成入库后
 * 由完工回调通知委外制单人可提交财务审核。subcontract 特性包只依赖本端口，
 * 与 production 特性包保持编译期隔离。
 */
public interface SubcontractOrderPreparationPort {

    /**
     * 幂等保证草稿订货行的前置生产分析：不存在则按缺口创建并通知计划部；
     * 已存在且数量变化但尚未排产时，取消旧分析按新缺口重建；已排产则
     * fail-closed（必须保留该行或红冲重下）。
     */
    void ensureDraftPreparation(DraftPreparationCommand command);

    /** 草稿编辑删除行/整单删除前：取消其前置生产分析；已排产行 fail-closed。 */
    void releaseDraftPreparations(Collection<UUID> orderItemIds, String reason);

    /** 校验行未排产（不取消）；已排产抛冲突。 */
    void requireDraftPreparationsIdle(Collection<UUID> orderItemIds);

    /**
     * 草稿编辑后行 ID 重建（update 全删重存）时，把已存在的前置生产分析
     * source_ref 从旧行 ID 迁移到新行 ID（仅限同货品同数量未变的行）。
     */
    void remapDraftPreparation(UUID oldOrderItemId, UUID newOrderItemId);

    /** 财务批准后的 MAKE_THEN 计划行自动启动前置生产（替代已退役的手工 start）。 */
    void autoStartPlanLinePreparation(UUID planItemId);

    /**
     * 完工入库审核回调：若本次入库使某张草稿委外订货单的全部有子层行
     * 库存备齐，通知制单人「可提交财务审核」（幂等，按订单聚合一轮）。
     */
    void afterFinishedInboundApproved(UUID stockDocumentId);

    /** 草稿订货行的前置生产缺口（基本单位）。 */
    record DraftPreparationCommand(
            UUID orderId,
            UUID orderItemId,
            String orderBillNo,
            UUID goodsId,
            UUID colorId,
            UUID unitId,
            BigDecimal baseQty,
            UUID warehouseId,
            LocalDate needDate) {
    }
}
