package com.uten.imp.features.stock.valuation;

import java.sql.Statement;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.LinkedHashSet;
import java.util.Set;
import com.uten.imp.features.stock.InventoryKey;
import org.springframework.jdbc.core.PreparedStatementCreatorFactory;
import org.springframework.jdbc.core.SqlParameter;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterUtils;
import org.springframework.transaction.support.TransactionSynchronizationManager;

/**
 * One value operation's ordered writes. PostgreSQL executes the original statements
 * in order (including immediate triggers), with bound parameters and one protocol
 * exchange. This is not a transaction cache: callers flush before observing facts,
 * and no pending writes or node snapshots escape the current operation.
 */
final class InventoryValueWriteSet {
    private final NamedParameterJdbcTemplate db;
    private final StringBuilder sql = new StringBuilder();
    private final List<SqlParameter> parameters = new ArrayList<>();
    private final List<Object> values = new ArrayList<>();
    private final List<String> conflicts = new ArrayList<>();
    private final Set<InventoryKey> precisionKeys = new LinkedHashSet<>();

    InventoryValueWriteSet(NamedParameterJdbcTemplate db) { this.db = db; }

    void add(String statement, Map<String, ?> arguments, String conflict) {
        add(statement,arguments,conflict,null);
    }

    private void add(String statement, Map<String, ?> arguments, String conflict,InventoryKey precisionKey) {
        var parsed = NamedParameterUtils.parseSqlStatement(statement);
        var source = new MapSqlParameterSource(arguments);
        var bound = NamedParameterUtils.buildValueArray(parsed, source, null);
        // Bound the PostgreSQL bind message without imposing a new business limit.
        if (values.size() + bound.length > 60_000) flush();
        // Register after a possible bind-limit flush: this proof belongs to the
        // edge being queued, not to the preceding SQL message.
        if(precisionKey!=null)precisionKeys.add(precisionKey);
        if (!sql.isEmpty()) sql.append(";\n");
        sql.append(NamedParameterUtils.substituteNamedParameters(parsed, source));
        parameters.addAll(NamedParameterUtils.buildSqlParameterList(parsed, source));
        java.util.Collections.addAll(values, bound);
        conflicts.add(conflict);
    }

    void flush() {
        if (conflicts.isEmpty()) return;
        if (!TransactionSynchronizationManager.isActualTransactionActive())
            throw new IllegalStateException("Value writes require the originating transaction");
        requirePrecisionClear(db,precisionKeys.stream().sorted().toList());
        var creator = new PreparedStatementCreatorFactory(sql.toString(), parameters);
        db.getJdbcTemplate().execute(creator.newPreparedStatementCreator(values), statement -> {
            boolean result = statement.execute();
            for (String conflict : conflicts) {
                if (result || statement.getUpdateCount() != 1) throw ValueMath.conflict(conflict);
                result = statement.getMoreResults(Statement.CLOSE_CURRENT_RESULT);
            }
            if (result || statement.getUpdateCount() != -1)
                throw new IllegalStateException("Unexpected result in ordered value writes");
            return null;
        });
        sql.setLength(0);
        parameters.clear();
        values.clear();
        conflicts.clear();
        precisionKeys.clear();
    }

    static void update(NamedParameterJdbcTemplate db, InventoryValueWriteSet writes,
                       String sql, Map<String, ?> values, String conflict) {
        update(db,writes,sql,values,conflict,null);
    }

    static void update(NamedParameterJdbcTemplate db, InventoryValueWriteSet writes,
                       String sql, Map<String, ?> values, String conflict,InventoryKey precisionKey) {
        if (writes == null) {
            if(precisionKey!=null)requirePrecisionClear(db,List.of(precisionKey));
            if (db.update(sql, values) != 1) throw ValueMath.conflict(conflict);
        } else writes.add(sql, values, conflict,precisionKey);
    }

    /** Recheck every queued edge's original goods/color immediately before the actual SQL write. */
    private static void requirePrecisionClear(NamedParameterJdbcTemplate db,List<InventoryKey> keys){
        for(int start=0;start<keys.size();start+=500){
            var batch=keys.subList(start,Math.min(start+500,keys.size()));
            if(Boolean.TRUE.equals(db.queryForObject("""
                    SELECT fn_inventory_value_precision_marked(ARRAY(
                        SELECT fn_inventory_value_precision_key(requested.goods,requested.color)
                        FROM unnest(CAST(:goods AS uuid[]),CAST(:colors AS uuid[])) requested(goods,color)))
                    """,Map.of("goods",new org.springframework.jdbc.support.SqlArrayValue("uuid",batch.stream().map(InventoryKey::goodsId).toArray()),
                        "colors",new org.springframework.jdbc.support.SqlArrayValue("uuid",batch.stream().map(InventoryKey::colorId).toArray())),Boolean.class)))
                throw ValueMath.conflict("该库存成本后继正在核对，请保留原单稍后重试；本次未确认");
        }
    }
}
