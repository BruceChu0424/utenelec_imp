package com.uten.imp.features.sales.quote;

import com.uten.imp.common.domain.SoftDeletableEntity;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Table;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.UUID;

/**
 * 销售报价单主表（销售管理）。源 S_Quote（老库 0 行，建结构保未来）。
 *
 * <p>老库 S_Quote 是最简主表, 新库补 valid_until(报价有效期)。ADR-134 起报价由财务核价:
 * 草稿(0) → 提交财务核价(2) → 财务确认(1) → 转订货单; 财务可退回(回到 0, 带退回原因)。
 * 表头补齐币种/业务员/交货日期/结账方式/合同号, 转订货单时一并带入。
 * 明细 {@link SalesQuoteItem} 独立仓库管理, 无库存/应收副作用。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "sales_quotes")
public class SalesQuote extends SoftDeletableEntity {

    @Column(name = "legacy_id", unique = true)
    private Integer legacyId;

    @Column(name = "bill_no", nullable = false)
    private String billNo;

    @Column(name = "bill_date", nullable = false)
    private LocalDate billDate;

    @Column(name = "client_id")
    private UUID clientId;

    @Column(name = "maker_id")
    private UUID makerId;

    @Column(name = "approver_id")
    private UUID approverId;

    @Column(name = "valid_until")
    private LocalDate validUntil;

    private String remark;

    @Column(name = "total_original", precision = 18, scale = 4)
    private BigDecimal totalOriginal;

    @Column(name = "total_local", precision = 18, scale = 4)
    private BigDecimal totalLocal;

    /** 0 草稿(退回原因非空 = 财务退回待修改) / 2 待财务核价 / 1 财务已确认 / -1 作废。 */
    @Column(name = "status", nullable = false)
    private Short status = 0;

    @Column(name = "is_closed", nullable = false)
    private boolean closed = false;

    @Column(name = "source_doc_no")
    private String sourceDocNo;

    // ---- ADR-134 表头商务字段(转订货单时带入) ----

    @Column(name = "currency_id")
    private UUID currencyId;

    @Column(name = "seller_id")
    private UUID sellerId;

    @Column(name = "deliver_date")
    private LocalDate deliverDate;

    @Column(name = "settlement_method_id")
    private UUID settlementMethodId;

    @Column(name = "contract_no")
    private String contractNo;

    /** 客户文件上单价的币种代码(如 USD); 单据本身按本位币计价, 只用于阅读明细的文件单价。 */
    @Column(name = "client_file_currency")
    private String clientFileCurrency;

    // ---- ADR-134 财务核价事实(人员列均为 employees.id) ----

    @Column(name = "submitted_at")
    private OffsetDateTime submittedAt;

    @Column(name = "submitted_by")
    private UUID submittedBy;

    @Column(name = "finance_confirmed_at")
    private OffsetDateTime financeConfirmedAt;

    @Column(name = "finance_confirmed_by")
    private UUID financeConfirmedBy;

    @Column(name = "finance_returned_at")
    private OffsetDateTime financeReturnedAt;

    @Column(name = "finance_returned_by")
    private UUID financeReturnedBy;

    @Column(name = "finance_return_reason")
    private String financeReturnReason;

    @Column(name = "finance_remark")
    private String financeRemark;

    /** 核价修订号: 提交/撤回/财务修改/退回/确认/重新打开各加 1, 所有核价动作带期望值防并发覆盖。 */
    @Column(name = "review_revision", nullable = false)
    private int reviewRevision;
}
