package com.uten.imp.features.production.analysis;

import com.uten.imp.common.util.NativeQueryResults;
import jakarta.persistence.EntityManager;

import java.math.BigDecimal;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;

/** One refresh-local exact baseline, never a cache of stock, source footprints or computed requirements. */
final class MaterialAnalysisSnapshotBaseline {
    static final List<String> ALLOCATION_COLUMNS = List.of(
            "required_qty", "allocated_available_qty", "allocated_start_qty", "allocated_finish_qty", "allocated_ship_qty",
            "shortage_qty", "lower_level_pending", "available_qty", "reserved_qty", "safety_stock_qty", "inbound_qty", "expected_ready_date");
    private final Map<Key, Stored> nodes;
    private final Set<String> confirmedNodes;
    private final List<MaterialAnalysisIssuedRoutePreservation.Identity> identities;
    private final int structureSize;

    private MaterialAnalysisSnapshotBaseline(Map<Key, Stored> nodes, Set<String> confirmedNodes, int structureSize,List<MaterialAnalysisIssuedRoutePreservation.Identity> identities) {
        this.nodes = nodes; this.confirmedNodes = Set.copyOf(confirmedNodes); this.structureSize = structureSize;
        this.identities=List.copyOf(identities);
    }

    static MaterialAnalysisSnapshotBaseline load(EntityManager em, UUID analysisId, List<String> structureColumns) {
        String sql = "SELECT analysis_item_id, node_key, " + String.join(", ", structureColumns)
                + ", " + String.join(", ", ALLOCATION_COLUMNS) + ", id, confirmed_route"
                + " FROM production_material_analysis_materials WHERE analysis_id=:analysisId"
                + " AND (active=TRUE OR confirmed_route IS NOT NULL)";
        Map<Key, Stored> nodes = new HashMap<>();
        Set<String> confirmed = new HashSet<>();
        List<MaterialAnalysisIssuedRoutePreservation.Identity> identities=new java.util.ArrayList<>();
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery(sql).setParameter("analysisId", analysisId))) {
            Key key = new Key((UUID) row[0], (String) row[1]);
            nodes.put(key, new Stored(row));
            if (row[row.length - 1] != null) confirmed.add(row[0] + "|" + row[1]);
            if(((Number)row[2+structureColumns.indexOf("depth")]).intValue()>0)
                identities.add(new MaterialAnalysisIssuedRoutePreservation.Identity((UUID)row[row.length-2],(UUID)row[0],(String)row[1],
                        (UUID)row[2+structureColumns.indexOf("goods_id")],(UUID)row[2+structureColumns.indexOf("color_id")],(UUID)row[2+structureColumns.indexOf("unit_id")],(String)row[row.length-1]));
        }
        return new MaterialAnalysisSnapshotBaseline(nodes, confirmed, structureColumns.size(),identities);
    }

    Set<String> confirmedNodes() { return confirmedNodes; }
    List<MaterialAnalysisIssuedRoutePreservation.Identity> identities() { return identities; }

    String confirmedRoute(UUID sourceId,String nodeKey) {
        Stored stored=nodes.get(new Key(sourceId,nodeKey));
        return stored==null?null:(String)stored.values[stored.values.length-1];
    }

    boolean unchangedStructure(UUID sourceId, String nodeKey, Object[] expected) {
        if (expected.length != structureSize) throw new IllegalArgumentException("Material structure column mismatch");
        Stored stored = nodes.get(new Key(sourceId, nodeKey));
        boolean equal = stored != null && equalsAt(stored.values, 2, expected);
        if (stored != null) stored.structureUnchanged = equal;
        return equal;
    }

    boolean unchangedAllocation(UUID sourceId, String nodeKey, Object[] expected) {
        if (expected.length != ALLOCATION_COLUMNS.size()) throw new IllegalArgumentException("Material allocation column mismatch");
        Stored stored = nodes.get(new Key(sourceId, nodeKey));
        // New/reactivated/structurally changed rows still use the original SQL:
        // guards or the upsert may have established different initial quantities.
        return stored != null && stored.structureUnchanged && equalsAt(stored.values, 2 + structureSize, expected);
    }

    private static boolean equalsAt(Object[] stored, int offset, Object[] expected) {
        for (int i = 0; i < expected.length; i++) if (!sameSqlValue(stored[offset + i], expected[i])) return false;
        return true;
    }

    static boolean sameSqlValue(Object left, Object right) {
        if (Objects.equals(left, right)) return true;
        if (left instanceof BigDecimal a && right instanceof BigDecimal b) return a.compareTo(b) == 0;
        if (left instanceof Number a && right instanceof Number b) {
            return new BigDecimal(a.toString()).compareTo(new BigDecimal(b.toString())) == 0;
        }
        if (left instanceof java.sql.Date date) left = date.toLocalDate();
        if (right instanceof java.sql.Date date) right = date.toLocalDate();
        return Objects.equals(left, right);
    }

    private record Key(UUID sourceId, String nodeKey) {}

    private static final class Stored {
        final Object[] values;
        boolean structureUnchanged;
        Stored(Object[] values) { this.values = values; }
    }
}
