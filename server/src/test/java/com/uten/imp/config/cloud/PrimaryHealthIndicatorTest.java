package com.uten.imp.config.cloud;

import org.junit.jupiter.api.Test;

import javax.sql.DataSource;
import java.sql.Connection;
import java.sql.Statement;

import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class PrimaryHealthIndicatorTest {

    @Test
    void pingBoundsTheSqlProbeAndMarksPrimaryUp() throws Exception {
        DataSource dataSource = mock(DataSource.class);
        Connection connection = mock(Connection.class);
        Statement statement = mock(Statement.class);
        when(dataSource.getConnection()).thenReturn(connection);
        when(connection.createStatement()).thenReturn(statement);

        PrimaryHealthIndicator health = new PrimaryHealthIndicator(dataSource);
        health.ping();

        verify(statement).setQueryTimeout(5);
        verify(statement).execute("SELECT 1");
        assertTrue(health.isUp());
    }
}
