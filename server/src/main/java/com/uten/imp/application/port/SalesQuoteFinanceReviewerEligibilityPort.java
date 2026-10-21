package com.uten.imp.application.port;

import java.util.List;
import java.util.UUID;

/**
 * 销售报价财务核价权限: 员工在职、账号启用，且有效权限同时持有
 * {@code sales_quote_finance:view} 与确认或退回权限之一。
 * 认领按此判定；核价修改、退回、确认及重新核价各自校验对应动作，不另查部门或授权来源。
 * 通知池使用真实授出权限，避免把超管固有全权限当成订阅全部业务待办。
 */
public interface SalesQuoteFinanceReviewerEligibilityPort {

    /** 该账号当前是否为合格核价人。 */
    boolean isEligible(UUID userId);

    /** 账号启用、员工在职，且同时持有查看和重新核价权限；不要求确认或认领。 */
    boolean canReopen(UUID userId);

    /** 全部合格核价人的账号 id(通知接收池), 按 id 排序。 */
    List<UUID> eligibleUserIds();
}
