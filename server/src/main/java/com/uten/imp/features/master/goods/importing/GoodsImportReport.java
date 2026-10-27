package com.uten.imp.features.master.goods.importing;

import java.util.List;
import java.util.UUID;

/**
 * 导入「检测」阶段报告（只读，不写库）。前端据此展示错误清单 + 将自动新建清单；
 * 问题行独立修复；检测计划只允许提交 readyRowNums 中的正常行。
 *
 * @param totalRows            总行数（含被跳过的空行/合计行）。
 * @param dataRows             本次参与检测的数据行数（排除 excludedRowNums）。
 * @param errors               错误清单（带行号列名）。
 * @param willCreateCategories 将自动新建的分类路径（如「成品-外贸系列-新系列」）。
 * @param willCreateColors     将自动新建的颜色名。
 * @param willCreateUnits      将自动新建的单位名。
 * @param readyToImport        正常行中有实际新增、补齐、恢复或待核对差异的行数；不含完全未变行。
 * @param restorableRows       将恢复的已删除货品行数（同编号命中软删行，导入时原 UUID 原编号复活）。
 * @param problemRows          问题行的文件输入，cells 可供逐格修正，不包含系统保存值。
 * @param readyRowNums         本次计划允许提交的正常物理行号，含无需变化的正常行。
 */
public record GoodsImportReport(
        int totalRows,
        int dataRows,
        List<GoodsImportError> errors,
        List<String> willCreateCategories,
        List<String> willCreateColors,
        List<String> willCreateUnits,
        int readyToImport,
        int restorableRows,
        UUID planId,
        List<GoodsImportReviewRow> reviewRows,
        int addedRows,
        int unchangedRows,
        int fillRows,
        int conflictRows,
        List<GoodsImportProblemRow> problemRows,
        List<Integer> readyRowNums) {
    public GoodsImportReport(int totalRows, int dataRows, List<GoodsImportError> errors,
                             List<String> categories, List<String> colors, List<String> units,
                             int readyToImport, int restorableRows, UUID planId,
                             List<GoodsImportReviewRow> reviewRows, int addedRows, int unchangedRows,
                             int fillRows, int conflictRows, List<GoodsImportProblemRow> problemRows) {
        this(totalRows, dataRows, errors, categories, colors, units, readyToImport,
                restorableRows, planId, reviewRows, addedRows, unchangedRows, fillRows, conflictRows,
                problemRows, List.of());
    }
    /** Preserve the original report constructor for existing callers. */
    public GoodsImportReport(int totalRows, int dataRows, List<GoodsImportError> errors,
                             List<String> categories, List<String> colors, List<String> units,
                             int readyToImport, int restorableRows, UUID planId,
                             List<GoodsImportReviewRow> reviewRows, int addedRows, int unchangedRows,
                             int fillRows, int conflictRows) {
        this(totalRows, dataRows, errors, categories, colors, units, readyToImport,
                restorableRows, planId, reviewRows, addedRows, unchangedRows, fillRows, conflictRows, List.of(), List.of());
    }
    public GoodsImportReport(int totalRows, int dataRows, List<GoodsImportError> errors,
                             List<String> categories, List<String> colors, List<String> units,
                             int readyToImport, int restorableRows, UUID planId) {
        this(totalRows, dataRows, errors, categories, colors, units, readyToImport,
                restorableRows, planId, List.of(), readyToImport - restorableRows, 0, 0, 0);
    }
}
