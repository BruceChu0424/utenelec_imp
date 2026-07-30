package com.uten.imp.features.production.dailyreport;

import com.uten.imp.common.domain.SoftDeletableEntity;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Table;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.time.LocalDate;
import java.util.UUID;

/**
 * 生产日报单头（生产管理 · 源 F_DateReport，<b>0 行 · 空结构保未来</b>）。
 *
 * <p>F_DateReport 老库从未启用（字段类型自相矛盾，design §3.4）。本期建空结构，
 * 保未来启用零成本（同采购 P_Ask / 仓库 O_Waste 先例）。
 *
 * <p>状态机同生产计划：status 0 草稿 / 1 已审 / -1 红冲。
 * <p><b>【本期后置】</b>日报审核未来需调 {@code StockService}（产成品进仓等），
 * 本期不实现（design §四 F_DateReport 触发器全 0）。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "production_daily_reports")
public class ProductionDailyReport extends SoftDeletableEntity {

    @Column(name = "legacy_id", unique = true)
    private Integer legacyId;

    @Column(name = "bill_no", nullable = false)
    private String billNo;

    @Column(name = "bill_date", nullable = false)
    private LocalDate billDate;

    /** StockID（F_DateReport 是 int ID，与 F_Plan varchar 矛盾，本期统一为 FK）。 */
    @Column(name = "warehouse_id")
    private UUID warehouseId;

    /** WorkShop（同 plans，能对齐才填）。 */
    @Column(name = "department_id")
    private UUID departmentId;

    /** WorkShop 原样留底（与 plans 一致，design §7.4）。 */
    @Column(name = "workshop_name")
    private String workshopName;

    /** WorkerID 报工人（迁移留空）。 */
    @Column(name = "worker_id")
    private UUID workerId;

    /** VendID 委外供应商？（语义存疑，留位）。 */
    @Column(name = "supplier_id")
    private UUID supplierId;

    @Column(name = "maker_id")
    private UUID makerId;

    @Column(name = "approver_id")
    private UUID approverId;

    @Column(name = "maker_legacy_id")
    private Integer makerLegacyId;

    @Column(name = "approver_legacy_id")
    private Integer approverLegacyId;

    private String remark;

    @Column(name = "status", nullable = false)
    private Short status = 0;

    @Column(name = "is_closed", nullable = false)
    private boolean closed = false;

    @Column(name = "is_canceled", nullable = false)
    private boolean canceled = false;

    @Column(name = "source_doc_no")
    private String sourceDocNo;
}
