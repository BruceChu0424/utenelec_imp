package com.uten.imp.application.port;

import java.util.UUID;

/**
 * 销售报价核价流程的通知出口(ADR-134; 实现在 features/notice, 与业务同事务, 失败随业务回滚)。
 * 文案面向业务人员, 只写单号、客户与下一步要做什么, 不出现代号。
 */
public interface SalesQuoteNoticePort {

    /** 报价提交财务核价: 通知全部合格核价人(提交人本人除外)。 */
    void notifySubmittedForReview(UUID quoteId);

    /** 财务退回报价: 通知报价负责人(制单人), 带退回原因。 */
    void notifyReturned(UUID quoteId);

    /** 财务确认报价: 通知报价负责人可以转订货单了。 */
    void notifyConfirmed(UUID quoteId);

    /** 财务撤销确认重新核价: 通知报价负责人暂时不能转订货单。 */
    void notifyFinanceReopened(UUID quoteId);

    /** 核价待办已办结(撤回/退回/确认): 撤回全部核价人的待办弹卡。 */
    void resolveReviewNotices(UUID quoteId, String reason);
}
