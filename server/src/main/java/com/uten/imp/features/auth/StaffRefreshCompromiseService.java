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
    private final AuthSessionService sessions;

    public StaffRefreshCompromiseService(RefreshTokenRepository tokens,
                                         AuditService audit,
                                         AuthSessionService sessions) {
        this.tokens = tokens;
        this.audit = audit;
        this.sessions = sessions;
    }

    /** 旧刷新令牌在仍然有效的会话里被重放: 视为令牌被盗, 该员工全部会话与刷新令牌一起作废。 */
    @Transactional(propagation = Propagation.REQUIRES_NEW)
    public void revoke(UUID userId, UUID reusedTokenId, UUID sessionId) {
        tokens.revokeAllByUserId(userId);
        sessions.revokeAllForUser(userId, AuthSessionService.REASON_REFRESH_REUSE);
        audit.logExplicit(userId, null, "refresh_reuse", "refresh_tokens",
                reusedTokenId.toString(), "reuse_detected", sessionId);
    }
}
