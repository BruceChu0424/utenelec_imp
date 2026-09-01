package com.uten.imp.features.subcontract.waste.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/** 委外损耗单详情（主表全字段 + 明细列表）。 */
@Getter
@AllArgsConstructor
public class WasteDetail
        implements com.uten.imp.common.web.StandardDocumentLifecycleCapabilities {
    private UUID id;
    private Integer legacyId;
    private String billNo;
    private LocalDate billDate;
    private UUID supplierId;
    private UUID warehouseId;
    private UUID workerId;
    private UUID makerId;
    private UUID approverId;
    private BigDecimal totalWeight;
    private String remark;
    private BigDecimal totalOriginal;
    private BigDecimal totalLocal;
    private Short status;
    private boolean closed;
    private String sourceDocNo;
    /** V304 历史/建议索赔金额；非现行会计事实。 */
    private BigDecimal deductAmount;
    /** V304 历史负应付标记；新单应为 false。 */
    private boolean deductPosted;
    private List<WasteItemDto> items;
    /** 制单员姓名（服务端按 maker_id 解析：employees 直查 + users 历史数据兼容）。 */
    private String makerName;
    /** 制单时间（审计 created_at，创建后不可变）。 */
    private java.time.Instant createdAt;
    /** 当前用户无委外商业金额权限时为 true，扣款/单价/金额字段同时置 null。 */
    private boolean priceMasked;
}
