package com.uten.imp.businesschain;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/** Isolated source-ledger adversary. API permissions and valuation run in the Spring E2E suite. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class WorkshopMaterialCustodyPostgresTest {
    @Test
    void actualUnissuedTransferReleaseAndReverseCannotResurrectTechnicalOrDestinationStockRights() {
        try(var pg=new PostgreSQLContainer<>("postgres:16-alpine")) {
            pg.start();
            migrate(pg,"614");
            var source=new DriverManagerDataSource(pg.getJdbcUrl(),pg.getUsername(),pg.getPassword());
            var db=new JdbcTemplate(source);
            var tx=new TransactionTemplate(new DataSourceTransactionManager(source));
            Object old=tx.execute(ignored->ReflectionTestUtils.invokeMethod(WorkshopDirectSourceHistoryPostgresTest.class,"seed",db,false));
            UUID reservation=ReflectionTestUtils.invokeMethod(old,"reservation");
            UUID demand=ReflectionTestUtils.invokeMethod(old,"demand");
            UUID plan=ReflectionTestUtils.invokeMethod(old,"parentPlan");
            migrate(pg,"619");
            UUID actor=id(db,"SELECT created_by FROM production_material_stock_postings WHERE reservation_id=? LIMIT 1",reservation);
            UUID maker=id(db,"SELECT employee_id FROM users WHERE id=?",actor);
            UUID segment=id(db,"SELECT execution_segment_id FROM production_material_demands WHERE id=?",demand);
            UUID workshop=id(db,"SELECT workshop_department_id FROM production_execution_segments WHERE id=?",segment);
            UUID tech=id(db,"SELECT warehouse_id FROM stock_reservations WHERE id=?",reservation);
            UUID main=id(db,"SELECT warehouse_id FROM production_material_demands WHERE id=?",demand);
            UUID goods=id(db,"SELECT goods_id FROM stock_reservations WHERE id=?",reservation);
            UUID unit=id(db,"SELECT unit_id FROM production_material_demands WHERE id=?",demand);
            UUID direct=id(db,"SELECT transfer_item_id FROM production_workshop_direct_source_allocations WHERE stock_reservation_id=?",reservation);
            UUID incomingSource=id(db,"SELECT item.id FROM stock_document_items item JOIN production_workshop_direct_transfer_items direct ON direct.source_report_item_id=item.source_daily_report_item_id WHERE direct.id=? AND item.bill_type='FINISHED_IN' AND NOT item.is_deleted",direct);
            UUID normal=UUID.randomUUID(),doc=UUID.randomUUID(),item=UUID.randomUUID(),requestItem=UUID.randomUUID();
            tx.executeWithoutResult(ignored->{
                actor(db,actor);
                db.update("INSERT INTO warehouses(id,code,name,parent_id,status,is_accountable) VALUES(?,?,?,?,'使用',true)",normal,"CUSTODY-"+normal,"正常接收仓",main);
                String number=ReflectionTestUtils.invokeMethod(WorkshopDirectSourceHistoryPostgresTest.class,"number",db,"STOCK_WDRAW");
                db.update("INSERT INTO stock_documents(id,doc_type,bill_no,bill_date,department_id,maker_id,status,created_by) VALUES(?,'WDRAW',?,CURRENT_DATE,?,?,0,?)",doc,number,workshop,maker,actor);
                db.update("INSERT INTO stock_document_items(id,doc_id,bill_type,bill_no,bill_date,line_no,goods_id,unit_id,unit_rate,qty,base_qty,upstream_item_id,goods_snapshot_source) VALUES(?,?,'WDRAW',?,CURRENT_DATE,1,?,?,1,2,2,?,'MASTER_AT_SAVE')",item,doc,number,goods,unit,incomingSource);
                db.update("INSERT INTO production_material_return_requests(id,plan_id,execution_segment_id,warehouse_id,source_department_id,idempotency_key,request_hash,reason,created_by) VALUES(?,?,?,?,?,?,?,?,?)",doc,plan,segment,tech,workshop,"custody-request-"+doc,"a".repeat(64),"未领用物料真实移到正常仓",actor);
                db.update("INSERT INTO production_material_return_request_items(id,request_id,stock_document_item_id,direct_transfer_item_id,qty_base,created_by) VALUES(?,?,?,?,2,?)",requestItem,doc,item,direct,actor);
            });
            qty(db,"1","SELECT fn_workshop_reservation_unissued_available(?)",reservation);
            tx.executeWithoutResult(ignored->{
                actor(db,actor);
                db.update("INSERT INTO production_material_return_receiving_confirmations(stock_document_id,return_request_id,source_warehouse_id,received_warehouse_id,idempotency_key,request_hash,created_by) VALUES(?,?,?,?,?,?,?)",doc,doc,tech,normal,"custody-confirm-"+doc,"b".repeat(64),actor);
                db.update("UPDATE stock_documents SET warehouse_id=? WHERE id=?",normal,doc);
                db.queryForObject("SELECT fn_prepare_workshop_return_custody(?,NULL,?)",Object.class,requestItem,actor);
                db.update("UPDATE stock_balances SET qty=qty-2 WHERE warehouse_id=? AND goods_id=?",tech,goods);
                db.update("INSERT INTO stock_balances(id,warehouse_id,goods_id,qty) VALUES(?,?,?,2)",UUID.randomUUID(),normal,goods);
                UUID out=movement(db,doc,item,tech,goods,unit,8,-1,actor);
                UUID in=movement(db,doc,item,normal,goods,unit,7,1,actor);
                db.queryForList("SELECT * FROM fn_move_workshop_return_custody(?,NULL,?,?,?)",requestItem,in,out,actor);
                db.update("UPDATE stock_documents SET status=1 WHERE id=?",doc);
            });
            UUID moved=id(db,"SELECT target_reservation_id FROM production_workshop_material_custody_moves WHERE request_item_id=?",requestItem);
            qty(db,"4","SELECT effective_qty FROM v_workshop_direct_source_allocations WHERE stock_reservation_id=?",reservation);
            qty(db,"2","SELECT effective_qty FROM v_workshop_direct_source_allocations WHERE stock_reservation_id=?",moved);
            qty(db,"4","SELECT available_qty FROM v_workshop_direct_supply_lots WHERE id=?",direct);
            tx.executeWithoutResult(ignored->{actor(db,actor);db.update("UPDATE stock_reservations SET released_qty=2,status=1 WHERE id=?",moved);});
            qty(db,"4","SELECT available_qty FROM v_workshop_direct_supply_lots WHERE id=?",direct);
            tx.executeWithoutResult(ignored->{
                actor(db,actor);
                db.queryForObject("SELECT fn_prepare_reverse_workshop_return_custody(?,NULL,?)",Object.class,requestItem,actor);
                db.update("UPDATE stock_balances SET qty=qty-2 WHERE warehouse_id=? AND goods_id=?",normal,goods);
                db.update("UPDATE stock_balances SET qty=qty+2 WHERE warehouse_id=? AND goods_id=?",tech,goods);
                UUID in=movement(db,doc,item,normal,goods,unit,7,-1,actor);
                UUID out=movement(db,doc,item,tech,goods,unit,8,1,actor);
                db.queryForObject("SELECT fn_reverse_workshop_return_custody(?,?,?,NULL,?)",Object.class,requestItem,in,out,actor);
                db.update("UPDATE stock_documents SET status=-1 WHERE id=?",doc);
            });
            qty(db,"6","SELECT effective_qty FROM v_workshop_direct_source_allocations WHERE stock_reservation_id=?",reservation);
            qty(db,"0","SELECT effective_qty FROM v_workshop_direct_source_allocations WHERE stock_reservation_id=?",moved);
            qty(db,"4","SELECT available_qty FROM v_workshop_direct_supply_lots WHERE id=?",direct);
            // Even unrelated replacement stock at the receiving warehouse cannot
            // reactivate the reversed source grant.
            tx.executeWithoutResult(ignored->{
                actor(db,actor);
                UUID replacement=UUID.randomUUID(),replacementItem=UUID.randomUUID();
                String number=ReflectionTestUtils.invokeMethod(WorkshopDirectSourceHistoryPostgresTest.class,"number",db,"STOCK_OTHER_IN");
                db.update("INSERT INTO stock_documents(id,doc_type,bill_no,bill_date,warehouse_id,department_id,maker_id,status,created_by) VALUES(?,'OTHER_IN',?,CURRENT_DATE,?,?,?,1,?)",replacement,number,normal,workshop,maker,actor);
                db.update("INSERT INTO stock_document_items(id,doc_id,bill_type,bill_no,bill_date,line_no,goods_id,unit_id,unit_rate,qty,base_qty,goods_snapshot_source) VALUES(?,?,'OTHER_IN',?,CURRENT_DATE,1,?,?,1,2,2,'MASTER_AT_SAVE')",replacementItem,replacement,number,goods,unit);
                movement(db,replacement,replacementItem,normal,goods,unit,11,1,actor);
                db.update("UPDATE stock_balances SET qty=qty+2 WHERE warehouse_id=? AND goods_id=?",normal,goods);
            });
            assertThatThrownBy(()->tx.executeWithoutResult(ignored->{actor(db,actor);db.update("UPDATE stock_reservations SET released_qty=0,status=0 WHERE id=?",moved);}))
                    .hasStackTraceContaining("Reversed");
            qty(db,"0","SELECT effective_qty FROM v_workshop_direct_source_allocations WHERE stock_reservation_id=?",moved);
        }
    }

    private static void migrate(PostgreSQLContainer<?> pg,String target) {
        Flyway.configure().dataSource(pg.getJdbcUrl(),pg.getUsername(),pg.getPassword()).locations("classpath:db/migration").target(target).load().migrate();
    }
    private static void actor(JdbcTemplate db,UUID actor){db.queryForObject("SELECT set_config('app.actor_id',?,true)",String.class,actor.toString());}
    private static UUID id(JdbcTemplate db,String sql,Object... args){return db.queryForObject(sql,UUID.class,args);}
    private static void qty(JdbcTemplate db,String expected,String sql,Object... args){assertThat(db.queryForObject(sql,BigDecimal.class,args)).isEqualByComparingTo(expected);}
    private static UUID movement(JdbcTemplate db,UUID doc,UUID item,UUID warehouse,UUID goods,UUID unit,int type,int direction,UUID actor) {
        UUID id=UUID.randomUUID();
        db.update("INSERT INTO stock_movements(id,transaction_date,movement_type,source_doc_type,source_doc_id,source_item_id,goods_id,warehouse_id,direction,qty,unit_id,unit_rate,created_by) VALUES(?,now(),?,'STOCK_DOC',?,?,?,?,?,2,?,1,?)",id,type,doc,item,goods,warehouse,direction,unit,actor);
        return id;
    }
}
