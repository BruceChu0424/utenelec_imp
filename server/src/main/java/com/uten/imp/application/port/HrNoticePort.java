package com.uten.imp.application.port;

import java.util.List;
import java.util.UUID;

/**
 * 人事域审核待办通知端口（ADR-017 跨 feature 只经 Port）：报销 / 工资 / 访客 /
 * 信息变更 / 建议箱在各自事务内调用，实现方 {@code features.notice.HrNoticeService}
 * 与业务同事务（失败随业务回滚）。方法语义见实现类 javadoc 与 ADR-063 附录。
 */
public interface HrNoticePort {

    /**
     * 员工档案 id → 通知收件账号 id（仅 active 且未删除账号；无账号返回 null，
     * 通知侧自行跳过）。业务侧只经本端口解析收件人，不直接依赖 auth 模块。
     */
    UUID recipientUserIdOf(UUID employeeId);

    // —— 信息变更 ——
    void notifyProfileChangeSubmitted(UUID batchId, String submitterName,
                                      List<String> fieldLabels, UUID submitterEmployeeId);

    void resolveProfileChangeBatch(UUID batchId, String reason);

    // —— 访客 ——
    void notifyVisitorApplySubmitted(UUID applicationId, String visitorName,
                                     String hostName, String visitPurpose);

    void notifyVisitorHostReviewRequired(UUID applicationId, String visitorName,
                                         UUID hostEmployeeId, String hostName);

    void resolveVisitorApplication(UUID applicationId, String reason);

    void resolveVisitorHostConfirm(UUID applicationId, String reason);

    // —— 报销 ——
    void notifyExpenseClaimSubmitted(UUID claimId, String applicantName,
                                     String amountLabel, UUID applicantEmployeeId);

    void notifyExpenseClaimApproved(UUID claimId, String applicantName,
                                    String amountLabel, UUID applicantUserId,
                                    UUID applicantEmployeeId);

    void notifyExpenseClaimRejected(UUID claimId, String applicantName,
                                    String reason, UUID applicantUserId);

    void notifyExpenseClaimPaid(UUID claimId, String applicantName,
                                String amountLabel, UUID applicantUserId);

    void resolveExpenseClaim(UUID claimId, String reason);

    // —— 工资批次 ——
    void notifyPayrollBatchSubmitted(UUID batchId, String periodLabel,
                                     String generatorName, UUID generatorEmployeeId);

    void notifyPayrollBatchApproved(UUID batchId, String periodLabel,
                                    UUID approverEmployeeId);

    void notifyPayrollBatchRejected(UUID batchId, String periodLabel,
                                    String reason, UUID generatorUserId);

    void resolvePayrollBatch(UUID batchId, String reason);

    void notifyPayrollPublished(UUID batchId, String periodLabel, List<UUID> employeeIdsWithSlip);

    // —— 建议箱 ——
    void notifySuggestionSubmitted(UUID suggestionId, UUID submitterUserId,
                                   String submitterName, String title, boolean anonymous);

    void notifySuggestionClosed(UUID suggestionId, UUID submitterUserId,
                                String title, String status);
}
