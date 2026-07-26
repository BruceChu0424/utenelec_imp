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
import java.util.UUID;

/**
 * 销售报价单主表（销售管理）。源 S_Quote（老库 0 行，建结构保未来）。
 *
 * <p>报价无币种/税率/结帐方式（老库 S_Quote 最简主表），新库补 valid_until（报价有效期）。
 * 审核无库存/应收副作用；明细 {@link SalesQuoteItem} 独立仓库管理。
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

    /** 0 草稿 / 1 已审 / -1 红冲。 */
    @Column(name = "status", nullable = false)
    private Short status = 0;

    @Column(name = "is_closed", nullable = false)
    private boolean closed = false;

    @Column(name = "source_doc_no")
    private String sourceDocNo;
}
