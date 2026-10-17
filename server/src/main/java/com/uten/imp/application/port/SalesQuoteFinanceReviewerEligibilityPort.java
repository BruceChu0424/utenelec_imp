package com.uten.imp.application.port;

import java.util.List;
import java.util.UUID;

/**
 * 销售报价财务核价权限: 员工在职、账号启用，且有效权限同时持有
 * {@code sales_quote_finance:view} 与 {@code sales_quote_finance:confirm}。
 * 认领、核价修改、退回与确认均按此判定，不另查部门或授权来源。
 * 通知池使用真实授出权限，避免把超管固有全权限当成订阅全部业务待办。
 */
public interface SalesQuoteFinanceReviewerEligibilityPort {

    /** 该账号当前是否为合格核价人。 */
    boolean isEligible(UUID userId);

    /** 全部合格核价人的账号 id(通知接收池), 按 id 排序。 */
    List<UUID> eligibleUserIds();
}
