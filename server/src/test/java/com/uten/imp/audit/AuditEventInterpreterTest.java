package com.uten.imp.audit;

import org.junit.jupiter.api.Test;

import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;

class AuditEventInterpreterTest {

    private final AuditEventInterpreter interpreter = new AuditEventInterpreter();

    @Test
    void keepsPermissionReadLowRiskAndLabelsItAsAView() {
        AuditLog log = request("http_get", "/api/admin/permissions");

        AuditEventInterpreter.InterpretedEvent event = interpreter.interpret(log);

        assertEquals("查看", event.actionLabel());
        assertEquals("权限配置", event.objectLabel());
        assertEquals("low", event.riskLevel());
        assertEquals("authorization", event.category());
    }

    @Test
    void classifiesPermissionWriteAsHighRisk() {
        AuditLog log = request("http_patch", "/api/admin/permissions");

        AuditEventInterpreter.InterpretedEvent event = interpreter.interpret(log);

        assertEquals("调整权限", event.actionLabel());
        assertEquals("high", event.riskLevel());
        assertEquals("涉及权限或数据可见范围变更", event.riskReason());
    }

    @Test
    void labelsRoutineAuditInvestigationReadsAsLowRiskSecurityEvents() {
        assertAuditInvestigation(
                "view_audit_log_list",
                "查看审计日志列表",
                "low",
                "授权人员进行常规审计核查");
        assertAuditInvestigation(
                "view_audit_log_summary",
                "查看审计统计",
                "low",
                "授权人员进行常规审计核查");
    }

    @Test
    void upgradesSensitiveAuditEvidenceAccessEvenWhenStoredClassificationIsLow() {
        assertAuditInvestigation(
                "view_audit_log_detail",
                "查看审计日志详情",
                "medium",
                "访问敏感审计证据");
        assertAuditInvestigation(
                "verify_local_audit_receipt",
                "核查本机操作回执",
                "medium",
                "访问敏感审计证据");
    }

    @Test
    void treatsPayrollSlipDownloadAsReadableMediumRiskDataExport() {
        AuditLog log = new AuditLog();
        log.setAction("download_payroll_slip");
        log.setTargetType("payroll_slips");
        log.setTargetId(UUID.randomUUID().toString());
        log.setHttpPath("/api/payroll/slips/ignored/download");
        log.setResult("success");
        log.setStatusCode(200);
        // Mirrors the stored generated-column fallback for this explicit action.
        log.setRiskLevel("low");
        log.setEventCategory("business");

        AuditEventInterpreter.InterpretedEvent event = interpreter.interpret(log);

        assertEquals("下载工资条 PDF", event.actionLabel());
        assertEquals("工资条", event.objectLabel());
        assertEquals("medium", event.riskLevel());
        assertEquals("工资条 PDF 被下载到系统外部，需关注使用范围", event.riskReason());
        assertEquals("export", event.category());
    }

    private void assertAuditInvestigation(
            String action,
            String expectedLabel,
            String expectedRisk,
            String expectedReason) {
        AuditLog log = new AuditLog();
        log.setAction(action);
        log.setTargetType("audit_log");
        log.setHttpPath("/api/admin/audit-logs");
        log.setResult("success");
        log.setStatusCode(200);
        // Mirrors the current generated-column fallback for newly introduced actions.
        log.setRiskLevel("low");
        log.setEventCategory("business");

        AuditEventInterpreter.InterpretedEvent event = interpreter.interpret(log);

        assertEquals(expectedLabel, event.actionLabel());
        assertEquals("审计日志", event.objectLabel());
        assertEquals(expectedRisk, event.riskLevel());
        assertEquals(expectedReason, event.riskReason());
        assertEquals("security", event.category());
    }

    private AuditLog request(String action, String path) {
        AuditLog log = new AuditLog();
        log.setAction(action);
        log.setTargetType("api/admin/permissions");
        log.setHttpPath(path);
        log.setResult("success");
        log.setStatusCode(200);
        return log;
    }
}
