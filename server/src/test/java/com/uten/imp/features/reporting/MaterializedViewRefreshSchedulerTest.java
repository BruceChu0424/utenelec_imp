package com.uten.imp.features.reporting;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import javax.sql.DataSource;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.Statement;
import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;

import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class MaterializedViewRefreshSchedulerTest {

    private DataSource dataSource;
    private Connection connection;
    private PreparedStatement preparedStatement;
    private ResultSet resultSet;
    private Statement refreshStatement;
    private MaterializedViewRefreshScheduler scheduler;

    @BeforeEach
    void setUp() throws Exception {
        dataSource = mock(DataSource.class);
        connection = mock(Connection.class);
        preparedStatement = mock(PreparedStatement.class);
        resultSet = mock(ResultSet.class);
        refreshStatement = mock(Statement.class);

        when(dataSource.getConnection()).thenReturn(connection);
        when(connection.prepareStatement(anyString())).thenReturn(preparedStatement);
        when(preparedStatement.executeQuery()).thenReturn(resultSet);
        when(resultSet.next()).thenReturn(true);
        when(resultSet.getBoolean(1)).thenReturn(true);
        when(connection.createStatement()).thenReturn(refreshStatement);

        scheduler = new MaterializedViewRefreshScheduler(
                dataSource,
                Clock.fixed(Instant.parse("2026-07-30T08:00:00Z"), ZoneOffset.UTC),
                "test-instance");
    }

    @Test
    void refreshesEveryAllowlistedViewAndReleasesTheLock() throws Exception {
        scheduler.refreshAll();

        for (String viewName : MaterializedViewRefreshScheduler.REPORT_VIEWS) {
            verify(refreshStatement).execute(
                    "REFRESH MATERIALIZED VIEW CONCURRENTLY " + viewName);
        }
        verify(refreshStatement, times(MaterializedViewRefreshScheduler.REPORT_VIEWS.size()))
                .execute(anyString());
        verify(preparedStatement, times(2)).executeQuery();
    }

    @Test
    void skipsRefreshWhenAnotherInstanceOwnsTheLock() throws Exception {
        when(resultSet.getBoolean(1)).thenReturn(false);

        scheduler.refreshAll();

        verify(connection, never()).createStatement();
        verify(refreshStatement, never()).execute(anyString());
        verify(preparedStatement, times(1)).executeQuery();
    }
}
