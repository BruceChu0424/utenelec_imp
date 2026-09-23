package com.uten.imp.features.visitor;

import com.uten.imp.audit.AuditService;
import com.uten.imp.features.auth.AuthSessionService;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.util.UUID;

/**
 * Revokes all visitor refresh tokens after reuse is detected.
 */
@Service
public class VisitorRefreshCompromiseService {

    private final VisitorRefreshTokenRepository tokens;
    private final AuditService audit;
    private final AuthSessionService sessions;

    public VisitorRefreshCompromiseService(VisitorRefreshTokenRepository tokens,
                                           AuditService audit,
                                           AuthSessionService sessions) {
        this.tokens = tokens;
        this.audit = audit;
        this.sessions = sessions;
    }

    @Transactional(propagation = Propagation.REQUIRES_NEW)
    public void revoke(UUID visitorId, UUID reusedTokenId, UUID sessionId) {
        tokens.revokeAllByVisitorAccountId(visitorId);
        sessions.revokeAllForVisitor(visitorId, AuthSessionService.REASON_REFRESH_REUSE);
        audit.logExplicit(visitorId, null, "visitor_refresh_reuse",
                "visitor_refresh_token", reusedTokenId.toString(),
                "reuse_detected", sessionId);
    }
}
