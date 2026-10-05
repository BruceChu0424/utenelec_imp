package com.uten.imp.application.port;

import java.util.UUID;

/**
 * Durable notice projections emitted by the subcontract draw lifecycle (ADR-143 §4.4).
 *
 * <p>Every method only appends a business-outbox event when called inside a business
 * transaction; the text is computed from live facts when the outbox worker delivers it.
 * Called inside an outbox delivery (the draw recheck worker), the card is rebuilt directly
 * in that delivery transaction.
 */
public interface SubcontractChainNoticePort {

    /**
     * 可领量比上次提醒时增加: 每个订货明细一张行动卡, 按投递时实时可领量覆盖。
     * 投递时可领为 0 则只撤卡。
     */
    void notifySubcontractDrawAvailable(UUID orderItemId);

    /** 提交领料 / 结束领料 / 订单红冲 / 可领归零: 撤掉该订货明细的「可领料」行动卡。 */
    void resolveSubcontractDrawAvailable(UUID orderItemId);

    /** 一张委外领料草稿等仓库发料(每张草稿一条, 发给草稿所在仓库的仓管)。 */
    void notifySubcontractOutboundReady(UUID issueId);

    /** 委外人员撤回了这张草稿里尚未发出的领料(整张撤销或删去部分行), 通知仓库。 */
    void notifySubcontractDrawWithdrawn(UUID issueId);

    /** 仓库把这张领料草稿整张退回(本次不发), 告诉提交领料的委外人员(含仓库填的原因)。 */
    void notifySubcontractDrawReturned(UUID issueId, String reason);

    /** 仓库审核发出一张委外领料草稿。 */
    void notifySubcontractOutboundCompleted(UUID issueId);

    /** 已发出的委外领料被红冲。 */
    void notifySubcontractOutboundReversed(UUID issueId);
}
