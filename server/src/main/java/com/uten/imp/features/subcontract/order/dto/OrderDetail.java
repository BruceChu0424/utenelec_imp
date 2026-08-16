package com.uten.imp.features.subcontract.order.dto;

import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.FinanceApproval;
import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/** 委外订货单详情（主表全字段 + 明细列表；BOM 成本子表只读走 /cost-items 端点）。 */
@Getter
@AllArgsConstructor
public class OrderDetail {
    private UUID id;
    private Integer legacyId;
    private String billNo;
    private LocalDate billDate;
    private UUID supplierId;
    private UUID warehouseId;
    private UUID currencyId;
    private BigDecimal exchangeRate;
    private BigDecimal taxRate;
    private UUID purchaserId;
    private UUID makerId;
    private UUID approverId;
    private LocalDate deliverDate;
    private boolean fulfill;
    private String remark;
    private BigDecimal totalOriginal;
    private BigDecimal totalLocal;
    private Short status;
    private boolean closed;
    private String sourceDocNo;
    private List<OrderItemDto> items;
    /** 制单员姓名（服务端按 maker_id 解析：employees 直查 + users 历史数据兼容）。 */
    private String makerName;
    /** 制单时间（审计 created_at，创建后不可变）。 */
    private java.time.Instant createdAt;
    private boolean productionLinked;
    private boolean canEdit;
    private boolean canDelete;
    private boolean canReverse;
    private String restrictionReason;
    private FinanceApproval financeApproval;
    /** 来源委外申请（全部明细同源时给出，供详情页跳转；跨申请为 null，看明细行谱系）。 */
    private UUID sourceApplicationId;
    private String sourceApplicationNo;
}
