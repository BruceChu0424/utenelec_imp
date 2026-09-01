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
                Map.entry("audit_session", "登录会话审计"),
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
                Map.entry("warehouse_goods_place_preferences", "仓库货品默认库位"),
                Map.entry("procurement_iqc_stock_in_batches", "IQC合格仓库入库批次"),
                Map.entry("procurement_iqc_stock_in_batch_items", "IQC合格仓库入库明细"),
                Map.entry("production_fqc_replenishment_cycle_cancellations",
                        "FQC补产周期取消记录"),
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
    void labelsFqcCancellationAuthorityFieldsInChinese() {
        AuditLog log = new AuditLog();
        log.setAction("update");
        log.setTargetType("production_fqc_replenishment_cycle_cancellations");
        log.setBefore("{\"cycle_id\":\"C1\",\"authorization_id\":\"A1\",\"reason_code\":\"OLD\"}");
        log.setAfter("{\"cycle_id\":\"C2\",\"authorization_id\":\"A2\",\"reason_code\":\"NEW\"}");
        log.setResult("success");

        AuditEventInterpreter.InterpretedEvent event = interpreter.interpret(log);

        assertEquals("FQC补产周期取消记录", event.objectLabel());
        assertTrue(event.changeSummary().contains("补产周期：C1 → C2"));
        assertTrue(event.changeSummary().contains("补产授权：A1 → A2"));
        assertTrue(event.changeSummary().contains("原因代码：OLD → NEW"));
    }

    @Test
    void labelsWarehouseGoodsPlacePreferenceFieldsInChinese() {
        AuditLog log = new AuditLog();
        log.setAction("update");
        log.setTargetType("warehouse_goods_place_preferences");
        log.setBefore("{\"place\":\"A31-3-1\",\"selection_count\":1,"
                + "\"source_registration_id\":\"10000000-0000-0000-0000-000000000001\","
                + "\"source_registered_at\":\"2026-08-30T08:00:00Z\","
                + "\"last_selected_by\":\"20000000-0000-0000-0000-000000000001\","
                + "\"last_selected_at\":\"2026-08-30T08:00:00Z\"}");
        log.setAfter("{\"place\":\"B02-1-4\",\"selection_count\":2,"
                + "\"source_registration_id\":\"10000000-0000-0000-0000-000000000002\","
                + "\"source_registered_at\":\"2026-08-31T08:00:00Z\","
                + "\"last_selected_by\":\"20000000-0000-0000-0000-000000000002\","
                + "\"last_selected_at\":\"2026-08-31T08:00:00Z\"}");
        log.setResult("success");

        AuditEventInterpreter.InterpretedEvent event = interpreter.interpret(log);

        assertEquals("仓库货品默认库位", event.objectLabel());
        assertTrue(event.changeSummary().contains("默认库位：A31-3-1 → B02-1-4"));
        assertTrue(event.changeSummary().contains("采用次数：1 → 2"));
        assertTrue(event.changeSummary().contains("来源送检登记："));
        assertTrue(event.changeSummary().contains("来源登记时间："));
        assertTrue(event.changeSummary().contains("最近选择人："));
        assertTrue(event.changeSummary().contains("最近选择时间："));
    }

    @Test
    void interpretsSalesDetailViewsWithBillNumberOrHistoryFallback() {
        AuditLog withBill = new AuditLog();
        withBill.setAction("view_sales_order_detail");
        withBill.setTargetType("sales_orders");
        withBill.setTargetId(UUID.randomUUID().toString());
        withBill.setAfter("{\"view_metadata_kind\":\"business_detail_view\","
                + "\"target_display_name\":\"销售订货单\","
                + "\"target_business_code\":\"SO-2026-001\","
                + "\"target_legacy_code\":null}");
        withBill.setEventSource("business");
        withBill.setResult("success");

        AuditEventInterpreter.InterpretedEvent event = interpreter.interpret(withBill);
        assertEquals("查看销售订单详情", event.actionLabel());
        assertEquals("销售订单", event.objectLabel());
        assertEquals("销售订货单", event.targetDisplayName());
        assertEquals("SO-2026-001", event.targetBusinessCode());
        assertEquals("", event.targetLegacyCode());
        assertEquals("SO-2026-001", event.targetName());
        assertEquals("", event.changeSummary());
        assertEquals("查看销售订单详情 SO-2026-001", event.summary());

        AuditLog historyOnly = new AuditLog();
        historyOnly.setAction("view_sales_quote_detail_history");
        historyOnly.setTargetType("sales_quotes");
        historyOnly.setTargetId(UUID.randomUUID().toString());
        historyOnly.setAfter("{\"view_metadata_kind\":\"business_detail_view\","
                + "\"view_display_name\":\"销售报价单(旧系统编号 11)\"}");
        historyOnly.setEventSource("business");
        historyOnly.setResult("success");
        assertEquals("销售报价单(旧系统编号 11)",
                interpreter.interpret(historyOnly).targetName());
        assertEquals("", interpreter.interpret(historyOnly).targetDisplayName());
        assertEquals("", interpreter.interpret(historyOnly).targetBusinessCode());
        assertEquals("", interpreter.interpret(historyOnly).targetLegacyCode());
        assertEquals("查看销售报价历史单据",
                interpreter.interpret(historyOnly).actionLabel());
        assertEquals("销售报价", interpreter.interpret(historyOnly).objectLabel());
        assertEquals("查看销售报价历史单据 销售报价单(旧系统编号 11)",
                interpreter.interpret(historyOnly).summary());
    }

    @Test
    void separatesSnapshotNameBusinessCodeAndLegacyCodeWithoutGuessing() {
        AuditLog snapshot = new AuditLog();
        snapshot.setAction("update");
        snapshot.setTargetType("clients");
        snapshot.setBefore("{\"name\":\"华南客户\",\"code\":\"KH-001\","
                + "\"legacy_id\":17,\"alias\":\"不要猜测\"}");
        snapshot.setAfter("{\"name\":\"华南客户\",\"code\":\"KH-002\","
                + "\"legacy_id\":17,\"alias\":\"仍不猜测\"}");
        snapshot.setResult("success");

        AuditEventInterpreter.InterpretedEvent event = interpreter.interpret(snapshot);

        assertEquals("华南客户", event.targetDisplayName());
        assertEquals("KH-002", event.targetBusinessCode());
        assertEquals("17", event.targetLegacyCode());
        assertEquals("华南客户", event.targetName(),
                "the compatibility field keeps the historical name-first behavior");

        AuditLog unknown = new AuditLog();
        unknown.setAction("update");
        unknown.setTargetType("clients");
        unknown.setAfter("{\"alias\":\"华南\",\"serial\":\"X-9\"}");
        unknown.setResult("success");
        AuditEventInterpreter.InterpretedEvent unknownEvent =
                interpreter.interpret(unknown);
        assertEquals("", unknownEvent.targetDisplayName());
        assertEquals("", unknownEvent.targetBusinessCode());
        assertEquals("", unknownEvent.targetLegacyCode());
        assertEquals("", unknownEvent.targetName());
    }

    @Test
    void translatesSensitiveAndFutureDetailViewsWithoutExposingActionCodes() {
        AuditLog employee = new AuditLog();
        employee.setAction("view_employee_detail");
        employee.setTargetType("employees");
        employee.setTargetId(UUID.randomUUID().toString());
        employee.setAfter("{\"view_metadata_kind\":\"business_detail_view\","
                + "\"view_display_name\":\"E-001\"}");
        employee.setEventSource("business");
        employee.setResult("success");

        AuditEventInterpreter.InterpretedEvent employeeEvent =
                interpreter.interpret(employee);
        assertEquals("查看员工档案", employeeEvent.actionLabel());
        assertEquals("员工档案", employeeEvent.objectLabel());
        assertEquals("查看员工档案 E-001", employeeEvent.summary());
        assertEquals("medium", employeeEvent.riskLevel());
        assertEquals("查看了包含个人、账户或财务敏感字段的业务详情",
                employeeEvent.riskReason());

        AuditLog receiptHistory = new AuditLog();
        receiptHistory.setAction("view_finance_receipt_detail_history");
        receiptHistory.setTargetType("finance_receipts");
        receiptHistory.setAfter("{\"view_metadata_kind\":\"business_detail_view\","
                + "\"view_display_name\":\"SK-001(旧系统编号 8)\"}");
        receiptHistory.setEventSource("business");
        receiptHistory.setResult("success");
        AuditEventInterpreter.InterpretedEvent historyEvent =
                interpreter.interpret(receiptHistory);
        assertEquals("查看销售收款单历史单据", historyEvent.actionLabel());
        assertEquals("SK-001(旧系统编号 8)", historyEvent.targetName());
        assertEquals("medium", historyEvent.riskLevel());

        AuditLog masterHistory = new AuditLog();
        masterHistory.setAction("view_goods_detail_history");
        masterHistory.setTargetType("goods");
        masterHistory.setEventSource("business");
        masterHistory.setResult("success");
        assertEquals("查看货品历史记录",
                interpreter.interpret(masterHistory).actionLabel());

        AuditLog futureDetail = new AuditLog();
        futureDetail.setAction("view_future_business_detail");
        futureDetail.setTargetType("future_business");
        futureDetail.setEventSource("business");
        futureDetail.setResult("success");
        assertEquals("查看详情", interpreter.interpret(futureDetail).actionLabel());
    }

    @Test
    void translatesSessionTimelineInvestigationAndPasswordRestart() {
        AuditLog sessionEvents = new AuditLog();
        sessionEvents.setAction("view_audit_session_events");
        sessionEvents.setTargetType("audit_session");
        sessionEvents.setEventSource("business");
        sessionEvents.setResult("success");
        AuditEventInterpreter.InterpretedEvent investigation =
                interpreter.interpret(sessionEvents);
        assertEquals("查看登录会话时间线", investigation.actionLabel());
        assertEquals("登录会话审计", investigation.objectLabel());
        assertEquals("security", investigation.category());
        assertEquals("medium", investigation.riskLevel());

        AuditLog sessionDetail = new AuditLog();
        sessionDetail.setAction("view_audit_session_detail");
        sessionDetail.setTargetType("audit_session");
        sessionDetail.setEventSource("business");
        sessionDetail.setResult("success");
        AuditEventInterpreter.InterpretedEvent detail =
                interpreter.interpret(sessionDetail);
        assertEquals("查看登录会话概览", detail.actionLabel());
        assertEquals("security", detail.category());
        assertEquals("medium", detail.riskLevel());

        AuditLog passwordRestart = new AuditLog();
        passwordRestart.setAction("session_start_after_password_change");
        passwordRestart.setTargetType("refresh_tokens");
        passwordRestart.setEventSource("business");
        passwordRestart.setResult("success");
        assertEquals("修改密码后建立新会话",
                interpreter.interpret(passwordRestart).actionLabel());
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
    void labelsAuditedBusinessRoutesWithExactChineseSubjects() {
        Map<String, String> expected = Map.ofEntries(
                Map.entry("/api/admin/audit-sessions", "登录会话审计"),
                Map.entry("/api/sales/quotes", "销售报价"),
                Map.entry("/api/sales/other-shipments", "销售其他出库"),
                Map.entry("/api/subcontract/applications", "委外申请"),
                Map.entry("/api/subcontract/inquiries", "委外询价"),
                Map.entry("/api/subcontract/material-issues", "委外发料"),
                Map.entry("/api/subcontract/material-returns", "委外退料"),
                Map.entry("/api/subcontract/wastes", "委外废料"),
                Map.entry("/api/production/material-analyses", "生产物料分析"),
                Map.entry("/api/production/quality-inspections", "成品检验"),
                Map.entry("/api/stock/docs", "库存单据"),
                Map.entry("/api/finance/incomes", "其他收入单"),
                Map.entry("/api/finance/ar-ap", "应收应付台账"),
                Map.entry("/api/finance/payments", "付款单"),
                Map.entry("/api/finance/supplier-settlements", "供应商对账单"),
                Map.entry("/api/finance/subcontract-loss-claims", "委外损耗索赔"),
                Map.entry("/api/finance/payables", "采购应付明细"),
                Map.entry("/api/finance/procurement-arrival-exceptions",
                        "采购到货异常财务审批"),
                Map.entry("/api/procurement/arrival-exceptions", "采购到货异常"),
                Map.entry("/api/payroll", "工资业务"),
                Map.entry("/api/master/payment-styles", "结算方式"),
                Map.entry("/api/visitor-approval", "访客审批"),
                Map.entry("/api/website-inquiries", "官网询价"));

        expected.forEach((path, label) -> {
            AuditEventInterpreter.InterpretedEvent event = interpreter.interpret(
                    request("http_get", path));
            assertEquals(label, event.objectLabel(), path);
            assertEquals("查看" + label, event.summary(), path);
            assertTrue(!event.pageLabel().isBlank(), path);
            assertTrue(!event.summary().contains("其他业务对象"), event.summary());
            assertTrue(!event.summary().contains("/api/"), event.summary());
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

        assertTrue(event.changeSummary().contains("未登记字段：1 → 101"),
                event.changeSummary());
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
    void formatsSnapshotTimestampsAsBeijingTimeInChangeEntries() {
        AuditLog log = new AuditLog();
        log.setAction("update");
        log.setTargetType("expense_claims");
        log.setTargetId(UUID.randomUUID().toString());
        log.setBefore("""
                {"doc_no":"BX-001","approved_at":"2026-08-28T09:00:00Z","due_at":null}
                """);
        log.setAfter("""
                {"doc_no":"BX-001","approved_at":"2026-08-29T03:17:00.123456+08:00",
                 "due_at":"2026-09-01"}
                """);
        log.setResult("success");
        log.setEventSource("database");

        AuditEventInterpreter.InterpretedEvent event = interpreter.interpret(log);

        assertTrue(event.changeSummary().contains(
                "审批时间：2026-08-28 17:00(北京时间) → "
                        + "2026-08-29 03:17(北京时间)"),
                event.changeSummary());
        // 日期-only 值不是时间戳，保持原样
        assertTrue(event.changeSummary().contains("交期：空 → 2026-09-01"),
                event.changeSummary());
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
        assertEquals("认领HR任务 转正任务 · 张三", claimEvent.summary());
        assertEquals("人事 · HR任务中心", claimEvent.pageLabel());

        // 认领端点的请求覆盖行也要显示成具体动作，而不是泛化的"新增"
        AuditEventInterpreter.InterpretedEvent httpEvent = interpreter.interpret(
                request("http_post", "/api/org/hr-tasks/claims"));
        assertEquals("认领任务", httpEvent.actionLabel());
        assertEquals("认领任务 · HR任务中心", httpEvent.summary());

        Map<String, String> noticeActions = Map.of(
                "notice_bless_withdraw", "撤回庆典祝福",
                "view_notice", "查看通知",
                "notice_read_all", "将全部通知标为已读",
                "notice_popup_ack", "确认关闭通知提醒",
                "notice_celebration_batch_publish", "批量发布庆典祝福");
        noticeActions.forEach((action, label) -> {
            AuditLog value = new AuditLog();
            value.setAction(action);
            value.setTargetType("notices");
            value.setTargetId("测试通知");
            value.setEventSource("business");
            value.setResult("success");
            assertEquals(label, interpreter.interpret(value).actionLabel());
        });

        AuditLog renew = new AuditLog();
        renew.setAction("task_renew");
        renew.setTargetType("task_claims");
        renew.setResult("success");
        assertEquals("续租任务认领(自动协调)",
                interpreter.interpret(renew).actionLabel());
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

    @Test
    void unknownInternalCodesNeverLeakIntoMainChineseDescriptions() {
        AuditLog log = new AuditLog();
        log.setAction("internal_unmapped_action");
        log.setTargetType("internal_unmapped_table");
        log.setResult("internal_result_code");
        log.setEventSource("business");

        AuditEventInterpreter.InterpretedEvent event = interpreter.interpret(log);

        assertEquals("未登记操作", event.actionLabel());
        assertEquals("", event.objectLabel());
        assertEquals("结果待核查", event.resultLabel());
        assertEquals("未登记操作（结果待核查）", event.summary());
        assertTrue(event.summary().contains("结果待核查"));
        assertTrue(!event.summary().contains("其他业务对象"), event.summary());
        assertTrue(!event.summary().contains("internal_"), event.summary());
    }

    @Test
    void getDetailPathShowsOnlyASafeShortRecordReference() {
        AuditLog detail = request(
                "http_get",
                "/api/sales/orders/3e27d660-5c36-41c8-8ea1-7f777f52a9cc");
        detail.setTargetType("api/sales/orders");
        detail.setEventSource("request");

        AuditEventInterpreter.InterpretedEvent detailEvent = interpreter.interpret(detail);

        assertEquals("查看销售订单 · 记录 3e27d660…", detailEvent.summary());
        assertEquals("记录 3e27d660…", detailEvent.targetName());

        AuditLog count = request("http_get", "/api/notices/unread-count");
        count.setEventSource("request");
        assertEquals("", interpreter.interpret(count).targetName());

        AuditLog phone = request("http_get", "/api/visitor/applications/13800138000");
        phone.setEventSource("request");
        assertEquals("", interpreter.interpret(phone).targetName(),
                "pure numeric phone/verification-code segments must never enter summaries");

        AuditLog businessCode = request(
                "http_get", "/api/sales/orders/SO-2026-001");
        businessCode.setEventSource("request");
        assertEquals("记录 SO-2026-001",
                interpreter.interpret(businessCode).targetName());
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
