package com.uten.imp.features.production.analysis;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;

import java.math.BigDecimal;
import java.math.BigInteger;
import java.math.RoundingMode;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.Comparator;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/** Exact original-to-target flow. Only caller-proven identity edges may carry quantity. */
final class AggregateOriginalTargetAllocator {
    private static final int SCALE = 4;
    // PostgreSQL UUID ordering is unsigned byte order, unlike UUID.compareTo().
    private static final Comparator<UUID> UUID_ORDER = Comparator.comparing(UUID::toString);

    private AggregateOriginalTargetAllocator() { }

    record Flow(Map<UUID, Map<UUID, BigDecimal>> byTarget, BigDecimal allocatedQty) {
        Flow {
            var immutable = new LinkedHashMap<UUID, Map<UUID, BigDecimal>>();
            byTarget.forEach((target, originals) -> immutable.put(target,
                    Collections.unmodifiableMap(new LinkedHashMap<>(originals))));
            byTarget = Collections.unmodifiableMap(immutable);
        }
    }

    /**
     * Returns a maximum flow in stable UUID order. Unallocated original quantity remains with
     * its original source; it is never reassigned through an unproven edge. The ledger mode
     * requires every actual target quantity to be fully attributable to these original caps.
     */
    static Flow allocate(Map<UUID, BigDecimal> originalCaps,
                         Map<UUID, BigDecimal> targetCaps,
                         Map<UUID, List<UUID>> originalsByTarget,
                         boolean requireTargetFull) {
        if (originalCaps == null || targetCaps == null || originalsByTarget == null) {
            throw invalid("缺少原物料与目标物料的精确分配范围");
        }
        Map<UUID, BigInteger> originals = capacities(originalCaps);
        Map<UUID, BigInteger> targets = capacities(targetCaps);
        Map<UUID, List<UUID>> edges = validatedEdges(originalsByTarget, originals, targets);

        int firstTarget = 1 + originals.size();
        int sink = firstTarget + targets.size();
        Graph graph = new Graph(sink + 1);
        Map<UUID, Integer> originalNodes = new HashMap<>();
        Map<UUID, Integer> targetNodes = new HashMap<>();
        int node = 1;
        BigInteger originalTotal = BigInteger.ZERO;
        for (var entry : originals.entrySet()) {
            originalNodes.put(entry.getKey(), node);
            graph.add(0, node++, entry.getValue());
            originalTotal = originalTotal.add(entry.getValue());
        }
        node = firstTarget;
        BigInteger targetTotal = BigInteger.ZERO;
        for (var entry : targets.entrySet()) {
            targetNodes.put(entry.getKey(), node);
            graph.add(node++, sink, entry.getValue());
            targetTotal = targetTotal.add(entry.getValue());
        }

        var traced = new LinkedHashMap<UUID, Map<UUID, Edge>>();
        for (var target : targets.entrySet()) {
            var sources = new LinkedHashMap<UUID, Edge>();
            traced.put(target.getKey(), sources);
            for (UUID original : edges.getOrDefault(target.getKey(), List.of())) {
                BigInteger capacity = originals.get(original).min(target.getValue());
                if (capacity.signum() == 0) continue;
                sources.put(original, graph.add(originalNodes.get(original),
                        targetNodes.get(target.getKey()), capacity));
            }
        }

        BigInteger allocated = graph.maximumFlow(0, sink, originalTotal.min(targetTotal));
        if (requireTargetFull && !allocated.equals(targetTotal)) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "真实目标数量无法按原物料来源完整分配，请刷新并核对来源后重试");
        }
        var result = new LinkedHashMap<UUID, Map<UUID, BigDecimal>>();
        for (var target : traced.entrySet()) {
            var allocations = new LinkedHashMap<UUID, BigDecimal>();
            for (var source : target.getValue().entrySet()) {
                Edge edge = source.getValue();
                BigInteger quantity = graph.reverse(edge).remaining;
                if (quantity.signum() > 0) allocations.put(source.getKey(), decimal(quantity));
            }
            result.put(target.getKey(), allocations);
        }
        return new Flow(result, decimal(allocated));
    }

    private static Map<UUID, BigInteger> capacities(Map<UUID, BigDecimal> values) {
        for (UUID id : values.keySet()) {
            if (id == null) throw invalid("物料来源和目标必须有明确标识");
        }
        var result = new LinkedHashMap<UUID, BigInteger>();
        for (UUID id : values.keySet().stream().sorted(UUID_ORDER).toList()) {
            BigDecimal value = values.get(id);
            if (value == null || value.signum() < 0) {
                throw invalid("原物料和目标数量必须为非负数，最多4位小数");
            }
            try {
                result.put(id, value.setScale(SCALE, RoundingMode.UNNECESSARY).unscaledValue());
            } catch (ArithmeticException invalidScale) {
                throw invalid("原物料和目标数量必须为非负数，最多4位小数");
            }
        }
        return result;
    }

    private static Map<UUID, List<UUID>> validatedEdges(
            Map<UUID, List<UUID>> scope,
            Map<UUID, BigInteger> originals,
            Map<UUID, BigInteger> targets) {
        var result = new HashMap<UUID, List<UUID>>();
        for (var entry : scope.entrySet()) {
            if (entry.getKey() == null || !targets.containsKey(entry.getKey()) || entry.getValue() == null) {
                throw invalid("精确分配包含范围外的目标物料");
            }
            var seen = new HashSet<UUID>();
            for (UUID original : entry.getValue()) {
                if (original == null || !originals.containsKey(original) || !seen.add(original)) {
                    throw invalid("精确分配包含未知或重复的原物料来源");
                }
            }
            result.put(entry.getKey(), seen.stream().sorted(UUID_ORDER).toList());
        }
        return result;
    }

    private static BigDecimal decimal(BigInteger quantity) { return new BigDecimal(quantity, SCALE); }
    private static ApiException invalid(String message) {
        return new ApiException(ErrorCode.VALIDATION_FAILED, message);
    }

    private static final class Edge {
        final int to;
        final int reverse;
        BigInteger remaining;

        Edge(int to, int reverse, BigInteger remaining) {
            this.to = to;
            this.reverse = reverse;
            this.remaining = remaining;
        }
    }

    /** Sparse Dinic graph, with an explicit path stack instead of recursive DFS. */
    private static final class Graph {
        final List<List<Edge>> outgoing;
        final int[] levels;
        final int[] next;
        final int[] queue;
        final int[] pathNodes;
        final Edge[] pathEdges;

        Graph(int size) {
            outgoing = new ArrayList<>(size);
            for (int i = 0; i < size; i++) outgoing.add(new ArrayList<>());
            levels = new int[size];
            next = new int[size];
            queue = new int[size];
            pathNodes = new int[size];
            pathEdges = new Edge[size];
        }

        Edge add(int from, int to, BigInteger capacity) {
            Edge forward = new Edge(to, outgoing.get(to).size(), capacity);
            Edge backward = new Edge(from, outgoing.get(from).size(), BigInteger.ZERO);
            outgoing.get(from).add(forward);
            outgoing.get(to).add(backward);
            return forward;
        }

        Edge reverse(Edge edge) { return outgoing.get(edge.to).get(edge.reverse); }

        BigInteger maximumFlow(int source, int sink, BigInteger limit) {
            BigInteger total = BigInteger.ZERO;
            while (total.compareTo(limit) < 0 && layer(source, sink)) {
                Arrays.fill(next, 0);
                BigInteger pushed;
                while ((pushed = augment(source, sink, limit.subtract(total))).signum() > 0) {
                    total = total.add(pushed);
                    if (total.equals(limit)) return total;
                }
            }
            return total;
        }

        boolean layer(int source, int sink) {
            Arrays.fill(levels, -1);
            int head = 0, tail = 0;
            queue[tail++] = source;
            levels[source] = 0;
            while (head < tail) {
                int node = queue[head++];
                for (Edge edge : outgoing.get(node)) {
                    if (edge.remaining.signum() <= 0 || levels[edge.to] >= 0) continue;
                    levels[edge.to] = levels[node] + 1;
                    queue[tail++] = edge.to;
                }
            }
            return levels[sink] >= 0;
        }

        BigInteger augment(int source, int sink, BigInteger limit) {
            int depth = 0;
            pathNodes[0] = source;
            while (depth >= 0) {
                int node = pathNodes[depth];
                if (node == sink) {
                    BigInteger pushed = limit;
                    for (int i = 0; i < depth; i++) pushed = pushed.min(pathEdges[i].remaining);
                    for (int i = 0; i < depth; i++) {
                        Edge edge = pathEdges[i];
                        edge.remaining = edge.remaining.subtract(pushed);
                        Edge reverse = reverse(edge);
                        reverse.remaining = reverse.remaining.add(pushed);
                    }
                    return pushed;
                }
                List<Edge> candidates = outgoing.get(node);
                while (next[node] < candidates.size()) {
                    Edge edge = candidates.get(next[node]);
                    if (edge.remaining.signum() > 0 && levels[edge.to] == levels[node] + 1) break;
                    next[node]++;
                }
                if (next[node] == candidates.size()) {
                    levels[node] = -1;
                    if (depth == 0) return BigInteger.ZERO;
                    depth--;
                    next[pathNodes[depth]]++;
                } else {
                    Edge edge = candidates.get(next[node]);
                    pathEdges[depth] = edge;
                    pathNodes[++depth] = edge.to;
                }
            }
            return BigInteger.ZERO;
        }
    }
}
