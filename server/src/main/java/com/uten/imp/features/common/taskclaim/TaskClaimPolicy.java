package com.uten.imp.features.common.taskclaim;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;

import java.util.Map;

/**
 * 统一任务认领的按类型策略：租约时长 + 认领所需权限 + 管理（强制释放/接管）权限。
 *
 * <p>未知 target_type 一律 fail-closed（必须在策略表登记，避免任意目标被认领）。
 * 调整某类型的租约/权限只需改本表，无需改库表或迁移。
 */
public record TaskClaimPolicy(int leaseMinutes, String claimPermission, String managePermission) {

    /** 已登记的策略。新增共享任务面时在此登记一行。 */
    private static final Map<String, TaskClaimPolicy> POLICIES = Map.of(
            // 池化审批人：费用报销审批——认领即"我来审"，他人见「XX 审批中」按钮禁用
            "EXPENSE_APPROVE", new TaskClaimPolicy(30, "expense:approve", "expense:approve"),
            // 跨申请选行分解订货——最高双工风险，租约缩短到 15 分。
            // 认领权限对齐动作端点写权限 purchase_order:edit（分解=创建订货单），非 purchase_request:edit。
            "PURCHASE_DECOMPOSE", new TaskClaimPolicy(15, "purchase_order:edit", "purchase_order:edit"),
            // 销售订单审核（池化）。审核端点实际由 sales_order:edit 把关（系统无 sales_order:approve 权限码）。
            "SALES_ORDER_APPROVE", new TaskClaimPolicy(30, "sales_order:edit", "sales_order:edit"),
            // 履约工作台（仓库/采购/委外）：打开单据编辑耗时较长，租约放宽到 2 小时
            "FULFILLMENT_TASK", new TaskClaimPolicy(120, "stock_doc:edit", "stock_doc:edit"));

    /** 取某类型策略；未登记抛 400（fail-closed）。 */
    public static TaskClaimPolicy of(String targetType) {
        TaskClaimPolicy p = POLICIES.get(targetType);
        if (p == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "未登记的任务认领类型：" + targetType + "（需先在 TaskClaimPolicy 登记）");
        }
        return p;
    }
}
