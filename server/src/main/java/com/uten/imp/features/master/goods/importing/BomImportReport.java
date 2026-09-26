package com.uten.imp.features.master.goods.importing;

import java.util.List;

/**
 * 组装信息导入（2026-09-25 用户口径「还可以导入组装，导入的格式和导出的一样」）：
 * 两段式「先检测后提交」，格式 = 配件清单导出的 13 列
 * （序号/物料编号/物料名称/型号/规格/单位/颜色/来源/计量方式/基准产量/尾包/数量/备注），
 * 序号列的级联段（1 / 2 / 2.1）表达层级——导出改完可直接导回。
 *
 * @param totalRows   非空数据行数（合计行跳过后）
 * @param errors      逐行错误（第几行 / 哪列 / 为什么）；非空即不可提交
 * @param warnings    逐行提醒（不拦提交，如名称与系统货品名不一致）
 * @param levelCounts 每层行数（下标 = 层级-1）
 * @param readyToImport 无错时可导入行数
 */
public record BomImportReport(
        int totalRows,
        List<GoodsImportError> errors,
        List<GoodsImportError> warnings,
        List<Integer> levelCounts,
        int readyToImport) {

    /** 便捷判断：无错误行即可提交。 */
    public boolean hasErrors() {
        return !errors.isEmpty();
    }
}
