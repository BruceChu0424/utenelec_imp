package com.uten.imp.audit;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class AuditNoisePolicyTest {

    @Test
    void historicalAutomaticSuccessIsNoiseButFailureRemainsEvidence() {
        assertTrue(AuditNoisePolicy.isSuccessfulStoredAutomaticRequest(
                request("GET", "/api/notices/unread-count", 200, "success")));
        assertTrue(AuditNoisePolicy.isSuccessfulStoredAutomaticRequest(
                request("POST", "/api/auth/refresh", 200, "succeeded;mode=rotated")));
        assertTrue(AuditNoisePolicy.isSuccessfulStoredAutomaticRequest(
                request("POST", "/api/task-claims/TYPE/key/heartbeat", 200, "success")));
        assertTrue(AuditNoisePolicy.isSuccessfulStoredAutomaticRequest(
                request("POST", "/api/notices/read-by-source", 200, "success")));

        assertFalse(AuditNoisePolicy.isSuccessfulStoredAutomaticRequest(
                request("GET", "/api/notices/unread-count", 503, "success")));
        assertFalse(AuditNoisePolicy.isSuccessfulStoredAutomaticRequest(
                request("POST", "/api/auth/refresh", 200, "failure")));
        assertFalse(AuditNoisePolicy.isSuccessfulStoredAutomaticRequest(
                request("POST", "/api/sales/orders", 200, "success")));
    }

    @Test
    void writeAndReadSidesReferenceTheSingleReviewedPolicy() throws Exception {
        String requestSide = Files.readString(Path.of(
                "src/main/java/com/uten/imp/audit/AuditRequestContext.java"),
                StandardCharsets.UTF_8);
        String querySide = Files.readString(Path.of(
                "src/main/java/com/uten/imp/audit/AuditQueryService.java"),
                StandardCharsets.UTF_8);

        assertTrue(requestSide.contains("AuditNoisePolicy.isAutomaticOperation"));
        assertTrue(querySide.contains("AuditNoisePolicy.automaticReadPaths"));
        assertTrue(querySide.contains("AuditNoisePolicy.automaticSessionWritePaths"));
        assertTrue(querySide.contains("AuditNoisePolicy.heartbeatSqlLikePattern"));
    }

    private AuditLog request(String method, String path, int status, String result) {
        AuditLog value = new AuditLog();
        value.setEventSource("request");
        value.setHttpMethod(method);
        value.setHttpPath(path);
        value.setStatusCode(status);
        value.setResult(result);
        return value;
    }
}
