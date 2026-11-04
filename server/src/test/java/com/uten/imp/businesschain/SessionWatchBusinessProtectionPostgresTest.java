package com.uten.imp.businesschain;

import com.uten.imp.features.auth.SessionWatchService;
import jakarta.servlet.AsyncEvent;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.Timeout;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.mock.web.MockAsyncContext;
import org.springframework.test.web.servlet.MvcResult;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.asyncDispatch;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;

/** Pending authentication observers must leave connection capacity and all write guards intact. */
class SessionWatchBusinessProtectionPostgresTest extends AuthSessionPostgresTestSupport {
    @Autowired SessionWatchService watches;

    @Test
    @Timeout(60)
    void sixteenPendingWatchesLeaveCapacityForReauthenticationAndProtectedWrites() throws Exception {
        String admin = adminToken();
        Employee employee = newEmployee(admin);
        List<MvcResult> adminWatches = new ArrayList<>();
        List<MvcResult> employeeWatches = new ArrayList<>();
        try {
            // More waits than the fixture's eight-connection JDBC pool. Each wait
            // must have returned its connection and servlet request thread already.
            for (int index = 0; index < 8; index++) {
                adminWatches.add(watch(admin));
                employeeWatches.add(watch(employee.accessToken()));
            }
            MvcResult withoutProof = mvc.perform(json(
                    post("/api/admin/users/" + employee.userId() + "/reset-password"), Map.of(), admin))
                    .andReturn();
            assertEquals(403, withoutProof.getResponse().getStatus(), body(withoutProof));
            assertEquals("REAUTH_REQUIRED", json(withoutProof).path("code").asText());
            String proof = stepUp(admin, ADMIN_PASSWORD);
            MvcResult accepted = mvc.perform(json(
                    post("/api/admin/users/" + employee.userId() + "/reset-password"), Map.of(), admin)
                    .header("X-Uten-Step-Up", proof)).andReturn();
            assertEquals(200, accepted.getResponse().getStatus(), body(accepted));
            assertTrue(json(accepted).path("temporaryPassword").isTextual());

            watches.reconcile();
            for (MvcResult pending : employeeWatches) {
                pending.getAsyncResult(2000);
                MvcResult ended = mvc.perform(asyncDispatch(pending)).andReturn();
                assertEquals(200, ended.getResponse().getStatus(), body(ended));
                assertEquals("expired", json(ended).path("status").asText());
            }
            for (MvcResult pending : adminWatches) assertFalse(
                    org.springframework.web.context.request.async.WebAsyncUtils
                            .getAsyncManager(pending.getRequest()).hasConcurrentResult());
            assertEquals(200, me(admin).getResponse().getStatus(), "写入后操作者原会话仍可用");
            assertEquals(401, me(employee.accessToken()).getResponse().getStatus(), "目标原凭证已立即撤销");
        } finally {
            for (MvcResult pending : adminWatches) timeoutAndFinish(pending);
            for (MvcResult pending : employeeWatches) timeoutAndFinish(pending);
        }
    }

    private MvcResult watch(String token) throws Exception {
        MvcResult pending = mvc.perform(get("/api/auth/session/watch")
                .header("Authorization", "Bearer " + token)).andReturn();
        assertTrue(pending.getRequest().isAsyncStarted(), body(pending));
        return pending;
    }

    private void timeoutAndFinish(MvcResult pending) throws Exception {
        if (!pending.getRequest().isAsyncStarted()) return;
        MockAsyncContext async = (MockAsyncContext) pending.getRequest().getAsyncContext();
        for (var listener : async.getListeners()) listener.onTimeout(new AsyncEvent(async));
        mvc.perform(asyncDispatch(pending));
    }
}
