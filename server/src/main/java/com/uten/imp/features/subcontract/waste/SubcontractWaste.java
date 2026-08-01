package com.uten.imp.features.subcontract.waste;

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
 * 委外材料损耗单主表（委外管理）。源 E_SWaste（3 行，含 waste_rate/cause）。
 *
 * <p>无币种、无 Price。审核（status 0→1）在同一事务内：
 * <ol>
 *   <li><b>回写 {@code material_issue_items.wasted_qty += qty}</b>（新库补全老库缺失链路，
 *       design doc 22 §一决策6 / §六）</li>
 * </ol>
 * 发料审核已经扣减公司仓库存，供应商处报损不能再次扣公司仓。
 * <b>不立应付</b>（损耗是加工过程损耗，不是加工费结算）。
 *
 * <p>特有字段：{@code total_weight}（主表汇总重量）；明细含 {@code waste_rate}/{@code cause}/
 * {@code ending_qty}/{@code standard_qty}。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "subcontract_wastes")
public class SubcontractWaste extends SoftDeletableEntity {

    @Column(name = "legacy_id", unique = true)
    private Integer legacyId;            // E_SWaste.ID

    @Column(name = "bill_no", nullable = false)
    private String billNo;

    @Column(name = "bill_date", nullable = false)
    private LocalDate billDate;

    @Column(name = "supplier_id")
    private UUID supplierId;

    @Column(name = "warehouse_id")
    private UUID warehouseId;            // 发料来源仓（追溯；报损不再次出库）

    @Column(name = "worker_id")
    private UUID workerId;               // WorkerID（无 FK）

    @Column(name = "maker_id")
    private UUID makerId;

    @Column(name = "approver_id")
    private UUID approverId;

    /** Weight 主表汇总重量。 */
    @Column(name = "total_weight", precision = 18, scale = 4)
    private BigDecimal totalWeight;

    private String remark;

    /** 无币种。 */
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
