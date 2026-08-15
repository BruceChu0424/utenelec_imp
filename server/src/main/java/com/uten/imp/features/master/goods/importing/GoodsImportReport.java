package com.uten.imp.features.master.goods.importing;

import java.util.List;
import java.util.UUID;

/**
 * 导入「检测」阶段报告（只读，不写库）。前端据此展示错误清单 + 将自动新建清单；
 * 存在任意一条错误即拦截提交，让用户改完重传。
 *
 * @param totalRows            总行数（含被跳过的空行/合计行）。
 * @param dataRows             有效数据行数。
 * @param errors               错误清单（带行号列名）。
 * @param willCreateCategories 将自动新建的分类路径（如「成品-外贸系列-新系列」）。
 * @param willCreateColors     将自动新建的颜色名。
 * @param willCreateUnits      将自动新建的单位名。
 * @param readyToImport        dataRows - errorRows；为 0 或 errors 非空时前端禁用「确认导入」。
 */
public record GoodsImportReport(
        int totalRows,
        int dataRows,
        List<GoodsImportError> errors,
        List<String> willCreateCategories,
        List<String> willCreateColors,
        List<String> willCreateUnits,
        int readyToImport,
        UUID planId) {}
