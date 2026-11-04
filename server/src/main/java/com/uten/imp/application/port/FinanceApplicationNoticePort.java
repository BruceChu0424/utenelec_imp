package com.uten.imp.application.port;
import java.util.*;

/** Explicit application responsibility; a view grant alone never enters a notice audience. */
public interface FinanceApplicationNoticePort {
    void review(UUID id,String title,String applicant,String step,List<UUID> recipientUserIds);
    void payment(UUID id,String title,List<UUID> recipientUserIds);
    void returned(UUID id,String title,String reason,UUID applicantUserId);
    void resolve(UUID id,String reason);
}
