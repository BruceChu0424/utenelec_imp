package com.uten.imp.audit;

import java.util.List;
import java.util.Locale;
import java.util.Set;

/**
 * 审计事件的风险等级与事件类型, 全平台唯一的一处计算(ADR-105)。
 *
 * <p>Java 侧写入的每一行(请求、业务、安全、系统事件)都在 {@link AuditService} 落库前由这里
 * 算好并存进 risk_level/event_category; 数据库行事件由 fn_audit 按三清单登记的事件类型直接赋值
 * (删除与权限/系统类记高风险)。查询与显示只读存储列, 不再有写入期触发器、查询期补丁或显示期抬升。
 *
 * <p>规则按明确的动作目录判断, 不做子串猜测: 语义写事件的动作码是「资源.方法」
 * (见 {@link AuditActionNames}), 显式事件用登记过的动作码。
 */
public final class AuditClassifier {

    public record Classification(String riskLevel, String eventCategory) {
    }

    /** 查看审计证据本身: 调查行为也要留痕, 详情/会话/本机回执核查记中风险。 */
    static final Set<String> AUDIT_EVIDENCE_ACTIONS = Set.of(
            "view_audit_log_list", "view_audit_log_summary", "view_audit_log_detail",
            "verify_local_audit_receipt", "view_audit_session_list",
            "view_audit_session_detail", "view_audit_session_events");
    private static final Set<String> MEDIUM_AUDIT_EVIDENCE_ACTIONS = Set.of(
            "view_audit_log_detail", "verify_local_audit_receipt", "view_audit_session_list",
            "view_audit_session_detail", "view_audit_session_events");
    private static final Set<String> CRITICAL_ACTIONS = Set.of(
            "refresh_reuse", "refresh_reuse_detected", "visitor_refresh_reuse");
    private static final Set<String> AUTHENTICATION_ACTIONS = Set.of(
            "login", "login_failed", "logout", "refresh_token", "refresh_failed",
            "visitor_login", "visitor_login_failed", "visitor_logout", "visitor_logout_failed",
            "visitor_refresh_token", "visitor_refresh_failed", "visitor_send_code",
            "visitor_send_code_failed", "change_password", "change_password_failed",
            "verify_password", "verify_password_failed", "session_start_after_password_change",
            "password_temporary_reset");
    private static final Set<String> MEDIUM_AUTHENTICATION_ACTIONS = Set.of(
            "login_failed", "visitor_login_failed", "change_password", "change_password_failed",
            "verify_password", "verify_password_failed");
    private static final Set<String> AUTHORIZATION_ACTIONS = Set.of(
            "super_admin_grant", "super_admin_revoke", "remote_access_grant", "remote_access_revoke",
            "impersonation_enter", "impersonation_switch", "impersonation_exit");
    private static final Set<String> SYSTEM_ACTIONS = Set.of(
            "update_system_setting", "audit_retention_completed", "audit_retention_failed",
            "business_data_reset", "business_data_reset_received", "business_data_reset_failed",
            "business_attachment_reset_prepare", "legacy_migration_run",
            "notice_celebration_auto_toggle");
    /** 不可逆或绕过常规流程的显式业务动作。 */
    private static final Set<String> HIGH_RISK_ACTIONS = Set.of(
            "password_temporary_reset", "task_force_release", "admin_force_release",
            "business_data_reset", "business_data_reset_received", "legacy_migration_run",
            "notice_delete");
    /** 含个人、账户或财务敏感字段的详情; 查看它们记中风险。 */
    static final Set<String> SENSITIVE_DETAIL_TARGETS = Set.of(
            "employees", "visitor_applications", "website_inquiries",
            "clients", "suppliers", "accounts", "payroll_slips", "payroll_batches",
            "finance_receipts", "finance_payments", "finance_expenses",
            "finance_other_incomes", "finance_bank_transfers", "ar_ap_ledger",
            "supplier_settlements", "subcontract_loss_claims", "procurement_payables",
            "procurement_iqc_rejection_cases",
            "procurement_arrival_exceptions", "expense_claims", "fixed_assets",
            "deferred_expenses", "finance_asset_posting_runs");

    /** 语义写事件里属于授权治理的资源(控制器)。 */
    private static final Set<String> AUTHORIZATION_RESOURCES = Set.of(
            "admin_permission", "admin_user", "department_staff_permission",
            "page_permission_workspace", "impersonation", "client_access");
    private static final Set<String> SYSTEM_RESOURCES = Set.of(
            "system_setting", "system_test", "legacy_migration");
    private static final Set<String> AUTHENTICATION_RESOURCES = Set.of("auth", "visitor_auth");
    /** 语义写事件里的高风险方法(按「资源.方法」的方法部分判断, 前缀匹配)。 */
    private static final List<String> HIGH_RISK_VERB_PREFIXES = List.of(
            "delete", "batch_delete", "remove", "reverse", "unapprove", "void", "force_release",
            "offboard", "reset", "lock", "unlock", "disable", "blacklist", "terminate", "dispose",
            "close_period", "reopen_period", "set_super_admin", "set_remote_access", "set_permission",
            "set_department_permission", "set_data_scope", "set_delegation", "reject_legacy_override",
            "finance_audit_reverse", "finance_reject_reverse", "revoke", "undo");
    /** 只按整个方法名匹配的高风险方法(库存余额调整等; adjust_item_qty 这类改量不算)。 */
    private static final Set<String> HIGH_RISK_EXACT_VERBS = Set.of("adjust");

    private AuditClassifier() {
    }

    public static Classification classify(
            String eventSource,
            String action,
            String targetType,
            String httpPath,
            String result,
            Integer statusCode) {
        String source = normalized(eventSource);
        String code = normalized(action);
        String path = normalized(httpPath);
        boolean failed = failed(result, statusCode);
        String category = category(source, code, normalized(targetType), path);
        return new Classification(risk(source, code, normalized(targetType), path, category, failed), category);
    }

    static String category(String source, String action, String targetType, String path) {
        if (CRITICAL_ACTIONS.contains(action) || "security".equals(source)
                || AUDIT_EVIDENCE_ACTIONS.contains(action)) {
            return "security";
        }
        if (action.startsWith("export_") || "download_payroll_slip".equals(action)) {
            return "export";
        }
        if (AUTHORIZATION_ACTIONS.contains(action)) {
            return "authorization";
        }
        if (AUTHENTICATION_ACTIONS.contains(action)) {
            return "authentication";
        }
        if (SYSTEM_ACTIONS.contains(action) || "system".equals(source)) {
            return "system";
        }
        String resource = AuditActionNames.resourceOf(action);
        if (resource != null) {
            String verb = AuditActionNames.verbOf(action);
            if ("export".equals(verb)) {
                return "export";
            }
            if (AUTHORIZATION_RESOURCES.contains(resource) || isAuthorizationVerb(verb)) {
                return "authorization";
            }
            if (SYSTEM_RESOURCES.contains(resource)) {
                return "system";
            }
            if (AUTHENTICATION_RESOURCES.contains(resource)) {
                return "authentication";
            }
            return "business";
        }
        if (path.startsWith("/api/auth/") || path.startsWith("/api/visitor/auth/")) {
            return "authentication";
        }
        return "business";
    }

    private static String risk(
            String source,
            String action,
            String targetType,
            String path,
            String category,
            boolean failed) {
        if (CRITICAL_ACTIONS.contains(action)) {
            return "critical";
        }
        if (HIGH_RISK_ACTIONS.contains(action) || AUTHORIZATION_ACTIONS.contains(action)
                || "update_system_setting".equals(action)
                || action.endsWith("_reverse") || action.endsWith("_delete")
                || "http_delete".equals(action)) {
            return "high";
        }
        String resource = AuditActionNames.resourceOf(action);
        if (resource != null) {
            String verb = AuditActionNames.verbOf(action);
            if (!failed && ("authorization".equals(category) || "system".equals(category)
                    || isHighRiskVerb(verb))) {
                return "high";
            }
            if (failed || "export".equals(category)) {
                return "medium";
            }
            return "low";
        }
        if (failed || "security".equals(source)
                || MEDIUM_AUDIT_EVIDENCE_ACTIONS.contains(action)
                || MEDIUM_AUTHENTICATION_ACTIONS.contains(action)
                || "export".equals(category)
                || isSensitiveDetailView(action, targetType)) {
            return "medium";
        }
        return "low";
    }

    static boolean isSensitiveDetailView(String action, String targetType) {
        return action.startsWith("view_")
                && (action.endsWith("_detail") || action.endsWith("_detail_history"))
                && SENSITIVE_DETAIL_TARGETS.contains(targetType);
    }

    static boolean isHighRiskVerb(String verb) {
        if (verb == null) {
            return false;
        }
        if (HIGH_RISK_EXACT_VERBS.contains(verb)) {
            return true;
        }
        for (String prefix : HIGH_RISK_VERB_PREFIXES) {
            if (verb.equals(prefix) || verb.startsWith(prefix + "_") || verb.endsWith("_" + prefix)) {
                return true;
            }
        }
        return false;
    }

    private static boolean isAuthorizationVerb(String verb) {
        return verb != null && (verb.contains("permission") || verb.contains("data_scope")
                || verb.contains("delegation") || verb.contains("super_admin")
                || verb.contains("remote_access"));
    }

    static boolean failed(String result, Integer statusCode) {
        if (statusCode != null && statusCode >= 400) {
            return true;
        }
        if (result == null || result.isBlank()) {
            return false;
        }
        String main = result.split(";", 2)[0].trim().toLowerCase(Locale.ROOT);
        return !"success".equals(main) && !"succeeded".equals(main);
    }

    /** 列表与详情里「为什么是这个风险等级」的中文说明; 只解释已存储的等级, 不重新判级。 */
    static String reason(AuditLog value) {
        String risk = normalized(value.getRiskLevel());
        String action = normalized(value.getAction());
        String category = normalized(value.getEventCategory());
        boolean failed = failed(value.getResult(), value.getStatusCode());
        if ("critical".equals(risk)) {
            return "刷新令牌被重复使用，可能存在会话泄露";
        }
        if (MEDIUM_AUDIT_EVIDENCE_ACTIONS.contains(action)) {
            return "访问敏感审计证据";
        }
        if (AUDIT_EVIDENCE_ACTIONS.contains(action)) {
            return "授权人员进行常规审计核查";
        }
        if ("download_payroll_slip".equals(action)) {
            return "工资条 PDF 被下载到系统外部，需关注使用范围";
        }
        if (isSensitiveDetailView(action, normalized(value.getTargetType()))) {
            return "查看了包含个人、账户或财务敏感字段的业务详情";
        }
        if (failed) {
            return "操作失败或被安全策略拒绝，需要结合详情核查";
        }
        if ("authorization".equals(category) && !"low".equals(risk)) {
            return "涉及权限或数据可见范围变更";
        }
        if ("system".equals(category) && !"low".equals(risk)) {
            return "涉及全局安全或运行策略变更";
        }
        if ("export".equals(category)) {
            return "数据被导出到系统外部，需关注使用范围";
        }
        if ("delete".equals(action) || "http_delete".equals(action)) {
            return "删除操作可能造成数据不可逆变化";
        }
        if ("high".equals(risk)) {
            return "红冲、反审核、删除或授权类关键动作";
        }
        if ("medium".equals(risk)) {
            return "命中审计风险规则";
        }
        return "未命中当前风险规则";
    }

    private static String normalized(String value) {
        return value == null ? "" : value.trim().toLowerCase(Locale.ROOT);
    }
}
