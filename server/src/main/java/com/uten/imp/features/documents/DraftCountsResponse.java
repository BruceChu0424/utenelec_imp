package com.uten.imp.features.documents;

/**
 * 全模块草稿（{@code status = 0}）计数，供 hub 单据卡「括号数字」与「草稿(N)」入口按钮使用。
 *
 * <p>口径见 {@link DocumentDraftCountQueryService}：每项都已按当前用户的
 * {@code *:view} 权限与该模块的对象级归属范围过滤；无权限的单据类型固定返回 0。
 *
 * <p><b>呈现形态</b>：草稿是「本人未提交的活」，属浏览型计数，前端一律渲染成中性括号
 * 数字 {@code 标签 (N)}，不用红色通知徽章，也不进任何上层待办累加
 * （见 {@code docs/00-项目准则/14-徽章与计数口径.md}）。
 *
 * <p><b>字段重叠说明</b>：{@link #stockDocument()} 是 8 类仓库单据的合计，
 * {@link #stockTransfer()} / {@link #stockCheck()} 是其中两类的切片。三者可同时非零，
 * 调用方必须择一展示——仓库 hub 只用两个切片（调拨卡 / 盘点卡），
 * 新建单据页的「草稿(N)」按钮用合计并在 tooltip 标注口径。
 */
public record DraftCountsResponse(
        long salesOrder,
        long salesShipment,
        long salesReturn,
        long salesQuote,
        long purchaseOrder,
        long subcontractOrder,
        long stockDocument,
        long productionPlan,
        long productionDailyReport,
        long financeReceipt,
        long financePayment,
        long financeExpense,
        long financeOtherIncome,
        long financeBankTransfer,
        // —— 2026-09-11 补齐：此前这 7 类单据的 hub 卡没有任何计数 ——
        long purchaseReceipt,
        long purchaseReturn,
        long subcontractReturn,
        long subcontractMaterialReturn,
        long subcontractWaste,
        long stockTransfer,
        long stockCheck) {
}
