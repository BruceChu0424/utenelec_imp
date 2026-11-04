package com.uten.imp.application.port;
import java.util.UUID;
/** Ordinary directed receipts, separate from approval eligibility and notice subscriptions. */
public interface EmployeeApplicationNoticePort {
    void result(UUID applicantEmployeeId,UUID applicationId,String message);
    void pending(UUID userId,UUID applicationId,String stageLabel);
}
