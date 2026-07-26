package com.uten.imp.features.sales.report;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

/**
 * 销售月度汇总行（sales_monthly_mv 上卷：货品 × 客户 × 类型 × 月；名称前端解析）。
 *
 * <p>RETURN（退货）的 qty/amt 为明细正数（migration 落正数），前端按 docType=RETURN 自行取负展示。
 */
@Getter
@AllArgsConstructor
public class MonthlySummaryRow {
    /** QUOTE / ORDER / SHIPMENT / OTHER_SHIPMENT / RETURN。 */
    private String docType;
    private LocalDate ym;
    private UUID goodsId;
    private UUID clientId;
    private BigDecimal qty;
    private BigDecimal amt;
    private Long lines;
}
