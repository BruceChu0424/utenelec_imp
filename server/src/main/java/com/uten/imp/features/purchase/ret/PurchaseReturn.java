package com.uten.imp.features.purchase.ret;

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

/** 采购退货单主表（采购管理）。源 P_Withdraw。审核→库存出库；红冲→入库冲销。 */
@Getter @Setter @NoArgsConstructor @Entity @Table(name = "purchase_returns")
public class PurchaseReturn extends SoftDeletableEntity {
    @Column(name = "legacy_id", unique = true) private Integer legacyId;
    @Column(name = "bill_no", nullable = false) private String billNo;
    @Column(name = "bill_date", nullable = false) private LocalDate billDate;
    @Column(name = "supplier_id") private UUID supplierId;
    @Column(name = "warehouse_id") private UUID warehouseId;
    @Column(name = "currency_id") private UUID currencyId;
    @Column(name = "exchange_rate", precision = 18, scale = 6) private BigDecimal exchangeRate;
    @Column(name = "tax_rate", precision = 18, scale = 4) private BigDecimal taxRate;
    @Column(name = "receiver_id") private UUID receiverId;
    @Column(name = "maker_id") private UUID makerId;
    @Column(name = "approver_id") private UUID approverId;
    @Column(name = "receiver_legacy_id") private Integer receiverLegacyId;
    @Column(name = "maker_legacy_id") private Integer makerLegacyId;
    @Column(name = "approver_legacy_id") private Integer approverLegacyId;
    /** 老库 PStyle（结帐方式原值，无字典，前端按字典常量渲染）。 */
    @Column(name = "settlement_style_legacy") private Short settlementStyleLegacy;
    private String remark;
    @Column(name = "total_original", precision = 18, scale = 4) private BigDecimal totalOriginal;
    @Column(name = "total_local", precision = 18, scale = 4) private BigDecimal totalLocal;
    @Column(name = "status", nullable = false) private Short status = 0;
    @Column(name = "is_closed", nullable = false) private boolean closed = false;
    @Column(name = "source_doc_no") private String sourceDocNo;
}
