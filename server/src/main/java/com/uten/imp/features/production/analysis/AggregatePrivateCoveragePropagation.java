package com.uten.imp.features.production.analysis;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;

import java.math.BigDecimal;
import java.math.BigInteger;
import java.math.RoundingMode;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.PriorityQueue;
import java.util.Set;
import java.util.UUID;

/** Propagates proven private source shares along actual inherited-coverage edges. */
final class AggregatePrivateCoveragePropagation {
    private static final int SCALE = 4;
    private static final Comparator<UUID> UUID_ORDER = Comparator.comparing(UUID::toString);

    private AggregatePrivateCoveragePropagation() { }

    /**
     * Direct private amounts and incoming inherited amounts are distinct facts and are added.
     * A node's known private quantity is budgeted once across all its outgoing actual edges;
     * an edge can receive no more than its recorded inherited quantity. Any unknown remainder
     * stays unknown. Source/original UUID order makes partial budgets reproducible.
     *
     * <p>{@code originalMaterialIds} is only a fallback identity whitelist: a source with no
     * positive private proof may be attributed to itself when its original material identity
     * is known and the actual outgoing edges prove the transferred quantity. Existing explicit
     * proof is retained even for historical original-request IDs outside this whitelist.</p>
     */
    static Map<UUID, Map<UUID, BigDecimal>> propagate(
            Map<UUID, Map<UUID, BigDecimal>> privateByTarget,
            Map<UUID, Map<UUID, BigDecimal>> inheritedByTarget,
            Set<UUID> originalMaterialIds) {
        if (privateByTarget == null || inheritedByTarget == null || originalMaterialIds == null) {
            throw invalid("缺少私有覆盖的来源证明或继承关系");
        }
        for (UUID original : originalMaterialIds) requireId(original);
        Set<UUID> nodes = new HashSet<>();
        Map<UUID, Map<UUID, BigInteger>> known = new HashMap<>();
        Map<UUID, Map<UUID, BigInteger>> outgoing = new HashMap<>();

        for (var target : privateByTarget.entrySet()) {
            requireId(target.getKey());
            nodes.add(target.getKey());
            if (target.getValue() == null) throw invalid("私有覆盖缺少原物料明细");
            Map<UUID, BigInteger> shares = known.computeIfAbsent(target.getKey(), ignored -> new HashMap<>());
            for (var original : target.getValue().entrySet()) {
                requireId(original.getKey());
                BigInteger quantity = ticks(original.getValue());
                if (quantity.signum() > 0) shares.put(original.getKey(), quantity);
            }
        }
        for (var target : inheritedByTarget.entrySet()) {
            requireId(target.getKey());
            nodes.add(target.getKey());
            if (target.getValue() == null) throw invalid("继承覆盖缺少实际来源明细");
            for (var source : target.getValue().entrySet()) {
                requireId(source.getKey());
                nodes.add(source.getKey());
                BigInteger quantity = ticks(source.getValue());
                if (quantity.signum() > 0) outgoing.computeIfAbsent(source.getKey(), ignored -> new HashMap<>())
                        .put(target.getKey(), quantity);
            }
        }

        // Validate the complete positive-quantity graph before propagating anything. Iterative
        // topological order also handles deep historic alias chains without recursive traversal.
        List<UUID> order = topologicalOrder(nodes, outgoing);
        for (UUID source : order) {
            Map<UUID, BigInteger> edges = outgoing.getOrDefault(source, Map.of());
            if (edges.isEmpty()) continue;
            Map<UUID, BigInteger> shares = known.computeIfAbsent(source, ignored -> new HashMap<>());
            if (shares.isEmpty() && originalMaterialIds.contains(source)) {
                BigInteger actualTotal = edges.values().stream().reduce(BigInteger.ZERO, BigInteger::add);
                shares.put(source, actualTotal);
            }
            if (shares.isEmpty()) continue;
            distributeOnce(shares, edges, known);
        }

        var result = new LinkedHashMap<UUID, Map<UUID, BigDecimal>>();
        for (UUID node : nodes.stream().sorted(UUID_ORDER).toList()) {
            Map<UUID, BigInteger> shares = known.getOrDefault(node, Map.of());
            var amounts = new LinkedHashMap<UUID, BigDecimal>();
            for (UUID original : shares.keySet().stream().sorted(UUID_ORDER).toList()) {
                amounts.put(original, new BigDecimal(shares.get(original), SCALE));
            }
            result.put(node, Collections.unmodifiableMap(amounts));
        }
        return Collections.unmodifiableMap(result);
    }

    /** Fully connected within one proven source; two cursors avoid a source-by-target matrix. */
    private static void distributeOnce(Map<UUID, BigInteger> shares, Map<UUID, BigInteger> edges,
                                       Map<UUID, Map<UUID, BigInteger>> known) {
        List<UUID> originals = shares.keySet().stream().sorted(UUID_ORDER).toList();
        BigInteger[] remaining = originals.stream().map(shares::get).toArray(BigInteger[]::new);
        int originalIndex = 0;
        for (UUID target : edges.keySet().stream().sorted(UUID_ORDER).toList()) {
            BigInteger edgeRemaining = edges.get(target);
            while (edgeRemaining.signum() > 0 && originalIndex < originals.size()) {
                BigInteger take = remaining[originalIndex].min(edgeRemaining);
                if (take.signum() > 0) {
                    known.computeIfAbsent(target, ignored -> new HashMap<>())
                            .merge(originals.get(originalIndex), take, BigInteger::add);
                    remaining[originalIndex] = remaining[originalIndex].subtract(take);
                    edgeRemaining = edgeRemaining.subtract(take);
                }
                if (remaining[originalIndex].signum() == 0) originalIndex++;
            }
            if (originalIndex == originals.size()) break;
        }
    }

    private static List<UUID> topologicalOrder(Set<UUID> nodes,
                                              Map<UUID, Map<UUID, BigInteger>> outgoing) {
        Map<UUID, Integer> indegree = new HashMap<>();
        nodes.forEach(node -> indegree.put(node, 0));
        outgoing.values().forEach(edges -> edges.keySet().forEach(target -> indegree.merge(target, 1, Integer::sum)));
        PriorityQueue<UUID> ready = new PriorityQueue<>(UUID_ORDER);
        indegree.forEach((node, degree) -> { if (degree == 0) ready.add(node); });
        List<UUID> order = new ArrayList<>(nodes.size());
        while (!ready.isEmpty()) {
            UUID source = ready.remove();
            order.add(source);
            for (UUID target : outgoing.getOrDefault(source, Map.of()).keySet()) {
                if (indegree.merge(target, -1, Integer::sum) == 0) ready.add(target);
            }
        }
        if (order.size() != nodes.size()) {
            throw new ApiException(ErrorCode.CONFLICT, "私有覆盖继承关系存在循环，请核对实际来源后重试");
        }
        return order;
    }

    private static BigInteger ticks(BigDecimal quantity) {
        if (quantity == null || quantity.signum() < 0) {
            throw invalid("私有覆盖及实际继承数量必须为非负数，最多4位小数");
        }
        try {
            return quantity.setScale(SCALE, RoundingMode.UNNECESSARY).unscaledValue();
        } catch (ArithmeticException invalidScale) {
            throw invalid("私有覆盖及实际继承数量必须为非负数，最多4位小数");
        }
    }

    private static void requireId(UUID id) {
        if (id == null) throw invalid("私有覆盖必须保留明确的物料来源标识");
    }

    private static ApiException invalid(String message) {
        return new ApiException(ErrorCode.VALIDATION_FAILED, message);
    }
}
