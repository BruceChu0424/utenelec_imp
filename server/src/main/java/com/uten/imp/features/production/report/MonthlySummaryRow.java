package com.uten.imp.features.production.report;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

/**
 * 生产月度汇总行（PLAN 计划 / DAILY 日报 × 月 × 货品 × 客户(固定 nil-uuid)，design §6.1）。
 *
 * <p>源 {@code production_monthly_mv}（物化视图），CONCURRENTLY 刷新；
 * client_id 恒 nil-uuid：production_plan_items 无 client FK（仅 client_name 文本冗余）。
 */
@Getter
@AllArgsConstructor
public class MonthlySummaryRow {
    /** PLAN / DAILY。 */
    private String docType;
    private LocalDate ym;
    private UUID goodsId;
    /** 恒 nil-uuid（生产无 client FK；保留字段以便前端同构采购/销售汇总行）。 */
    private UUID clientId;
    private BigDecimal planQtySum;
    private BigDecimal orderQtySum;
    private BigDecimal finishedQtySum;
    private BigDecimal inboundQtySum;
    private Long lineCnt;
}
