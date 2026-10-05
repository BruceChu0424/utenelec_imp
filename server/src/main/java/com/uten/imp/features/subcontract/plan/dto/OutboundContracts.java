package com.uten.imp.features.subcontract.plan.dto;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

/**
 * 仓库委外出仓工作台契约(ADR-143 §4.3, 仓库视角: 无价格/金额字段)。
 *
 * <p>一行 = 一张委外人员已提交、仓库还没发出的领料草稿(委外材料出仓单)。拣货改少与审核出仓
 * 仍走既有委外材料出仓单的保存/审核端点。
 */
public final class OutboundContracts {

    private OutboundContracts() {
    }

    /** 待发料任务列表行: 一张待发的领料草稿。 */
    public record OutboundTaskListItem(
            UUID issueId,
            String issueBillNo,
            UUID planId,
            UUID orderId,
            String orderBillNo,
            String supplierName,
            UUID warehouseId,
            String warehouseName,
            int lineCount,
            int materialKindCount,
            OffsetDateTime submittedAt,
            String submittedByName) {
    }

    /** 待发料任务详情(拣货页): 草稿头 + 每行的申请量/当前量/该仓可拣量。 */
    public record OutboundTaskDetail(
            UUID issueId,
            String issueBillNo,
            UUID planId,
            UUID orderId,
            String orderBillNo,
            String supplierName,
            UUID warehouseId,
            String warehouseName,
            /** 草稿行版本(数据库行版本, 不透明): 只用于前端判断拣货期间草稿是否被别人改过。 */
            long version,
            List<OutboundTaskLine> lines) {
        public OutboundTaskDetail {
            lines = List.copyOf(lines);
        }
    }

    /**
     * 拣货行。{@code requestedQty} 是委外人员提交的领料数量(仓库只能改少); {@code qty} 是当前拣货量;
     * {@code stockAvailableQty} = 本单本行已占用的量 + 该仓此刻其余合格可用量(基本单位)。
     */
    public record OutboundTaskLine(
            UUID issueItemId,
            UUID planItemId,
            Integer lineNo,
            String parentGoodsName,
            String parentGoodsCode,
            UUID goodsId,
            String goodsCode,
            String goodsName,
            String colorName,
            String unitName,
            BigDecimal requestedQty,
            BigDecimal qty,
            BigDecimal stockAvailableQty,
            String locationHint) {
    }

    /** 仓库整张退回一张领料草稿(本次不发)。reason 必填, 不超过 200 字, 会告诉提交领料的委外人员。 */
    public record ReturnToDrawRequest(String reason) {
    }
}
