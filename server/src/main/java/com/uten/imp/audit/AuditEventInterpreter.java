package com.uten.imp.audit;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.json.JsonMapper;
import org.springframework.stereotype.Component;

import java.util.ArrayList;
import java.util.Collections;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.regex.Pattern;

/**
 * 把面向存储的审计元数据（英文动作码 / 表名 / 结果码 / before-after JSON）
 * 翻译成普通管理者能直接读懂的中文事件描述。
 *
 * <p>列表页与详情页展示的 actionLabel / objectLabel / summary / changeSummary /
 * resultLabel 全部由这里一次性算好随行下发，前端只做兜底映射。
 */
@Component
public class AuditEventInterpreter {

    private static final JsonMapper AUDIT_JSON = JsonMapper.builder().build();
    private static final Map<String, String> TARGET_LABELS = targetLabels();
    private static final Map<String, String> ROUTE_LABELS = routeLabels();
    private static final Map<String, String> PAGE_LABELS = pageLabels();
    private static final Map<String, String> FIELD_LABELS = fieldLabels();
    private static final Map<String, String> RESULT_LABELS = resultLabels();
    private static final Map<String, String> VALUE_LABELS = valueLabels();
    private static final Map<String, String> EXPORT_SUBJECTS = exportSubjects();
    private static final Pattern UUID_PATTERN =
            Pattern.compile("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
                    + "[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$");
    private static final List<String> GENERIC_VERBS = List.of("查看", "新增", "修改", "删除");

    /**
     * 从 before/after 快照里提取"人看得懂"的对象名时优先尝试的字段。
     * 顺序即优先级：姓名/名称类优先，单据编号其次，编码兜底。
     * 不取 phone / id_card 等 PII 字段。
     */
    private static final List<String> TARGET_NAME_KEYS = List.of(
            "full_name", "name", "title", "doc_no", "bill_no", "voucher_no",
            "plan_no", "order_no", "request_no", "slip_no", "code",
            "login_account");

    /** 计算变更明细时跳过的纯技术列（不含业务含义或与业务变化无关）。 */
    private static final List<String> META_COLUMNS = List.of(
            "id", "created_at", "created_by", "updated_at", "updated_by",
            "version", "is_deleted", "deleted_at", "deleted_by");

    /** 列表摘要里最多内联的变更条数；详情 changeSummary 里最多列出的条数。 */
    private static final int SUMMARY_MAX_INLINE_CHANGES = 2;
    private static final int DETAIL_MAX_CHANGE_ENTRIES = 6;
    private static final int MAX_VALUE_LENGTH = 30;

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
        String targetName = targetDisplayName(value);
        if (targetName.isBlank()) {
            targetName = businessTargetName(value);
        }
        String pageLabel = pageLabel(path);
        String resultLabel = resultLabel(value.getResult(), value.getStatusCode());
        List<String> changes = changeEntries(action, value.getBefore(), value.getAfter());
        String changeSummary = changeSummary(action, value.getBefore(), value.getAfter(), changes);
        String summary = buildSummary(
                action, actionLabel, objectLabel, targetName, changes, resultLabel);
        return new InterpretedEvent(
                actionLabel,
                objectLabel,
                summary,
                risk,
                riskReason(risk, action, target, path, result, value.getStatusCode()),
                category,
                targetName,
                pageLabel,
                resultLabel,
                changeSummary);
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
        if (action.startsWith("export_")) return exportLabel(action);
        if (path.contains("/export")) return "导出数据";
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
        if ("password_temporary_reset".equals(action)) return "重置账号密码";
        if ("super_admin_grant".equals(action)) return "授予超级管理员";
        if ("super_admin_revoke".equals(action)) return "收回超级管理员";
        if ("remote_access_grant".equals(action)) return "开通外网访问";
        if ("remote_access_revoke".equals(action)) return "关闭外网访问";
        if ("impersonation_enter".equals(action)) return "开始模拟身份";
        if ("impersonation_switch".equals(action)) return "切换模拟身份";
        if ("impersonation_exit".equals(action)) return "结束模拟身份";
        if ("attachment_download_grant".equals(action)) return "签发附件下载授权";
        if ("attachment_download_raw".equals(action)) return "下载附件";
        if ("update_system_setting".equals(action)) return "修改系统设置";
        if ("webinquiry_status".equals(action)) return "处理官网询价";
        if ("webinquiry_convert".equals(action)) return "转化官网询价";
        if ("sales_partial_shipment_confirm".equals(action)) return "确认销售部分出货";
        if ("sales_partial_shipment_revoke".equals(action)) return "撤销销售部分出货";
        if ("sales_order_priority".equals(action)) return "调整销售订单优先级";
        if ("sales_reservation_yield".equals(action)) return "让单释放库存预留";
        // 通知域人工操作（V424 后由服务层显式留痕）
        if ("notice_publish".equals(action)) return "发布通知";
        if ("notice_acknowledge".equals(action)) return "确认收到通知";
        if ("notice_todo_complete".equals(action)) return "完成待办任务";
        if ("notice_bless".equals(action)) return "回复庆典祝福";
        if ("notice_delete".equals(action)) return "移除通知";
        // 任务认领（HR 任务中心 + 通用软认领）
        if ("hr_task_claim".equals(action)) return "认领HR任务";
        if ("hr_task_release".equals(action)) return "释放HR任务";
        if ("hr_task_takeover".equals(action)) return "接管HR任务";
        if ("task_claim".equals(action)) return "认领任务";
        if ("task_release".equals(action)) return "释放任务";
        if ("task_takeover".equals(action)) return "接管任务";
        if ("task_force_release".equals(action)) return "强制释放任务";
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
        // 任务认领 / 通知互动的写请求：按路径给出具体动词，避免显示成泛化的"新增/修改"
        if (!"http_get".equals(action)) {
            if (containsAny(path, "/claim", "/claims")) return "认领任务";
            if (path.contains("/takeover")) return "接管任务";
            if (path.contains("/force-release")) return "强制释放任务";
            if (path.contains("/acknowledge")) return "确认收到通知";
            if (path.contains("/batch-delete")) return "移除通知";
        }
        return switch (action) {
            case "http_get" -> "查看";
            case "insert", "http_post" -> "新增";
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
            if (segments.length > 0) {
                String first = segments[0];
                String asTable = first.replace('-', '_');
                return TARGET_LABELS.getOrDefault(asTable, humanize(first));
            }
        }
        return humanize(target);
    }

    /** export_purchase_report → 导出采购报表。 */
    private String exportLabel(String action) {
        String subject = action.substring("export_".length());
        return "导出" + EXPORT_SUBJECTS.getOrDefault(subject, humanize(subject));
    }

    /**
     * 组装列表页摘要：动作 + 对象 + 对象名，数据库变更行再内联前两项具体变更，
     * 失败的操作在末尾标注失败原因，例如
     * 「修改销售订单 SO-2026-001：状态：待审核 → 已审核；金额：100 → 200等 3 项变更」。
     */
    private String buildSummary(String action,
                                String actionLabel,
                                String objectLabel,
                                String targetName,
                                List<String> changes,
                                String resultLabel) {
        StringBuilder text = new StringBuilder();
        boolean genericVerb = GENERIC_VERBS.contains(actionLabel);
        if (genericVerb && !objectLabel.isBlank()) {
            text.append(actionLabel).append(objectLabel);
        } else {
            text.append(actionLabel);
            if (!objectLabel.isBlank() && !actionLabel.contains(objectLabel)) {
                text.append(" · ").append(objectLabel);
            }
        }
        if (!targetName.isBlank()) {
            text.append(' ').append(targetName);
        }
        boolean dataChange = "update".equals(action) && !changes.isEmpty();
        if (dataChange) {
            text.append('：');
            for (int i = 0; i < Math.min(SUMMARY_MAX_INLINE_CHANGES, changes.size()); i++) {
                if (i > 0) {
                    text.append("；");
                }
                text.append(changes.get(i));
            }
            if (changes.size() > SUMMARY_MAX_INLINE_CHANGES) {
                text.append("等 ").append(changes.size()).append(" 项变更");
            }
        }
        if (!resultLabel.isBlank() && !resultLabel.equals("成功")) {
            text.append("（").append(resultLabel).append('）');
        }
        return text.toString();
    }

    /**
     * 数据库触发行的逐字段变更明细（详情页"具体变更"数据源）。
     * 只对 update 计算字段级差异；insert/delete 的信息量用 {@link #changeSummary} 概括。
     */
    private List<String> changeEntries(String action, String beforeJson, String afterJson) {
        if (!"update".equals(action)) {
            return List.of();
        }
        JsonNode before = parseAuditJson(beforeJson);
        JsonNode after = parseAuditJson(afterJson);
        if (before == null || after == null || !before.isObject() || !after.isObject()) {
            return List.of();
        }
        List<String> entries = new ArrayList<>();
        Iterator<String> fields = after.fieldNames();
        while (fields.hasNext()) {
            String field = fields.next();
            if (META_COLUMNS.contains(field)) {
                continue;
            }
            JsonNode oldValue = before.get(field);
            JsonNode newValue = after.get(field);
            if (nodesEqual(oldValue, newValue)) {
                continue;
            }
            entries.add(fieldLabel(field) + "：" + valueLabel(oldValue)
                    + " → " + valueLabel(newValue));
        }
        return entries;
    }

    /**
     * 详情页"这次操作做了什么"卡片里的具体变更文案：
     * update 列出最多 {@value #DETAIL_MAX_CHANGE_ENTRIES} 项字段变化；
     * insert / delete 概括为信息量描述；其余（请求级/显式事件）为空。
     */
    private String changeSummary(String action,
                                 String beforeJson,
                                 String afterJson,
                                 List<String> changes) {
        if ("update".equals(action)) {
            if (changes.isEmpty()) {
                return "";
            }
            StringBuilder text = new StringBuilder();
            for (int i = 0; i < Math.min(DETAIL_MAX_CHANGE_ENTRIES, changes.size()); i++) {
                if (i > 0) {
                    text.append("；");
                }
                text.append(changes.get(i));
            }
            if (changes.size() > DETAIL_MAX_CHANGE_ENTRIES) {
                text.append("；另有 ").append(changes.size() - DETAIL_MAX_CHANGE_ENTRIES)
                        .append(" 项变更见「数据变更」标签页");
            }
            return text.toString();
        }
        if ("insert".equals(action)) {
            JsonNode after = parseAuditJson(afterJson);
            int count = businessFieldCount(after);
            return count > 0 ? "新建记录，共填写 " + count + " 项信息" : "";
        }
        if ("delete".equals(action)) {
            JsonNode before = parseAuditJson(beforeJson);
            int count = businessFieldCount(before);
            return count > 0 ? "删除了整条记录（含 " + count + " 项信息）" : "";
        }
        return "";
    }

    private int businessFieldCount(JsonNode node) {
        if (node == null || !node.isObject()) {
            return 0;
        }
        int count = 0;
        Iterator<String> fields = node.fieldNames();
        while (fields.hasNext()) {
            if (!META_COLUMNS.contains(fields.next())) {
                count++;
            }
        }
        return count;
    }

    /** result 存储码（含 "success;mode=custom" 复合形式）→ 中文结果。 */
    String resultLabel(String result, Integer statusCode) {
        String normalized = normalized(result);
        if (normalized.isBlank()) {
            return statusCode != null && statusCode >= 400
                    ? "失败（HTTP " + statusCode + "）"
                    : "";
        }
        String main = normalized;
        String extra = "";
        int separator = normalized.indexOf(';');
        if (separator >= 0) {
            main = normalized.substring(0, separator);
            extra = normalized.substring(separator + 1);
        }
        String label = RESULT_LABELS.getOrDefault(main, main);
        if (statusCode != null && statusCode >= 400 && "成功".equals(label)) {
            label = "失败";
        }
        if (!extra.isBlank()) {
            label = label + "；" + RESULT_LABELS.getOrDefault(extra, extra);
        }
        return label;
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

    /**
     * 从 before/after 快照提取对象的可读名称（姓名、单据号、编码等）。
     * 数据库主键 UUID 对人没有意义；快照里的业务字段才是用户当时看到的东西。
     * 取不到时返回空串，调用方继续用 targetId。
     */
    private static String targetDisplayName(AuditLog value) {
        String fromAfter = firstNameKey(parseAuditJson(value.getAfter()));
        if (!fromAfter.isBlank()) {
            return fromAfter;
        }
        return firstNameKey(parseAuditJson(value.getBefore()));
    }

    /**
     * 显式业务事件没有 before/after 快照，但 targetId 里通常直接放了
     * 人可读的信息（通知标题、"任务类型 · 员工姓名"、系统设置键值等）。
     * 用它当对象名，让"发布通知 《关于xx的通知》"这样的句子成立。
     * 跳过路径、UUID 和分号串（统计参数这类机器格式）。
     */
    private static String businessTargetName(AuditLog value) {
        if (!"business".equals(value.getEventSource())) {
            return "";
        }
        String id = value.getTargetId();
        if (id == null || id.isBlank() || id.length() > 200) {
            return "";
        }
        String trimmed = id.trim();
        if (trimmed.startsWith("/") || trimmed.contains(";")
                || UUID_PATTERN.matcher(trimmed).matches()) {
            return "";
        }
        return trimmed;
    }

    private static String firstNameKey(JsonNode node) {
        if (node == null || !node.isObject()) {
            return "";
        }
        for (String key : TARGET_NAME_KEYS) {
            JsonNode field = node.get(key);
            if (field != null && field.isValueNode()) {
                String text = field.asText();
                if (text != null && !text.isBlank()) {
                    return text.trim();
                }
            }
        }
        return "";
    }

    /** 把请求路径翻译成用户熟悉的页面名（"哪个页面操作的"）。 */
    static String pageLabel(String path) {
        if (path == null || path.isBlank()) {
            return "";
        }
        String normalizedPath = path.toLowerCase(Locale.ROOT);
        String bestKey = null;
        for (String key : PAGE_LABELS.keySet()) {
            if (normalizedPath.startsWith(key)
                    && (bestKey == null || key.length() > bestKey.length())) {
                bestKey = key;
            }
        }
        return bestKey == null ? "" : PAGE_LABELS.get(bestKey);
    }

    private static Map<String, String> pageLabels() {
        Map<String, String> values = new LinkedHashMap<>();
        values.put("/api/admin/audit-logs", "系统管理 · 审计中心");
        values.put("/api/admin/system-settings", "系统管理 · 系统设置");
        values.put("/api/admin/departments", "系统管理 · 部门权限");
        values.put("/api/admin/permissions", "系统管理 · 权限配置");
        values.put("/api/admin/users", "系统管理 · 用户账号");
        values.put("/api/admin", "系统管理");
        values.put("/api/auth", "登录与账号");
        values.put("/api/org/employees", "组织人事 · 员工档案");
        values.put("/api/org/departments", "组织人事 · 部门管理");
        values.put("/api/org/positions", "组织人事 · 岗位管理");
        values.put("/api/employees", "组织人事 · 员工档案");
        values.put("/api/profile-change", "组织人事 · 资料变更");
        values.put("/api/payroll", "薪酬 · 工资业务");
        values.put("/api/expense-claims", "费用 · 报销单");
        values.put("/api/master/material-categories", "基础资料 · 货品分类");
        values.put("/api/master/goods", "基础资料 · 货品");
        values.put("/api/master/moulds", "基础资料 · 模具");
        values.put("/api/master/clients", "基础资料 · 客户");
        values.put("/api/master/suppliers", "基础资料 · 供应商");
        values.put("/api/master/warehouses", "基础资料 · 仓库");
        values.put("/api/master/accounts", "基础资料 · 资金账户");
        values.put("/api/master/currencies", "基础资料 · 币种");
        values.put("/api/master/colors", "基础资料 · 颜色");
        values.put("/api/master/units", "基础资料 · 单位");
        values.put("/api/master/payment-styles", "基础资料 · 结算方式");
        values.put("/api/master", "基础资料");
        values.put("/api/sales/orders", "销售 · 销售订单");
        values.put("/api/sales/shipments", "销售 · 销售出货");
        values.put("/api/sales/returns", "销售 · 销售退货");
        values.put("/api/sales/quotes", "销售 · 销售报价");
        values.put("/api/sales/reports", "销售 · 销售报表");
        values.put("/api/sales", "销售");
        values.put("/api/purchase/requests", "采购 · 采购申请");
        values.put("/api/purchase/orders", "采购 · 采购订单");
        values.put("/api/purchase/receipts", "采购 · 采购收货");
        values.put("/api/purchase/returns", "采购 · 采购退货");
        values.put("/api/purchase/reports", "采购 · 采购报表");
        values.put("/api/purchase", "采购");
        values.put("/api/subcontract/orders", "委外 · 委外订单");
        values.put("/api/subcontract/receipts", "委外 · 委外收货");
        values.put("/api/subcontract/returns", "委外 · 委外退货");
        values.put("/api/subcontract", "委外");
        values.put("/api/production/daily-reports", "生产 · 生产日报");
        values.put("/api/production/plans", "生产 · 生产计划");
        values.put("/api/production/material-analysis", "生产 · 物料分析");
        values.put("/api/production", "生产");
        values.put("/api/stock/documents", "仓库 · 库存单据");
        values.put("/api/stock/balances", "仓库 · 即时库存");
        values.put("/api/stock/movements", "仓库 · 库存流水");
        values.put("/api/stock", "仓库");
        values.put("/api/finance/fixed-assets", "财务 · 固定资产");
        values.put("/api/finance/deferred-expenses", "财务 · 待摊费用");
        values.put("/api/finance/receipts", "财务 · 收款单");
        values.put("/api/finance/payments", "财务 · 付款单");
        values.put("/api/finance/expenses", "财务 · 费用单");
        values.put("/api/finance/other-incomes", "财务 · 其他收入单");
        values.put("/api/finance/bank-transfers", "财务 · 银行转账单");
        values.put("/api/finance/reports", "财务 · 钱流报表");
        values.put("/api/finance", "财务");
        values.put("/api/warehouse/inbound", "仓库 · 到货入库");
        values.put("/api/warehouse", "仓库");
        values.put("/api/notices", "工作台 · 通知");
        values.put("/api/org/hr-tasks", "人事 · HR任务中心");
        values.put("/api/task-claims", "工作台 · 任务认领");
        values.put("/api/suggestions", "工作台 · 意见建议");
        values.put("/api/dashboard", "工作台");
        values.put("/api/visitor", "访客管理");
        values.put("/api/website-inquiries", "官网询价");
        values.put("/api/rd/tasks", "研发任务");
        values.put("/api/attachments", "附件");
        return Collections.unmodifiableMap(new LinkedHashMap<>(values));
    }

    /**
     * 数据库表名 → 中文名。审计触发器覆盖 public 下全部业务表，
     * 这里逐一收录；新增业务表时须同步补一条，否则界面会回退显示英文表名。
     */
    private static Map<String, String> targetLabels() {
        Map<String, String> values = new LinkedHashMap<>();
        // 账号 / 权限 / 组织
        values.put("users", "用户账号");
        values.put("user", "用户账号");
        values.put("roles", "角色");
        values.put("permissions", "权限项");
        values.put("role_permissions", "角色权限");
        values.put("user_roles", "用户角色");
        values.put("department_roles", "部门角色");
        values.put("departments", "部门");
        values.put("positions", "岗位");
        values.put("employees", "员工档案");
        values.put("employee_sensitive", "员工敏感信息");
        values.put("employee_compensation", "员工薪酬信息");
        values.put("employee_contracts", "员工合同");
        values.put("employee_credentials", "员工系统凭证");
        values.put("employee_education", "员工教育经历");
        values.put("employee_phones", "员工联系电话");
        values.put("employee_vehicles", "员工车辆信息");
        values.put("employee_offboarding_events", "员工离职记录");
        values.put("employee_data_handovers", "员工数据交接单");
        values.put("employee_data_handover_scopes", "数据交接范围");
        values.put("employment_history", "任职记录");
        values.put("emergency_contacts", "紧急联系人");
        values.put("user_permission_overrides", "个人权限");
        values.put("department_permissions", "部门权限");
        values.put("user_data_scopes", "数据范围");
        values.put("user_preferences", "个人偏好设置");
        values.put("authorization_state", "权限版本状态");
        values.put("manager_permission_delegations", "管理者权限委托");
        values.put("organization_permission_leader_assignments", "组织权限负责人配置");
        values.put("permission_surfaces", "权限页面清单");
        values.put("permission_surface_permissions", "权限页面配置");
        values.put("workflow_responsibility_assignments", "流程责任配置");
        values.put("client_access_change_events", "客户权限变更记录");
        values.put("client_visibility_grants", "客户可见范围");
        values.put("profile_change_requests", "资料变更申请");
        values.put("task_claims", "任务");
        values.put("hr_task_claims", "HR任务");
        values.put("system_settings", "系统设置");
        values.put("audit_retention", "审计留存数据");
        values.put("audit_log", "审计日志");
        values.put("password_history", "密码历史");
        values.put("refresh_tokens", "员工登录会话");
        values.put("visitor_refresh_tokens", "访客登录会话");
        values.put("visitor_sms_codes", "访客短信验证码");
        values.put("visitor_accounts", "访客账号");
        values.put("visitor_applications", "访客申请");
        values.put("visitor_approval_steps", "访客审批步骤");
        values.put("official_policy_briefs", "官方政策简报");
        // 基础资料
        values.put("material_categories", "货品分类");
        values.put("goods", "货品");
        values.put("goods_bom_items", "货品 BOM");
        values.put("goods_import_batches", "货品导入批次");
        values.put("goods_import_creations", "货品导入生成记录");
        values.put("mould_categories", "模具分类");
        values.put("moulds", "模具");
        values.put("client_categories", "客户分类");
        values.put("clients", "客户");
        values.put("client_ship_addresses", "客户收货地址");
        values.put("client_default_settlement_migration_issues", "客户结算方式迁移问题");
        values.put("supplier_categories", "供应商分类");
        values.put("suppliers", "供应商");
        values.put("colors", "颜色");
        values.put("units", "单位");
        values.put("currencies", "币种");
        values.put("warehouses", "仓库");
        values.put("accounts", "资金账户");
        values.put("payment_styles", "结算方式");
        values.put("settlement_methods", "结算方式");
        values.put("system_master_category_registry", "主数据分类注册表");
        values.put("system_posting_style_roles", "过账方式角色配置");
        values.put("legacy_departments", "旧系统部门");
        values.put("legacy_warehouse_workshop_links", "旧系统仓库车间映射");
        values.put("master_code_change_batches", "主数据编码变更批次");
        values.put("master_code_history", "主数据编码历史");
        values.put("master_code_reservations", "主数据编码预留");
        values.put("master_code_reservation_members", "主数据编码预留成员");
        values.put("business_identifier_namespaces", "业务标识命名空间");
        values.put("business_identifier_conflicts", "业务标识冲突");
        values.put("business_identifier_reservations", "业务标识预留");
        values.put("business_identifier_reservation_members", "业务标识预留成员");
        values.put("business_prefix_reservations", "业务前缀预留");
        values.put("business_prefix_reservation_members", "业务前缀预留成员");
        values.put("business_outbox", "业务事件发件箱");
        values.put("attachments", "附件");
        values.put("attachment_upload_sessions", "附件上传会话");
        values.put("attachment_object_outbox", "附件事件发件箱");
        values.put("attachment_reconciliation_findings", "附件对账差异");
        values.put("account_flow_monthly_summaries", "账户月度流水汇总");
        values.put("account_balance_adjustment_batches", "账户余额调整批次");
        values.put("account_balance_adjustment_items", "账户余额调整明细");
        // 工作台
        values.put("notices", "通知");
        values.put("notice_user_states", "通知阅读状态");
        values.put("notice_acknowledgments", "通知知悉确认");
        values.put("notice_blessings", "通知祝福回复");
        values.put("suggestions", "意见建议");
        values.put("suggestion_replies", "建议回复");
        values.put("suggestion_likes", "建议点赞");
        values.put("website_inquiries", "官网询价");
        values.put("rd_tasks", "研发任务");
        values.put("rd_task_forwarders", "研发任务转发配置");
        // 薪酬 / 费用
        values.put("expense_claims", "报销单");
        values.put("expense_claim_items", "报销单明细");
        values.put("payroll_batches", "工资批次");
        values.put("payroll_items", "工资项目");
        values.put("payroll_slips", "工资条");
        values.put("payroll_variable_inputs", "工资变量输入");
        // 销售
        values.put("sales_quotes", "销售报价");
        values.put("sales_quote_items", "销售报价明细");
        values.put("sales_orders", "销售订单");
        values.put("sales_order_items", "销售订单明细");
        values.put("sales_order_cost_items", "销售订单成本明细");
        values.put("sales_shipments", "销售出货");
        values.put("sales_shipment_items", "销售出货明细");
        values.put("sales_shipment_warehouse_events", "销售出货仓储事件");
        values.put("sales_other_shipments", "销售其他出库");
        values.put("sales_other_shipment_items", "销售其他出库明细");
        values.put("sales_returns", "销售退货");
        values.put("sales_return_items", "销售退货明细");
        values.put("sales_return_disposition_events", "销售退货处置事件");
        values.put("sales_return_quality_events", "销售退货质检事件");
        values.put("sales_return_quality_items", "销售退货质检明细");
        values.put("execution_segment_sales_allocations", "执行分段销售分配");
        // 采购 / 到货
        values.put("purchase_requests", "采购申请");
        values.put("purchase_request_items", "采购申请明细");
        values.put("purchase_orders", "采购订单");
        values.put("purchase_order_items", "采购订单明细");
        values.put("purchase_receipts", "采购收货");
        values.put("purchase_receipt_items", "采购收货明细");
        values.put("purchase_returns", "采购退货");
        values.put("purchase_return_items", "采购退货明细");
        values.put("procurement_order_approval_cases", "采购订单审批案卷");
        values.put("procurement_order_approval_events", "采购订单审批事件");
        values.put("procurement_arrival_exceptions", "到货异常");
        values.put("procurement_arrival_exception_events", "到货异常事件");
        values.put("procurement_inspection_events", "采购质检事件");
        values.put("procurement_inspection_items", "采购质检明细");
        values.put("inbound_expectations", "到货登记");
        values.put("inbound_expectation_items", "到货登记明细");
        values.put("warehouse_arrival_registration_commands", "到货登记指令");
        // 委外
        values.put("subcontract_orders", "委外订单");
        values.put("subcontract_order_items", "委外订单明细");
        values.put("subcontract_order_cost_items", "委外订单成本明细");
        values.put("subcontract_receipts", "委外收货");
        values.put("subcontract_receipt_items", "委外收货明细");
        values.put("subcontract_returns", "委外退货");
        values.put("subcontract_return_items", "委外退货明细");
        values.put("subcontract_applications", "委外申请");
        values.put("subcontract_application_items", "委外申请明细");
        values.put("subcontract_inquiries", "委外询价");
        values.put("subcontract_inquiry_items", "委外询价明细");
        values.put("subcontract_material_plans", "委外用料计划");
        values.put("subcontract_material_plan_items", "委外用料计划明细");
        values.put("subcontract_material_issues", "委外发料单");
        values.put("subcontract_material_issue_items", "委外发料明细");
        values.put("subcontract_material_returns", "委外退料单");
        values.put("subcontract_material_return_items", "委外退料明细");
        values.put("subcontract_wastes", "委外报废单");
        values.put("subcontract_waste_items", "委外报废明细");
        values.put("subcontract_loss_cases", "委外损失案件");
        values.put("subcontract_loss_case_lines", "委外损失明细");
        values.put("subcontract_loss_events", "委外损失事件");
        values.put("subcontract_loss_resolutions", "委外损失处理");
        values.put("subcontract_loss_fulfillment_allocations", "委外损失履约分配");
        values.put("supplier_settlement_batches", "供应商结算批次");
        values.put("supplier_settlement_batch_lines", "供应商结算批次明细");
        values.put("supplier_settlement_batch_events", "供应商结算批次事件");
        values.put("supplier_claim_receivables", "供应商索赔应收");
        values.put("supplier_claim_cash_receipts", "供应商索赔收款");
        values.put("supplier_open_item_offsets", "供应商未清项核销");
        values.put("supplier_return_tasks", "供应商退货任务");
        // 生产
        values.put("production_plans", "生产计划");
        values.put("production_plan_items", "生产计划明细");
        values.put("production_plan_costs", "生产计划成本");
        values.put("plan_draw_links", "计划领料关联");
        values.put("plan_order_item_links", "计划订单明细关联");
        values.put("subplan_links", "子计划关联");
        values.put("production_planning_drafts", "生产计划草稿");
        values.put("production_planning_packages", "生产计划包");
        values.put("production_planning_package_documents", "生产计划包单据");
        values.put("production_planning_package_document_items", "生产计划包单据明细");
        values.put("production_daily_reports", "生产日报");
        values.put("production_daily_report_items", "生产日报明细");
        values.put("production_daily_report_commands", "生产日报提交指令");
        values.put("production_execution_segments", "生产执行分段");
        values.put("production_execution_segment_events", "生产执行分段事件");
        values.put("production_material_analyses", "生产物料分析");
        values.put("production_material_analysis_items", "生产物料分析明细");
        values.put("production_material_analysis_materials", "物料分析物料");
        values.put("production_material_analysis_borrows", "物料分析借用");
        values.put("production_material_analysis_plan_links", "物料分析计划关联");
        values.put("production_material_analysis_commands", "物料分析提交指令");
        values.put("production_material_demands", "生产物料需求");
        values.put("production_material_supply_pegs", "生产物料供需挂钩");
        values.put("production_material_stock_events", "生产物料库存事件");
        values.put("production_material_stock_postings", "生产物料库存记账");
        values.put("production_material_settlement_events", "生产物料结算事件");
        values.put("production_material_settlement_postings", "生产物料结算记账");
        values.put("production_material_receipt_allocations", "生产物料收货分配");
        values.put("production_material_make_receipt_allocations", "生产自制收货分配");
        values.put("production_material_subcontract_receipt_allocations", "生产委外收货分配");
        values.put("production_material_peg_transfers", "生产物料挂钩转移");
        values.put("production_material_subcontract_peg_transfers", "生产委外挂钩转移");
        values.put("production_goods_workshop_preferences", "货品车间偏好");
        values.put("production_finished_in_confirmations", "生产完工入库确认");
        values.put("production_finished_in_confirmation_items", "生产完工入库明细");
        values.put("production_finished_in_confirmation_reversals", "生产完工入库冲销");
        values.put("production_finished_in_confirmation_reversal_items", "生产完工入库冲销明细");
        values.put("production_fqc_inspections", "生产FQC质检");
        values.put("production_fqc_decision_events", "FQC判定事件");
        values.put("production_fqc_cancellation_events", "FQC取消事件");
        values.put("production_fqc_contribution_adjustments", "FQC贡献调整");
        values.put("production_fqc_release_allocations", "FQC放行分配");
        values.put("production_fqc_release_commands", "FQC放行指令");
        values.put("production_fqc_legacy_exemptions", "FQC历史豁免");
        values.put("production_fqc_recovery_authorizations", "FQC补产授权");
        values.put("production_fqc_recovery_allocation_events", "FQC补产分配事件");
        values.put("production_fqc_recovery_cancellation_events", "FQC补产取消事件");
        values.put("production_fqc_replenishment_cycles", "FQC补产周期");
        values.put("production_fqc_replenishment_tasks", "FQC补产任务");
        values.put("production_fqc_replenishment_attempts", "FQC补产尝试");
        values.put("production_fqc_replenishment_analysis_links", "FQC补产分析关联");
        values.put("production_fqc_replenishment_draw_links", "FQC补产领料关联");
        values.put("production_fqc_replenishment_ready_events", "FQC补产就绪事件");
        values.put("production_fqc_replenishment_ready_reversals", "FQC补产就绪冲销");
        values.put("production_fqc_replenishment_supply_gaps", "FQC补产供应缺口");
        values.put("mrp_generations", "MRP运算批次");
        values.put("preplan_supply_actions", "预计划供应动作");
        values.put("preplan_supply_action_allocations", "预计划供应分配");
        values.put("preplan_material_reallocations", "预计划物料调拨");
        values.put("preplan_stock_entitlement_events", "预计划库存权益事件");
        values.put("preplan_make_entitlement_delegations", "预计划自制权益委托");
        values.put("preplan_analysis_stock_exact_pegs", "预计划分析精确挂钩");
        // 仓库 / 库存
        values.put("stock_documents", "库存单据");
        values.put("stock_document_items", "库存单据明细");
        values.put("stock_balances", "即时库存");
        values.put("stock_movements", "库存流水");
        values.put("stock_movements_pt", "库存流水");
        values.put("stock_reservations", "库存预留");
        values.put("stock_balance_adjustment_requests", "库存余额调整申请");
        // 财务
        values.put("ar_ap_ledger", "应收应付台账");
        values.put("ar_ap_source_refs", "应收应付来源引用");
        values.put("finance_receipts", "收款单");
        values.put("finance_receipt_lines", "收款单明细");
        values.put("finance_receipt_source_allocations", "收款单来源核销");
        values.put("finance_payments", "付款单");
        values.put("finance_payment_lines", "付款单明细");
        values.put("finance_payment_methods", "付款方式");
        values.put("finance_expenses", "费用单");
        values.put("finance_expense_items", "费用单明细");
        values.put("finance_other_incomes", "其他收入单");
        values.put("finance_other_income_items", "其他收入单明细");
        values.put("finance_bank_transfers", "银行转账单");
        values.put("finance_bank_transfer_lines", "银行转账明细");
        values.put("finance_reconciliations", "对账单");
        values.put("finance_check_register", "出票登记");
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
        values.put("customer_open_item_offset_batches", "客户未清项核销批次");
        values.put("customer_open_item_offsets", "客户未清项核销");
        // 报表导出事件的虚拟对象（export_*_report 系列的 targetType）
        values.put("purchase_reports", "采购报表");
        values.put("sales_reports", "销售报表");
        values.put("stock_reports", "仓库报表");
        values.put("production_reports", "生产报表");
        values.put("finance_reports", "钱流报表");
        values.put("subcontract_reports", "委外报表");
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
        values.put("/api/sales/shipments", "销售出货");
        values.put("/api/sales/returns", "销售退货");
        values.put("/api/purchase/requests", "采购申请");
        values.put("/api/purchase/orders", "采购订单");
        values.put("/api/purchase/receipts", "采购收货");
        values.put("/api/purchase/returns", "采购退货");
        values.put("/api/subcontract/orders", "委外订单");
        values.put("/api/subcontract/receipts", "委外收货");
        values.put("/api/subcontract/returns", "委外退货");
        values.put("/api/production/plans", "生产计划");
        values.put("/api/production/daily-reports", "生产日报");
        values.put("/api/production/material-analysis", "生产物料分析");
        values.put("/api/stock/documents", "库存单据");
        values.put("/api/stock/balances", "即时库存");
        values.put("/api/stock/movements", "库存流水");
        values.put("/api/finance/fixed-assets", "固定资产");
        values.put("/api/finance/deferred-expenses", "待摊费用");
        values.put("/api/finance/receipts", "收款单");
        values.put("/api/finance/payments", "付款单");
        values.put("/api/finance/expenses", "费用单");
        values.put("/api/finance/other-incomes", "其他收入单");
        values.put("/api/finance/bank-transfers", "银行转账单");
        values.put("/api/finance/fa/depreciate", "固定资产折旧");
        values.put("/api/finance/fa/amortize", "待摊费用摊销");
        values.put("/api/notices", "通知");
        values.put("/api/org/hr-tasks", "HR任务中心");
        values.put("/api/task-claims", "任务认领");
        values.put("/api/suggestions", "意见建议");
        values.put("/api/visitor/applications", "访客申请");
        values.put("/api/expense-claims", "报销单");
        values.put("/api/payroll", "工资业务");
        return Collections.unmodifiableMap(new LinkedHashMap<>(values));
    }

    /** 变更明细用的列名 → 中文（与前端 AuditFieldLabels 字典保持同义）。 */
    private static Map<String, String> fieldLabels() {
        Map<String, String> values = new LinkedHashMap<>();
        // 通用
        values.put("status", "状态");
        values.put("remark", "备注");
        values.put("remarks", "备注");
        values.put("note", "备注");
        values.put("code", "编号");
        values.put("name", "名称");
        values.put("title", "标题");
        values.put("type", "类型");
        values.put("category", "分类");
        values.put("level", "级别");
        values.put("sort_order", "排序号");
        values.put("enabled", "是否启用");
        values.put("is_active", "是否启用");
        values.put("description", "描述");
        values.put("content", "内容");
        values.put("body", "内容");
        values.put("reason", "原因");
        values.put("quantity", "数量");
        values.put("qty", "数量");
        values.put("price", "单价");
        values.put("unit_price", "单价");
        values.put("amount", "金额");
        values.put("total_amount", "合计金额");
        values.put("tax_rate", "税率");
        values.put("tax_amount", "税额");
        values.put("discount", "折扣");
        values.put("currency_id", "币种");
        values.put("exchange_rate", "汇率");
        values.put("doc_no", "单据编号");
        values.put("bill_no", "单据编号");
        values.put("order_no", "订单编号");
        values.put("voucher_no", "凭证号");
        values.put("plan_no", "计划编号");
        values.put("request_no", "申请编号");
        values.put("slip_no", "工资条编号");
        values.put("doc_date", "单据日期");
        values.put("biz_date", "业务日期");
        values.put("expected_date", "预计日期");
        values.put("delivery_date", "交付日期");
        values.put("due_date", "交期");
        values.put("start_date", "开始日期");
        values.put("end_date", "结束日期");
        values.put("approved_at", "审批时间");
        values.put("approved_by", "审批人");
        values.put("submitted_at", "提交时间");
        values.put("submitted_by", "提交人");
        values.put("confirmed_at", "确认时间");
        values.put("revoked_by", "撤销人");
        values.put("revoked_at", "撤销时间");
        values.put("revoke_reason", "撤销原因");
        values.put("source_id", "来源单据");
        values.put("source_type", "来源类型");
        // 员工 / 组织
        values.put("full_name", "姓名");
        values.put("gender", "性别");
        values.put("department_id", "所属部门");
        values.put("position_id", "所属职位");
        values.put("supervisor_id", "直属上级");
        values.put("hire_date", "入职日期");
        values.put("resign_date", "离职日期");
        values.put("offboard_reason", "离职原因");
        values.put("employment_type", "用工类型");
        values.put("work_location", "工作地点");
        values.put("birth_month_day", "生日(月-日)");
        values.put("login_account", "登录账号");
        values.put("employee_id", "关联员工");
        values.put("user_id", "用户");
        values.put("role_id", "角色");
        values.put("permission_id", "权限项");
        values.put("must_change_password", "下次登录须改密");
        values.put("failed_attempts", "连续失败次数");
        values.put("locked_until", "锁定至");
        values.put("is_super_admin", "超级管理员");
        values.put("remote_access", "允许外网访问");
        values.put("auth_version", "授权版本号");
        values.put("temp_password_expires_at", "临时密码有效期");
        values.put("last_login_at", "最近登录时间");
        // 基础资料引用
        values.put("unit_id", "单位");
        values.put("color_id", "颜色");
        values.put("warehouse_id", "仓库");
        values.put("workshop_id", "车间");
        values.put("category_id", "分类");
        values.put("goods_id", "货品");
        values.put("client_id", "客户");
        values.put("supplier_id", "供应商");
        values.put("account_id", "资金账户");
        values.put("payment_style_id", "结算方式");
        values.put("spec", "规格");
        values.put("specification", "规格型号");
        values.put("series", "系列");
        values.put("barcode", "条码");
        values.put("stock_place", "库位号");
        // 生产
        values.put("workshop", "车间");
        values.put("planned_qty", "计划数量");
        values.put("completed_qty", "完成数量");
        values.put("priority", "优先级");
        values.put("analysis_id", "物料分析");
        values.put("from_material_id", "被借用物料");
        values.put("to_material_id", "借出物料");
        values.put("borrow_qty", "借用数量");
        values.put("last_effective_qty", "最近生效数量");
        // 财务
        values.put("payee", "收款方");
        values.put("payer", "付款方");
        values.put("bank_account", "银行账号");
        values.put("subject_code", "科目编码");
        values.put("debit", "借方金额");
        values.put("credit", "贷方金额");
        values.put("period", "会计期间");
        // 设置
        values.put("setting_key", "设置项");
        values.put("setting_value", "设置值");
        return Collections.unmodifiableMap(new LinkedHashMap<>(values));
    }

    /** result 存储码 → 中文。复合形式（"success;mode=custom"）按分号拆开分别翻译。 */
    private static Map<String, String> resultLabels() {
        Map<String, String> values = new LinkedHashMap<>();
        values.put("success", "成功");
        values.put("failure", "失败");
        values.put("failed", "失败");
        values.put("bad_password", "密码错误");
        values.put("account_not_found", "账号不存在");
        values.put("rate_limited", "尝试过于频繁（已限流）");
        values.put("locked", "账号已锁定");
        values.put("disabled", "账号已停用");
        values.put("expired", "已过期");
        values.put("invalid", "凭证无效");
        values.put("not_found", "对象不存在");
        values.put("denied", "被拒绝");
        values.put("reuse_detected", "检测到令牌重用");
        values.put("mode=custom", "方式：管理员指定密码");
        values.put("mode=generated", "方式：系统随机生成");
        return Collections.unmodifiableMap(new LinkedHashMap<>(values));
    }

    /** 常见状态枚举值 → 中文（仅做精确匹配，避免误翻业务编码）。 */
    private static Map<String, String> valueLabels() {
        Map<String, String> values = new LinkedHashMap<>();
        values.put("draft", "草稿");
        values.put("submitted", "已提交");
        values.put("pending", "待处理");
        values.put("approved", "已审核");
        values.put("rejected", "已驳回");
        values.put("confirmed", "已确认");
        values.put("completed", "已完成");
        values.put("cancelled", "已取消");
        values.put("closed", "已关闭");
        values.put("active", "启用");
        values.put("inactive", "停用");
        values.put("enabled", "启用");
        values.put("paid", "已付款");
        values.put("received", "已收货");
        values.put("true", "是");
        values.put("false", "否");
        return Collections.unmodifiableMap(new LinkedHashMap<>(values));
    }

    private static Map<String, String> exportSubjects() {
        Map<String, String> values = new LinkedHashMap<>();
        values.put("purchase_report", "采购报表");
        values.put("sales_report", "销售报表");
        values.put("stock_report", "仓库报表");
        values.put("production_report", "生产报表");
        values.put("finance_report", "钱流报表");
        values.put("subcontract_report", "委外报表");
        values.put("goods", "货品清单");
        values.put("goods_bom", "货品 BOM");
        values.put("client", "客户清单");
        values.put("supplier", "供应商清单");
        values.put("account", "资金账户清单");
        values.put("currency", "币种清单");
        values.put("audit_log", "审计日志");
        return Collections.unmodifiableMap(new LinkedHashMap<>(values));
    }

    private static String fieldLabel(String field) {
        return FIELD_LABELS.getOrDefault(field, field);
    }

    /** 变更值的可读化：空值/布尔/常见状态翻译，UUID 取前 8 位，长文本截断。 */
    private static String valueLabel(JsonNode node) {
        if (node == null || node.isNull() || node.isMissingNode()) {
            return "空";
        }
        if (node.isBoolean()) {
            return node.booleanValue() ? "是" : "否";
        }
        String text = node.isValueNode() ? node.asText() : node.toString();
        if (text.isBlank()) {
            return "(空)";
        }
        String translated = VALUE_LABELS.get(text.toLowerCase(Locale.ROOT));
        if (translated != null) {
            return translated;
        }
        if (UUID_PATTERN.matcher(text).matches()) {
            return text.substring(0, 8) + "…";
        }
        if (text.length() > MAX_VALUE_LENGTH) {
            return text.substring(0, MAX_VALUE_LENGTH) + "…";
        }
        return text;
    }

    private static boolean nodesEqual(JsonNode left, JsonNode right) {
        if (left == null) {
            return right == null || right.isNull();
        }
        if (right == null) {
            return left.isNull();
        }
        return left.equals(right);
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
            String category,
            String targetName,
            String pageLabel,
            String resultLabel,
            String changeSummary) {
    }
}
