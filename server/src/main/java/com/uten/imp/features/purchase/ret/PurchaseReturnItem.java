package com.uten.imp.features.purchase.ret;

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

/** 采购退货明细。源 P_WithdrawItem。receipt_item_id→收货明细、order_item_id→订货明细（审核回写 returned_qty）。 */
@Getter @Setter @NoArgsConstructor @Entity @Table(name = "purchase_return_items")
public class PurchaseReturnItem extends BaseEntity {
    private Integer legacyId;
    @Column(name = "bill_no") private String billNo;
    @Column(name = "bill_date") private LocalDate billDate;
    @Column(name = "return_id", nullable = false) private UUID returnId;
    @Column(name = "receipt_item_id") private UUID receiptItemId;
    @Column(name = "order_item_id") private UUID orderItemId;
    private Integer lineNo;
    @Column(name = "goods_id", nullable = false) private UUID goodsId;
    @Column(name = "color_id") private UUID colorId;
    @Column(name = "unit_id") private UUID unitId;
    @Column(name = "unit_rate", precision = 18, scale = 6) private BigDecimal unitRate;
    @Column(name = "qty", nullable = false, precision = 18, scale = 4) private BigDecimal qty;
    @Column(name = "price", precision = 18, scale = 4) private BigDecimal price;
    @Column(name = "amount_original", precision = 18, scale = 4) private BigDecimal amountOriginal;
    @Column(name = "amount_local", precision = 18, scale = 4) private BigDecimal amountLocal;
    @Column(name = "weight", precision = 18, scale = 4) private BigDecimal weight;
    @Column(name = "source_doc_no") private String sourceDocNo;
    private String remark;
}
