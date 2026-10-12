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

    public ObservedSqlDataSource(String url, String user, String password) {
        super(url, user, password);
    }

    @Override public Connection getConnection() throws SQLException { return observe(super.getConnection()); }
    @Override public Connection getConnection(String user, String password) throws SQLException {
        return observe(super.getConnection(user,password));
    }

    private Connection observe(Connection connection) {
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
}
