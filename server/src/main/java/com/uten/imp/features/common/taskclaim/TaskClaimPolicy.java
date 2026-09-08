package com.uten.imp.features.common.taskclaim;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;

import java.util.Map;
import java.util.Set;

/**
 * 统一任务认领的按类型策略：租约时长 + 认领所需权限 + 管理（强制释放/接管）权限。
 *
 * <p>未知 target_type 一律 fail-closed（必须在策略表登记，避免任意目标被认领）。
 * 调整某类型的租约/权限只需改本表，无需改库表或迁移。
 */
public record TaskClaimPolicy(int leaseMinutes, Set<String> claimPermissions, Set<String> managePermissions,
        String requiredViewPermission) {

    public TaskClaimPolicy {
        claimPermissions = Set.copyOf(claimPermissions);
        managePermissions = Set.copyOf(managePermissions);
    }

    private TaskClaimPolicy(int leaseMinutes, String claimPermission, String managePermission) {
        this(leaseMinutes, Set.of(claimPermission), Set.of(managePermission),null);
    }

    public TaskClaimPolicy(int leaseMinutes,Set<String> claimPermissions,Set<String> managePermissions) {
        this(leaseMinutes,claimPermissions,managePermissions,null);
    }

    private static final Set<String> FINANCE_REVIEW_ACTIONS = Set.of(
            "finance_order_approval:approve", "finance_order_approval:reject");

    /** 已登记的策略。新增共享任务面时在此登记一行。 */
    private static final Map<String, TaskClaimPolicy> POLICIES = Map.of(
            // 池化审批人：费用报销审批——认领即"我来审"，他人见「XX 审批中」按钮禁用
            "EXPENSE_APPROVE", new TaskClaimPolicy(30, "expense:approve", "expense:approve"),
            // 跨申请选行分解订货——最高双工风险，租约缩短到 15 分。
            // 认领权限对齐申请分解动作 purchase_order:decompose；实际建单还由 create 门禁把关。
            "PURCHASE_DECOMPOSE", new TaskClaimPolicy(15, "purchase_order:decompose", "purchase_order:decompose"),
            // 销售订单审核（池化）与审核端点共同使用 sales_order:approve。
            "SALES_ORDER_APPROVE", new TaskClaimPolicy(30, "sales_order:approve", "sales_order:approve"),
            // 仓库单据认领按实际动作拆分；编辑权不再覆盖审核认领。
            "FULFILLMENT_TASK_EDIT", new TaskClaimPolicy(120, "stock_doc:edit", "stock_doc:edit"),
            "FULFILLMENT_TASK_APPROVE", new TaskClaimPolicy(30, "stock_doc:approve", "stock_doc:approve"),
            // V459 审核待办弹卡三线（ADR-063）：认领即「我来审」，弹卡/收件台显示
            // 「XX 正在审核」；与 ReviewNoticeCatalog 的 claimTargetType 一一对应。
            "SALES_ORDER_FINANCE_CONFIRM", new TaskClaimPolicy(30,Set.of("sales_order_finance:confirm"),Set.of("sales_order_finance:confirm"),"sales_order_finance:view"),
            "SALES_SHIPMENT_FINANCE_AUDIT", new TaskClaimPolicy(30,Set.of("finance_shipment_audit"),Set.of("finance_shipment_audit"),"finance_shipment_audit"),
            "PROCUREMENT_FINANCE_APPROVE", new TaskClaimPolicy(30,FINANCE_REVIEW_ACTIONS,FINANCE_REVIEW_ACTIONS,"finance_order_approval:view"),
            "IQC_INSPECT", new TaskClaimPolicy(30, "procurement_inspection:handle", "procurement_inspection:handle"));

    /** 取某类型策略；未登记抛 400（fail-closed）。 */
    public static TaskClaimPolicy of(String targetType) {
        TaskClaimPolicy p = POLICIES.get(targetType);
        if (p == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "未登记的任务认领类型：" + targetType + "(需先在 TaskClaimPolicy 登记)");
        }
        return p;
    }
}
