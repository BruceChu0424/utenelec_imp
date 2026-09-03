package com.uten.imp.features.subcontract.order.dto;

import jakarta.validation.constraints.NotNull;
import lombok.Getter;
import lombok.Setter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/** 委外订货单保存请求中的明细行（create/update 嵌套）。 */
@Getter
@Setter
public class OrderItemLine {

    private Integer lineNo;

    @NotNull
    private UUID goodsId;

    /**
     * 明细级委外商（可选）：覆盖表头供应商，用于「一张订货单录入多个委外商、保存按委外商自动拆单」。
     * 为空时使用 {@link OrderSaveRequest#getSupplierId()}。
     */
    private UUID supplierId;

    /**
     * 明细级结算方式（可选，2026-09 行级商业条款）：与币种/汇率/税率一样逐行录入，
     * 批量创建时按「委外商+商业条款」组合拆单，每组条款归集到该张单的头字段。
     * 为空时使用 {@link OrderSaveRequest#getSettlementMethodId()}；单张创建/编辑
     * 路径行值必须与表头一致（一单一套条款）。
     */
    private UUID settlementMethodId;

    /** 明细级币种：为空回落表头；拆单分组维度之一。 */
    private UUID currencyId;

    /** 明细级汇率：为空回落表头；拆单分组维度之一（委外历史单固定 1，新单可跨币种）。 */
    private BigDecimal exchangeRate;

    /** 明细级税率(%，0-100)：为空回落表头；拆单分组维度之一。 */
    private BigDecimal taxRate;

    private UUID colorId;
    private UUID unitId;
    private BigDecimal unitRate;

    @NotNull
    private BigDecimal qty;

    private BigDecimal price;
    private BigDecimal amountOriginal;
    private BigDecimal amountLocal;

    /**
     * 申请明细真FK（申请分解行必填；审核订货时回写 ordered_qty）。
     * V304 起允许为空 = 委外自建手工行（无申请来源），提交财务时只对非空行做来源校验。
     */
    private UUID applicationItemId;

    /**
     * 多来源申请明细（V463/ADR-069 同货品合并行）：非空时本行数量按各申请行
     * 剩余量 FIFO 拆分落 subcontract_order_item_sources，末位来源吸收超额（超委外）；
     * {@link #applicationItemId} 作为首来源（主锚点，兼容历史消费方）。
     * 与 applicationItemId 合并去重后按「需求日期升序、id 升序」稳定排序；
     * 两者皆空 = 手工行（不落 sources）。
     */
    private List<UUID> applicationItemIds;

    private LocalDate deliverDate;
    private BigDecimal weight;

    private String sourceDocNo;
    private String remark;

    /**
     * 本行全部来源申请明细（稳定顺序）：applicationItemIds 非空取其与
     * applicationItemId 的并集，否则单来源；手工行为空列表。
     */
    public List<UUID> resolvedApplicationItemIds() {
        if (applicationItemIds == null || applicationItemIds.isEmpty()) {
            return applicationItemId == null ? List.of() : List.of(applicationItemId);
        }
        var linked = new java.util.LinkedHashSet<UUID>();
        if (applicationItemId != null) {
            linked.add(applicationItemId);
        }
        linked.addAll(applicationItemIds);
        return List.copyOf(linked);
    }
}
