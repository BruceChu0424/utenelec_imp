package com.uten.imp.features.sales.report;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

/**
 * 销售明细报表行（5 单据类型共用同结构；名称/分类前端解析）。
 *
 * <p>用于 GET /api/sales/reports/{docType}/detail，覆盖报价/订货/出货/其它出货/退货五种明细。
 */
@Getter
@AllArgsConstructor
public class SalesDetailRow {
    private UUID id;
    private String billNo;
    private LocalDate billDate;
    private UUID clientId;
    private UUID goodsId;
    private UUID colorId;
    private UUID unitId;
    private Integer lineNo;
    private BigDecimal qty;
    private BigDecimal price;
    private BigDecimal amountOriginal;
    private BigDecimal amountLocal;
    private String remark;
}
