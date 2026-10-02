package com.uten.imp.features.stock.ledger;

import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

/** 出入库类型目录: 方向感知的「(红冲)」、报废单按单据种类显示、汇总与分析用的类型集合。 */
class StockMovementTypeCatalogTest {

    @Test
    void reversalIsLabelledByDirectionNotByType() {
        // 销售出库红冲 = 类型 3、方向 +1。
        assertThat(StockMovementTypeCatalog.label((short) 3, (short) -1, null)).isEqualTo("销售出库");
        assertThat(StockMovementTypeCatalog.label((short) 3, (short) 1, null)).isEqualTo("销售出库(红冲)");
        // 采购入库红冲 = 类型 1、方向 -1。
        assertThat(StockMovementTypeCatalog.label((short) 1, (short) -1, null)).isEqualTo("采购入库(红冲)");
        // 15-20 也有中文名, 不再显示「类型15」。
        assertThat(StockMovementTypeCatalog.label((short) 20, (short) -1, null)).isEqualTo("销售其它出库");
        assertThat(StockMovementTypeCatalog.label((short) 19, (short) -1, null)).isEqualTo("委外材料损耗");
    }

    @Test
    void wasteDocumentsShowAsScrapAndUnknownTypesStayNeutral() {
        assertThat(StockMovementTypeCatalog.label((short) 12, (short) -1, "WASTE")).isEqualTo("报废出库");
        assertThat(StockMovementTypeCatalog.label((short) 12, (short) 1, "WASTE")).isEqualTo("报废出库(红冲)");
        assertThat(StockMovementTypeCatalog.label((short) 12, (short) -1, "OTHER_OUT")).isEqualTo("其它出");
        assertThat(StockMovementTypeCatalog.label((short) 99, (short) -1, null)).isEqualTo("类型99");
        assertThat(StockMovementTypeCatalog.label((short) 21, (short) -1, null)).isEqualTo("内料仓盘点耗用");
        assertThat(StockMovementTypeCatalog.label((short) 22, (short) 1, null)).isEqualTo("内料仓盘盈");
        assertThat(StockMovementTypeCatalog.label((short) 23, (short) -1, null)).isEqualTo("批准盘点调整");
        assertThat(StockMovementTypeCatalog.label(Short.MAX_VALUE, (short) -1, null)).isEqualTo("类型32767");
        assertThat(StockMovementTypeCatalog.label(null, null, null)).isEqualTo("—");
    }

    @Test
    void typeSetsFollowTheCatalogCategories() {
        assertThat(StockMovementTypeCatalog.naturalInCodes())
                .containsExactly((short) 1, (short) 4, (short) 6, (short) 7, (short) 9, (short) 11, (short) 13,
                        (short) 16, (short) 17, (short) 22);
        assertThat(StockMovementTypeCatalog.codesOf(StockMovementTypeCatalog.Category.CONSUMPTION))
                .containsExactly((short) 3, (short) 5, (short) 12, (short) 14, (short) 15, (short) 20, (short) 21);
        // 库龄批次: 外部来货 + 盘盈; 退料 (6/16) 与调拨 (7) 不在其中。
        assertThat(StockMovementTypeCatalog.agingInboundCodes())
                .containsExactly((short) 1, (short) 4, (short) 9, (short) 11, (short) 13, (short) 17, (short) 22);
    }

    @Test void approvedNegativeCountIsNotAReversal() {
        assertThat(StockMovementTypeCatalog.label((short)23,(short)-1,null)).isEqualTo("批准盘点调整");
        assertThat(StockMovementTypeCatalog.label((short)23,(short)1,null)).isEqualTo("批准盘点调整");
        assertThat(StockMovementTypeCatalog.codesOf(StockMovementTypeCatalog.Category.COUNT)).contains((short)23);
    }
}
