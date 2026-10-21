package com.uten.imp.security;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.audit.AuditService;
import org.junit.jupiter.api.Test;
import org.springframework.mock.web.MockFilterChain;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.mock.web.MockHttpServletResponse;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;

import java.util.List;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.mock;

class CostBootstrapReadOnlyRouteContractTest {
    @Test void onlyTheExactCostPreparationPostRetainsReadOnlyBrowsingEligibility() {
        String path = "/api/master/goods/cost-sheets/bootstrap";
        assertTrue(ImpersonationWriteGuardFilter.readOnlyCostBootstrap("POST", path));
        for (String method : List.of("GET", "PUT", "PATCH", "DELETE")) {
            assertFalse(ImpersonationWriteGuardFilter.readOnlyCostBootstrap(method, path));
        }
        for (String other : List.of(path + "/", path + "/../confirm", path + "/confirm",
                "/api/master/goods/cost-sheets", "/api/master/goods/cost-sheets/preview")) {
            assertFalse(ImpersonationWriteGuardFilter.readOnlyCostBootstrap("POST", other));
        }
    }

    @Test void simulatedStaffMayPrepareTheSameCostViewButCannotDownloadOriginalsOrWriteCostData() throws Exception {
        var actor = new AuthUser(UUID.randomUUID(), UUID.randomUUID(), "simulated-cost-reader",
                Set.of("goods:view", "goods:cost:view"), false, true, false, false, UUID.randomUUID());
        SecurityContextHolder.getContext().setAuthentication(
                new UsernamePasswordAuthenticationToken(actor, null, actor.getAuthorities()));
        var filter = new ImpersonationWriteGuardFilter(new ObjectMapper(), mock(AuditService.class));
        try {
            var read = new MockHttpServletRequest("POST", "/app/api/master/goods/cost-sheets/bootstrap");
            read.setContextPath("/app");
            var readChain = new MockFilterChain();
            filter.doFilter(read, new MockHttpServletResponse(), readChain);
            assertSame(read, readChain.getRequest());
            for (String path : List.of("/api/master/goods/cost-sheets", "/api/master/goods/cost-sheets/confirm",
                    "/api/sales/quotes/" + UUID.randomUUID() + "/input-originals/" + UUID.randomUUID() + "/download")) {
                var write = new MockHttpServletRequest("POST", path);
                var response = new MockHttpServletResponse();
                var chain = new MockFilterChain();
                filter.doFilter(write, response, chain);
                assertEquals(403, response.getStatus());
                assertNull(chain.getRequest());
            }
        } finally {
            SecurityContextHolder.clearContext();
        }
    }
}
