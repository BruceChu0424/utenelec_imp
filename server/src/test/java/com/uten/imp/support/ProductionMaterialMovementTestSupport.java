package com.uten.imp.support;

import java.sql.Connection;
import java.sql.SQLException;
import java.util.UUID;

/** Current-schema fixtures append actual material movements; pre-V514 migration fixtures stay historical. */
public final class ProductionMaterialMovementTestSupport {
    private ProductionMaterialMovementTestSupport() {}

    public static UUID beginEvent(Connection connection,UUID document,String type,String key)throws SQLException {
        boolean needsLink=required(connection);
        if(needsLink) {
            if(!connection.getAutoCommit()) throw new IllegalStateException("Use bindInCurrentTransaction for a fixture that already owns its transaction");
            connection.setAutoCommit(false);
        }
        UUID event=UUID.randomUUID();
        try(var statement=connection.prepareStatement("INSERT INTO production_material_stock_events(id,stock_document_id,event_type,idempotency_key,request_hash) VALUES(?,?,?,?,?)")) {
            statement.setObject(1,event);statement.setObject(2,document);statement.setString(3,type);statement.setString(4,key);statement.setString(5,"c".repeat(64));
            statement.executeUpdate();return event;
        } catch(SQLException failure) {
            if(needsLink) abort(connection);
            throw failure;
        }
    }

    public static void bindAndCommit(Connection connection,UUID event,UUID item)throws SQLException {
        if(!required(connection)) return;
        try { bindInCurrentTransaction(connection,event,item);connection.commit(); }
        catch(SQLException failure) { connection.rollback();throw failure; }
        finally { connection.setAutoCommit(true); }
    }

    public static void bindInCurrentTransaction(Connection connection,UUID event,UUID item)throws SQLException {
        if(!required(connection)) return;
        if(connection.getAutoCommit()) throw new IllegalStateException("Physical movement, material event and link must share one transaction");
        UUID movement=UUID.randomUUID();
        try(var statement=connection.prepareStatement("""
                INSERT INTO stock_movements(id,transaction_date,movement_type,source_doc_type,source_doc_id,source_item_id,
                    goods_id,color_id,warehouse_id,direction,qty,unit_id,unit_rate)
                SELECT ?,now(),CASE WHEN event.event_type IN('ISSUE','ISSUE_REVERSE') THEN 5 ELSE 6 END,
                    'STOCK_DOC',event.stock_document_id,item.id,item.goods_id,item.color_id,document.warehouse_id,
                    CASE WHEN event.event_type IN('ISSUE','GOOD_RETURN_REVERSE') THEN -1 ELSE 1 END,
                    (SELECT sum(posting.qty_base) FROM production_material_stock_postings posting
                        WHERE posting.event_id=event.id AND posting.stock_document_item_id=item.id),item.unit_id,item.unit_rate
                FROM production_material_stock_events event JOIN stock_documents document ON document.id=event.stock_document_id
                JOIN stock_document_items item ON item.doc_id=document.id WHERE event.id=? AND item.id=?
                """)) {
            statement.setObject(1,movement);statement.setObject(2,event);statement.setObject(3,item);
            if(statement.executeUpdate()!=1) throw new SQLException("Fixture did not resolve its exact material document item");
        }
        try(var statement=connection.prepareStatement("INSERT INTO production_material_movement_links(event_id,document_item_id,movement_id) VALUES(?,?,?)")) {
            statement.setObject(1,event);statement.setObject(2,item);statement.setObject(3,movement);statement.executeUpdate();
        }
    }

    public static void abort(Connection connection)throws SQLException {
        if(!connection.getAutoCommit()) { connection.rollback();connection.setAutoCommit(true); }
    }

    private static boolean required(Connection connection)throws SQLException {
        try(var statement=connection.createStatement();var result=statement.executeQuery(
                "SELECT COALESCE(max(version::integer),0)>=514 FROM flyway_schema_history WHERE success AND version IS NOT NULL")) {
            if(!result.next()) throw new SQLException("Missing fixture migration identity");
            return result.getBoolean(1);
        }
    }
}
