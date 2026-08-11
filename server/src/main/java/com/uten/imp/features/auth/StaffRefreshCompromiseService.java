package com.uten.imp.features.auth;

import com.uten.imp.audit.AuditService;
import com.uten.imp.features.auth.model.RefreshTokenRepository;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.util.UUID;

/**
 * Revokes all staff refresh tokens after reuse is detected.
 */
@Service
public class StaffRefreshCompromiseService {

    private final RefreshTokenRepository tokens;
    private final AuditService audit;

    public StaffRefreshCompromiseService(RefreshTokenRepository tokens,
                                         AuditService audit) {
        this.tokens = tokens;
        this.audit = audit;
    }

    @Transactional(propagation = Propagation.REQUIRES_NEW)
    public void revoke(UUID userId, UUID reusedTokenId) {
        tokens.revokeAllByUserId(userId);
        audit.logExplicit(userId, null, "refresh_reuse", "refresh_tokens",
                reusedTokenId.toString(), "reuse_detected");
    }
}
