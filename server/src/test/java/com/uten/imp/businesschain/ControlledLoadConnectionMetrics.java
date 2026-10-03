package com.uten.imp.businesschain;

import org.springframework.beans.factory.config.BeanPostProcessor;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.context.annotation.Bean;
import org.springframework.jdbc.datasource.DelegatingDataSource;

import javax.sql.DataSource;
import java.sql.Connection;
import java.sql.SQLException;
import java.util.Map;

/** Counts pool acquisition independently of SQL and JDBC COMMIT; never changes connections or limits. */
final class ControlledLoadConnectionMetrics {
    private static final ThreadLocal<Sample> ACTIVE = new ThreadLocal<>();
    static final class Sample {
        long attempts, failures, nanos, maxNanos;
        Map<String, Object> result() {
            return Map.of("attempts", attempts, "failures", failures, "totalMillis", nanos / 1_000_000.0,
                    "maxMillis", maxNanos / 1_000_000.0);
        }
    }
    static Sample begin() {
        if (ACTIVE.get() != null) throw new IllegalStateException("Connection measurements cannot nest");
        var result = new Sample(); ACTIVE.set(result); return result;
    }
    static void end() { ACTIVE.remove(); }

    @TestConfiguration(proxyBeanMethods = false)
    static class Configuration {
        @Bean static BeanPostProcessor controlledLoadConnectionCounter() {
            return new BeanPostProcessor() {
                @Override public Object postProcessAfterInitialization(Object bean, String name) {
                    if (!(bean instanceof DataSource source)) return bean;
                    return new DelegatingDataSource(source) {
                        @Override public Connection getConnection() throws SQLException {
                            return measure(super::getConnection);
                        }
                        @Override public Connection getConnection(String user, String password) throws SQLException {
                            return measure(() -> super.getConnection(user, password));
                        }
                    };
                }
            };
        }
    }
    @FunctionalInterface private interface Borrow { Connection get() throws SQLException; }
    private static Connection measure(Borrow borrow) throws SQLException {
        Sample sample = ACTIVE.get();
        if (sample == null) return borrow.get();
        sample.attempts++;
        long started = System.nanoTime();
        try { return borrow.get(); }
        catch (SQLException failure) { sample.failures++; throw failure; }
        finally {
            long elapsed = System.nanoTime() - started;
            sample.nanos += elapsed; sample.maxNanos = Math.max(sample.maxNanos, elapsed);
        }
    }
}
