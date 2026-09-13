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
import java.util.HexFormat;
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
    private static final Map<String, QueryMetadata> METADATA = new java.util.concurrent.ConcurrentHashMap<>();
    private record QueryMetadata(String fingerprint, String label, boolean explainable) {}

    static final class Sample {
        long jdbcCalls;
        long logicalStatements;
        long jdbcNanos;
        long commits;
        long rollbacks;
        long prepareNanos;
        long commitNanos;
        long rollbackNanos;
        long instrumentationNanos;
        int maxPreparedParameterIndex;
        final Map<String, Long> fingerprints = new LinkedHashMap<>();
        final Map<String, Long> nanosByFingerprint = new LinkedHashMap<>();
        final Map<String, Long> maxNanosByFingerprint = new LinkedHashMap<>();
        final Map<String, String> labelsByFingerprint = new LinkedHashMap<>();
        final Map<String, CapturedQuery> explainCandidates = new LinkedHashMap<>();

        Map<String, Object> result() {
            Map<String,Object> result = new LinkedHashMap<>(Map.of("jdbcCalls", jdbcCalls, "logicalStatements", logicalStatements,
                    "jdbcMillis", jdbcNanos / 1_000_000.0, "commits", commits,
                    "rollbacks", rollbacks, "maxPreparedParameterIndex", maxPreparedParameterIndex, "sqlFingerprints", fingerprints,
                    "sqlNanos", nanosByFingerprint, "sqlMaxNanos", maxNanosByFingerprint,
                    "sqlLabels", labelsByFingerprint));
            result.put("prepareMillis", prepareNanos / 1_000_000.0);
            result.put("commitMillis", commitNanos / 1_000_000.0);
            result.put("rollbackMillis", rollbackNanos / 1_000_000.0);
            result.put("instrumentationMillis", instrumentationNanos / 1_000_000.0);
            return result;
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
                || normalized.startsWith("with recursive roots as") && (normalized.contains("from expansion") || normalized.contains("from parents"))
                || normalized.contains("select material.id,material.goods_id,material.color_id,md5(")
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
                    boolean prepare = method.getName().startsWith("prepare");
                    boolean commit = method.getName().equals("commit");
                    boolean rollback = method.getName().equals("rollback");
                    long started = sample != null && (prepare || commit || rollback) ? System.nanoTime() : 0;
                    Object value;
                    try { value = invoke(target, method, args); }
                    finally {
                        if (started != 0) {
                            long duration = System.nanoTime() - started;
                            if (prepare) sample.prepareNanos += duration;
                            else if (commit) sample.commitNanos += duration;
                            else sample.rollbackNanos += duration;
                        }
                    }
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
        int[] highestParameter = {0};
        Map<Integer,Binding> bindings=new java.util.TreeMap<>();
        QueryMetadata[] metadata = {null};
        return Proxy.newProxyInstance(type.getClassLoader(), new Class<?>[] {type}, (proxy, method, args) -> {
            String name = method.getName();
            if (name.startsWith("set") && args != null && args.length >= 2 && args[0] instanceof Integer index) {
                highestParameter[0] = Math.max(highestParameter[0], index);
            }
            Sample sample = ACTIVE.get();
            long accountingStarted = sample == null ? 0 : System.nanoTime();
            if (sample != null && metadata[0] == null && preparedSql != null) metadata[0] = metadata(preparedSql);
            boolean explainable = metadata[0] != null && metadata[0].explainable();
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
            if (sample == null || !name.startsWith("execute")) {
                if (sample != null) sample.instrumentationNanos += System.nanoTime() - accountingStarted;
                return invoke(target, method, args);
            }
            sample.jdbcCalls++;
            sample.maxPreparedParameterIndex = Math.max(sample.maxPreparedParameterIndex, highestParameter[0]);
            sample.logicalStatements += batch ? queued[0] : 1;
            String sql = preparedSql != null ? preparedSql
                    : args != null && args.length > 0 && args[0] instanceof String text ? text : "statement-batch";
            QueryMetadata current = metadata[0] == null ? metadata(sql) : metadata[0];
            String fingerprint = current.fingerprint();
            sample.fingerprints.merge(fingerprint, 1L, Long::sum);
            sample.labelsByFingerprint.putIfAbsent(fingerprint, current.label());
            if (explainable) sample.explainCandidates.putIfAbsent(fingerprint,
                    new CapturedQuery(fingerprint,preparedSql,Map.copyOf(bindings)));
            sample.instrumentationNanos += System.nanoTime() - accountingStarted;
            long start = System.nanoTime();
            try { return invoke(target, method, args); }
            finally {
                long duration = System.nanoTime() - start;
                long finished = System.nanoTime();
                sample.jdbcNanos += duration;
                sample.nanosByFingerprint.merge(fingerprint, duration, Long::sum);
                sample.maxNanosByFingerprint.merge(fingerprint, duration, Math::max);
                if (batch) queued[0] = 0;
                sample.instrumentationNanos += System.nanoTime() - finished;
            }
        });
    }

    private static QueryMetadata metadata(String sql) throws Exception {
        QueryMetadata cached = METADATA.get(sql);
        if (cached != null) return cached;
        String normalized = sql.replaceAll("\\s+", " ").trim();
        String fingerprint = HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256")
                .digest(normalized.getBytes(StandardCharsets.UTF_8))).substring(0, 16);
        var created = new QueryMetadata(fingerprint, queryLabel(normalized), explainCandidate(normalized));
        // Test instrumentation only: bounded SQL-shape metadata, never values,
        // results, identities or transaction state. Bindings stay sample-local.
        if (METADATA.size() < 2048) METADATA.putIfAbsent(sql, created);
        return created;
    }

    /** Fixed diagnostic labels only; never emit SQL text, query values or bindings. */
    private static String queryLabel(String sql) {
        String normalized = sql.replaceAll("\\s+", " ").trim().toLowerCase(java.util.Locale.ROOT);
        if (normalized.startsWith("with recursive walk")
                || normalized.startsWith("with recursive roots(") && normalized.contains(", walk as (")) return "bom.validation";
        if (normalized.startsWith("with recursive roots as")) return "bom.lock_footprint";
        if (normalized.startsWith("with recursive roots(")) return "bom.expansion";
        String verb = normalized.startsWith("insert")
                || normalized.startsWith("with incoming ") && normalized.contains("insert into production_material_analysis_materials")
                ? "insert" : normalized.startsWith("update") ? "update" : "read";
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
