package com.uten.imp.features.sales.shipment.dto;

import jakarta.validation.constraints.NotNull;
import lombok.Getter;
import lombok.Setter;

import java.math.BigDecimal;
import java.util.UUID;

/** 销售出货保存请求中的明细行。 */
@Getter
@Setter
public class ShipmentItemLine {

    private Integer lineNo;

    /** 关联订货明细（可选；有则审核回写 shipped_qty），空=直销行。 */
    private UUID orderItemId;

    @NotNull
    private UUID goodsId;

    private UUID colorId;
    private UUID unitId;
    private BigDecimal unitRate;

    @NotNull
    private BigDecimal qty;

    private BigDecimal price;
    private BigDecimal amountOriginal;
    private BigDecimal amountLocal;
    private BigDecimal costAmount;
    private BigDecimal weight;
    private BigDecimal parcelQty;
    private BigDecimal cartonCount;
    private String clientNo;
    private String clientModel;
    /** SPrice 材料价（V66）。 */
    private BigDecimal materialPrice;
    /** WPrice 压铸价（V66）。 */
    private BigDecimal dieCastPrice;
    /** JPrice 机加价（V66）。 */
    private BigDecimal machiningPrice;
    /** KQTY2 围数（V66）。 */
    private BigDecimal circumference;
    /** Discount 折扣（V66）。 */
    private BigDecimal discount;
    private String sourceDocNo;
    private String remark;
}
