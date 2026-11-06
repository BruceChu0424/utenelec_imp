package com.uten.imp.support;

import com.zaxxer.hikari.HikariDataSource;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.SQLException;
import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

class ObservedSqlPoolTest {
    @Test void observationDelegatesTheSamePoolWithoutCopyingItsMutableState() throws Exception {
        var pool=mock(HikariDataSource.class);
        var connection=mock(Connection.class);
        var statement=mock(PreparedStatement.class);
        when(pool.getConnection()).thenReturn(connection);
        when(connection.prepareStatement("SELECT 1")).thenReturn(statement);
        var counts=new ObservedSqlDataSource();
        try(var observed=new ObservedSqlDataSource.Pooled(pool)) {
            assertThat(observed.getTargetDataSource()).isSameAs(pool);
            try(var scope=observed.observe(counts);var borrowed=observed.getConnection();
                var sql=borrowed.prepareStatement("SELECT 1")) { sql.execute(); }
            assertThat(counts.statements.get()).isOne();
            try(var ordinary=observed.getConnection()) { assertThat(ordinary).isSameAs(connection); }
        }
        verify(pool,times(1)).close();
        verify(statement,times(1)).close();
    }

    @Test void aNestedObserverCannotStealTheExistingObservationOwner() throws Exception {
        var pool=mock(HikariDataSource.class);
        try(var observed=new ObservedSqlDataSource.Pooled(pool)) {
            var first=new ObservedSqlDataSource();var second=new ObservedSqlDataSource();
            try(var scope=observed.observe(first)) {
                assertThatThrownBy(()->observed.observe(second)).isInstanceOf(IllegalStateException.class);
            }
            try(var next=observed.observe(second)) { assertThat(second.statements.get()).isZero(); }
        }
    }

    @Test void aConnectionFailureDoesNotReplayOrLoseTheObservationScope() throws Exception {
        var pool=mock(HikariDataSource.class);
        when(pool.getConnection()).thenThrow(new SQLException("controlled borrow failure"));
        try(var observed=new ObservedSqlDataSource.Pooled(pool)) {
            try(var scope=observed.observe(new ObservedSqlDataSource())) {
                assertThatThrownBy(observed::getConnection).isInstanceOf(SQLException.class);
            }
            try(var next=observed.observe(new ObservedSqlDataSource())) { verify(pool,times(1)).getConnection(); }
        }
    }
}
