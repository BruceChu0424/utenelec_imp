package com.uten.imp.audit;

import java.util.Locale;
import java.util.Map;

/**
 * 语义写事件的动作码与中文名称(ADR-105)。
 *
 * <p>每个成功的写请求由 {@link UserOperationAuditInterceptor} 从处理它的控制器方法推导一条
 * 业务事件, 动作码是「资源.方法」: 控制器类名去掉 Controller 转下划线小写为资源,
 * 方法名转下划线小写为方法, 例如 SalesOrderController#approve -> {@code sales_order.approve}。
 * 不需要在每个控制器上加注解, 新增的写端点自动有语义事件。
 *
 * <p>审核、驳回、反审核、红冲、作废、过账、删除等关键动作在这里集中给出中文名称;
 * 其余方法按请求方式给通用名称(新增/修改/删除)。
 */
public final class AuditActionNames {

    private static final Map<String, String> VERB_LABELS = Map.ofEntries(
            Map.entry("approve", "审核通过"),
            Map.entry("approve_batch", "批量审核通过"),
            Map.entry("approve_and_issue", "审核并发料"),
            Map.entry("approve_reviewed", "审核通过"),
            Map.entry("reject", "驳回"),
            Map.entry("reject_batch", "批量驳回"),
            Map.entry("unapprove", "反审核"),
            Map.entry("finance_audit", "财务审核通过"),
            Map.entry("finance_audit_reject", "财务退回"),
            Map.entry("finance_audit_reverse", "财务反审核"),
            Map.entry("finance_reject_reverse", "撤销财务退回"),
            Map.entry("reverse", "红冲"),
            Map.entry("reverse_issue", "红冲发料"),
            Map.entry("reverse_settlement", "红冲结算"),
            Map.entry("reverse_fulfillment", "撤销交付"),
            Map.entry("reverse_run", "反过账"),
            Map.entry("reverse_finished_inbound", "红冲成品入库"),
            Map.entry("reverse_planning_package", "红冲计划包"),
            Map.entry("cancel", "作废"),
            Map.entry("void", "作废"),
            Map.entry("cancel_analysis", "取消物料分析"),
            Map.entry("cancel_planning_package", "取消计划包"),
            Map.entry("post_run", "过账"),
            Map.entry("gl_confirm", "确认入账"),
            Map.entry("generate", "生成凭证"),
            Map.entry("generate_all", "批量生成凭证"),
            Map.entry("close_period", "关闭会计期间"),
            Map.entry("reopen_period", "重新打开会计期间"),
            Map.entry("delete", "删除"),
            Map.entry("batch_delete", "批量删除"),
            Map.entry("submit", "提交"),
            Map.entry("submit_finance", "提交财务审核"),
            Map.entry("withdraw", "撤回"),
            Map.entry("close", "结案"),
            Map.entry("close_plan", "结案计划"),
            Map.entry("set_stopped", "中止或恢复"),
            Map.entry("settle", "结算"),
            Map.entry("pay", "确认付款"),
            Map.entry("issue", "发料"),
            Map.entry("issue_batch", "批量发料"),
            Map.entry("dispatch", "下达执行"),
            Map.entry("issue_workshop_plans", "下达车间计划"),
            Map.entry("lock", "锁定账号"),
            Map.entry("lock_account", "锁定账号"),
            Map.entry("unlock", "解锁账号"),
            Map.entry("unlock_account", "解锁账号"),
            Map.entry("disable", "停用账号"),
            Map.entry("enable", "启用账号"),
            Map.entry("reset_password", "重置密码"),
            Map.entry("set_super_admin", "设置超级管理员"),
            Map.entry("set_remote_access", "设置外网访问"),
            Map.entry("set_department_permissions", "调整部门权限"),
            Map.entry("set_permission_overrides", "调整个人权限"),
            Map.entry("set_permissions", "调整权限"),
            Map.entry("set_data_scopes", "调整数据范围"),
            Map.entry("set_delegation", "调整权限委托"),
            Map.entry("offboard", "办理离职"),
            Map.entry("rehire", "办理复职"),
            Map.entry("onboard", "办理入职"),
            Map.entry("force_release", "强制释放任务"),
            Map.entry("claim", "认领任务"),
            Map.entry("release", "释放任务"),
            Map.entry("takeover", "接管任务"),
            Map.entry("adjust", "调整库存余额"),
            Map.entry("blacklist", "加入黑名单"),
            Map.entry("unblacklist", "移出黑名单"),
            Map.entry("reset_business_data", "清空业务数据"),
            Map.entry("undo", "撤销导入"),
            Map.entry("revoke_borrow", "撤销借用"),
            Map.entry("revoke_cross_reallocation", "撤销跨单调拨"),
            Map.entry("revoke_root_output", "撤销根产出"),
            Map.entry("terminate", "终止"),
            Map.entry("dispose", "处置资产"),
            Map.entry("publish", "发布"),
            Map.entry("export", "导出数据"));

    private AuditActionNames() {
    }

    /** SalesOrderController#approveBatch -> sales_order.approve_batch。 */
    public static String semanticAction(Class<?> controller, String methodName) {
        return resourceCode(controller) + "." + snake(methodName);
    }

    public static String resourceCode(Class<?> controller) {
        String name = controller.getSimpleName();
        if (name.contains("$$")) {
            name = name.substring(0, name.indexOf("$$"));
        }
        if (name.endsWith("Controller")) {
            name = name.substring(0, name.length() - "Controller".length());
        }
        return snake(name);
    }

    /** 语义动作码的资源部分; 不是「资源.方法」形态的动作码返回 null。 */
    public static String resourceOf(String action) {
        if (action == null) {
            return null;
        }
        int dot = action.indexOf('.');
        return dot > 0 && dot < action.length() - 1 ? action.substring(0, dot) : null;
    }

    public static String verbOf(String action) {
        if (action == null) {
            return null;
        }
        int dot = action.indexOf('.');
        return dot > 0 && dot < action.length() - 1 ? action.substring(dot + 1) : null;
    }

    /** 关键动作的中文名称; 未登记的方法返回 null, 由调用方按请求方式给通用名称。 */
    public static String verbLabel(String verb) {
        return verb == null ? null : VERB_LABELS.get(verb);
    }

    static String snake(String value) {
        StringBuilder result = new StringBuilder(value.length() + 8);
        for (int index = 0; index < value.length(); index++) {
            char current = value.charAt(index);
            if (Character.isUpperCase(current)) {
                boolean previousLower = index > 0 && !Character.isUpperCase(value.charAt(index - 1));
                boolean nextLower = index + 1 < value.length()
                        && Character.isLowerCase(value.charAt(index + 1));
                if (index > 0 && (previousLower || nextLower)) {
                    result.append('_');
                }
                result.append(Character.toLowerCase(current));
            } else {
                result.append(current);
            }
        }
        return result.toString().toLowerCase(Locale.ROOT);
    }
}
