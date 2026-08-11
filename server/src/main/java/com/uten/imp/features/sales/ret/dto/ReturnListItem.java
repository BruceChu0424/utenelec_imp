package com.uten.imp.features.sales.ret.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

/** 销售退货列表项。 */
@Getter
@AllArgsConstructor
public class ReturnListItem {
    private UUID id;
    private String billNo;
    private LocalDate billDate;
    private UUID clientId;
    private UUID warehouseId;
    private BigDecimal totalLocal;
    private Short status;
    private boolean closed;
    private boolean arPosted;
    private Integer legacyId;
    /** Current caller may mutate this document (functional permission + owner scope). */
    private boolean writable;
    /** 币种（列表补全，供前端列展示）。 */
    private UUID currencyId;
    /** 业务员 id（列表补全）。 */
    private UUID sellerId;
    /** 业务员姓名（列表补全，服务端解析）。 */
    private String sellerName;
}
