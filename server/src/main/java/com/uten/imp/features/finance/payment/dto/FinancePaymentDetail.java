package com.uten.imp.features.finance.payment.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

/** 采购付款单详情。 */
@Getter
@AllArgsConstructor
public class FinancePaymentDetail {
    private UUID id;
    private Integer legacyId;
    private String billNo;
    private LocalDate billDate;
    private UUID supplierId;
    private UUID accountId;
    private UUID counterpartAccountId;
    private UUID currencyId;
    private BigDecimal exchangeRate;
    private BigDecimal amountOriginal;
    private BigDecimal amountLocal;
    private UUID paymentMethodId;
    private Integer paymentMethodLegacyId;
    private String invoiceNo;
    private OffsetDateTime cancelDate;
    private String operatorName;
    private UUID operatorId;
    private UUID makerId;
    private UUID approverId;
    private String sourceRemark;
    private String remark;
    private Short status;
    private boolean closed;
    private List<FinancePaymentLineDto> items;
    /** 制单员姓名（服务端按 maker_id 解析：employees 直查 + users 历史数据兼容）。 */
    private String makerName;
    /** 制单时间（审计 created_at，创建后不可变）。 */
    private java.time.Instant createdAt;
    /** 草稿乐观并发版本；编辑请求必须原样回传 expectedVersion。 */
    private long version;
    /** 创建请求幂等键；同一制单人重试同一请求时返回原单。 */
    private String createIdempotencyKey;
}
