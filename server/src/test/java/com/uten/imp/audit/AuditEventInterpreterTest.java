package com.uten.imp.audit;

import org.junit.jupiter.api.Test;

import java.util.Map;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

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
            log.setEventSource("database");

            AuditEventInterpreter.InterpretedEvent event = interpreter.interpret(log);
            assertEquals(label, event.objectLabel(), targetType);
            assertEquals("新增" + label, event.summary(), targetType);
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
            assertEquals("新增" + label, event.summary(), path);
        });
    }

    @Test
    void buildsDetailedChineseSummaryWithInlineFieldChanges() {
        AuditLog log = new AuditLog();
        log.setAction("update");
        log.setTargetType("sales_orders");
        log.setTargetId(UUID.randomUUID().toString());
        log.setBefore("""
                {"id":"1","doc_no":"SO-2026-001","status":"draft","remark":null,
                 "priority":1,"updated_at":"2026-08-01T00:00:00Z"}
                """);
        log.setAfter("""
                {"id":"1","doc_no":"SO-2026-001","status":"approved","remark":"加急",
                 "priority":9,"updated_at":"2026-08-02T00:00:00Z"}
                """);
        log.setResult("success");

        AuditEventInterpreter.InterpretedEvent event = interpreter.interpret(log);

        assertEquals("修改销售订单 SO-2026-001"
                + "：状态：草稿 → 已审核；备注：空 → 加急等 3 项变更",
                event.summary());
        assertEquals("状态：草稿 → 已审核；备注：空 → 加急；优先级：1 → 9",
                event.changeSummary());
        assertEquals("成功", event.resultLabel());
    }

    @Test
    void capsDetailChangeEntriesAndPointsToTheChangeTab() {
        StringBuilder before = new StringBuilder("{");
        StringBuilder after = new StringBuilder("{");
        for (int i = 1; i <= 8; i++) {
            if (i > 1) {
                before.append(',');
                after.append(',');
            }
            before.append("\"f").append(i).append("\":").append(i);
            after.append("\"f").append(i).append("\":").append(i + 100);
        }
        before.append('}');
        after.append('}');
        AuditLog log = new AuditLog();
        log.setAction("update");
        log.setTargetType("goods");
        log.setTargetId(UUID.randomUUID().toString());
        log.setBefore(before.toString());
        log.setAfter(after.toString());
        log.setResult("success");

        AuditEventInterpreter.InterpretedEvent event = interpreter.interpret(log);

        assertTrue(event.changeSummary().contains("f1：1 → 101"), event.changeSummary());
        assertTrue(event.changeSummary().contains("另有 2 项变更见「数据变更」标签页"),
                event.changeSummary());
    }

    @Test
    void describesInsertAndDeleteInformationVolume() {
        AuditLog insert = new AuditLog();
        insert.setAction("insert");
        insert.setTargetType("goods");
        insert.setTargetId(UUID.randomUUID().toString());
        insert.setAfter("""
                {"id":"1","code":"G001","name":"轴承","spec":"6204"}
                """);
        insert.setResult("success");

        AuditEventInterpreter.InterpretedEvent insertEvent = interpreter.interpret(insert);

        assertEquals("新增货品 轴承", insertEvent.summary());
        assertEquals("新建记录，共填写 3 项信息", insertEvent.changeSummary());

        AuditLog delete = new AuditLog();
        delete.setAction("delete");
        delete.setTargetType("sales_orders");
        delete.setTargetId(UUID.randomUUID().toString());
        delete.setBefore("""
                {"id":"1","doc_no":"SO-2026-009","status":"draft"}
                """);
        delete.setResult("success");

        AuditEventInterpreter.InterpretedEvent deleteEvent = interpreter.interpret(delete);

        assertEquals("删除销售订单 SO-2026-009", deleteEvent.summary());
        assertEquals("删除了整条记录（含 2 项信息）", deleteEvent.changeSummary());
    }

    @Test
    void translatesResultCodesAndFailureSummariesIntoChinese() {
        assertEquals("成功", interpreter.resultLabel("success", 200));
        assertEquals("密码错误", interpreter.resultLabel("bad_password", null));
        assertEquals("尝试过于频繁（已限流）", interpreter.resultLabel("rate_limited", null));
        assertEquals("成功；方式：系统随机生成",
                interpreter.resultLabel("success;mode=generated", 200));
        assertEquals("失败（HTTP 403）", interpreter.resultLabel("", 403));
        assertEquals("失败", interpreter.resultLabel("success", 500));

        AuditLog failed = request("http_put", "/api/master/goods");
        failed.setResult("failure");
        AuditEventInterpreter.InterpretedEvent event = interpreter.interpret(failed);
        assertEquals("修改货品（失败）", event.summary());
        assertEquals("失败", event.resultLabel());
    }

    @Test
    void labelsNoticeAndTaskClaimUserActionsInChinese() {
        AuditLog publish = new AuditLog();
        publish.setAction("notice_publish");
        publish.setTargetType("notices");
        publish.setTargetId("关于国庆放假安排的通知");
        publish.setEventSource("business");
        publish.setResult("success");
        publish.setHttpPath("/api/notices");

        AuditEventInterpreter.InterpretedEvent publishEvent = interpreter.interpret(publish);
        assertEquals("发布通知", publishEvent.actionLabel());
        assertEquals("发布通知 关于国庆放假安排的通知", publishEvent.summary());
        assertEquals("工作台 · 通知", publishEvent.pageLabel());

        AuditLog claim = new AuditLog();
        claim.setAction("hr_task_claim");
        claim.setTargetType("hr_task_claims");
        claim.setTargetId("confirm · 张三");
        claim.setEventSource("business");
        claim.setResult("success");
        claim.setHttpPath("/api/org/hr-tasks/claims");

        AuditEventInterpreter.InterpretedEvent claimEvent = interpreter.interpret(claim);
        assertEquals("认领HR任务", claimEvent.actionLabel());
        assertEquals("认领HR任务 confirm · 张三", claimEvent.summary());
        assertEquals("人事 · HR任务中心", claimEvent.pageLabel());

        // 认领端点的请求覆盖行也要显示成具体动作，而不是泛化的"新增"
        AuditEventInterpreter.InterpretedEvent httpEvent = interpreter.interpret(
                request("http_post", "/api/org/hr-tasks/claims"));
        assertEquals("认领任务", httpEvent.actionLabel());
        assertEquals("认领任务 · HR任务中心", httpEvent.summary());
    }

    @Test
    void businessTargetNameIgnoresPathsUuidsAndStatStrings() {
        AuditLog log = new AuditLog();
        log.setAction("view_audit_log_list");
        log.setTargetType("audit_log");
        log.setTargetId("page=1;size=20;total=88");
        log.setEventSource("business");
        log.setResult("success");

        AuditEventInterpreter.InterpretedEvent event = interpreter.interpret(log);
        assertEquals("", event.targetName());
    }

    @Test
    void labelsNoticeAndExportActionsInReadableChinese() {
        AuditLog export = new AuditLog();
        export.setAction("export_purchase_report");
        export.setTargetType("purchase_reports");
        export.setTargetId("2026-08-29/128rows");
        export.setResult("success");

        AuditEventInterpreter.InterpretedEvent exportEvent = interpreter.interpret(export);
        assertEquals("导出采购报表", exportEvent.actionLabel());
        // 导出是显式事件（targetId 放了日期/行数），会作为对象信息拼进摘要
        assertEquals("导出采购报表 2026-08-29/128rows", exportEvent.summary());

        AuditLog reset = new AuditLog();
        reset.setAction("password_temporary_reset");
        reset.setTargetType("user");
        reset.setTargetId(UUID.randomUUID().toString());
        reset.setResult("success;mode=custom");

        AuditEventInterpreter.InterpretedEvent resetEvent = interpreter.interpret(reset);
        assertEquals("重置账号密码", resetEvent.actionLabel());
        assertEquals("成功；方式：管理员指定密码", resetEvent.resultLabel());
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
        assertEquals("删除货品", event.summary());
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
