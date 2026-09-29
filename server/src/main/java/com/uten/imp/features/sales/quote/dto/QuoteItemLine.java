package com.uten.imp.features.sales.quote.dto;

import com.uten.imp.common.finance.ServerDerivedAmounts;
import jakarta.validation.constraints.DecimalMin;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;
import lombok.Getter;
import lombok.Setter;

import java.math.BigDecimal;
import java.util.UUID;

/**
 * 销售报价保存请求中的明细行。
 *
 * <p>单价不是写入来源: 新行取货品资料售价(未维护则为空, 标「待财务定价」), 同一草稿的既有行保留已冻结的
 * 单价(含财务设定的成交单价); price 只是页面预览, 与权威价不一致按冲突拒绝。金额由服务端计算。
 * 看不到价格的人保存时 discount 必须为空: 既有行保留原折扣, 新行按文件单价反推。
 */
@Getter
@Setter
public class QuoteItemLine implements ServerDerivedAmounts {

    /** 既有明细行 id(编辑草稿时回传, 用于保留冻结单价与修订对照); 新行留空。 */
    private UUID id;

    private Integer lineNo;

    @NotNull
    private UUID goodsId;

    private UUID colorId;
    private UUID unitId;
    private BigDecimal unitRate;

    @NotNull
    private BigDecimal qty;

    /** 页面预览单价(只校验, 不写入)。 */
    private BigDecimal price;
    /** 折扣倍率: 0 < 折扣 <= 1, 最多 4 位小数; 空/0 = 原价。 */
    private BigDecimal discount;
    private BigDecimal weight;
    private String remark;

    /** 客户文件上的型号/货号原文。 */
    @Size(max = 128, message = "文件型号不能超过 128 个字符")
    private String clientModel;
    /** 客户文件上的品名/描述原文。 */
    @Size(max = 500, message = "文件品名不能超过 500 个字符")
    private String clientGoodsName;
    /** 客户文件上的单价原文数值(币种见表头 clientFileCurrency), 只作参考。 */
    @DecimalMin(value = "0", message = "文件单价不能为负数")
    private BigDecimal clientPrice;

    /** 识别结果里的行键(只在请求里, 不落库; 学习时据此对上服务端识别结果)。 */
    @Size(max = 32)
    private String intakeLineKey;
    /** 用户在识别面板或明细里明确选择/改成了这个货品(只在请求里)。 */
    private Boolean userConfirmed;
    /** 用户勾选「设为货品英文名」(只在请求里)。 */
    private Boolean setNameEn;
}
