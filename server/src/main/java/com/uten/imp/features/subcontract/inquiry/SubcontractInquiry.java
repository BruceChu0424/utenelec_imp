package com.uten.imp.features.subcontract.inquiry;

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
 * 委外询价单主表（委外管理）。源 E_Ask（0 行·建结构保未来）。
 *
 * <p>链路起点：审核仅状态变更（无库存联动、无上游回写、无应收应付）。
 * 与采购申请单 {@code PurchaseRequest} 同构（无物流无 ArAp），但带供应商/币种。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "subcontract_inquiries")
public class SubcontractInquiry extends SoftDeletableEntity {

    @Column(name = "legacy_id", unique = true)
    private Integer legacyId;            // E_Ask.ID

    @Column(name = "bill_no", nullable = false)
    private String billNo;

    @Column(name = "bill_date", nullable = false)
    private LocalDate billDate;

    @Column(name = "supplier_id")
    private UUID supplierId;             // VendID（委外商）

    @Column(name = "warehouse_id")
    private UUID warehouseId;            // StockID

    @Column(name = "currency_id")
    private UUID currencyId;

    @Column(name = "exchange_rate", precision = 18, scale = 6)
    private BigDecimal exchangeRate;

    @Column(name = "maker_id")
    private UUID makerId;                // MakeID（无 FK）

    @Column(name = "approver_id")
    private UUID approverId;

    @Column(name = "deliver_date")
    private LocalDate deliverDate;       // SendDate

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
