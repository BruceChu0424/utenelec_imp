package com.uten.imp.audit;

import org.junit.jupiter.api.Test;

import java.util.Map;
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

    @Test
    void labelsCoreDatabaseTargetsInChinese() {
        Map<String, String> expected = Map.ofEntries(
                Map.entry("goods", "货品"),
                Map.entry("material_categories", "货品分类"),
                Map.entry("mould_categories", "模具分类"),
                Map.entry("client_categories", "客户分类"),
                Map.entry("supplier_categories", "供应商分类"),
                Map.entry("clients", "客户"),
                Map.entry("suppliers", "供应商"),
                Map.entry("stock_balances", "即时库存"),
                Map.entry("sales_orders", "销售订单"),
                Map.entry("user_permission_overrides", "个人权限"),
                Map.entry("finance_asset_categories", "资产/待摊分类"),
                Map.entry("finance_asset_books", "固定资产账簿"),
                Map.entry("finance_deferral_schedule_versions", "待摊计划版本"),
                Map.entry("finance_deferral_schedule_lines", "待摊计划明细"),
                Map.entry("finance_asset_approval_steps", "资产审批步骤"),
                Map.entry("finance_asset_events", "资产业务事件"),
                Map.entry("finance_asset_accounting_periods", "资产会计期间"),
                Map.entry("finance_asset_posting_runs", "折旧摊销过账批次"),
                Map.entry("finance_asset_posting_lines", "折旧摊销过账明细"),
                Map.entry("deferred_expenses", "待摊费用"));

        expected.forEach((targetType, label) -> {
            AuditLog log = new AuditLog();
            log.setAction("insert");
            log.setTargetType(targetType);
            log.setTargetId("target-id");
            log.setResult("success");

            AuditEventInterpreter.InterpretedEvent event = interpreter.interpret(log);
            assertEquals(label, event.objectLabel(), targetType);
            assertEquals("新增/发起 · " + label, event.summary(), targetType);
        });
    }

    @Test
    void labelsMasterDataRoutesInChinese() {
        Map<String, String> expected = Map.of(
                "/api/master/goods", "货品",
                "/api/master/material-categories", "货品分类",
                "/api/master/mould-categories", "模具分类",
                "/api/master/client-categories", "客户分类",
                "/api/master/supplier-categories", "供应商分类");

        expected.forEach((path, label) -> {
            AuditEventInterpreter.InterpretedEvent event = interpreter.interpret(
                    request("http_post", path));
            assertEquals(label, event.objectLabel(), path);
            assertEquals("新增/发起 · " + label, event.summary(), path);
        });
    }

    @Test
    void labelsHistoricalSoftDeleteUpdatesAsDeletes() {
        AuditLog log = new AuditLog();
        log.setAction("update");
        log.setTargetType("goods");
        log.setTargetId(UUID.randomUUID().toString());
        log.setBefore("""
                {"is_deleted":false,"deleted_at":null}
                """);
        log.setAfter("""
                {"is_deleted":true,"deleted_at":"2026-08-01T06:00:00Z"}
                """);
        log.setResult("success");
        // V169 stored historical UPDATE transitions as low risk.
        log.setRiskLevel("low");

        AuditEventInterpreter.InterpretedEvent event = interpreter.interpret(log);

        assertEquals("删除", event.actionLabel());
        assertEquals("删除 · 货品", event.summary());
        assertEquals("high", event.riskLevel());
        assertEquals("data_change", event.category());
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
