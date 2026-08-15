package com.uten.imp.features.subcontract.report;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

/**
 * 委外月度汇总行（上卷货品×供应商×类型；MV {@code subcontract_monthly_mv}）。
 * 名称前端解析。覆盖老库 8 张汇总报表（按 docType 切换）。
 */
@Getter
@AllArgsConstructor
public class SubcontractMonthlyRow {
    /** INQUIRY/APPLICATION/ORDER/RECEIPT/RETURN/MATERIAL_ISSUE/MATERIAL_RETURN/WASTE。 */
    private String docType;
    private LocalDate ym;
    private UUID goodsId;
    private String goodsCode;
    private String goodsName;
    private UUID supplierId;
    private BigDecimal qty;
    private BigDecimal amt;
    private Long lines;
}
