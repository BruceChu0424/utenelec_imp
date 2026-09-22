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
    private UUID settlementMethodId;
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
    /** 当前用户无委外商业金额权限时为 true，币种/结算/单价/金额字段同时置 null。 */
    private boolean priceMasked;

    /**
     * ADR-098 修订：回厂短交待委外判定期间的「锁定」提示。非空表示本单正等委外判定
     * (分批到货还是接受损耗), 期间这批货先不入库、也不许人工改量; 判定完成自动解除。
     */
    private ShortDeliveryHold shortDeliveryHold;

    /**
     * @param caseId 首条案件 id, 供页面深链到委外回厂短交判定页
     * @param caseCount 本单待判定的行数
     * @param summary 面向人的一句话说明(不含表名/状态码)
     * @param overdue 是否由「分批到货」逾期未到齐重新转回待判定
     */
    public record ShortDeliveryHold(
            java.util.UUID caseId,
            int caseCount,
            String summary,
            boolean overdue) {
    }
}
