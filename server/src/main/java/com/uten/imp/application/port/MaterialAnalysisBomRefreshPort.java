package com.uten.imp.application.port;

import java.util.List;
import java.util.UUID;

/**
 * 研发完善委外件 BOM 后自动刷新物料分析(ADR-143 §二.3)。实现在生产物料分析模块。
 *
 * <p>通知侧在 outbox {@code GOODS_BOM_UPDATED} 投递时(BOM 保存事务已提交)只用
 * {@link #analysesAwaitingBomRefresh} 找出要刷新的分析, 每张排一条自己的 outbox 事件;
 * 每条事件单独投递时才调用 {@link #refreshAnalysisAfterBomUpdated}。刷新因此不占用别的通知的投递,
 * 一张分析刷新失败只让它自己那条事件退避重试, 不影响其余分析。
 */
public interface MaterialAnalysisBomRefreshPort {

    /** 一张分析这次自动刷新的结果。 */
    enum Outcome {
        /** 本次已按新 BOM 刷新。 */
        REFRESHED,
        /** 早已按新 BOM 展开出直属物料(别的事件或人工刷新做过了), 不用再刷。 */
        ALREADY_CURRENT,
        /** 不能自动刷新: 分析已结束、已删除、不再含这个委外件, 或负责人账号已停用 / 授权已变。 */
        SKIPPED
    }

    /**
     * 还没展开出这个委外件可发外直属物料的未结束分析(货品现在有 {@code fn_subcontract_draw_edges} 行,
     * 而分析里该货品的委外节点下面一个对应的物料行都没有; 负责人账号已停用的不算)。按分析编号排序。
     */
    List<UUID> analysesAwaitingBomRefresh(UUID goodsId);

    /**
     * 以分析负责人的身份、在独立事务里按新 BOM 刷新一张分析(与页面刷新同一把锁、同一套重算)。
     * 刷新本身失败时原样抛出, 调用方的 outbox 投递据此退避重试。
     */
    Outcome refreshAnalysisAfterBomUpdated(UUID analysisId, UUID goodsId);
}
