package com.uten.imp.features.production.dailyreport.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.util.UUID;

/** 日报已登记的本次实际用料，供编辑页回填与详情页只读回看(V583)。 */
@Getter
@AllArgsConstructor
public class DailyReportMaterialUsageDto {
    private UUID id;
    private Integer lineNo;
    private UUID planId;
    private UUID demandId;
    /** 物料所属执行段；分批生产时可能是前批原领料段，不等于报工行执行段。 */
    private UUID materialExecutionSegmentId;
    private String materialExecutionSegmentCode;
    private UUID goodsId;
    private String goodsCode;
    private String goodsName;
    private String colorName;
    private String unitName;
    /** 本次实际用料基本量。 */
    private BigDecimal qtyBase;
}
