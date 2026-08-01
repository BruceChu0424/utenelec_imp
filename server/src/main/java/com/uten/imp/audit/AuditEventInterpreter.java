package com.uten.imp.audit;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.json.JsonMapper;
import org.springframework.stereotype.Component;

import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.Locale;
import java.util.Map;

/** Converts storage-oriented metadata into an explainable, human-readable event. */
@Component
public class AuditEventInterpreter {

    private static final JsonMapper AUDIT_JSON = JsonMapper.builder().build();
    private static final Map<String, String> TARGET_LABELS = targetLabels();
    private static final Map<String, String> ROUTE_LABELS = routeLabels();

    public InterpretedEvent interpret(AuditLog value) {
        boolean softDelete = isSoftDelete(value);
        String action = softDelete ? "delete" : normalized(value.getAction());
        String target = normalized(value.getTargetType());
        String path = normalized(firstNonBlank(value.getHttpPath(), value.getTargetId()));
        String result = normalized(value.getResult());
        boolean auditInvestigation = isAuditInvestigation(action);
        boolean sensitiveAuditEvidenceAccess = isSensitiveAuditEvidenceAccess(action);
        boolean sensitiveDataExport = isSensitiveDataExport(action);
        String risk = firstNonBlank(value.getRiskLevel(),
                classifyRisk(action, target, path, result, value.getStatusCode()));
        if (softDelete) {
            risk = "high";
        }
        if ((sensitiveAuditEvidenceAccess || sensitiveDataExport)
                && "low".equals(normalized(risk))) {
            risk = "medium";
        }
        String category = firstNonBlank(value.getEventCategory(),
                classifyCategory(action, target, path));
        if (auditInvestigation) {
            category = "security";
        } else if (sensitiveDataExport) {
            category = "export";
        }
        String objectLabel = objectLabel(target, path);
        String actionLabel = actionLabel(action, path);
        String summary = actionLabel + (objectLabel.isBlank() ? "" : " · " + objectLabel);
        return new InterpretedEvent(
                actionLabel,
                objectLabel,
                summary,
                risk,
                riskReason(risk, action, target, path, result, value.getStatusCode()),
                category);
    }

    String classifyRisk(String action,
                        String target,
                        String path,
                        String result,
                        Integer statusCode) {
        String haystack = action + ' ' + target + ' ' + path + ' ' + result;
        if (containsAny(haystack, "refresh_reuse", "reuse_detected")) {
            return "critical";
        }
        if (isSensitiveAuditEvidenceAccess(action) || isSensitiveDataExport(action)) {
            return "medium";
        }
        boolean readOnlyRequest = "http_get".equals(action);
        if ("delete".equals(action)
                || "http_delete".equals(action)
                || !readOnlyRequest && containsAny(haystack,
                "permission", "authorization", "data-scopes", "data_scopes",
                "system-setting", "system_setting", "reset-password",
                "balance-adjust", "blacklist", "/reverse", "/offboard")) {
            return "high";
        }
        if ((statusCode != null && statusCode >= 400)
                || containsAny(result,
                "failure", "failed", "denied", "bad_", "not_found",
                "locked", "disabled", "rate_limited", "invalid", "expired")
                || containsAny(action, "login_failed", "change_password", "verify_password")
                || action.startsWith("export_")
                || path.contains("/export")) {
            return "medium";
        }
        return "low";
    }

    String classifyCategory(String action, String target, String path) {
        String haystack = action + ' ' + target + ' ' + path;
        if (isAuditInvestigation(action)) {
            return "security";
        }
        if (isSensitiveDataExport(action)) {
            return "export";
        }
        if (containsAny(haystack, "reuse", "access_denied", "blacklist")) {
            return "security";
        }
        if (containsAny(haystack,
                "permission", "authorization", "role", "data-scope", "data_scope")) {
            return "authorization";
        }
        if (action.startsWith("export_") || path.contains("/export")) {
            return "export";
        }
        if (containsAny(haystack, "login", "logout", "password", "refresh_token", "auth/")) {
            return "authentication";
        }
        if (containsAny(haystack, "system_setting", "system-setting", "user_preferences")) {
            return "system";
        }
        if (containsAny(action, "insert", "update", "delete")) {
            return "data_change";
        }
        return "business";
    }

    private String actionLabel(String action, String path) {
        if ("verify_local_audit_receipt".equals(action)) return "核查本机操作回执";
        if ("view_audit_log_list".equals(action)) return "查看审计日志列表";
        if ("view_audit_log_summary".equals(action)) return "查看审计统计";
        if ("view_audit_log_detail".equals(action)) return "查看审计日志详情";
        if (isSensitiveDataExport(action)) return "下载工资条 PDF";
        if (action.startsWith("export_") || path.contains("/export")) return "导出数据";
        if (action.contains("login_failed")) return "登录失败";
        if ("login".equals(action) || "visitor_login".equals(action)) return "登录系统";
        if (action.contains("logout")) return "退出登录";
        if (action.contains("refresh_reuse")) return "检测到令牌重用";
        if (action.contains("refresh_failed")) return "刷新会话失败";
        if (action.contains("refresh_token")) return "刷新登录会话";
        if (action.contains("change_password_failed")) return "修改密码失败";
        if (action.contains("change_password")) return "修改密码";
        if (action.contains("verify_password_failed")) return "二次密码校验失败";
        if (action.contains("verify_password")) return "完成二次密码校验";
        if (action.contains("access_denied")) return "访问被安全策略拒绝";
        if (action.contains("visitor_send_code_failed")) return "发送验证码失败";
        if (action.contains("visitor_send_code")) return "发送访客验证码";
        if (path.contains("/approve")) return "审批通过";
        if (path.contains("/reject")) return "驳回";
        if (path.contains("/submit")) return "提交";
        if (path.contains("/withdraw")) return "撤回";
        if (path.contains("/pay")) return "确认付款";
        if (path.contains("/unlock")) return "解锁账号";
        if (path.contains("/lock")) return "锁定账号";
        if (path.contains("/disable")) return "停用账号";
        if (path.contains("/enable")) return "启用账号";
        if (path.contains("/reset-password")) return "重置密码";
        if (!"http_get".equals(action)
                && containsAny(path, "/permission-overrides", "/permissions"))
            return "调整权限";
        if (!"http_get".equals(action) && path.contains("/data-scopes"))
            return "调整数据范围";
        if (path.contains("/reverse")) return "执行红冲/撤销";
        if (path.contains("/dispatch")) return "下达执行";
        if (path.contains("/complete")) return "标记完成";
        return switch (action) {
            case "http_get" -> "查看";
            case "insert", "http_post" -> "新增/发起";
            case "update", "http_put", "http_patch" -> "修改";
            case "delete", "http_delete" -> "删除";
            default -> humanize(action);
        };
    }

    private String objectLabel(String target, String path) {
        String direct = TARGET_LABELS.get(target);
        if (direct != null) return direct;
        for (Map.Entry<String, String> entry : ROUTE_LABELS.entrySet()) {
            if (path.contains(entry.getKey())) return entry.getValue();
        }
        for (Map.Entry<String, String> entry : TARGET_LABELS.entrySet()) {
            if (path.contains('/' + entry.getKey().replace('_', '-'))) return entry.getValue();
        }
        if (path.startsWith("/api/")) {
            String[] segments = path.substring(5).split("/");
            if (segments.length > 0) return humanize(segments[0]);
        }
        return humanize(target);
    }

    private String riskReason(String risk,
                              String action,
                              String target,
                              String path,
                              String result,
                              Integer statusCode) {
        String haystack = action + ' ' + target + ' ' + path + ' ' + result;
        if (isSensitiveAuditEvidenceAccess(action))
            return "访问敏感审计证据";
        if (isSensitiveDataExport(action))
            return "工资条 PDF 被下载到系统外部，需关注使用范围";
        if ("view_audit_log_list".equals(action)
                || "view_audit_log_summary".equals(action))
            return "授权人员进行常规审计核查";
        if (containsAny(haystack, "refresh_reuse", "reuse_detected"))
            return "刷新令牌被重复使用，可能存在会话泄露";
        if (!"http_get".equals(action)
                && containsAny(haystack,
                "permission", "authorization", "data-scope", "data_scope"))
            return "涉及权限或数据可见范围变更";
        if (!"http_get".equals(action)
                && containsAny(haystack, "system-setting", "system_setting"))
            return "涉及全局安全或运行策略变更";
        if (containsAny(haystack, "reset-password", "change_password"))
            return "涉及账号凭证变更";
        if ("delete".equals(action) || "http_delete".equals(action))
            return "删除操作可能造成数据不可逆变化";
        if (containsAny(haystack, "balance-adjust", "/reverse", "/offboard", "blacklist"))
            return "涉及库存、红冲、离职或限制名单等关键业务动作";
        if ((statusCode != null && statusCode >= 400)
                || !"success".equals(result) && containsAny(
                result, "failure", "failed", "denied", "bad_", "locked",
                "disabled", "rate_limited", "invalid", "expired"))
            return "操作失败或被安全策略拒绝，需要结合详情核查";
        if (action.startsWith("export_") || path.contains("/export"))
            return "数据被导出到系统外部，需关注使用范围";
        return "low".equals(risk) ? "未命中当前风险规则" : "命中审计风险规则";
    }

    private static Map<String, String> targetLabels() {
        Map<String, String> values = new LinkedHashMap<>();
        values.put("users", "用户账号");
        values.put("roles", "角色");
        values.put("permissions", "权限项");
        values.put("role_permissions", "角色权限");
        values.put("user_roles", "用户角色");
        values.put("department_roles", "部门角色");
        values.put("departments", "部门");
        values.put("positions", "岗位");
        values.put("employees", "员工档案");
        values.put("user_permission_overrides", "个人权限");
        values.put("department_permissions", "部门权限");
        values.put("user_data_scopes", "数据范围");
        values.put("authorization_state", "权限版本状态");
        values.put("system_settings", "系统设置");
        values.put("audit_retention", "审计留存数据");
        values.put("audit_log", "审计日志");
        values.put("refresh_tokens", "员工登录会话");
        values.put("visitor_refresh_tokens", "访客登录会话");
        values.put("material_categories", "货品分类");
        values.put("goods", "货品");
        values.put("goods_bom_items", "货品 BOM");
        values.put("mould_categories", "模具分类");
        values.put("moulds", "模具");
        values.put("client_categories", "客户分类");
        values.put("clients", "客户");
        values.put("customers", "客户");
        values.put("supplier_categories", "供应商分类");
        values.put("suppliers", "供应商");
        values.put("colors", "颜色");
        values.put("units", "单位");
        values.put("currencies", "币种");
        values.put("warehouses", "仓库");
        values.put("accounts", "资金账户");
        values.put("payment_styles", "结算方式");
        values.put("notices", "通知");
        values.put("expense_claims", "报销单");
        values.put("stock_balances", "即时库存");
        values.put("stock_documents", "库存单据");
        values.put("stock_document_items", "库存单据明细");
        values.put("stock_movements", "库存流水");
        values.put("stock_reservations", "库存预留");
        values.put("production_plans", "生产计划");
        values.put("production_plan_items", "生产计划明细");
        values.put("production_plan_costs", "生产计划成本");
        values.put("production_daily_reports", "生产日报");
        values.put("production_execution_segments", "生产执行分段");
        values.put("purchase_orders", "采购订单");
        values.put("purchase_order_items", "采购订单明细");
        values.put("purchase_requests", "采购申请");
        values.put("purchase_receipts", "采购收货");
        values.put("purchase_returns", "采购退货");
        values.put("sales_quotes", "销售报价");
        values.put("sales_orders", "销售订单");
        values.put("sales_order_items", "销售订单明细");
        values.put("sales_shipments", "销售出货");
        values.put("sales_returns", "销售退货");
        values.put("subcontract_orders", "委外订单");
        values.put("subcontract_order_items", "委外订单明细");
        values.put("subcontract_receipts", "委外收货");
        values.put("subcontract_returns", "委外退货");
        values.put("ar_ap_ledger", "应收应付台账");
        values.put("finance_receipts", "收款单");
        values.put("finance_payments", "付款单");
        values.put("finance_expenses", "费用单");
        values.put("finance_other_incomes", "其他收入单");
        values.put("finance_bank_transfers", "银行转账单");
        values.put("finance_reconciliations", "对账单");
        values.put("gl_vouchers", "总账凭证");
        values.put("gl_entries", "总账分录");
        values.put("finance_asset_categories", "资产/待摊分类");
        values.put("finance_asset_books", "固定资产账簿");
        values.put("finance_deferral_schedule_versions", "待摊计划版本");
        values.put("finance_deferral_schedule_lines", "待摊计划明细");
        values.put("finance_asset_approval_steps", "资产审批步骤");
        values.put("finance_asset_events", "资产业务事件");
        values.put("finance_asset_accounting_periods", "资产会计期间");
        values.put("finance_asset_posting_runs", "折旧摊销过账批次");
        values.put("finance_asset_posting_lines", "折旧摊销过账明细");
        values.put("fixed_assets", "固定资产");
        values.put("deferred_expenses", "待摊费用");
        values.put("fa_depreciation_log", "固定资产折旧记录");
        values.put("da_amortization_log", "待摊费用摊销记录");
        values.put("payroll_slips", "工资条");
        return Collections.unmodifiableMap(new LinkedHashMap<>(values));
    }

    private static Map<String, String> routeLabels() {
        Map<String, String> values = new LinkedHashMap<>();
        values.put("/api/admin/audit-logs", "审计日志");
        values.put("/permission-overrides", "个人权限");
        values.put("/effective-permissions", "有效权限");
        values.put("/data-scopes", "数据范围");
        values.put("/api/admin/departments", "部门权限");
        values.put("/api/admin/permissions", "权限配置");
        values.put("/api/admin/users", "用户账号");
        values.put("/api/admin/system-settings", "系统设置");
        values.put("/api/system-settings", "系统设置");
        values.put("/api/master/material-categories", "货品分类");
        values.put("/api/master/goods", "货品");
        values.put("/api/master/mould-categories", "模具分类");
        values.put("/api/master/moulds", "模具");
        values.put("/api/master/client-categories", "客户分类");
        values.put("/api/master/clients", "客户");
        values.put("/api/master/supplier-categories", "供应商分类");
        values.put("/api/master/suppliers", "供应商");
        values.put("/api/master/colors", "颜色");
        values.put("/api/master/units", "单位");
        values.put("/api/master/currencies", "币种");
        values.put("/api/master/warehouses", "仓库");
        values.put("/api/master/accounts", "资金账户");
        values.put("/api/master/payment-styles", "结算方式");
        values.put("/api/employees", "员工档案");
        values.put("/api/org/employees", "员工档案");
        values.put("/api/departments", "部门");
        values.put("/api/org/departments", "部门");
        values.put("/api/positions", "岗位");
        values.put("/api/sales/orders", "销售订单");
        values.put("/api/purchase/requests", "采购申请");
        values.put("/api/purchase/orders", "采购订单");
        values.put("/api/purchase/receipts", "采购收货");
        values.put("/api/purchase/returns", "采购退货");
        values.put("/api/subcontract/orders", "委外订单");
        values.put("/api/production/plans", "生产计划");
        values.put("/api/production/daily-reports", "生产日报");
        values.put("/api/stock/documents", "库存单据");
        values.put("/api/stock/balances", "即时库存");
        values.put("/api/stock/movements", "库存流水");
        values.put("/api/finance/fixed-assets", "固定资产");
        values.put("/api/finance/deferred-expenses", "待摊费用");
        values.put("/api/finance/fa/depreciate", "固定资产折旧");
        values.put("/api/finance/fa/amortize", "待摊费用摊销");
        values.put("/api/notices", "通知");
        values.put("/api/suggestions", "意见建议");
        values.put("/api/visitor/applications", "访客申请");
        values.put("/api/expense-claims", "报销单");
        values.put("/api/payroll", "工资业务");
        return Collections.unmodifiableMap(new LinkedHashMap<>(values));
    }

    private static boolean containsAny(String source, String... values) {
        for (String value : values) if (source.contains(value)) return true;
        return false;
    }

    private static boolean isAuditInvestigation(String action) {
        return "view_audit_log_list".equals(action)
                || "view_audit_log_summary".equals(action)
                || isSensitiveAuditEvidenceAccess(action);
    }

    private static boolean isSensitiveAuditEvidenceAccess(String action) {
        return "view_audit_log_detail".equals(action)
                || "verify_local_audit_receipt".equals(action);
    }

    private static boolean isSensitiveDataExport(String action) {
        return "download_payroll_slip".equals(action);
    }

    private static boolean isSoftDelete(AuditLog value) {
        if (!"update".equals(normalized(value.getAction()))) {
            return false;
        }
        JsonNode before = parseAuditJson(value.getBefore());
        JsonNode after = parseAuditJson(value.getAfter());
        if (before == null || after == null) {
            return false;
        }
        JsonNode beforeDeleted = before.get("is_deleted");
        JsonNode afterDeleted = after.get("is_deleted");
        boolean flagTransition = beforeDeleted != null
                && afterDeleted != null
                && beforeDeleted.isBoolean()
                && afterDeleted.isBoolean()
                && !beforeDeleted.booleanValue()
                && afterDeleted.booleanValue();
        boolean timestampTransition = before.has("deleted_at")
                && before.get("deleted_at").isNull()
                && after.has("deleted_at")
                && !after.get("deleted_at").isNull();
        return flagTransition || timestampTransition;
    }

    private static JsonNode parseAuditJson(String value) {
        if (value == null || value.isBlank()) {
            return null;
        }
        try {
            return AUDIT_JSON.readTree(value);
        } catch (JsonProcessingException ignored) {
            return null;
        }
    }

    private static String normalized(String value) {
        return value == null ? "" : value.trim().toLowerCase(Locale.ROOT);
    }

    private static String firstNonBlank(String first, String second) {
        return first != null && !first.isBlank() ? first : second;
    }

    private static String humanize(String value) {
        if (value == null || value.isBlank()) return "";
        return value.replace('_', ' ').replace('-', ' ').trim();
    }

    public record InterpretedEvent(
            String actionLabel,
            String objectLabel,
            String summary,
            String riskLevel,
            String riskReason,
            String category) {
    }
}
