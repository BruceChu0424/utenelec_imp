package com.uten.imp.businesschain;

import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.lang.reflect.Proxy;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.sql.Connection;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import javax.sql.DataSource;
import org.springframework.beans.factory.config.BeanPostProcessor;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.context.annotation.Bean;
import org.springframework.jdbc.datasource.DelegatingDataSource;

/** Opt-in, test-context-only JDBC accounting. SQL/parameters are never emitted. */
final class ProductionJdbcMeasurement {
    private static final ThreadLocal<Sample> ACTIVE = new ThreadLocal<>();

    static final class Sample {
        long jdbcCalls;
        long logicalStatements;
        long jdbcNanos;
        long commits;
        long rollbacks;
        final Map<String, Long> fingerprints = new LinkedHashMap<>();
        final Map<String, Long> nanosByFingerprint = new LinkedHashMap<>();
        final Map<String, Long> maxNanosByFingerprint = new LinkedHashMap<>();
        final Map<String, String> labelsByFingerprint = new LinkedHashMap<>();
        final Map<String, CapturedQuery> explainCandidates = new LinkedHashMap<>();

        Map<String, Object> result() {
            return Map.of("jdbcCalls", jdbcCalls, "logicalStatements", logicalStatements,
                    "jdbcMillis", jdbcNanos / 1_000_000.0, "commits", commits,
                    "rollbacks", rollbacks, "sqlFingerprints", fingerprints,
                    "sqlNanos", nanosByFingerprint, "sqlMaxNanos", maxNanosByFingerprint,
                    "sqlLabels", labelsByFingerprint);
        }
    }

    /** Bindings live only in test memory and are never serialized into measurement artifacts. */
    record Binding(Method method, Object[] arguments) {
        void apply(java.sql.PreparedStatement statement) throws Exception {
            try { method.invoke(statement,arguments); }
            catch (InvocationTargetException failure) {
                if (failure.getCause() instanceof Exception cause) throw cause;
                throw failure;
            }
        }
    }
    record CapturedQuery(String fingerprint,String sql,Map<Integer,Binding> bindings) {
        void bind(java.sql.PreparedStatement statement) throws Exception {
            for (Binding binding:bindings.values()) binding.apply(statement);
        }
    }

    private static boolean explainCandidate(String sql) {
        if (sql==null) return false;
        String normalized=sql.replaceAll("\\s+"," ").trim().toLowerCase(java.util.Locale.ROOT);
        return normalized.startsWith("with recursive walk as") && normalized.contains("from goods_bom_items b")
                || normalized.startsWith("with analysis_page as materialized")
                || normalized.startsWith("with recursive roots(") && normalized.contains("from goods_bom_items edge")
                || normalized.startsWith("with recursive roots as") && normalized.contains("from expansion")
                || normalized.startsWith("select") && normalized.contains("from production_material_analyses analysis")
                && (normalized.startsWith("select count(*)") || normalized.startsWith("select analysis.id"))
                && !normalized.contains("for update");
    }

    static Sample begin() {
        if (ACTIVE.get() != null) throw new IllegalStateException("Measurements cannot nest");
        Sample sample = new Sample();
        ACTIVE.set(sample);
        return sample;
    }

    static void end() { ACTIVE.remove(); }

    @TestConfiguration(proxyBeanMethods = false)
    static class Configuration {
        @Bean
        static BeanPostProcessor productionJdbcCounter() {
            return new BeanPostProcessor() {
                @Override
                public Object postProcessAfterInitialization(Object bean, String name) {
                    if (!(bean instanceof DataSource source)) return bean;
                    return new DelegatingDataSource(source) {
                        @Override public Connection getConnection() throws SQLException {
                            return connection(super.getConnection());
                        }
                        @Override public Connection getConnection(String user, String password) throws SQLException {
                            return connection(super.getConnection(user, password));
                        }
                    };
                }
            };
        }
    }

    private static Connection connection(Connection target) {
        return (Connection) Proxy.newProxyInstance(Connection.class.getClassLoader(),
                new Class<?>[] {Connection.class}, (proxy, method, args) -> {
                    Sample sample = ACTIVE.get();
                    if (sample != null && method.getName().equals("commit")) sample.commits++;
                    if (sample != null && method.getName().equals("rollback")) sample.rollbacks++;
                    Object value = invoke(target, method, args);
                    if (value instanceof Statement statement && method.getName().startsWith("prepare")) {
                        return statement(statement, (String) args[0]);
                    }
                    if (value instanceof Statement statement && method.getName().equals("createStatement")) {
                        return statement(statement, null);
                    }
                    return value;
                });
    }

    private static Object statement(Statement target, String preparedSql) {
        Class<?> type = target instanceof java.sql.CallableStatement ? java.sql.CallableStatement.class
                : target instanceof java.sql.PreparedStatement ? java.sql.PreparedStatement.class : Statement.class;
        int[] queued = {0};
        Map<Integer,Binding> bindings=new java.util.TreeMap<>();
        boolean explainable=explainCandidate(preparedSql);
        return Proxy.newProxyInstance(type.getClassLoader(), new Class<?>[] {type}, (proxy, method, args) -> {
            String name = method.getName();
            if (explainable && name.startsWith("set") && args!=null && args.length>=2 && args[0] instanceof Integer index) {
                // These two read shapes bind scalar UUID/string/numeric values; do not retain streams or connection-owned arrays.
                if (args[1]==null || args[1] instanceof String || args[1] instanceof Number || args[1] instanceof java.util.UUID
                        || args[1] instanceof Boolean || args[1] instanceof java.time.temporal.TemporalAccessor) {
                    bindings.put(index,new Binding(method,args.clone()));
                }
            }
            if (name.equals("clearParameters")) bindings.clear();
            if (name.equals("addBatch")) queued[0]++;
            if (name.equals("clearBatch")) queued[0] = 0;
            boolean batch = name.equals("executeBatch") || name.equals("executeLargeBatch");
            Sample sample = ACTIVE.get();
            if (sample == null || !name.startsWith("execute")) return invoke(target, method, args);
            sample.jdbcCalls++;
            sample.logicalStatements += batch ? queued[0] : 1;
            String sql = preparedSql != null ? preparedSql
                    : args != null && args.length > 0 && args[0] instanceof String text ? text : "statement-batch";
            String fingerprint = java.util.HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256")
                    .digest(sql.replaceAll("\\s+", " ").trim().getBytes(StandardCharsets.UTF_8))).substring(0, 16);
            sample.fingerprints.merge(fingerprint, 1L, Long::sum);
            sample.labelsByFingerprint.putIfAbsent(fingerprint, queryLabel(sql));
            if (explainable) sample.explainCandidates.putIfAbsent(fingerprint,
                    new CapturedQuery(fingerprint,preparedSql,Map.copyOf(bindings)));
            long start = System.nanoTime();
            try { return invoke(target, method, args); }
            finally {
                long duration = System.nanoTime() - start;
                sample.jdbcNanos += duration;
                sample.nanosByFingerprint.merge(fingerprint, duration, Long::sum);
                sample.maxNanosByFingerprint.merge(fingerprint, duration, Math::max);
                if (batch) queued[0] = 0;
            }
        });
    }

    /** Fixed diagnostic labels only; never emit SQL text, query values or bindings. */
    private static String queryLabel(String sql) {
        String normalized = sql.replaceAll("\\s+", " ").trim().toLowerCase(java.util.Locale.ROOT);
        if (normalized.startsWith("with recursive walk")) return "bom.validation";
        if (normalized.startsWith("with recursive roots as")) return "bom.lock_footprint";
        if (normalized.startsWith("with recursive roots(")) return "bom.expansion";
        String verb = normalized.startsWith("insert") ? "insert" : normalized.startsWith("update") ? "update" : "read";
        for (String table : List.of("production_material_analysis_materials", "production_material_analysis_items",
                "production_material_analyses", "preplan_supply_actions", "stock_reservations", "goods_bom_items")) {
            if (normalized.contains(table)) return verb + "." + table;
        }
        return verb + ".other";
    }

    private static Object invoke(Object target, Method method, Object[] args) throws Throwable {
        try { return method.invoke(target, args); }
        catch (InvocationTargetException exception) { throw exception.getCause(); }
    }
}
