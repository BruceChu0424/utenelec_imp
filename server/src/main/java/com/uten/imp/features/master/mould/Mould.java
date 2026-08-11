package com.uten.imp.features.master.mould;

import com.uten.imp.common.domain.SoftDeletableEntity;
import com.uten.imp.features.master.mouldcategory.MouldCategory;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.FetchType;
import jakarta.persistence.JoinColumn;
import jakarta.persistence.ManyToOne;
import jakarta.persistence.Table;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.math.BigDecimal;
import java.util.UUID;

/**
 * 模具主档（基础资料-模具资料）。
 *
 * 逐字段照抄 V34 moulds 表（id/审计/软删来自 {@link SoftDeletableEntity}）。
 * 老库 B_Mould 全字段迁移：legacy_id=B_Mould.ID（溯源+重跑幂等），
 * category_id 源自 B_Mould.ParentID→SystemItem.ItemID（ItemclassID=18）。
 *
 * 字段语义（老库字段名有误导，新库起清晰名，见 V34）：
 *   code←Number(模具编号)、name←MouldName、mnumber←Mnumber、
 *   qty←QTY(varchar "1+1")、tqty←TQTY(总数量)、
 *   mstatus←MStatus(制造年月)、status←[Status](使用/报废 生命周期)、
 *   place←Place(车间)、keeper←summary(保管人)、remark←Remark。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "moulds")
public class Mould extends SoftDeletableEntity {

    /** 老库 B_Mould.ID（迁移溯源+重跑幂等）；手工新建的为 null。 */
    @Column(name = "legacy_id", unique = true)
    private Integer legacyId;

    /** 所属模具分类（mould_categories.id）。@ManyToOne LAZY，仿 Goods category 写法。 */
    @ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "category_id")
    private MouldCategory category;

    // ===== 标识 / 名称 =====
    private String name;            // MouldName（模具名称）
    private String code;            // Number（模具编号，如 C20-001【B3-12】）
    @Column(name = "mnumber")
    private String mnumber;         // Mnumber（备用编号）

    // ===== 数量 =====
    private String qty;             // QTY（varchar，如 "1+1"）
    private BigDecimal tqty;        // TQTY（总数量）

    // ===== 状态 =====
    private String mstatus;         // MStatus（制造年月，如 2018年7月）
    private String status;          // [Status]（生命周期：使用/禁用）
    private String place;           // Place（车间/位置）
    private String keeper;          // summary（保管人）

    /** 车间部门 id（departments.id，对齐生产计划单；place 文本作 fallback 显示）。跨模块不建 FK。 */
    @Column(name = "department_id")
    private UUID departmentId;

    /** 保管人员工 id（employees.id，对齐生产计划单；keeper 文本作 fallback 显示）。跨模块不建 FK。 */
    @Column(name = "keeper_id")
    private UUID keeperId;

    private String remark;          // Remark（备注）
}
