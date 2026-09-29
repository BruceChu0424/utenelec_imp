package com.uten.imp.features.sales.intake;

/**
 * 客户文件表格里一列的含义(ADR-134)。{@code IGNORED} 表示认得但不需要的列(装箱、毛重、体积、尺寸、图片)。
 * 名称会写进识别结果与学习到的版式(sales_intake_layouts.column_roles), 改名要兼容已存数据。
 */
enum ColumnRole {
    LINE_NO,
    PART_NO,
    DESCRIPTION,
    DESCRIPTION_ALT,
    SERIES,
    COLOR,
    COLOR_ALT,
    QTY,
    UNIT,
    UNIT_PRICE,
    AMOUNT,
    PCS_PER_CTN,
    CTN,
    REMARK,
    IGNORED;

    /** 解析存储/AI 返回的角色名; 不认识返回 null。 */
    static ColumnRole parse(String value) {
        if (value == null) {
            return null;
        }
        try {
            return ColumnRole.valueOf(value.strip().toUpperCase(java.util.Locale.ROOT));
        } catch (IllegalArgumentException e) {
            return null;
        }
    }
}
