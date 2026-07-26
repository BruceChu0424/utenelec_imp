package com.uten.imp.features.sales.order;

import com.uten.imp.common.domain.BaseEntity;
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
 * 销售订单 BOM 展开子表。源 S_OrderCostItem（老库 718 行，约 93% 订单未展开）。
 *
 * <p>parent_id 自挂 BOM 层级 / level 深度（最深 30）。本期结构保未来 MRP，成本重算逻辑后置
 * （design doc 20 §一·13）。Java 端只读，迁移负责原样落。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "sales_order_cost_items")
public class SalesOrderCostItem extends BaseEntity {

    private Integer legacyId;

    @Column(name = "bill_no")
    private String billNo;

    @Column(name = "bill_date")
    private LocalDate billDate;

    @Column(name = "order_item_id", nullable = false)
    private UUID orderItemId;

    @Column(name = "parent_id")
    private UUID parentId;

    @Column(name = "level", nullable = false)
    private Integer level = 0;

    /** 0=父件 / 非 0=子件。 */
    @Column(name = "class_code")
    private Integer classCode;

    @Column(name = "goods_id")
    private UUID goodsId;

    @Column(name = "color_id")
    private UUID colorId;

    @Column(name = "alt_goods_id")
    private UUID altGoodsId;

    @Column(name = "alt_color_id")
    private UUID altColorId;

    @Column(name = "unit_id")
    private UUID unitId;

    @Column(name = "qty", precision = 18, scale = 4)
    private BigDecimal qty;

    @Column(name = "order_qty", precision = 18, scale = 4)
    private BigDecimal orderQty = BigDecimal.ZERO;

    @Column(name = "received_qty", precision = 18, scale = 4)
    private BigDecimal receivedQty = BigDecimal.ZERO;

    @Column(name = "draw_qty", precision = 18, scale = 4)
    private BigDecimal drawQty = BigDecimal.ZERO;

    @Column(name = "purge_qty", precision = 18, scale = 4)
    private BigDecimal purgeQty = BigDecimal.ZERO;

    @Column(name = "other_draw_qty", precision = 18, scale = 4)
    private BigDecimal otherDrawQty = BigDecimal.ZERO;

    @Column(name = "supplier_id")
    private UUID supplierId;

    @Column(name = "l_status")
    private Short lStatus = 0;

    @Column(name = "source_doc_no")
    private String sourceDocNo;

    private String remark;
}
