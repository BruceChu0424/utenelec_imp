package com.uten.imp.features.visitor;

import com.uten.imp.audit.AuditService;
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

    public VisitorRefreshCompromiseService(VisitorRefreshTokenRepository tokens,
                                           AuditService audit) {
        this.tokens = tokens;
        this.audit = audit;
    }

    @Transactional(propagation = Propagation.REQUIRES_NEW)
    public void revoke(UUID visitorId, UUID reusedTokenId) {
        tokens.revokeAllByVisitorAccountId(visitorId);
        audit.logExplicit(visitorId, null, "visitor_refresh_reuse",
                "visitor_refresh_token", reusedTokenId.toString(), "reuse_detected");
    }
}
