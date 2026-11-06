package com.uten.imp.common.util;

import jakarta.persistence.EntityManager;
import jakarta.persistence.PersistenceException;
import java.sql.Connection;
import java.sql.SQLException;
import org.hibernate.Session;

/** Bounds optimizer compilation overhead for proven complex interactive task reads.
 * The existing transaction, connection, SQL, authorization and isolation are retained. */
public final class InteractiveTaskReadScope implements AutoCloseable {
    private static final InteractiveTaskReadScope UNMANAGED_TEST_QUERY = new InteractiveTaskReadScope(null,null);
    private final Connection connection;
    private final String previous;
    private boolean closed;
    private InteractiveTaskReadScope(Connection connection,String previous){this.connection=connection;this.previous=previous;}

    public static InteractiveTaskReadScope open(EntityManager entityManager){
        Session session=entityManager.unwrap(Session.class);
        // Query-only unit doubles have no JDBC connection. Real Hibernate
        // sessions retain the transaction already owned by the service caller.
        if(session==null)return UNMANAGED_TEST_QUERY;
        return session.doReturningWork(connection->{
            if(connection.getAutoCommit())throw new IllegalStateException("Interactive task reads require an active transaction");
            try(var statement=connection.prepareStatement("""
                    WITH previous AS MATERIALIZED(SELECT current_setting('jit') AS value)
                    SELECT previous.value,set_config('jit','off',true) FROM previous
                    """);var result=statement.executeQuery()){
                if(!result.next())throw new SQLException("PostgreSQL did not return the interactive read setting");
                String previous=result.getString(1);
                if(!"on".equals(previous)&&!"off".equals(previous))throw new SQLException("Unexpected PostgreSQL JIT setting");
                return new InteractiveTaskReadScope(connection,previous);
            }
        });
    }

    @Override public void close(){
        if(connection==null||closed)return;
        closed=true;
        try(var statement=connection.prepareStatement("SELECT set_config('jit',?,true)")){
            statement.setString(1,previous);statement.execute();
        }catch(SQLException failure){
            // An aborted database transaction may reject cleanup; its rollback
            // still removes SET LOCAL. try-with-resources retains the original
            // exception and attaches cleanup failure as suppressed.
            throw new PersistenceException("Cannot restore interactive task read setting",failure);
        }
    }
}
