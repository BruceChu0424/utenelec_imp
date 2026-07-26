package com.uten.imp.features.subcontract.application;

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
 * 委外申请单主表（委外管理）。源 E_Application（0 行·建结构保未来）。
 *
 * <p>链路中间节点：审核仅状态变更（无库存联动、无应收应付）；被订货单审核回写
 * {@code application_items.ordered_qty}（design doc 22 §3.2，订货审核回写）。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "subcontract_applications")
public class SubcontractApplication extends SoftDeletableEntity {

    @Column(name = "legacy_id", unique = true)
    private Integer legacyId;            // E_Application.ID

    @Column(name = "bill_no", nullable = false)
    private String billNo;

    @Column(name = "bill_date", nullable = false)
    private LocalDate billDate;

    @Column(name = "supplier_id")
    private UUID supplierId;

    @Column(name = "warehouse_id")
    private UUID warehouseId;

    @Column(name = "applicant_id")
    private UUID applicantId;            // 申请人（无 FK）

    @Column(name = "maker_id")
    private UUID makerId;

    @Column(name = "approver_id")
    private UUID approverId;

    @Column(name = "need_date")
    private LocalDate needDate;          // 需求日

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
