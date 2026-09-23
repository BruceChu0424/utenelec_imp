package com.uten.imp.audit;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** 风险等级与事件类型只在写入时按明确目录算一次(ADR-105, audit-retention-settings-05)。 */
class AuditClassifierTest {

    private static AuditClassifier.Classification classify(
            String source, String action, String targetType, String path, String result, Integer status) {
        return AuditClassifier.classify(source, action, targetType, path, result, status);
    }

    @Test
    void semanticWritesAreGradedByVerbAndResource() {
        assertEquals(new AuditClassifier.Classification("low", "business"),
                classify("business", "sales_order.approve", "sales_order", "/api/sales/orders/1/approve", "success", 200));
        assertEquals(new AuditClassifier.Classification("high", "business"),
                classify("business", "stock_doc.reverse", "stock_doc", "/api/stock/docs/1/reverse", "success", 200));
        assertEquals(new AuditClassifier.Classification("high", "business"),
                classify("business", "goods_bom.batch_delete", "goods_bom", "/x", "success", 200));
        assertEquals(new AuditClassifier.Classification("high", "authorization"),
                classify("business", "admin_permission.set_department_permissions", "admin_permission", "/x", "success", 200));
        assertEquals(new AuditClassifier.Classification("high", "system"),
                classify("business", "system_setting.update", "system_setting", "/x", "success", 200));
        assertEquals(new AuditClassifier.Classification("medium", "export"),
                classify("business", "goods.export", "goods", "/x", "success", 200));
        assertEquals(new AuditClassifier.Classification("medium", "business"),
                classify("business", "sales_order.approve", "sales_order", "/x", "failure", 409),
                "a failed ordinary write is worth a look but is not a key action");
        assertEquals("low",
                classify("business", "sales_order.adjust_item_qty", "sales_order", "/x", "success", 200).riskLevel(),
                "quantity revision is not a balance adjustment");
        assertEquals("high",
                classify("business", "stock_balance_adjustment.adjust", "x", "/x", "success", 200).riskLevel());
    }

    @Test
    void auditEvidenceAccessIsSecurityAndDetailOrSessionReadsAreMedium() {
        assertEquals(new AuditClassifier.Classification("low", "security"),
                classify("business", "view_audit_log_list", "audit_log", "/api/admin/audit-logs", "success", 200));
        for (String action : new String[]{"view_audit_log_detail", "verify_local_audit_receipt",
                "view_audit_session_list", "view_audit_session_detail", "view_audit_session_events"}) {
            assertEquals(new AuditClassifier.Classification("medium", "security"),
                    classify("business", action, "audit_log", "/api/admin/audit-logs", "success", 200), action);
        }
    }

    @Test
    void sensitiveDetailViewsExportsAndCredentialsAreMedium() {
        assertEquals(new AuditClassifier.Classification("medium", "business"),
                classify("business", "view_employee_detail", "employees", null, "success", null));
        assertEquals(new AuditClassifier.Classification("low", "business"),
                classify("business", "view_goods_detail", "goods", null, "success", null));
        assertEquals(new AuditClassifier.Classification("medium", "export"),
                classify("business", "download_payroll_slip", "payroll_slips", null, "success", null));
        assertEquals(new AuditClassifier.Classification("medium", "authentication"),
                classify("business", "login_failed", "users", "/api/auth/login", "bad_credentials", null));
        assertEquals(new AuditClassifier.Classification("low", "authentication"),
                classify("business", "login", "users", "/api/auth/login", "success", null));
        assertEquals(new AuditClassifier.Classification("critical", "security"),
                classify("business", "refresh_reuse", "refresh_tokens", null, "reuse_detected", null));
    }

    @Test
    void securityAndSystemEventsKeepTheirOwnVocabulary() {
        assertEquals(new AuditClassifier.Classification("medium", "security"),
                classify("security", "access_denied", "api_request", "/api/notices", "unauthorized", 401));
        assertEquals(new AuditClassifier.Classification("low", "system"),
                classify("system", "audit_retention_completed", "audit_retention", null, "success", null));
        assertEquals(new AuditClassifier.Classification("medium", "system"),
                classify("business", "audit_retention_failed", "audit_retention", null, "failure", null));
        assertEquals(new AuditClassifier.Classification("high", "authorization"),
                classify("business", "impersonation_enter", "users", null, "success", null));
        assertEquals(new AuditClassifier.Classification("high", "system"),
                classify("business", "update_system_setting", "system_settings", null, "success", null));
    }

    @Test
    void readingAPermissionPageIsNotAnAuthorizationChange() {
        assertEquals(new AuditClassifier.Classification("low", "business"),
                classify("request", "http_get", "api/department-staff-permissions",
                        "/api/department-staff-permissions/capability", "success", 200),
                "substring matching used to file badge polls under authorization");
        assertEquals(new AuditClassifier.Classification("high", "business"),
                classify("request", "http_delete", "api/task-claims", "/api/task-claims/x/y", "success", 200));
    }

    @Test
    void highRiskVerbsMatchWholeWordsOnly() {
        assertTrue(AuditClassifier.isHighRiskVerb("reverse_issue"));
        assertTrue(AuditClassifier.isHighRiskVerb("finance_audit_reverse"));
        assertTrue(AuditClassifier.isHighRiskVerb("delete_contact"));
        assertTrue(AuditClassifier.isHighRiskVerb("unlock_account"));
        assertFalse(AuditClassifier.isHighRiskVerb("approve"));
        assertFalse(AuditClassifier.isHighRiskVerb("adjust_item_qty"));
        assertFalse(AuditClassifier.isHighRiskVerb("release"));
    }
}
