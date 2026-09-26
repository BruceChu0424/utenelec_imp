package com.uten.imp.features.production.execution;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

/** Exact work order with separate production, quality and warehouse facts. */
public record ProductionExecutionWorkbenchSegment(
        UUID segmentId,
        UUID planId,
        String planNo,
        String segmentCode,
        String salesOrderNos,
        UUID workshopDepartmentId,
        String workshopName,
        String responsibleEmployeeName,
        String productCode,
        String productName,
        String productColorName,
        String productUnitName,
        BigDecimal plannedQty,
        BigDecimal reportedQty,
        BigDecimal remainingReportQty,
        BigDecimal fqcPendingQty,
        BigDecimal fqcPassedQty,
        BigDecimal fqcFailedQty,
        BigDecimal finishedInboundPendingQty,
        BigDecimal inboundQty,
        String segmentStatus,
        String materialStatus,
        String preparationStatus,
        boolean materialReady,
        boolean warehouseReady,
        boolean issued,
        boolean canDispatch,
        boolean canStart,
        boolean canReport,
        boolean canBatchReport,
        String blockedReason,
        LocalDate planBeginDate,
        LocalDate planEndDate,
        long lockVersion,
        boolean zeroMaterial,
        boolean canRecheckMaterial,
        boolean hasMaterialActivity,
        boolean hasUnregisteredMaterial,
        boolean drawRequested,
        boolean canRequestDraw,
        boolean canSplitBatch,
        UUID sourceSegmentId,
        boolean splitReplaced,
        boolean hasSharedMaterialActivity,
        boolean hasPendingReturn,
        boolean hasAvailableMaterial,
        /**
         * 按增量备料(ADR-095 起的唯一含义)：持续生产恒为真；曾按持续生产备过部分料再改
         * 齐套的工单也保持为真(既有部分预留/领料/直送投入一件不动)。开工门看 startRoute。
         */
        boolean continuousSupply,
        /** 已确认的开工路线(V599)：FULL_KIT/BATCH/CONTINUOUS；NULL=待车间确认。 */
        String startRoute,
        /** 待确认生产路线(V599)：等待物料且尚未选路，「下一步」首条=确认生产路线。 */
        boolean canConfirmRoute,
        /** 开工前(且尚无报工)可更改路线(ADR-095)：已备料、已领料、直送已投入的事实全部保留。 */
        boolean routeChangeable,
        /**
         * 路线记忆(V602 恢复，2026-09-20 用户口径「记住上次选的」)：同产品最近一次
         * 确认的开工路线。仅作未确认行的预填展示（前端黄标提醒核对），选中才提交，
         * 不自动生效——与 ADR-093「路线必须是明确确认的事实」不冲突。
         */
        String suggestedStartRoute,
        /**
         * 路线记忆来源(ADR-096)：PRODUCT=同产品最近一次确认；OPERATOR=本产品没有历史时取当前
         * 操作者最近一次确认的路线(记住上次的选择)；无记忆为 null。
         */
        String suggestedStartRouteSource,
        /** 逐种物料事实(ADR-095/V628)：本任务正式物料需求的种数(零料任务为 0)。 */
        int materialKindCount,
        /** 已按需求量实领到车间的种数(含同车间直送已投入)。 */
        int materialIssuedKindCount,
        /** 实领了一部分、尚未领足的种数(与其它桶不互斥，只用于说明)。 */
        int materialPartialIssuedKindCount,
        /** 车间已提交领料、等仓库实际发料的种数。 */
        int materialAwaitingWarehouseKindCount,
        /** 已备好可由车间提交领料的种数。 */
        int materialDrawableKindCount,
        /** 只剩线边仓直送料待开工时自动投入的种数。 */
        int materialLineSidePendingKindCount,
        /** 已预留、领料指令尚未生成的种数。 */
        int materialPreparingKindCount,
        /** 尚未备齐(预留不足需求量)的种数：采购/委外未到或自制子件尚未交到本任务。 */
        int materialShortKindCount,
        /**
         * 缺料中由自制子件工单供给的种数(ADR-096)：子件做完可能直送本车间也可能入库后领料，
         * 交接方式在子件报工时才决定，这里只说明来源是在产的自制子件。
         */
        int materialShortMakeKindCount,
        /** 已实领物料共同支持的可产量(冻结耗用曲线，V609)。 */
        BigDecimal materialSupportedOutputQty,
        /** 已预留物料(含未领)共同支持的可产量。 */
        BigDecimal materialPreparedOutputQty,
        /** Effective output above the original plan; never changes its commitment. */
        BigDecimal actualSurplusReportedQty,
        /** Actual surplus physically received after quality release. */
        BigDecimal actualSurplusInboundQty,
        /** Qualified receipts belonging to the original plan, excluding actual surplus. */
        BigDecimal plannedInboundQty,
        BigDecimal allowedOverproductionRate,
        long overproductionRateVersion,
        UUID pendingOverproductionRateRequestId,
        BigDecimal pendingOverproductionRate,
        boolean overproductionPolicyApplies,
        UUID actualOutputSupplementRequestId,
        /**
         * ADR-117：缺料里「计划还没下单」的种数——物料分析那一行此刻还缺(与主表「还缺数量」
         * 同一个数)。0 = 缺的料计划都已下过单(在途 / 在产)，只是在等到货。
         */
        int materialPlanningGapKindCount,
        /** 计划还没下单的物料点名(「铜片 800个、弹簧 1000个 等 5 种」)；没有为 null。 */
        String materialPlanningGapSummary,
        /** 车间已经催过计划的次数(在催记录)；没催或计划已下够单为 0。 */
        int planningUrgeCount,
        /** 最近一次催计划的时间；没在催为 null。 */
        java.time.OffsetDateTime planningUrgedAt,
        /** 最近一次是谁催的。 */
        String planningUrgedByName,
        /** 最早什么时候可以再催(30 分钟内不重复打扰计划员)；没催过为 null。 */
        java.time.OffsetDateTime planningNextUrgeAt,
        /** 当前用户能不能催：有计划还没下单的料，且本人是有效车间人员、有开工 / 领料权限。 */
        boolean canUrgePlanning,
        boolean materialDiscoveryRequired,
        UUID materialDiscoveryRequestId,
        String materialDiscoveryStatus,
        boolean canRequestMaterialDiscovery,
        /** 来源计划（V719）：ANALYSIS 根的 WL 分析编号；历史计划根为 null。 */
        String analysisNo) {
}
