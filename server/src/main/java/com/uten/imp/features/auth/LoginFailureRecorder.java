package com.uten.imp.features.auth;

import com.uten.imp.audit.AuditService;
import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
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

    @Transactional(propagation = Propagation.REQUIRES_NEW)
    public void record(UUID userId, String loginAccount) {
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
                && attempts >= settings.readInt("lockout_threshold", 5)) {
            user.setStatus("locked");
            user.setLockedUntil(OffsetDateTime.now()
                    .plusMinutes(settings.readInt("lockout_minutes", 15)));
        }

        userRepo.save(user);
        audit.logExplicit(user.getId(), loginAccount, "login_failed",
                "users", user.getId().toString(), "bad_password");
    }
}
