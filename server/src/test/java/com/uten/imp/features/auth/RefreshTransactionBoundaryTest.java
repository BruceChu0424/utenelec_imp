package com.uten.imp.features.auth;

import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.auth.model.RefreshTokenRepository;
import com.uten.imp.features.visitor.VisitorAuthService;
import com.uten.imp.features.visitor.VisitorRefreshCompromiseService;
import com.uten.imp.features.visitor.VisitorRefreshTokenRepository;
import com.uten.imp.features.visitor.VisitorRefreshTransaction;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.lang.reflect.Method;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class RefreshTransactionBoundaryTest {

    @Mock
    private RefreshTokenRepository staffTokens;
    @Mock
    private VisitorRefreshTokenRepository visitorTokens;
    @Mock
    private AuditService audit;
    @Mock
    private StaffRefreshTransaction staffRotation;
    @Mock
    private StaffRefreshCompromiseService staffCompromise;

    @Test
    void compromiseRevocationsUseIndependentTransactions() throws Exception {
        assertRequiresNew(
                StaffRefreshCompromiseService.class
                        .getMethod("revoke", UUID.class, UUID.class));
        assertRequiresNew(
                VisitorRefreshCompromiseService.class
                        .getMethod("revoke", UUID.class, UUID.class));
    }

    @Test
    void throwingFacadesDoNotWrapReuseRevocationInAnOuterTransaction()
            throws Exception {
        assertNull(TokenIssuer.class
                .getMethod("refresh", String.class)
                .getAnnotation(Transactional.class));
        assertNull(VisitorAuthService.class
                .getMethod("refresh", String.class, String.class)
                .getAnnotation(Transactional.class));
        assertNotNull(StaffRefreshTransaction.class
                .getMethod("rotate", String.class)
                .getAnnotation(Transactional.class));
        assertNotNull(VisitorRefreshTransaction.class
                .getMethod("rotate", String.class, String.class)
                .getAnnotation(Transactional.class));
    }

    @Test
    void staffCompromiseServiceRevokesFamilyAndAudits() {
        StaffRefreshCompromiseService service =
                new StaffRefreshCompromiseService(staffTokens, audit);
        UUID userId = UUID.randomUUID();
        UUID tokenId = UUID.randomUUID();

        service.revoke(userId, tokenId);

        verify(staffTokens).revokeAllByUserId(userId);
        verify(audit).logExplicit(userId, null, "refresh_reuse",
                "refresh_tokens", tokenId.toString(), "reuse_detected");
    }

    @Test
    void visitorCompromiseServiceRevokesFamilyAndAudits() {
        VisitorRefreshCompromiseService service =
                new VisitorRefreshCompromiseService(visitorTokens, audit);
        UUID visitorId = UUID.randomUUID();
        UUID tokenId = UUID.randomUUID();

        service.revoke(visitorId, tokenId);

        verify(visitorTokens).revokeAllByVisitorAccountId(visitorId);
        verify(audit).logExplicit(visitorId, null, "visitor_refresh_reuse",
                "visitor_refresh_token", tokenId.toString(), "reuse_detected");
    }

    @Test
    void tokenIssuerRevokesBeforeReportingReuseAsUnauthorized() {
        UUID userId = UUID.randomUUID();
        UUID tokenId = UUID.randomUUID();
        UUID sessionId = UUID.randomUUID();
        when(staffRotation.rotate("reused"))
                .thenReturn(new StaffRefreshTransaction.Outcome(
                        true, userId, tokenId, sessionId, null, null));
        TokenIssuer issuer = new TokenIssuer(
                null,
                null,
                null,
                staffRotation,
                staffCompromise,
                null,
                audit);

        assertThrows(ApiException.class, () -> issuer.refresh("reused"));
        verify(staffCompromise).revoke(userId, tokenId, sessionId);
    }

    private void assertRequiresNew(Method method) {
        Transactional transactional = method.getAnnotation(Transactional.class);
        assertNotNull(transactional);
        assertEquals(Propagation.REQUIRES_NEW, transactional.propagation());
    }
}
