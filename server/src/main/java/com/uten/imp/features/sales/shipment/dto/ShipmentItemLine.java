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

    /**
     * 新流程必须关联已审订货明细；货品/单位/换算率及商业金额均由服务端按来源覆盖。
     * NULL 仅用于历史兼容，零星无订单出库应走其它出货单。
     */
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
