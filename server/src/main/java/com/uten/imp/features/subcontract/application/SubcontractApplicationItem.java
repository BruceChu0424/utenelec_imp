package com.uten.imp.features.subcontract.application;

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
 * 委外申请明细。源 E_ApplicationItem。
 *
 * <p>{@code ordered_qty} 由订货单审核回写（{@code SubcontractOrderService.approve} 同事务累加），
 * 表达"申请已被订货消化多少"。design doc 22 §3.2 字段注释。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "subcontract_application_items")
public class SubcontractApplicationItem extends BaseEntity {

    private Integer legacyId;

    @Column(name = "bill_no")
    private String billNo;

    @Column(name = "bill_date")
    private LocalDate billDate;

    @Column(name = "application_id", nullable = false)
    private UUID applicationId;

    private Integer lineNo;

    @Column(name = "goods_id", nullable = false)
    private UUID goodsId;

    @Column(name = "color_id")
    private UUID colorId;

    @Column(name = "unit_id")
    private UUID unitId;

    @Column(name = "unit_rate", precision = 18, scale = 6)
    private BigDecimal unitRate;

    @Column(name = "qty", nullable = false, precision = 18, scale = 4)
    private BigDecimal qty;

    @Column(name = "price", precision = 18, scale = 4)
    private BigDecimal price;

    @Column(name = "amount_original", precision = 18, scale = 4)
    private BigDecimal amountOriginal;

    @Column(name = "amount_local", precision = 18, scale = 4)
    private BigDecimal amountLocal;

    /** 已订量（订货单审核回写：order_item.qty 累加）。 */
    @Column(name = "ordered_qty", precision = 18, scale = 4)
    private BigDecimal orderedQty = BigDecimal.ZERO;

    @Column(name = "weight", precision = 18, scale = 4)
    private BigDecimal weight;

    @Column(name = "source_doc_no")
    private String sourceDocNo;

    private String remark;
}
