package com.uten.imp.features.sales.other_shipment.dto;

import jakarta.validation.constraints.NotNull;
import lombok.Getter;
import lombok.Setter;

import java.math.BigDecimal;
import java.util.UUID;

/** 其它出货保存请求中的明细行（order_item_id 字段留位但业务不挂单，前端默认不显示）。 */
@Getter
@Setter
public class OtherShipmentItemLine {

    private Integer lineNo;

    /** 留位字段，前端默认不传（业务上不挂订单）。 */
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
    /** SPrice 材料价。 */
    private BigDecimal materialPrice;
    /** WPrice 压铸价。 */
    private BigDecimal dieCastPrice;
    /** JPrice 机加价。 */
    private BigDecimal machiningPrice;
    /** KQTY2 围数。 */
    private BigDecimal circumference;
    /** Discount 折扣。 */
    private BigDecimal discount;
    private String sourceDocNo;
    private String remark;
}
