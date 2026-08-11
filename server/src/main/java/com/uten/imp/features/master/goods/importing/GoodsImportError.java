package com.uten.imp.features.master.goods.importing;

/**
 * 导入检测/提交中的单条错误（带 Excel 行号 + 列名 + 原因）。
 *
 * @param rowNum  Excel 行号（1-based，含表头；数据从第 2 行起）。
 * @param column  列名（中文，如「编号」「类别」）；表头级错误为「表头」。
 * @param message 具体原因。
 */
public record GoodsImportError(int rowNum, String column, String message) {}
