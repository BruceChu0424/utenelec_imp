package com.uten.imp.features.purchase.order.dto;

import jakarta.validation.constraints.NotNull;
import lombok.Getter;
import lombok.Setter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

@Getter
@Setter
public class OrderItemLine {
    private Integer lineNo;
    @NotNull private UUID goodsId;
    /**
     * 明细级供应商（可选）：覆盖表头供应商，用于「一张订货单录入多个供应商、保存按供应商自动拆单」。
     * 为空时使用 {@link OrderSaveRequest#getSupplierId()}。
     */
    private UUID supplierId;

    /**
     * 明细级结账方式（可选，2026-09 行级商业条款）：与币种/汇率/税率一样逐行录入，
     * 批量创建时按「供应商+商业条款」组合拆单，每组条款归集到该张单的头字段。
     * 为空时使用 {@link OrderSaveRequest#getSettlementMethodId()}；单张创建/编辑
     * 路径行值必须与表头一致（一单一套条款）。
     */
    private UUID settlementMethodId;

    /** 明细级币种：为空回落表头；拆单分组维度之一。 */
    private UUID currencyId;

    /** 明细级汇率：为空回落表头；拆单分组维度之一。 */
    private BigDecimal exchangeRate;

    /** 明细级税率(%，0-100)：为空回落表头；拆单分组维度之一。 */
    private BigDecimal taxRate;
    private UUID colorId;
    private UUID unitId;
    private BigDecimal unitRate;
    @NotNull private BigDecimal qty;
    private BigDecimal price;
    private BigDecimal amountOriginal;
    private BigDecimal amountLocal;
    private BigDecimal giftQty;
    /** 关联申请明细（单来源行；审核时回写 ordered_qty）。 */
    @NotNull private UUID requestItemId;
    /**
     * 多来源申请明细（V463/ADR-069 同货品合并行）：非空时本行数量按各申请行
     * 剩余量 FIFO 拆分落 purchase_order_item_sources，末位来源吸收超额（超采）；
     * {@link #requestItemId} 仍为必填且作为首来源（主锚点，兼容历史消费方）。
     * 与 requestItemId 合并去重后按「需求日期升序、id 升序」稳定排序。
     */
    private List<UUID> requestItemIds;
    private LocalDate deliverDate;
    private BigDecimal weight;
    private String sourceDocNo;
    private String remark;

    /**
     * 本行全部来源申请明细（稳定顺序：需求日期升序、id 升序）：
     * requestItemIds 非空取其与 requestItemId 的并集，否则单来源。
     */
    public List<UUID> resolvedRequestItemIds() {
        if (requestItemIds == null || requestItemIds.isEmpty()) {
            return requestItemId == null ? List.of() : List.of(requestItemId);
        }
        var linked = new java.util.LinkedHashSet<UUID>();
        if (requestItemId != null) {
            linked.add(requestItemId);
        }
        linked.addAll(requestItemIds);
        return List.copyOf(linked);
    }
}
