package com.uten.imp.features.master.goods;

import com.uten.imp.common.domain.SoftDeletableEntity;
import com.uten.imp.features.master.materialcategory.MaterialCategory;
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

/**
 * 货品主档（基础资料-货品资料）。
 *
 * 逐字段照抄 V32 goods 表（id/审计/软删来自 {@link SoftDeletableEntity}）。
 * 老库 B_Goods 全字段迁移：legacy_id=B_Goods.ID（溯源+重跑幂等），
 * category_id 源自 B_Goods.ParentID→SystemItem.ItemID。
 *
 * 关联字段（Unit/Color/Mould/Client/Vend/...）保留 *_legacy_id INT（老库主键，暂不建 FK，
 * 待对应主档表迁移后再加约束）。图片列建 bytea 但本次迁移不灌二进制（多数货品无图），结构留位。
 *
 * 类型映射：DOUBLE PRECISION→Double，NUMERIC(18,4)→BigDecimal，INT→Integer，
 *           TEXT→String，BOOLEAN→Boolean，BYTEA→byte[]。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "goods")
public class Goods extends SoftDeletableEntity {

    /** 老库 B_Goods.ID（迁移溯源+重跑幂等）；手工新建的为 null。 */
    @Column(name = "legacy_id", unique = true)
    private Integer legacyId;

    /** 所属分类（material_categories.id）。@ManyToOne LAZY，仿 Department parent 写法。 */
    @ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "category_id")
    private MaterialCategory category;

    // ===== 标识 / 名称 =====
    private String code;            // ANumber 编号
    private String name;            // Goods_Name 名称
    @Column(name = "short_name")
    private String shortName;       // Short_Name
    private String model;           // Number 型号
    private String spec;            // Standard 规格

    // ===== 关联（老库主键，暂不 FK） =====
    @Column(name = "unit_legacy_id")
    private Integer unitLegacyId;       // UnitID
    @Column(name = "color_legacy_id")
    private Integer colorLegacyId;      // MColorID
    @Column(name = "mould_legacy_id")
    private Integer mouldLegacyId;      // MouldID
    @Column(name = "client_legacy_id")
    private Integer clientLegacyId;     // ClientID
    @Column(name = "vend_legacy_id")
    private Integer vendLegacyId;       // VendID
    @Column(name = "vend2_legacy_id")
    private Integer vend2LegacyId;      // VendID2
    @Column(name = "assteam_legacy_id")
    private Integer assteamLegacyId;    // AssTeamID
    @Column(name = "veil_legacy_id")
    private Integer veilLegacyId;       // VeilID
    @Column(name = "approver_legacy_id")
    private Integer approverLegacyId;   // ApproverID
    @Column(name = "make_legacy_id")
    private Integer makeLegacyId;       // MakeID

    /** 归属业务员（外贸系列按人授权；NULL=公共货品全员可见）。V85 新增。 */
    @Column(name = "owner_employee_id")
    private java.util.UUID ownerEmployeeId;

    // ===== 价格 / 数量 =====
    private Double price;               // Price (DOUBLE PRECISION)
    @Column(name = "a_price")
    private BigDecimal aPrice;          // APrice
    private BigDecimal price2;          // Price2
    @Column(name = "max_qty")
    private Double maxQty;              // Max_QTY (DOUBLE PRECISION)
    @Column(name = "min_qty")
    private Double minQty;              // Min_QTY (DOUBLE PRECISION)
    @Column(name = "init_stock")
    private Integer initStock;          // InitStock
    @Column(name = "init_count")
    private BigDecimal initCount;       // InitCount
    @Column(name = "init_weight")
    private BigDecimal initWeight;      // InitWeight
    private BigDecimal kqty;            // KQTY
    private BigDecimal kqty2;           // KQTY2
    private Integer pieces;             // Pieces
    @Column(name = "lost_rate")
    private BigDecimal lostRate;        // LostRate
    private Double cap;                 // CAP (DOUBLE PRECISION)

    // ===== 物理属性 =====
    private String material;            // Material
    private BigDecimal thickness;       // Thickness
    @Column(name = "l_style")
    private String lStyle;              // LStyle
    @Column(name = "z_weight")
    private BigDecimal zWeight;         // ZWeight
    @Column(name = "m_weight")
    private BigDecimal mWeight;         // MWeight
    private String pack;                // Pack
    @Column(name = "b_pack")
    private String bPack;               // BPack
    private String paper;               // Paper
    private String series;              // Series
    @Column(name = "chart_id")
    private String chartId;             // ChartID
    private String lights;              // Lights
    @Column(name = "stock_place")
    private String stockPlace;          // StockPlace
    @Column(name = "c_number")
    private String cNumber;             // CNumber
    @Column(name = "v_number")
    private String vNumber;             // VNumber
    @Column(name = "bs_test")
    private String bsTest;              // BSTest
    @Column(name = "require_remark")
    private String requireRemark;       // Require（保留字避让）

    // ===== 成本项 =====
    @Column(name = "source_e")
    private BigDecimal sourceE;         // SourceE
    @Column(name = "work_e")
    private BigDecimal workE;           // WorkE
    @Column(name = "lacquer_e")
    private BigDecimal lacquerE;        // LacquerE
    @Column(name = "incidental_e")
    private BigDecimal incidentalE;     // IncidentalE
    @Column(name = "plating_e")
    private BigDecimal platingE;        // PlatingE
    @Column(name = "casing_e")
    private BigDecimal casingE;         // CasingE
    @Column(name = "manage_e")
    private BigDecimal manageE;         // ManageE
    @Column(name = "polish_e")
    private BigDecimal polishE;         // PolishE
    @Column(name = "electric_e")
    private BigDecimal electricE;       // ElectricE
    @Column(name = "machining_e")
    private BigDecimal machiningE;      // MachiningE
    @Column(name = "lost_e")
    private BigDecimal lostE;           // LostE
    @Column(name = "rent_e")
    private BigDecimal rentE;           // RentE
    @Column(name = "make_e")
    private BigDecimal makeE;           // MakeE
    @Column(name = "work_rate")
    private BigDecimal workRate;        // WorkRate
    @Column(name = "make_rate")
    private BigDecimal makeRate;        // MakeRate
    @Column(name = "rent_rate")
    private BigDecimal rentRate;        // RentRate
    private BigDecimal total;           // Total
    @Column(name = "c_total")
    private BigDecimal cTotal;          // CTotal
    @Column(name = "g_total")
    private BigDecimal gTotal;          // GTotal

    // ===== 状态 / 标志 =====
    @Column(name = "bom_status")
    private Boolean bomStatus;          // BomStatus (bit)
    private String status;              // Status
    @Column(name = "app_status")
    private Integer appStatus;          // AppStatus
    @Column(name = "app_status2")
    private Integer appStatus2;         // AppStatus2
    @Column(name = "g_style")
    private Integer gStyle;             // GStyle
    private Integer ck;                 // ck
    private BigDecimal zk;              // zk

    // ===== 图片（bytea，本次建列不迁二进制，结构留位，后续 bcp 灌图） =====
    @Column(name = "ground_graph")
    private byte[] groundGraph;         // GroundGraph
    @Column(name = "product_graph1")
    private byte[] productGraph1;       // ProductGraph1
    @Column(name = "product_graph2")
    private byte[] productGraph2;       // ProductGraph2
    @Column(name = "product_graph3")
    private byte[] productGraph3;       // ProductGraph3
    @Column(name = "product_graph4")
    private byte[] productGraph4;       // ProductGraph4
    @Column(name = "product_graph5")
    private byte[] productGraph5;       // ProductGraph5
    @Column(name = "product_graph6")
    private byte[] productGraph6;       // ProductGraph6
    @Column(name = "budget_graph")
    private byte[] budgetGraph;         // BudgetGraph
}
