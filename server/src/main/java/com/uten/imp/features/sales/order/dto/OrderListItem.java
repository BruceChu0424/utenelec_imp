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
    /** 销售阶段的订单原币合计。 */
    private BigDecimal totalOriginal;
    /** 历史兼容字段；销售订单在发运立账前不形成本币事实，因此接口统一返回 null。 */
    private BigDecimal totalLocal;
    private Short status;
    private boolean closed;
    private boolean stopped;
    private Integer legacyId;
    private LocalDate deliverDate;
    /** 延期预警（业务链）：已审未结案且距交货日 ≤3 天（含已逾期），前端标红置顶。 */
    private boolean delayWarning;
    /**
     * 价格脱敏（SOP §三8）：无 sales_order:price:view 时 true，
     * totalOriginal/totalLocal 已置 null，前端渲染 ***。
     */
    private boolean priceMasked;
    /** Current caller may mutate this document (functional permission + owner scope). */
    private boolean writable;
    /** 销售员姓名（服务端按 seller_id 经 EmployeeNameResolver 解析；生产计划选单等场景展示）。 */
    private String sellerName;
    /** 销售员 id（供前端跟单员联动回填）。 */
    private UUID sellerId;
    /** 财务确认（V294）：false=待财务确认（计划部不可见）；仅已审订单有意义。 */
    private boolean financeConfirmed;
    /** 财务驳回（V300）：已审未确认且被财务驳回，待销售修正；前端列表显示驳回徽章。 */
    private boolean financeRejected;
}
