package com.uten.imp.features.production.analysis;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.util.Collections;
import java.util.Comparator;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

/**
 * The source batch's original gross BOM requirement, independent of execution.
 * Callers provide admitted source lines, excluding MAKE_COMPONENT and
 * SUBCONTRACT_MAKE execution anchors whose requested quantities may grow.
 * Nodes retain their original source/path identity even after an anchor is made.
 *
 * <p>This projection neither reads stock nor consumes planned, fulfilled,
 * delegated or appended quantities. Missing ancestry is an invalid snapshot,
 * never permission to substitute the operational requirement or return zero.
 */
final class MaterialAnalysisSourceRequirementProjection {
    private MaterialAnalysisSourceRequirementProjection() { }

    record Source(UUID id, BigDecimal requestedQty, BigDecimal unitRate) { }

    record Node(UUID id, UUID analysisLineId, String nodeKey, String parentNodeKey,
                int level, BigDecimal bomQty, String consumptionBasis,
                BigDecimal basisOutputQty, boolean allowPartialPackage) { }

    static Map<UUID, BigDecimal> project(List<Source> sources, List<Node> nodes) {
        require(sources != null && nodes != null, "Source and material snapshots are required");
        Map<UUID, BigDecimal> sourceOutput = new HashMap<>();
        for (Source source : sources) {
            require(source != null && source.id() != null, "Source identity is required");
            require(source.requestedQty() != null && source.requestedQty().signum() >= 0,
                    "Source quantity must be nonnegative");
            require(source.unitRate() != null && source.unitRate().signum() > 0,
                    "Source unit conversion must be positive");
            // Retain the exact conversion until the first BOM edge. Rounding the
            // displayed root first can multiply a small conversion remainder.
            require(sourceOutput.putIfAbsent(source.id(),
                    source.requestedQty().multiply(source.unitRate())) == null,
                    "Duplicate source identity");
        }

        Map<Key, Node> byPath = new HashMap<>();
        Set<UUID> materialIds = new HashSet<>();
        Set<UUID> rootSources = new HashSet<>();
        for (Node node : nodes) {
            require(node != null && node.id() != null && node.analysisLineId() != null,
                    "Material and source identities are required");
            require(node.nodeKey() != null && !node.nodeKey().isBlank(), "Material path is required");
            require(node.parentNodeKey() == null || !node.parentNodeKey().isBlank(),
                    "Material parent path cannot be blank");
            require(node.level() >= 0, "Material level cannot be negative");
            require(sourceOutput.containsKey(node.analysisLineId()),
                    "Material has no admitted source: " + node.id());
            require(materialIds.add(node.id()), "Duplicate material identity: " + node.id());
            require(byPath.putIfAbsent(key(node), node) == null,
                    "Duplicate material path within one source: " + node.id());
            if (node.level() == 0) {
                require(node.parentNodeKey() == null, "Source root cannot have a material parent");
                require(rootSources.add(node.analysisLineId()), "Duplicate root for one source");
            }
        }

        Map<Key, BigDecimal> requirementByPath = new HashMap<>();
        Map<UUID, BigDecimal> result = new LinkedHashMap<>();
        for (Node node : nodes.stream().sorted(Comparator.comparingInt(Node::level)).toList()) {
            BigDecimal required;
            if (node.level() == 0) {
                required = sourceOutput.get(node.analysisLineId()).setScale(4, RoundingMode.CEILING);
            } else {
                BigDecimal parentOutput;
                if (node.level() == 1 && node.parentNodeKey() == null) {
                    // Some standalone preparation sources have no ROOT_SUPPLY
                    // row. Their admitted Source still anchors the first edge.
                    parentOutput = sourceOutput.get(node.analysisLineId());
                } else {
                    require(node.parentNodeKey() != null,
                            "Nested material has no parent path: " + node.id());
                    Key parentKey = new Key(node.analysisLineId(), node.parentNodeKey());
                    Node parent = byPath.get(parentKey);
                    require(parent != null, "Material parent is missing from its source: " + node.id());
                    require(parent.level() + 1 == node.level(),
                            "Material parent level is inconsistent: " + node.id());
                    // Explicit root links follow the same conversion precision
                    // as first-level nodes whose parent key is NULL.
                    parentOutput = parent.level() == 0
                            ? sourceOutput.get(node.analysisLineId()) : requirementByPath.get(parentKey);
                    require(parentOutput != null, "Material ancestry cannot be resolved: " + node.id());
                }
                if (parentOutput.signum() == 0) {
                    // MaterialConsumptionMath returns early for zero output.
                    // Still validate the frozen edge instead of hiding bad data.
                    MaterialConsumptionMath.required(BigDecimal.ONE, node.bomQty(), node.consumptionBasis(),
                            node.basisOutputQty(), node.allowPartialPackage());
                }
                required = MaterialConsumptionMath.required(parentOutput, node.bomQty(), node.consumptionBasis(),
                        node.basisOutputQty(), node.allowPartialPackage());
            }
            requirementByPath.put(key(node), required);
            result.put(node.id(), required);
        }
        return Collections.unmodifiableMap(result);
    }

    private static Key key(Node node) { return new Key(node.analysisLineId(), node.nodeKey()); }

    private static void require(boolean condition, String message) {
        if (!condition) throw new IllegalArgumentException(message);
    }

    private record Key(UUID sourceId, String path) { }
}
