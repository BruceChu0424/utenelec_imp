package com.uten.imp.features.purchase.request;

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

/** 采购申请单主表（采购管理）。源 P_Application。链路起点：无供应商/币种（本币），审核无库存联动。 */
@Getter @Setter @NoArgsConstructor @Entity @Table(name = "purchase_requests")
public class PurchaseRequest extends SoftDeletableEntity {
    @Column(name = "legacy_id", unique = true) private Integer legacyId;
    @Column(name = "bill_no", nullable = false) private String billNo;
    @Column(name = "bill_date", nullable = false) private LocalDate billDate;
    @Column(name = "warehouse_id") private UUID warehouseId;
    @Column(name = "applicant_id") private UUID applicantId;
    @Column(name = "maker_id") private UUID makerId;
    @Column(name = "approver_id") private UUID approverId;
    @Column(name = "applicant_legacy_id") private Integer applicantLegacyId;
    @Column(name = "maker_legacy_id") private Integer makerLegacyId;
    @Column(name = "approver_legacy_id") private Integer approverLegacyId;
    @Column(name = "need_date") private LocalDate needDate;
    private String remark;
    @Column(name = "total_original", precision = 18, scale = 4) private BigDecimal totalOriginal;
    @Column(name = "total_local", precision = 18, scale = 4) private BigDecimal totalLocal;
    @Column(name = "status", nullable = false) private Short status = 0;
    @Column(name = "is_closed", nullable = false) private boolean closed = false;
    /** 老库 Stop 位（是否中止）。V65 默认 FALSE，用 Boolean 包装以兼容历史 NULL。 */
    @Column(name = "is_stopped") private Boolean isStopped = false;
    @Column(name = "source_doc_no") private String sourceDocNo;
}
