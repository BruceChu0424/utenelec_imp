package com.uten.imp.application.port;

import java.util.List;
import java.util.UUID;

/**
 * 销售报价财务核价人资格(ADR-134, 沿用 ADR-027 审核组模型): 财务部门(DEPT_FIN)子树在职员工或经个人加授
 * {@code sales_quote_finance:confirm} 的人员、账号启用, 且最终权限同时持有
 * {@code sales_quote_finance:view} 与 {@code sales_quote_finance:confirm}。
 * 认领、核价修改、退回、确认与通知接收池都只认这一个口径。
 */
public interface SalesQuoteFinanceReviewerEligibilityPort {

    /** 该账号当前是否为合格核价人。 */
    boolean isEligible(UUID userId);

    /** 全部合格核价人的账号 id(通知接收池), 按 id 排序。 */
    List<UUID> eligibleUserIds();
}
