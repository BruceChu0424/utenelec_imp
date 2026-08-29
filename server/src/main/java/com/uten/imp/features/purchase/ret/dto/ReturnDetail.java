package com.uten.imp.features.purchase.ret.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

@Getter @AllArgsConstructor
public class ReturnDetail
        implements com.uten.imp.common.web.StandardDocumentLifecycleCapabilities {
    private UUID id;
    private Integer legacyId;
    private String billNo;
    private LocalDate billDate;
    private UUID supplierId;
    private UUID warehouseId;
    private UUID currencyId;
    private BigDecimal exchangeRate;
    private BigDecimal taxRate;
    private UUID receiverId;
    private UUID settlementMethodId;
    private Integer settlementStyleLegacy;
    private UUID makerId;
    private UUID approverId;
    private String remark;
    private BigDecimal totalOriginal;
    private BigDecimal totalLocal;
    private Short status;
    private boolean closed;
    private String sourceDocNo;
    private List<ReturnItemDto> items;
    /** 制单员姓名（服务端按 maker_id 解析：employees 直查 + users 历史数据兼容）。 */
    private String makerName;
    /** 制单时间（审计 created_at，创建后不可变）。 */
    private java.time.Instant createdAt;
    /** 当前用户无采购商业金额权限时为 true，币种/结算/单价/金额字段同时置 null。 */
    private boolean priceMasked;
}
