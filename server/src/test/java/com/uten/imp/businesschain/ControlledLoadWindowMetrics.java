package com.uten.imp.businesschain;

import org.springframework.beans.factory.config.BeanPostProcessor;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.context.annotation.Bean;
import org.springframework.jdbc.datasource.DelegatingDataSource;
import javax.sql.DataSource;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.lang.reflect.Proxy;
import java.sql.Connection;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.EnumMap;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.concurrent.atomic.AtomicReference;
import java.util.concurrent.atomic.LongAdder;

/** All application DataSource threads are counted, including untagged production workers. */
final class ControlledLoadWindowMetrics {
    enum Phase { COMMAND, PREPARATION, VERIFY, DRAIN, OBSERVER, BACKGROUND, UNSCOPED }
    enum Outcome { RETURNED_COMMIT_CONFIRMED, COMMIT_CONFIRMED_CALL_FAILED, ROLLBACK_CONFIRMED, OUTCOME_UNKNOWN }
    private static final ThreadLocal<Span> CURRENT = new ThreadLocal<>();
    private static final AtomicReference<EnumMap<Phase, Counters>> GLOBAL = new AtomicReference<>(newCounters());

    static final class Counters {
        final LongAdder sql = new LongAdder(), sqlNanos = new LongAdder(), sqlFailures = new LongAdder();
        final LongAdder acquire = new LongAdder(), acquireNanos = new LongAdder(), acquireFailures = new LongAdder();
        final LongAdder commitAttempts = new LongAdder(), commitConfirmed = new LongAdder(), commitUncertain = new LongAdder(), commitNanos = new LongAdder();
        final LongAdder rollbackConfirmed = new LongAdder(), rollbackNanos = new LongAdder(), savepointRollbacks = new LongAdder();
        Map<String, Object> snapshot() {
            var result = new LinkedHashMap<String, Object>();
            result.put("sqlStatements", sql.sum()); result.put("sqlMillis", ms(sqlNanos)); result.put("sqlFailures", sqlFailures.sum());
            result.put("connectionAcquisitions", acquire.sum()); result.put("connectionAcquireMillis", ms(acquireNanos)); result.put("connectionAcquireFailures", acquireFailures.sum());
            result.put("commitAttempts", commitAttempts.sum()); result.put("commitConfirmed", commitConfirmed.sum());
            result.put("commitUncertain", commitUncertain.sum()); result.put("commitMillis", ms(commitNanos));
            result.put("rollbackConfirmed", rollbackConfirmed.sum()); result.put("rollbackMillis", ms(rollbackNanos));
            result.put("savepointRollbacks", savepointRollbacks.sum()); return result;
        }
        private static double ms(LongAdder value) { return value.sum() / 1_000_000.0; }
    }
    static final class Span implements AutoCloseable {
        final Phase phase; final Counters counters = new Counters(); private final Span previous;
        private Span(Phase phase) { this.phase = phase; previous = CURRENT.get(); CURRENT.set(this); }
        @Override public void close() { if (previous == null) CURRENT.remove(); else CURRENT.set(previous); }
    }
    static Span span(Phase phase) { return new Span(phase); }
    static void beginWindow() { GLOBAL.set(newCounters()); }
    static Map<String, Object> allThreads() {
        var result = new LinkedHashMap<String, Object>(); GLOBAL.get().forEach((phase, value) -> result.put(phase.name(), value.snapshot())); return result;
    }
    static Outcome outcome(boolean returned, Counters counters) {
        if (counters.commitUncertain.sum() > 0) return Outcome.OUTCOME_UNKNOWN;
        if (counters.commitConfirmed.sum() > 0) return returned ? Outcome.RETURNED_COMMIT_CONFIRMED : Outcome.COMMIT_CONFIRMED_CALL_FAILED;
        if (!returned && counters.rollbackConfirmed.sum() > 0 && counters.commitAttempts.sum() == 0) return Outcome.ROLLBACK_CONFIRMED;
        return Outcome.OUTCOME_UNKNOWN;
    }
    private static EnumMap<Phase, Counters> newCounters() {
        var result = new EnumMap<Phase, Counters>(Phase.class); for (Phase phase : Phase.values()) result.put(phase, new Counters()); return result;
    }
    private static Phase phase() {
        if (CURRENT.get() != null) return CURRENT.get().phase;
        String name = Thread.currentThread().getName();
        return name.startsWith("scheduling-") || name.startsWith("business-outbox-") || name.startsWith("ai-job-")
                || name.startsWith("workshop-material-close-") || name.startsWith("server-status-") ? Phase.BACKGROUND : Phase.UNSCOPED;
    }
    private static void add(java.util.function.Consumer<Counters> event) {
        event.accept(GLOBAL.get().get(phase())); if (CURRENT.get() != null) event.accept(CURRENT.get().counters);
    }

    @TestConfiguration(proxyBeanMethods = false)
    static class Configuration {
        @Bean static BeanPostProcessor controlledWindowJdbcMetrics() {
            return new BeanPostProcessor() {
                @Override public Object postProcessAfterInitialization(Object bean, String name) {
                    return bean instanceof DataSource data && !(bean instanceof MeteredDataSource) ? new MeteredDataSource(data) : bean;
                }
            };
        }
    }
    private static final class MeteredDataSource extends DelegatingDataSource {
        MeteredDataSource(DataSource source) { super(source); }
        @Override public Connection getConnection() throws SQLException { return borrow(super::getConnection); }
        @Override public Connection getConnection(String user, String password) throws SQLException { return borrow(() -> super.getConnection(user, password)); }
    }
    @FunctionalInterface private interface Borrow { Connection get() throws SQLException; }
    private static Connection borrow(Borrow supplier) throws SQLException {
        add(c -> c.acquire.increment()); long started = System.nanoTime();
        try { return connection(supplier.get()); }
        catch (SQLException failure) { add(c -> c.acquireFailures.increment()); throw failure; }
        finally { long elapsed = System.nanoTime() - started; add(c -> c.acquireNanos.add(elapsed)); }
    }
    private static Connection connection(Connection target) {
        return (Connection) Proxy.newProxyInstance(Connection.class.getClassLoader(), new Class<?>[]{Connection.class}, (proxy, method, args) -> {
            String name = method.getName(); boolean commit = name.equals("commit");
            boolean rollback = name.equals("rollback") && (args == null || args.length == 0);
            if (commit) add(c -> c.commitAttempts.increment());
            long start = System.nanoTime();
            try {
                Object result = invoke(target, method, args);
                if (commit) add(c -> c.commitConfirmed.increment());
                if (rollback) add(c -> c.rollbackConfirmed.increment());
                if (name.equals("rollback") && !rollback) add(c -> c.savepointRollbacks.increment());
                if (result instanceof Statement statement && (name.startsWith("prepare") || name.equals("createStatement"))) return statement(statement);
                return result;
            } catch (Throwable failure) { if (commit) add(c -> c.commitUncertain.increment()); throw failure; }
            finally {
                long elapsed = System.nanoTime() - start;
                if (commit) add(c -> c.commitNanos.add(elapsed));
                if (rollback) add(c -> c.rollbackNanos.add(elapsed));
            }
        });
    }
    private static Statement statement(Statement target) {
        Class<?> type = target instanceof java.sql.CallableStatement ? java.sql.CallableStatement.class
                : target instanceof java.sql.PreparedStatement ? java.sql.PreparedStatement.class : Statement.class;
        int[] queued = {0};
        return (Statement) Proxy.newProxyInstance(type.getClassLoader(), new Class<?>[]{type}, (proxy, method, args) -> {
            String name = method.getName();
            if (name.equals("addBatch")) queued[0]++;
            if (name.equals("clearBatch")) queued[0] = 0;
            if (!name.startsWith("execute")) return invoke(target, method, args);
            boolean batch = name.equals("executeBatch") || name.equals("executeLargeBatch");
            int count = batch ? queued[0] : 1; add(c -> c.sql.add(count)); long start = System.nanoTime();
            try { return invoke(target, method, args); }
            catch (Throwable failure) { add(c -> c.sqlFailures.increment()); throw failure; }
            finally { if (batch) queued[0] = 0; long elapsed = System.nanoTime() - start; add(c -> c.sqlNanos.add(elapsed)); }
        });
    }
    private static Object invoke(Object target, Method method, Object[] arguments) throws Throwable {
        try { return method.invoke(target, arguments); } catch (InvocationTargetException failure) { throw failure.getCause(); }
    }
}
