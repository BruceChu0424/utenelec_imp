package com.uten.imp.businesschain;

import org.springframework.jdbc.core.JdbcTemplate;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** Isolated PostgreSQL function counters; records function identities, never parameters or business values. */
final class ProductionFunctionMeasurement {
    record Counter(long calls, double totalMillis, double selfMillis) {}
    private ProductionFunctionMeasurement() {}

    static Map<String, Counter> snapshot(JdbcTemplate jdbc) {
        jdbc.execute("SELECT pg_stat_clear_snapshot()");
        Map<String, Counter> result = new LinkedHashMap<>();
        jdbc.query("""
                SELECT stat.schemaname || '.' || stat.funcname || '(' || pg_get_function_identity_arguments(stat.funcid) || ')' AS identity,
                       stat.calls, stat.total_time, stat.self_time
                FROM pg_stat_user_functions stat WHERE stat.schemaname='public'
                """, rs -> { result.put(rs.getString("identity"), new Counter(rs.getLong("calls"),
                    rs.getDouble("total_time"), rs.getDouble("self_time"))); });
        return result;
    }

    static List<Map<String, Object>> differences(Map<String, Counter> before, Map<String, Counter> after) {
        List<Map<String, Object>> changes = new java.util.ArrayList<>();
        after.forEach((name, value) -> {
            Counter old = before.getOrDefault(name, new Counter(0, 0, 0));
            if (value.calls() > old.calls()) changes.add(Map.of("function", name, "calls", value.calls() - old.calls(),
                    "totalMillis", value.totalMillis() - old.totalMillis(), "selfMillis", value.selfMillis() - old.selfMillis()));
        });
        changes.sort(java.util.Comparator.<Map<String, Object>>comparingDouble(row -> ((Number) row.get("selfMillis")).doubleValue()).reversed());
        return changes;
    }
}
