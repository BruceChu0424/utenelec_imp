package com.uten.imp.features.auth;

import com.uten.imp.audit.AuditService;
import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import com.uten.imp.features.admin.systemsetting.SystemSettingKey;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.security.TxSessionVars;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.time.OffsetDateTime;
import java.util.UUID;

/**
 * Persists a failed login in a transaction independent from the request transaction.
 *
 * <p>The authentication flow throws immediately afterwards, so joining that transaction
 * would roll back both the counter and the lock state.
 */
@Service
public class LoginFailureRecorder {

    private final UserAccountRepository userRepo;
    private final SystemSettingsService settings;
    private final AuditService audit;
    private final TxSessionVars tx;

    public LoginFailureRecorder(UserAccountRepository userRepo,
                                SystemSettingsService settings,
                                AuditService audit,
                                TxSessionVars tx) {
        this.userRepo = userRepo;
        this.settings = settings;
        this.audit = audit;
        this.tx = tx;
    }

    /**
     * 记一次失败并按阈值加临时锁; 锁定期内的尝试 (reason=attempt_while_locked) 同样计数并顺延锁定,
     * 让锁定期内不断试密码的人一直拿不到结果。
     */
    @Transactional(propagation = Propagation.REQUIRES_NEW)
    public void record(UUID userId, String loginAccount, String reason) {
        tx.bindActor(userId, loginAccount);
        UserAccount user = userRepo.findByIdForUpdate(userId).orElse(null);
        if (user == null) {
            return;
        }

        int attempts = user.getFailedAttempts() + 1;
        user.setFailedAttempts(attempts);

        /*
         * Never rewrite disabled or manually locked accounts as temporary locks.
         * Otherwise a later successful login could reactivate an administratively
         * disabled/locked account after lockedUntil expires.
         */
        boolean active = "active".equals(user.getStatus());
        boolean temporaryLock = "locked".equals(user.getStatus())
                && user.getLockedUntil() != null;
        if ((active || temporaryLock)
                && attempts >= settings.readInt(SystemSettingKey.LOCKOUT_THRESHOLD)) {
            user.setStatus("locked");
            user.setLockedUntil(OffsetDateTime.now()
                    .plusMinutes(settings.readInt(SystemSettingKey.LOCKOUT_MINUTES)));
        }

        userRepo.save(user);
        audit.logExplicit(user.getId(), loginAccount, "login_failed",
                "users", user.getId().toString(), reason);
    }
}
