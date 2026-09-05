package com.uten.imp.features.sales.order.dto;

import jakarta.validation.constraints.NotNull;
import lombok.Getter;
import lombok.Setter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

/** 销售订货保存请求中的明细行。 */
@Getter
@Setter
public class OrderItemLine {

    /** 被驳回订单修订时用于稳定匹配既有行；新行留空。 */
    private UUID id;

    private Integer lineNo;

    @NotNull
    private UUID goodsId;

    private UUID colorId;
    private UUID unitId;
    private BigDecimal unitRate;

    @NotNull
    private BigDecimal qty;

    /**
     * 旧客户端兼容预览字段，不是写入权威：普通新行取货品主档价，报价转单取报价快照，
     * 既有草稿同一行保留已冻结价；非空预览值若与权威价不同则按冲突拒绝。
     */
    private BigDecimal price;
    /** 客户端预览兼容字段；持久化前由服务端按数量、权威单价和折扣重算。 */
    private BigDecimal amountOriginal;
    /** 销售订单阶段不形成本币金额；本字段被服务端忽略。 */
    private BigDecimal amountLocal;
    /** 销售可编辑的折扣倍率；新写 0 < discount <= 1，null/0 兼容为原价。 */
    private BigDecimal discount;
    private BigDecimal taxAmount;
    private BigDecimal weight;
    private String clientNo;
    private String clientModel;
    private LocalDate deliverDate;
    private String sourceDocNo;
    /** JPrice 机加价。 */
    private BigDecimal machiningPrice;
    /** KQTY2 围数。 */
    private BigDecimal circumference;
    /** IQTY 进仓数量（系统/报表用——通常只读，前端可不入录）。 */
    private BigDecimal inboundQty;
    /** InNo 成品进仓单号（系统字段，前端默认只读）。 */
    private String inNo;
    /** OutNo 销售出货单号（系统字段，前端默认只读）。 */
    private String outNo;
    private String remark;
}
