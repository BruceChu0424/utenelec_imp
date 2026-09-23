package com.uten.imp.features.notice;

import com.uten.imp.application.port.AccountSecurityNoticePort;
import com.uten.imp.features.auth.model.UserAccountRepository;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.util.UUID;

/**
 * {@link AccountSecurityNoticePort} 的实现: 定向系统通知 (重要级, 不可静默, 本人不可删除)。
 */
@Service
@RequiredArgsConstructor
public class AccountSecurityNoticeService implements AccountSecurityNoticePort {

    private final NoticeService noticeService;
    private final UserAccountRepository users;

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void notifyAccountHolder(UUID targetUserId, String title, String content) {
        publish(targetUserId, title, content);
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void notifySuperAdministrators(UUID actorUserId, String title, String content) {
        for (UUID administrator : users.findActiveSuperAdminIds()) {
            if (!administrator.equals(actorUserId)) {
                publish(administrator, title, content);
            }
        }
    }

    private void publish(UUID audienceUserId, String title, String content) {
        noticeService.publishForUser(
                audienceUserId, title, content, "system", "系统", null,
                NoticeService.ACCOUNT_SECURITY_SOURCE_EVENT, "important");
    }
}
