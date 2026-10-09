package com.uten.imp.application.port;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/**
 * Neutral application boundary for production-created subcontract requests.
 *
 * <p>Production owns the demand; subcontract owns its documents. The immutable
 * demand id is returned with every created application item so production can
 * create an exact supply peg without importing subcontract entities.</p>
 */
public interface ProductionSubcontractRequestPort {

    /**
     * 生成计划下达的委外申请。
     *
     * @param productionPlanNo 来源单号（计划路径=计划单号；物料分析路径=可读来源标签）
     * @param materialAnalysisId 非空表示来源为计划前物料分析（按 id 回溯谱系，不再字符串匹配）
     */
    DraftResult createProductionDraft(
            String productionPlanNo,
            UUID materialAnalysisId,
            LocalDate needDate,
            UUID warehouseId,
            List<DraftLine> lines,
            UUID applicantEmployeeId,
            UUID makerEmployeeId);

    void closeGeneratedDraft(UUID applicationId, LifecycleAction action);

    /**
     * 就地追加（ADR-099）：把生产下达的委外申请明细数量改大。只允许申请仍开着、
     * 明细尚未订货的情形；其余情形拒绝，由生产侧另立新申请。
     */
    void increaseProductionDraftLine(UUID applicationId, UUID applicationItemId, BigDecimal addedQty);

    /**
     * ADR-065 修订三（滚动合单）：找本物料分析最近一张「尚未被下游动过」的委外申请
     * （全部明细未订货、无订货单来源行引用）。没有可并入的返回 null，调用方新开一张。
     * [incomingLines] 为本次准备并入的行数，并入后超过单据规模上限的候选不算可并入。
     */
    MergeableDraft findMergeableProductionDraft(UUID materialAnalysisId, int incomingLines);

    /**
     * ADR-065 修订三：把明细行并入既有委外申请。行号接既有最大行号续排；
     * 任一明细已被下游动过即拒绝。
     */
    DraftResult appendProductionDraftLines(
            UUID applicationId,
            String productionPlanNo,
            UUID materialAnalysisId,
            List<DraftLine> lines);

    enum LifecycleAction {
        CANCEL,
        REVERSE
    }

    record DraftLine(
            UUID demandId,
            UUID goodsId,
            UUID colorId,
            UUID unitId,
            BigDecimal qty,
            LocalDate needDate,
            String remark) {
    }

    record DraftLineResult(
            UUID demandId,
            UUID applicationItemId,
            LocalDate expectedDate,
            BigDecimal qty) {
    }

    record DraftResult(
            UUID applicationId,
            String billNo,
            List<DraftLineResult> lines) {
    }

    /** {@link #findMergeableProductionDraft} 的命中结果：可继续并入明细的既有申请。 */
    record MergeableDraft(
            UUID applicationId,
            String billNo) {
    }
}
