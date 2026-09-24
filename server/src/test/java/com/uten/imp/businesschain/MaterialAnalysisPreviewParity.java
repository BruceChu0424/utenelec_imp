package com.uten.imp.businesschain;

import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.AnalysisView;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.MaterialView;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.ProductView;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;
import java.util.function.Function;

/**
 * ADR-116 下达预览一致性: 「预览结果」与「真实下达后 GET 详情」逐行逐字段比对。
 *
 * <p>比的是预览要回答的全部数量口径——物料行的需求/库存/在途/缺口/还需安排/计划产出/
 * 内部承诺, 来源行与锚点的配额/已提交/已审核/剩余/可排/齐套。真实下达后才存在的东西
 * (新建锚点那一行、计划单号与执行进度)不在预览的回答范围内, 由调用方用 skip 显式排除
 * 本批「新锚点」的那几条物料行。</p>
 */
final class MaterialAnalysisPreviewParity {
    private MaterialAnalysisPreviewParity() {}

    private static final Map<String, Function<MaterialView, Object>> MATERIAL_FIELDS = new LinkedHashMap<>();
    private static final Map<String, Function<ProductView, Object>> PRODUCT_FIELDS = new LinkedHashMap<>();
    static {
        MATERIAL_FIELDS.put("requiredQty", MaterialView::requiredQty);
        MATERIAL_FIELDS.put("availableQty", MaterialView::availableQty);
        MATERIAL_FIELDS.put("allocatedAvailableQty", MaterialView::allocatedAvailableQty);
        MATERIAL_FIELDS.put("reservedQty", MaterialView::reservedQty);
        MATERIAL_FIELDS.put("safetyStockQty", MaterialView::safetyStockQty);
        MATERIAL_FIELDS.put("inboundQty", MaterialView::inboundQty);
        MATERIAL_FIELDS.put("shortageQty", MaterialView::shortageQty);
        MATERIAL_FIELDS.put("expectedReadyDate", MaterialView::expectedReadyDate);
        MATERIAL_FIELDS.put("lowerLevelPending", MaterialView::lowerLevelPending);
        MATERIAL_FIELDS.put("demandSupplyGapQty", MaterialView::demandSupplyGapQty);
        MATERIAL_FIELDS.put("additionalSupplyRecommendedQty", MaterialView::additionalSupplyRecommendedQty);
        MATERIAL_FIELDS.put("netShortageQty", MaterialView::netShortageQty);
        MATERIAL_FIELDS.put("plannedOutputQty", MaterialView::plannedOutputQty);
        MATERIAL_FIELDS.put("internalCommittedOutputQty", MaterialView::internalCommittedOutputQty);
        MATERIAL_FIELDS.put("externalFutureCoverageQty", MaterialView::externalFutureCoverageQty);
        MATERIAL_FIELDS.put("sourceRequiredQty", MaterialView::sourceRequiredQty);
        PRODUCT_FIELDS.put("requestedQty", ProductView::requestedQty);
        PRODUCT_FIELDS.put("submittedQty", ProductView::submittedQty);
        PRODUCT_FIELDS.put("approvedQty", ProductView::approvedQty);
        PRODUCT_FIELDS.put("remainingQty", ProductView::remainingQty);
        PRODUCT_FIELDS.put("issuedPlanQty", ProductView::issuedPlanQty);
        PRODUCT_FIELDS.put("canSchedule", ProductView::canSchedule);
        PRODUCT_FIELDS.put("canIssueSurplus", ProductView::canIssueSurplus);
        PRODUCT_FIELDS.put("maxSchedulableQty", ProductView::maxSchedulableQty);
        PRODUCT_FIELDS.put("readyNowQty", ProductView::readyNowQty);
        PRODUCT_FIELDS.put("readyByDateQty", ProductView::readyByDateQty);
        PRODUCT_FIELDS.put("readyStartQty", ProductView::readyStartQty);
        PRODUCT_FIELDS.put("readyFinishQty", ProductView::readyFinishQty);
        PRODUCT_FIELDS.put("readyShipQty", ProductView::readyShipQty);
        PRODUCT_FIELDS.put("readinessRatio", ProductView::readinessRatio);
    }

    /** 全部不一致的字段(空 = 逐字段相等); 物料行按 id、来源行按分析行 id 对齐。 */
    static List<String> mismatches(AnalysisView preview, AnalysisView afterIssue, Set<UUID> skipMaterialLines) {
        List<String> result = new ArrayList<>();
        Map<UUID, MaterialView> previewed = new LinkedHashMap<>();
        preview.flatMaterials().forEach(row -> previewed.putIfAbsent(row.materialLineId(), row));
        for (MaterialView actual : afterIssue.flatMaterials()) {
            if (skipMaterialLines.contains(actual.materialLineId())) continue;
            MaterialView expected = previewed.get(actual.materialLineId());
            if (expected == null) {
                result.add("material " + actual.goodsName() + " missing in preview");
                continue;
            }
            MATERIAL_FIELDS.forEach((name, field) -> {
                if (!same(field.apply(expected), field.apply(actual))) result.add("material " + actual.goodsName()
                        + "/" + actual.nodeKey() + "." + name + ": preview=" + field.apply(expected)
                        + " issued=" + field.apply(actual));
            });
        }
        Map<UUID, ProductView> products = new LinkedHashMap<>();
        preview.products().forEach(row -> products.put(row.analysisLineId(), row));
        for (ProductView actual : afterIssue.products()) {
            ProductView expected = products.get(actual.analysisLineId());
            // 真实下达当场新建的锚点: 预览不建行, 由其父物料行的数量体现。
            if (expected == null) continue;
            PRODUCT_FIELDS.forEach((name, field) -> {
                if (!same(field.apply(expected), field.apply(actual))) result.add("product " + actual.goodsName()
                        + "(" + actual.sourceType() + ")." + name + ": preview=" + field.apply(expected)
                        + " issued=" + field.apply(actual));
            });
        }
        return result;
    }

    private static boolean same(Object left, Object right) {
        if (left instanceof BigDecimal a && right instanceof BigDecimal b) return a.compareTo(b) == 0;
        return Objects.equals(left, right);
    }
}
