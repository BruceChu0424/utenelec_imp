package com.uten.imp.support;

import org.junit.jupiter.api.Test;

import java.sql.Array;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;

import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.*;

class PostgresFixtureDdlTest {
    @Test void rawSubstitutionAndWrongArityAreRefusedBeforeOpeningAnyResource() {
        var connection = mock(Connection.class);
        assertThatThrownBy(() -> PostgresFixtureDdl.execute(connection, "COMMENT ON TABLE %s IS %L", "table", "text"))
                .isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> PostgresFixtureDdl.execute(connection, "COMMENT ON TABLE %I IS %L", "table"))
                .isInstanceOf(IllegalArgumentException.class);
        verifyNoInteractions(connection);
    }

    @Test void templatesAndArgumentsAreBoundAndEverySuccessfulResourceIsClosed() throws Exception {
        var connection = mock(Connection.class);
        var array = mock(Array.class);
        var formatter = mock(PreparedStatement.class);
        var row = mock(ResultSet.class);
        var statement = mock(Statement.class);
        when(connection.createArrayOf(eq("text"), any())).thenReturn(array);
        when(connection.prepareStatement("SELECT format(?::text, VARIADIC ?::text[])")).thenReturn(formatter);
        when(formatter.executeQuery()).thenReturn(row);
        when(row.next()).thenReturn(true);
        when(row.getString(1)).thenReturn("COMMENT ON TABLE example IS 'quoted' ");
        when(connection.createStatement()).thenReturn(statement);
        PostgresFixtureDdl.execute(connection, "COMMENT ON TABLE %I IS %L", "example", "quoted");
        verify(formatter).setString(1, "COMMENT ON TABLE %I IS %L");
        verify(formatter).setArray(2, array);
        verify(row).close();
        verify(formatter).close();
        verify(array).free();
        verify(statement).execute("COMMENT ON TABLE example IS 'quoted' ");
        verify(statement).close();
        verify(connection, never()).close();
    }

    @Test void formatterFailureStillClosesItsStatementAndArrayWithoutExecutingDdl() throws Exception {
        var connection = mock(Connection.class);
        var array = mock(Array.class);
        var formatter = mock(PreparedStatement.class);
        when(connection.createArrayOf(eq("text"), any())).thenReturn(array);
        when(connection.prepareStatement(any())).thenReturn(formatter);
        when(formatter.executeQuery()).thenThrow(new SQLException("controlled formatter failure"));
        assertThatThrownBy(() -> PostgresFixtureDdl.execute(connection, "COMMENT ON TABLE %I IS %L", "example", "quoted"))
                .isInstanceOf(SQLException.class);
        verify(formatter).close();
        verify(array).free();
        verify(connection, never()).createStatement();
    }
}
