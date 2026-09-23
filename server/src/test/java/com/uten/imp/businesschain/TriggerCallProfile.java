package com.uten.imp.businesschain;

import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

import java.util.Map;
import java.util.TreeMap;
import java.util.stream.Collectors;

/**
 * 一笔真实业务事务的触发器调用剖面(ADR-106)：在同一笔事务里打开 track_functions，业务做完后用
 * SET CONSTRAINTS ALL IMMEDIATE 把排队的延迟校验当场跑完，再读本事务的函数计数。计数取自
 * pg_stat_get_xact_function_calls(本后端尚未冲刷的计数，取前后差值)，不依赖统计冲刷时机，结果是确定的。
 * 延迟校验的耗时单独计时(原本发生在 COMMIT 里)。只统计返回 trigger 的函数，不含任何参数或业务值。
 */
final class TriggerCallProfile {

    /** 剖面自己发的语句：SET LOCAL、两次快照、SET CONSTRAINTS。 */
    static final int OWN_STATEMENTS = 4;

    record Result(Map<String, Long> calls, long triggerCalls, long deferredCheckCalls,
                  double deferredCheckMillis, ProductionJdbcMeasurement.Sample sample) {

        long businessStatements() {
            return sample.logicalStatements - OWN_STATEMENTS;
        }

        long calls(String function) {
            return calls.getOrDefault(function, 0L);
        }

        String top() {
            return calls.entrySet().stream()
                    .sorted((a, b) -> Long.compare(b.getValue(), a.getValue()))
                    .map(entry -> entry.getKey() + "=" + entry.getValue())
                    .collect(Collectors.joining(","));
        }

        String line(String phase, int rows) {
            return "TRIGGER-PROFILE phase=" + phase + " rows=" + rows
                    + " total=" + triggerCalls + " deferredChecks=" + deferredCheckCalls
                    + " deferredCheckMillis=" + deferredCheckMillis
                    + " commitMillis=" + sample.commitNanos / 1_000_000.0
                    + " jdbcMillis=" + sample.jdbcNanos / 1_000_000.0
                    + " statements=" + businessStatements()
                    + " commits=" + sample.commits
                    + " top=" + top();
        }
    }

    private TriggerCallProfile() {
    }

    static Result measure(JdbcTemplate jdbc, PlatformTransactionManager manager, Runnable action) {
        long[] deferredNanos = new long[1];
        @SuppressWarnings("unchecked") Map<String, Long>[] snapshots = new Map[2];
        ProductionJdbcMeasurement.Sample sample = ProductionJdbcMeasurement.begin();
        try {
            new TransactionTemplate(manager).executeWithoutResult(status -> {
                jdbc.execute("SET LOCAL track_functions = 'all'");
                snapshots[0] = snapshot(jdbc);
                action.run();
                long start = System.nanoTime();
                jdbc.execute("SET CONSTRAINTS ALL IMMEDIATE");
                deferredNanos[0] = System.nanoTime() - start;
                snapshots[1] = snapshot(jdbc);
            });
        } finally {
            ProductionJdbcMeasurement.end();
        }
        Map<String, Long> delta = new TreeMap<>();
        snapshots[1].forEach((name, calls) -> {
            long diff = calls - snapshots[0].getOrDefault(name, 0L);
            if (diff > 0) delta.put(name, diff);
        });
        long total = delta.values().stream().mapToLong(Long::longValue).sum();
        long deferred = delta.entrySet().stream()
                .filter(entry -> isCheck(entry.getKey()))
                .mapToLong(Map.Entry::getValue).sum();
        return new Result(delta, total, deferred, deferredNanos[0] / 1_000_000.0, sample);
    }

    /** 与 WorkshopDirectTransferBatchEndToEndTest 同一口径：守恒/溯源校验函数的命名前缀。 */
    static boolean isCheck(String function) {
        return function.startsWith("fn_check_") || function.startsWith("fn_validate_")
                || function.startsWith("fn_assert_");
    }

    private static Map<String, Long> snapshot(JdbcTemplate jdbc) {
        Map<String, Long> result = new TreeMap<>();
        jdbc.query("""
                SELECT p.proname, SUM(pg_stat_get_xact_function_calls(p.oid)) AS calls
                FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace AND n.nspname = 'public'
                WHERE p.prorettype = 'trigger'::regtype
                GROUP BY p.proname
                HAVING SUM(pg_stat_get_xact_function_calls(p.oid)) > 0
                """, rs -> {
            result.put(rs.getString(1), rs.getLong(2));
        });
        return result;
    }
}
