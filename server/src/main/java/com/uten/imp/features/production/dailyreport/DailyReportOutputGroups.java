package com.uten.imp.features.production.dailyreport;

import com.uten.imp.common.production.OutputLotText;
import com.uten.imp.features.production.dailyreport.dto.DailyReportItemDto;
import com.uten.imp.features.production.dailyreport.dto.DailyReportOutputBatch;
import com.uten.imp.features.production.dailyreport.dto.DailyReportOutputGroup;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * 报工详情的产出分组与审核摘要(ADR-148)：一次录入的批次一行，批内按实物交接批(库里的
 * output_lot_id)分去向组；摘要文案只在这里拼一次，页面直接显示。
 */
final class DailyReportOutputGroups {

    private DailyReportOutputGroups() {
    }

    /** {@code lotOfItem}：报工行 -> 库里生成的实物交接批号。 */
    static List<DailyReportOutputBatch> of(List<DailyReportItemDto> items, Map<UUID, UUID> lotOfItem) {
        Map<UUID, List<DailyReportItemDto>> batches = new LinkedHashMap<>();
        List<DailyReportItemDto> ordered = new ArrayList<>(items);
        ordered.sort(Comparator.comparing(DailyReportItemDto::getLineNo, Comparator.nullsLast(Comparator.naturalOrder()))
                .thenComparing(item -> item.getId().toString()));
        for (DailyReportItemDto item : ordered) {
            UUID batch = item.getOutputBatchId() == null ? item.getId() : item.getOutputBatchId();
            batches.computeIfAbsent(batch, ignored -> new ArrayList<>()).add(item);
        }
        List<DailyReportOutputBatch> result = new ArrayList<>(batches.size());
        for (Map.Entry<UUID, List<DailyReportItemDto>> batch : batches.entrySet()) {
            List<DailyReportItemDto> members = batch.getValue();
            Map<UUID, List<DailyReportItemDto>> lots = new LinkedHashMap<>();
            for (DailyReportItemDto item : members) {
                UUID lot = lotOfItem.getOrDefault(item.getId(), item.getId());
                lots.computeIfAbsent(lot, ignored -> new ArrayList<>()).add(item);
            }
            List<DailyReportOutputGroup> groups = new ArrayList<>(lots.size());
            BigDecimal total = BigDecimal.ZERO;
            for (Map.Entry<UUID, List<DailyReportItemDto>> lot : lots.entrySet()) {
                DailyReportOutputGroup group = group(lot.getKey(), lot.getValue());
                total = total.add(group.qty());
                groups.add(group);
            }
            // 直送转给上层工单的组排在前面(与报工页去向分配同序)，送入仓库最后。
            groups.sort(Comparator.comparing(group -> "WAREHOUSE".equals(group.destination())));
            DailyReportItemDto head = members.getFirst();
            BigDecimal batchQty = head.getOutputBatchQty() != null ? head.getOutputBatchQty() : total;
            String goods = firstNonBlank(head.getGoodsCode(), head.getGoodsName(), "本行产出");
            String summary = goods + " 共 " + OutputLotText.plain(batchQty) + "："
                    + String.join("；", groups.stream().map(DailyReportOutputGroup::summary).toList());
            result.add(new DailyReportOutputBatch(batch.getKey(), head.getId(),
                    members.stream().map(DailyReportItemDto::getId).toList(), batchQty, summary, groups));
        }
        return result;
    }

    private static DailyReportOutputGroup group(UUID lotId, List<DailyReportItemDto> members) {
        BigDecimal qty = BigDecimal.ZERO;
        BigDecimal demand = BigDecimal.ZERO;
        BigDecimal publicQty = BigDecimal.ZERO;
        BigDecimal surplus = BigDecimal.ZERO;
        String reason = null;
        for (DailyReportItemDto item : members) {
            BigDecimal value = item.getQty() == null ? BigDecimal.ZERO : item.getQty();
            qty = qty.add(value);
            if (item.isActualSurplus()) {
                surplus = surplus.add(value);
            } else if (item.isPublicOutput()) {
                publicQty = publicQty.add(value);
            } else {
                demand = demand.add(value);
                if (reason == null && item.getOutputRouteReasonText() != null
                        && !item.getOutputRouteReasonText().isBlank()) {
                    reason = item.getOutputRouteReasonText().strip();
                }
            }
        }
        DailyReportItemDto head = members.getFirst();
        boolean workshop = "WORKSHOP".equals(head.getDestination());
        String summary;
        if (workshop) {
            summary = "转给 " + firstNonBlank(head.getDirectTransferTargetLabel(), null, "上层工单")
                    + " " + OutputLotText.plain(qty);
        } else {
            List<String> notes = new ArrayList<>(2);
            List<String> shares = new ArrayList<>(2);
            if (publicQty.signum() > 0) shares.add("计划公共备货 " + OutputLotText.plain(publicQty));
            if (surplus.signum() > 0) shares.add("实际超产 " + OutputLotText.plain(surplus));
            if (!shares.isEmpty()) notes.add("其中" + String.join(" · ", shares));
            if (reason != null) notes.add(reason);
            summary = "送入仓库 " + OutputLotText.plain(qty)
                    + (notes.isEmpty() ? "" : "(" + String.join("；", notes) + ")");
        }
        return new DailyReportOutputGroup(lotId,
                members.stream().map(DailyReportItemDto::getId).toList(),
                head.getDestination(), head.getDirectTransferDemandId(),
                workshop ? head.getDirectTransferTargetLabel() : null,
                qty, demand, publicQty, surplus,
                OutputLotText.split(demand, publicQty, surplus), reason, summary);
    }

    private static String firstNonBlank(String first, String second, String fallback) {
        if (first != null && !first.isBlank()) return first.strip();
        if (second != null && !second.isBlank()) return second.strip();
        return fallback;
    }
}
