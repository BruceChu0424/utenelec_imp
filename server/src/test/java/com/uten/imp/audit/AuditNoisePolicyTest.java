package com.uten.imp.audit;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class AuditNoisePolicyTest {

    private static final String UUID_VALUE =
            "123e4567-e89b-42d3-a456-426614174099";

    @Test
    void historicalAutomaticSuccessIsNoiseButFailureRemainsEvidence() {
        assertTrue(AuditNoisePolicy.isSuccessfulStoredAutomaticRequest(
                request("GET", "/api/notices/unread-count", 200, "success")));
        assertTrue(AuditNoisePolicy.isSuccessfulStoredAutomaticRequest(
                request("GET", "/api/admin/server-status", 200, "success")));
        assertFalse(AuditNoisePolicy.isSuccessfulStoredAutomaticRequest(
                request("GET", "/api/admin/server-status", 403, "denied")));
        assertTrue(AuditNoisePolicy.isSuccessfulStoredAutomaticRequest(
                request("POST", "/api/auth/refresh", 200, "succeeded;mode=rotated")));
        assertTrue(AuditNoisePolicy.isSuccessfulStoredAutomaticRequest(
                request("POST", "/api/task-claims/TYPE/key/heartbeat", 200, "success")));
        assertTrue(AuditNoisePolicy.isSuccessfulStoredAutomaticRequest(
                request("POST", "/api/notices/read-by-source", 200, "success")));
        assertTrue(AuditNoisePolicy.isSuccessfulStoredAutomaticRequest(
                request("POST", "/api/payroll/slips/" + UUID_VALUE + "/view",
                        200, "success")));
        assertTrue(AuditNoisePolicy.isSuccessfulStoredAutomaticRequest(
                request("GET", "/api/master/goods/facets", 200, "success")));
        assertTrue(AuditNoisePolicy.isSuccessfulStoredAutomaticRequest(
                request(
                        "GET",
                        "/api/sales/orders/" + UUID_VALUE + "/plan-progress",
                        200,
                        "succeeded")));

        assertFalse(AuditNoisePolicy.isSuccessfulStoredAutomaticRequest(
                request("GET", "/api/notices/unread-count", 503, "success")));
        assertFalse(AuditNoisePolicy.isSuccessfulStoredAutomaticRequest(
                request("POST", "/api/auth/refresh", 200, "failure")));
        assertFalse(AuditNoisePolicy.isSuccessfulStoredAutomaticRequest(
                request("POST", "/api/sales/orders", 200, "success")));
    }

    @Test
    void reviewedAutomaticPageReadsAreNoiseForGetAndHeadOnly() {
        List<String> automaticPaths = List.of(
                "/api/master/goods/facets",
                "/api/master/goods/lookup",
                "/api/master/clients/facets",
                "/api/master/clients/dict",
                "/api/master/suppliers/facets",
                "/api/master/suppliers/dict",
                "/api/master/accounts/facets",
                "/api/master/accounts/summary",
                "/api/master/accounts/dict",
                "/api/master/currencies/facets",
                "/api/master/currencies/dict",
                "/api/master/warehouses/facets",
                "/api/master/warehouses/dict",
                "/api/master/units/facets",
                "/api/master/units/dict",
                "/api/master/colors/facets",
                "/api/master/colors/dict",
                "/api/master/moulds/facets",
                "/api/master/client-categories/tree",
                "/api/master/supplier-categories/tree",
                "/api/master/material-categories/tree",
                "/api/master/mould-categories/tree",
                "/api/master/payment-styles/tree",
                "/api/org/departments/tree",
                "/api/org/departments/employee-picker-tree",
                "/api/my-department/tree",
                "/api/sales/orders/stats",
                "/api/sales/orders/progress",
                "/api/sales/orders/progress/stage-counts",
                "/api/production/plans/progress",
                "/api/production/plans/progress/summary",
                "/api/production/plans/progress/workshops",
                "/api/production/quality-inspections/count",
                "/api/production/quality-inspections/capability",
                "/api/purchase/orders/last-suppliers",
                "/api/subcontract/orders/last-suppliers");

        automaticPaths.forEach(path -> {
            assertTrue(AuditNoisePolicy.isAutomaticOperation("GET", path), path);
            assertTrue(AuditNoisePolicy.isAutomaticOperation("HEAD", path), path);
            assertFalse(AuditNoisePolicy.isAutomaticOperation("POST", path), path);
        });
    }

    @Test
    void dynamicAutomaticSubresourcesRequireOneExactUuidSegment() {
        List<String> automaticPaths = List.of(
                "/api/sales/orders/" + UUID_VALUE + "/plan-progress",
                "/api/sales/orders/" + UUID_VALUE + "/progress-timeline",
                "/api/sales/returns/" + UUID_VALUE + "/quality",
                "/api/subcontract/orders/" + UUID_VALUE + "/cost-items",
                "/api/subcontract/orders/" + UUID_VALUE + "/progress",
                "/api/production/material-analyses/" + UUID_VALUE
                        + "/materials/" + UUID_VALUE + "/supply-progress");
        automaticPaths.forEach(path ->
                assertTrue(AuditNoisePolicy.isAutomaticOperation("GET", path), path));

        assertFalse(AuditNoisePolicy.isAutomaticOperation(
                "GET", "/api/sales/orders/not-a-uuid/plan-progress"));
        assertFalse(AuditNoisePolicy.isAutomaticOperation(
                "GET", "/api/sales/orders/" + UUID_VALUE + "/extra/plan-progress"));
        assertFalse(AuditNoisePolicy.isAutomaticOperation(
                "GET", "/api/subcontract/orders/" + UUID_VALUE));
        assertFalse(AuditNoisePolicy.isAutomaticOperation(
                "POST", "/api/sales/returns/" + UUID_VALUE + "/quality"));
        assertTrue(AuditNoisePolicy.isAutomaticOperation(
                "POST", "/api/payroll/slips/" + UUID_VALUE + "/view"));
        assertFalse(AuditNoisePolicy.isAutomaticOperation(
                "POST", "/api/payroll/slips/not-a-uuid/view"));
    }

    @Test
    void historicalDynamicRoutesUseOneFixedLengthUuidLikeSegment() {
        String uuidLike = "________-____-____-____-____________";
        assertEquals(
                List.of(
                        "/api/sales/orders/" + uuidLike + "/plan-progress",
                        "/api/sales/orders/" + uuidLike + "/progress-timeline",
                        "/api/sales/returns/" + uuidLike + "/quality",
                        "/api/subcontract/orders/" + uuidLike + "/cost-items",
                        "/api/subcontract/orders/" + uuidLike + "/progress",
                        "/api/production/material-analyses/" + uuidLike
                                + "/materials/" + uuidLike + "/supply-progress"),
                AuditNoisePolicy.automaticReadSqlLikePatterns());
        AuditNoisePolicy.automaticReadSqlLikePatterns().forEach(pattern ->
                assertFalse(pattern.contains("%"), pattern));
        assertEquals(
                List.of("/api/payroll/slips/" + uuidLike + "/view"),
                AuditNoisePolicy.automaticSessionWriteSqlLikePatterns());
    }

    @Test
    void listsSearchDetailsExportsDownloadsApprovalsAndFailuresRemainEvidence() {
        List<String> ordinaryReads = List.of(
                "/api/master/goods",
                "/api/master/goods/search-category-ids",
                "/api/sales/orders",
                "/api/sales/orders/" + UUID_VALUE,
                "/api/admin/audit-logs/export",
                "/api/attachments/" + UUID_VALUE + "/download");
        ordinaryReads.forEach(path ->
                assertFalse(AuditNoisePolicy.isAutomaticOperation("GET", path), path));
        assertFalse(AuditNoisePolicy.isAutomaticOperation(
                "POST", "/api/sales/orders/" + UUID_VALUE + "/approve"));
        assertFalse(AuditNoisePolicy.isAutomaticOperation(
                "PUT", "/api/master/goods/" + UUID_VALUE));

        assertFalse(AuditNoisePolicy.isSuccessfulStoredAutomaticRequest(
                request("GET", "/api/master/goods/facets", 404, "success")));
        assertFalse(AuditNoisePolicy.isSuccessfulStoredAutomaticRequest(
                request(
                        "GET",
                        "/api/sales/orders/" + UUID_VALUE + "/plan-progress",
                        500,
                        "success")));
        assertFalse(AuditNoisePolicy.isSuccessfulStoredAutomaticRequest(
                request("GET", "/api/master/accounts/summary", 200, "failure")));
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
        assertTrue(querySide.contains(
                "AuditNoisePolicy.automaticReadSqlLikePatterns"));
        assertTrue(querySide.contains(
                "AuditNoisePolicy.automaticSessionWriteSqlLikePatterns"));
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
