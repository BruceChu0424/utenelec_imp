package com.uten.imp.features.production.analysis;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.delivery.DeliveryPlan;
import com.uten.imp.common.delivery.DeliveryBom;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

/** Order delivery decisions are frozen independently from production consumption facts. */
final class MaterialAnalysisDeliverySnapshot {
    static final String ASSEMBLED = "{\"version\":1,\"mode\":\"ASSEMBLED\",\"packaging\":\"ORIGINAL\",\"nodeModes\":[],\"processes\":[]}";
    private static final ObjectMapper JSON = new ObjectMapper();

    private MaterialAnalysisDeliverySnapshot() { }

    static void freeze(EntityManager em, UUID analysisId) {
        // The ordinary admission lock already owns the selected sales rows. Never silently
        // replace the configuration behind existing allocations, plans or physical receipts.
        List<Object[]> changed = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT item.id, sales.id
                FROM production_material_analysis_items item
                JOIN sales_order_items sales ON sales.id=item.sales_order_item_id
                WHERE item.analysis_id=:id AND NOT item.is_deleted
                  AND item.source_type='SALES_ORDER_ITEM'
                  AND item.delivery_plan_snapshot IS NOT NULL
                  AND item.delivery_plan_snapshot IS DISTINCT FROM sales.delivery_plan
                LIMIT 1
                """).setParameter("id", analysisId));
        if (!changed.isEmpty()) throw conflict("销售交付方案已变化，请核对原分析及已有业务后重新建立分析，不能覆盖原快照");
        em.createNativeQuery("""
                UPDATE production_material_analysis_items item
                SET delivery_plan_snapshot=sales.delivery_plan,
                    delivery_plan_fingerprint=sales.delivery_plan->>'bomFingerprint'
                FROM sales_order_items sales
                WHERE item.analysis_id=:id AND NOT item.is_deleted
                  AND item.source_type='SALES_ORDER_ITEM'
                  AND sales.id=item.sales_order_item_id
                  AND item.delivery_plan_snapshot IS NULL
                """).setParameter("id", analysisId).executeUpdate();
    }

    static DeliveryPlan plan(String json) {
        try { return JSON.readValue(json == null || json.isBlank() ? ASSEMBLED : json, DeliveryPlan.class); }
        catch (JsonProcessingException ex) { throw conflict("订单交付方案快照不正确，请核对原销售单"); }
    }

    static boolean bom(String json) { return "BOM".equals(tree(json).path("mode").asText()); }

    private static JsonNode tree(String json) {
        try { return JSON.readTree(json == null || json.isBlank() ? ASSEMBLED : json); }
        catch (JsonProcessingException ex) { throw conflict("订单交付方案快照不正确，请核对原销售单"); }
    }

    static Set<String> splitPaths(String json) {
        Set<String> paths = new LinkedHashSet<>();
        for (JsonNode node : tree(json).path("nodeModes")) {
            if ("CHILDREN".equals(node.path("mode").asText())) paths.add(path(node.path("path")));
        }
        return Set.copyOf(paths);
    }

    static Map<String, List<String>> operations(String json) {
        Map<String, Set<String>> result = new LinkedHashMap<>();
        for (JsonNode node : tree(json).path("processes")) {
            if (!node.path("required").asBoolean()) continue;
            String operation = node.path("operation").asText();
            if (operation.isBlank()) continue;
            result.computeIfAbsent(path(node.path("path")), ignored -> new LinkedHashSet<>()).add(operation);
        }
        Map<String, List<String>> immutable = new LinkedHashMap<>();
        result.forEach((key, value) -> immutable.put(key, List.copyOf(value)));
        return Map.copyOf(immutable);
    }

    private static String path(JsonNode nodes) {
        List<String> result = new ArrayList<>();
        for (JsonNode node : nodes) {
            try { result.add(UUID.fromString(node.asText()).toString()); }
            catch (IllegalArgumentException ex) { throw conflict("交付层级必须使用原BOM边的完整路径"); }
        }
        return String.join("/", result);
    }

    /** Keep every original BOM row. Only effective split ancestors are transparent. */
    static List<MaterialAnalysisService.BomNode> project(
            MaterialAnalysisService.SourceLine source, List<MaterialAnalysisService.BomNode> nodes) {
        return project(source, nodes, null);
    }

    static List<MaterialAnalysisService.BomNode> project(
            MaterialAnalysisService.SourceLine source, List<MaterialAnalysisService.BomNode> nodes,
            DeliveryBom.Preview preview) {
        if (!source.bomDelivery()) return nodes;
        Set<String> splits = splitPaths(source.deliveryPlanJson());
        Map<String, List<String>> operations = new LinkedHashMap<>(operations(source.deliveryPlanJson()));
        Set<String> excludedPackaging = new LinkedHashSet<>();
        if (preview != null) {
            collectRules(preview.root(), operations, excludedPackaging,
                    preview.deliveryPlan().packaging() != DeliveryPlan.Packaging.ORIGINAL);
            for (var item : preview.items()) mergeOperations(operations, path(item.path()),
                    item.operations().stream().map(Enum::name).toList());
        }
        Map<String, Boolean> context = new HashMap<>();
        Set<String> suppressed = new LinkedHashSet<>();
        Map<String, MaterialAnalysisService.BomNode> rebased = new HashMap<>();
        List<MaterialAnalysisService.BomNode> result = new ArrayList<>(nodes.size());
        for (var node : nodes) {
            boolean parentContext = node.depth() == 1 || Boolean.TRUE.equals(context.get(node.parentNodeKey()));
            // Bulk delivery replaces customer-facing packaging. Packaging consumed
            // inside a whole manufactured boundary still belongs to that recipe.
            boolean suppress = parentContext && excludedPackaging.contains(node.nodeKey())
                    || suppressed.contains(node.parentNodeKey());
            if (suppress) suppressed.add(node.nodeKey());
            boolean transparent = !suppress && parentContext && splits.contains(node.nodeKey());
            if (transparent && !node.hasChildren()) throw conflict("按下级交付的BOM节点已没有下级，请重新确认销售交付方案");
            context.put(node.nodeKey(), transparent);
            boolean frontier = !suppress && parentContext && !transparent;
            MaterialAnalysisService.BomNode parent = rebased.get(node.parentNodeKey());
            var usage = parentContext ? MaterialAnalysisService.BomUsage.design(node.usage().designQty()) : node.usage();
            var parentPer = parent == null ? source.unitRate() : parent.perProductQty();
            var parentOutput = parent == null ? source.plannedOutputQty().multiply(source.unitRate())
                    : parent.snapshotRequiredQty();
            // Customer quantities use design usage along transparent paths. Existing actual
            // consumption/defect usage is retained below each manufactured delivery boundary.
            var per = MaterialConsumptionMath.effectivePerProduct(parentPer, usage.usedQty(),
                    node.consumptionBasis(), node.basisOutputQty());
            var required = suppress ? java.math.BigDecimal.ZERO : MaterialConsumptionMath.required(parentOutput, usage.usedQty(),
                    node.consumptionBasis(), node.basisOutputQty(), node.allowPartialPackage());
            var marked = node.withDelivery(transparent || suppress, frontier,
                    operations.getOrDefault(node.nodeKey(), List.of()), parentPer, usage, per, required);
            result.add(marked);
            rebased.put(node.nodeKey(), marked);
        }
        Set<String> present = nodes.stream().map(MaterialAnalysisService.BomNode::nodeKey)
                .collect(java.util.stream.Collectors.toSet());
        if (!present.containsAll(splits)) throw conflict("销售交付路径已变化或属于非按单用料，不能按旧路径下达生产");
        if (preview != null && !present.containsAll(preview.items().stream().map(item -> path(item.path())).toList()))
            throw conflict("交付BOM路径未完整载入，可能超过生产分析允许的十层或存在无效物料，不能遗漏后继续");
        return List.copyOf(result);
    }

    private static void collectRules(DeliveryBom.Node node, Map<String, List<String>> operations,
            Set<String> excludedPackaging, boolean bulk) {
        String key = path(node.path());
        mergeOperations(operations, key, node.requiredOperations().stream().map(Enum::name).toList());
        if (bulk && node.materialRole() == DeliveryBom.MaterialRole.PRODUCT_PACKAGING) excludedPackaging.add(key);
        node.children().forEach(child -> collectRules(child, operations, excludedPackaging, bulk));
    }

    private static String path(List<UUID> path) { return path.stream().map(UUID::toString).collect(java.util.stream.Collectors.joining("/")); }

    private static void mergeOperations(Map<String, List<String>> operations, String path, List<String> more) {
        Set<String> joined = new LinkedHashSet<>(operations.getOrDefault(path, List.of()));
        joined.addAll(more);
        operations.put(path, List.copyOf(joined));
    }

    private static ApiException conflict(String message) { return new ApiException(ErrorCode.CONFLICT, message); }
}
