package com.uten.imp.features.production;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.production.plan.ProductionPlan;
import com.uten.imp.features.production.plan.ProductionPlanItem;
import com.uten.imp.features.production.plan.dto.PlanSaveRequest;
import com.uten.imp.features.production.dailyreport.ProductionDailyReport;
import com.uten.imp.features.production.dailyreport.ProductionDailyReportItem;
import com.uten.imp.features.production.dailyreport.dto.DailyReportSaveRequest;

import java.math.BigDecimal;
import java.util.*;

/** Review edits preserve stored business identities; downstream validation remains in each owning service. */
public final class ProductionReviewedInputGuard {
    private ProductionReviewedInputGuard() { }
    private static final BigDecimal MAX_QUANTITY = new BigDecimal("99999999999999.9999");

    public static boolean planQuantityEditable(ProductionPlan header) {
        return header.getMaterialAnalysisId() == null && header.getActualOutputSupplementRequestId() == null;
    }

    public static void plan(ProductionPlan header, List<ProductionPlanItem> stored, PlanSaveRequest request) {
        require(request != null && Objects.equals(header.getBillDate(), request.getBillDate())
                && Objects.equals(header.getDepartmentId(), request.getDepartmentId())
                && Objects.equals(header.getSellerId(), request.getSellerId())
                && Objects.equals(header.getWorkerId(), request.getWorkerId()), "审核修改不能更换计划日期、车间或人员身份");
        require(request.getItems() != null && request.getItems().size() == stored.size(), "审核修改不能增删生产计划行");
        Map<UUID, ProductionPlanItem> originals = new HashMap<>();
        stored.forEach(item -> originals.put(item.getId(), item));
        Set<UUID> seen = new HashSet<>();
        for (var line : request.getItems()) {
            var before = line == null ? null : originals.get(line.getSourceItemId());
            require(before != null && seen.add(before.getId()), "审核修改必须保留每条原计划行身份");
            if(line.getPlatformFields() != null) require(Objects.equals(line.getPlatformFields().sourceRecordId(),before.getId()), "审核修改的扩展字段必须绑定本条原计划行");
            require(Objects.equals(before.getGoodsId(), line.getGoodsId())
                    && Objects.equals(before.getColorId(), line.getColorId())
                    && Objects.equals(before.getUnitId(), line.getUnitId())
                    && decimalEquals(before.getUnitRate(), line.getUnitRate())
                    && Objects.equals(before.getSalesOrderItemId(), line.getSalesOrderItemId()), "审核修改不能更换货品、颜色、单位或销售来源");
            if (line.getProductNo() != null) require(Objects.equals(before.getProductNo(), line.getProductNo()), "审核修改不能更换计划产品编号");
            if (line.getOqty() != null) require(decimalEquals(before.getOqty(), line.getOqty()), "来源订货数量不能通过审核修改");
            if (line.getAllowedOverproductionRate() != null) require(decimalEquals(before.getAllowedOverproductionRate(), line.getAllowedOverproductionRate()), "已冻结的超产授权比例不能通过审核修改");
            requireQuantity(line.getQty(), "排产量");
            if (!planQuantityEditable(header)) require(decimalEquals(before.getQty(), line.getQty()), "来源分析或追加申请已冻结计划量，请回原业务入口调整");
        }
    }

    public static void daily(ProductionDailyReport header, List<ProductionDailyReportItem> stored,
                             DailyReportSaveRequest request) {
        require(request != null && Objects.equals(header.getBillDate(), request.getBillDate())
                && Objects.equals(header.getDepartmentId(), request.getDepartmentId()), "审核修改不能更换日报日期或车间");
        if (request.getWarehouseId() != null) require(Objects.equals(header.getWarehouseId(), request.getWarehouseId()), "审核修改不能更换日报入库仓库");
        if (request.getSupplierId() != null) require(Objects.equals(header.getSupplierId(),request.getSupplierId()), "审核修改不能更换日报供应商");
        if (request.getSourceDocNo() != null) require(Objects.equals(header.getSourceDocNo(),request.getSourceDocNo()), "审核修改不能更换日报来源");
        Map<UUID, ProductionDailyReportItem> originals = new HashMap<>();
        Map<UUID, Set<UUID>> routes = new HashMap<>();
        Set<UUID> expectedGroups = new HashSet<>();
        for (var item : stored) {
            originals.put(item.getId(), item);
            UUID group = group(item);
            expectedGroups.add(group);
            routes.computeIfAbsent(group, ignored -> new HashSet<>()).add(item.getDirectTransferDemandId());
        }
        Set<UUID> seenGroups = new HashSet<>();
        require(request.getItems() != null && request.getItems().size() == expectedGroups.size(), "审核修改不能增删日报产出批次");
        for (var line : request.getItems()) {
            UUID source = line == null ? null : line.getReviewSourceItemId();
            var before = originals.get(source);
            require(before != null && seenGroups.add(group(before)), "审核修改必须保留每个原报工批次身份");
            if(line.getPlatformFields() != null) require(Objects.equals(line.getPlatformFields().sourceRecordId(),before.getId()), "审核修改的扩展字段必须绑定本个原报工批次");
            require(Objects.equals(before.getGoodsId(), line.getGoodsId())
                    && Objects.equals(before.getColorId(), line.getColorId())
                    && Objects.equals(before.getUnitId(), line.getUnitId())
                    && decimalEquals(before.getUnitRate(), line.getUnitRate())
                    && Objects.equals(before.getPlanItemId(), line.getPlanItemId())
                    && Objects.equals(before.getExecutionSegmentId(), line.getExecutionSegmentId())
                    && Objects.equals(before.getExecutionSegmentSalesAllocationId(), line.getExecutionSegmentSalesAllocationId())
                    && Objects.equals(before.getSalesOrderItemId(), line.getSalesOrderItemId())
                    && Objects.equals(before.getFqcRecoveryAuthorizationId(), line.getFqcRecoveryAuthorizationId())
                    && Objects.equals(before.getSupplementProofId(), line.getSupplementProofId()), "审核修改不能更换货品、计划、执行批次或原授权来源");
            requireQuantity(line.getQty(), "实际产量");
            if (before.getSupplementProofId() != null || before.getFqcRecoveryAuthorizationId() != null) {
                BigDecimal original = stored.stream().filter(item -> group(item).equals(group(before)))
                        .map(ProductionDailyReportItem::getQty).reduce(BigDecimal.ZERO, BigDecimal::add);
                require(decimalEquals(original, line.getQty()), "追加或品质恢复批次的授权数量已冻结");
            }
            Set<UUID> requestedRoutes = new HashSet<>();
            if (line.getAllocations() == null || line.getAllocations().isEmpty()) requestedRoutes.add(null);
            else line.getAllocations().forEach(route -> {
                require(route != null, "审核修改的产出去向不能为空");
                requestedRoutes.add(route.directTransferDemandId());
            });
            require(routes.get(group(before)).equals(requestedRoutes), "审核修改只能调整原产出去向份额，不能更换接收工单");
        }
    }

    private static UUID group(ProductionDailyReportItem item) {
        return item.getOutputBatchId() == null ? item.getId() : item.getOutputBatchId();
    }

    private static boolean decimalEquals(BigDecimal first, BigDecimal second) {
        return first == null ? second == null : second != null && first.compareTo(second) == 0;
    }

    private static void requireQuantity(BigDecimal value, String label) {
        if (value == null || value.signum() <= 0 || value.stripTrailingZeros().scale() > 4 || value.compareTo(MAX_QUANTITY) > 0)
            throw new ApiException(ErrorCode.VALIDATION_FAILED, label + "须大于 0，最多 14 位整数、4 位小数");
    }

    private static void require(boolean condition, String message) {
        if (!condition) throw new ApiException(ErrorCode.CONFLICT, message);
    }
}
