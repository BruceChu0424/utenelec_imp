package com.uten.imp.application.port;

import java.math.BigDecimal;
import java.util.UUID;

/**
 * Durable notice projections emitted by the subcontract draw lifecycle (ADR-143 §4.4).
 *
 * <p>Every notify/resolve method only appends a business-outbox event when called inside a
 * business transaction; the text is computed from live facts when the outbox worker delivers it.
 * Called inside an outbox delivery (the draw recheck worker), the card is rebuilt directly
 * in that delivery transaction. The two refresh methods exist only for the recheck worker.
 */
public interface SubcontractChainNoticePort {

    /**
     * 领料重算(只在 Outbox 投递事务里)发现可领量比上次提醒时增加: 按此刻实时可领量重建该订货明细的
     * 行动卡(每个订货明细一张), 返回卡上写的可领量; 此刻已不可领时只撤卡, 返回 0。重算把返回值记作
     * 提醒水位, 不用自己先前读到的数: 两次读取之间库存被别处用掉时不会「水位抬了、卡没发」。
     */
    BigDecimal refreshSubcontractDrawAvailable(UUID orderItemId);

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

    /**
     * ADR-156 委外申请可下单量比上次提醒时增加(直属物料到了一部分或全部; 只在 Outbox 投递事务里): 按此刻
     * 实时可下单量重建该申请明细的行动卡(每个申请明细一张), 返回卡上写的可下单量; 此刻为 0 时只撤卡, 返回 0。
     * 重算把返回值记作提醒水位(同 {@link #refreshSubcontractDrawAvailable})。
     */
    BigDecimal refreshSubcontractOrderKitReady(UUID applicationItemId);

    /** 可下单归零(物料被别的单占走、已全部下单、申请关闭): 撤掉该申请明细的「可下单」行动卡。 */
    void resolveSubcontractOrderKitReady(UUID applicationItemId);
}
