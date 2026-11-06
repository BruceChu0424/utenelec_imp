package com.uten.imp.support;

import org.springframework.jdbc.datasource.DriverManagerDataSource;

import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Proxy;
import java.sql.Connection;
import java.sql.SQLException;
import java.sql.Statement;
import java.sql.PreparedStatement;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.function.Consumer;

/** Counts JDBC statement executions, including plain/PreparedStatement queries. */
public final class ObservedSqlDataSource extends DriverManagerDataSource {
    public final AtomicInteger statements = new AtomicInteger();
    public volatile Consumer<String> beforePrepare = ignored -> {};

    /** Observation-only instance may wrap a fixture's existing pooled connection. */
    public ObservedSqlDataSource() { }

    public ObservedSqlDataSource(String url, String user, String password) {
        super(url, user, password);
    }

    @Override public Connection getConnection() throws SQLException { return observeConnection(super.getConnection()); }
    @Override public Connection getConnection(String user, String password) throws SQLException {
        return observeConnection(super.getConnection(user,password));
    }

    public Connection observeConnection(Connection connection) {
        return (Connection) Proxy.newProxyInstance(Connection.class.getClassLoader(), new Class<?>[]{Connection.class},
                (proxy, method, arguments) -> {
                    if (method.getName().equals("prepareStatement") && arguments[0] instanceof String sql) {
                        beforePrepare.accept(sql);
                    }
                    try {
                        Object result=method.invoke(connection, arguments);
                        if (method.getName().equals("prepareStatement")) {
                            return observeStatement((Statement)result,PreparedStatement.class);
                        }
                        if (method.getName().equals("createStatement")) {
                            return observeStatement((Statement)result,Statement.class);
                        }
                        return result;
                    }
                    catch (InvocationTargetException failure) { throw failure.getCause(); }
                });
    }

    private Object observeStatement(Statement statement, Class<?> type) {
        return Proxy.newProxyInstance(Statement.class.getClassLoader(),new Class<?>[]{type},
                (proxy,method,arguments) -> {
                    if (method.getName().startsWith("execute")) statements.incrementAndGet();
                    try { return method.invoke(statement,arguments); }
                    catch (InvocationTargetException failure) { throw failure.getCause(); }
                });
    }

    /** Delegates to the same live pool; unlike a Mockito spy it copies no mutable pool fields. */
    public static final class Pooled extends org.springframework.jdbc.datasource.DelegatingDataSource implements AutoCloseable {
        private final com.zaxxer.hikari.HikariDataSource owned;
        private final java.util.concurrent.atomic.AtomicReference<ObservedSqlDataSource> observer=new java.util.concurrent.atomic.AtomicReference<>();
        public Pooled(com.zaxxer.hikari.HikariDataSource owned) { super(owned);this.owned=owned; }
        public AutoCloseable observe(ObservedSqlDataSource next) {
            java.util.Objects.requireNonNull(next);
            if(!observer.compareAndSet(null,next)) { throw new IllegalStateException("A pool observation is already active"); }
            return ()->{ if(!observer.compareAndSet(next,null)) { throw new IllegalStateException("Pool observation owner changed"); } };
        }
        @Override public Connection getConnection() throws SQLException {
            var current=observer.get();var connection=super.getConnection();
            return current==null?connection:current.observeConnection(connection);
        }
        @Override public Connection getConnection(String user,String password) throws SQLException {
            var current=observer.get();var connection=super.getConnection(user,password);
            return current==null?connection:current.observeConnection(connection);
        }
        @Override public void close() { owned.close(); }
    }
}
