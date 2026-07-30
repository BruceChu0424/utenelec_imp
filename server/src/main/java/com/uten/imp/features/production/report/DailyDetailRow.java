package com.uten.imp.features.production.report;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

/**
 * 生产日报明细报表行（design §6.2，空结构留位）。
 *
 * <p>源 production_daily_report_items JOIN goods/colors/units。
 * <b>本期 0 行</b>（F_DateReport 老库从未启用，design §3.4）；结构留位供未来启用。
 */
@Getter
@AllArgsConstructor
public class DailyDetailRow {
    private UUID id;
    private String billNo;
    private LocalDate billDate;
    private UUID reportId;
    private Integer lineNo;
    private UUID goodsId;
    private UUID colorId;
    private UUID unitId;
    private BigDecimal unitRate;
    private BigDecimal qty;
    private BigDecimal price;
    private BigDecimal total;
    private BigDecimal stotal;
    private UUID salesOrderItemId;
    private String salesOrderNo;
    private UUID planItemId;
    private String planNo;
    private String outboundNo;
    private BigDecimal outboundQty;
    private BigDecimal orderQty;
    private Integer stepLegacyId;
    private LocalDate orderDate;
    private BigDecimal boxes;
    private BigDecimal perBoxQty;
    private BigDecimal weight;
    private String clientName;
    private Short status;
    private Integer legacyId;
    private String remark;
}
