package com.uten.imp.features.sales.order.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

/** 销售订货列表项。 */
@Getter
@AllArgsConstructor
public class OrderListItem {
    private UUID id;
    private String billNo;
    private LocalDate billDate;
    private UUID clientId;
    private UUID currencyId;
    private BigDecimal totalLocal;
    private Short status;
    private boolean closed;
    private boolean stopped;
    private Integer legacyId;
    private LocalDate deliverDate;
    /** 延期预警（业务链）：已审未结案且距交货日 ≤3 天（含已逾期），前端标红置顶。 */
    private boolean delayWarning;
    /** 价格脱敏（SOP §三8）：无 sales_order:price:view 时 true，totalLocal 已置 null，前端渲染 ***。 */
    private boolean priceMasked;
}
