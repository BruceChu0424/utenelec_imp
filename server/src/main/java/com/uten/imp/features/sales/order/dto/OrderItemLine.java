package com.uten.imp.features.sales.order.dto;

import com.uten.imp.common.finance.ServerDerivedAmounts;
import jakarta.validation.constraints.NotNull;
import lombok.Getter;
import lombok.Setter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

/** 销售订货保存请求中的明细行。 */
@Getter
@Setter
public class OrderItemLine implements ServerDerivedAmounts {

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
    /**
     * 销售可编辑的折扣倍率；新写 0 < discount <= 1，null/0 兼容为原价。报价转入的行由财务在报价上核定,
     * 改动按冲突拒绝(空 = 沿用报价折扣); 看不到价格的人保存时本字段被忽略(既有行保留, 新行按文件单价反推)。
     */
    private BigDecimal discount;
    private BigDecimal weight;
    private String clientNo;
    /** 客户文件上的型号/货号原文。 */
    @jakarta.validation.constraints.Size(max = 128, message = "文件型号不能超过 128 个字符")
    private String clientModel;
    /** ADR-134 客户文件上的品名/描述原文。 */
    @jakarta.validation.constraints.Size(max = 500, message = "文件品名不能超过 500 个字符")
    private String clientGoodsName;
    /** ADR-134 客户文件上的单价原文数值(币种见表头 clientFileCurrency), 只作参考。 */
    @jakarta.validation.constraints.DecimalMin(value = "0", message = "文件单价不能为负数")
    private BigDecimal clientPrice;
    /** 识别结果里的行键(只在请求里, 不落库)。 */
    @jakarta.validation.constraints.Size(max = 32)
    private String intakeLineKey;
    /** 用户明确选择/改成了这个货品(只在请求里)。 */
    private Boolean userConfirmed;
    /** 用户勾选「设为货品英文名」(只在请求里)。 */
    private Boolean setNameEn;
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
