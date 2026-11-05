package com.uten.imp.businesschain;

import com.uten.imp.support.MigratedProjectionSchema;
import com.uten.imp.testsupport.BoundTestSql;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.core.io.ClassPathResource;
import org.springframework.jdbc.core.*;
import org.springframework.test.context.*;
import org.springframework.transaction.support.TransactionTemplate;
import java.nio.charset.StandardCharsets;
import java.sql.*;
import java.util.*;
import static org.assertj.core.api.Assertions.*;

/** Real V1057 triggers over private copies of the fully migrated owning tables; everything rolls back. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
 "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
 "uten.production.readiness-reconcile.enabled=false","uten.features.goods-owner-scope-enabled=false",
 "uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
 "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
 "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
 "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
 "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class ReceiptExplicitOrderAttributionPostgresTest {
 private static final String PREPAYMENT_INSERT =
     "INSERT INTO finance_receipts(id,sales_order_id,client_id,currency_id,status,receipt_kind,order_selection_version)VALUES(?,?,?,?,0,'CUSTOMER_PREPAYMENT',1)";
 @DynamicPropertySource static void database(DynamicPropertyRegistry r){FullChainEndToEndTest.registerDataSource(r);}
 @Autowired JdbcTemplate db;
 @Autowired TransactionTemplate transactions;
 @Test void selectedOrderCannotBecomeAnotherOrderNullFifoOrDowngradedContract() {
  transactions.executeWithoutResult(tx->{
   db.execute((ConnectionCallback<Void>)c->{
    String schema="receipt_order_"+UUID.randomUUID().toString().replace("-","");
    try(var st=c.createStatement()){
     st.execute("CREATE SCHEMA "+schema);st.execute("SET LOCAL search_path TO "+schema+",public");
     MigratedProjectionSchema.copyEmptyTablesFromMigratedCatalog(c,"sales_orders","finance_receipts","finance_receipt_lines","ar_ap_source_refs","finance_receipt_source_allocations");
     st.execute("ALTER TABLE sales_orders ADD PRIMARY KEY(id)");
     st.execute("ALTER TABLE finance_receipt_lines DROP COLUMN requested_sales_order_id,DROP COLUMN applied_source_doc_type,DROP COLUMN applied_source_doc_id,DROP COLUMN applied_source_doc_no");
     st.execute("ALTER TABLE finance_receipts DROP COLUMN order_selection_version");
     try(var input=new ClassPathResource("db/migration/V1057__receipt_explicit_order_collection_source.sql").getInputStream()){
      st.execute(new String(input.readAllBytes(),StandardCharsets.UTF_8));
     } catch(java.io.IOException e){throw new IllegalStateException(e);}
     UUID a=UUID.randomUUID(),b=UUID.randomUUID(),client=UUID.randomUUID(),currency=UUID.randomUUID(),receipt=UUID.randomUUID(),line=UUID.randomUUID(),ledger=UUID.randomUUID();
     BoundTestSql.execute(st,"INSERT INTO sales_orders(id,client_id,currency_id)VALUES(?,?,?),(?,?,?)",a,client,currency,b,client,currency);
     BoundTestSql.execute(st,"INSERT INTO finance_receipts(id,client_id,status,receipt_kind,order_selection_version)VALUES(?,?,0,'AR_SETTLEMENT',1)",receipt,client);
     BoundTestSql.execute(st,"INSERT INTO ar_ap_source_refs(id,ledger_id,source_type,source_id)VALUES(gen_random_uuid(),?,'SALES_ORDER',?),(gen_random_uuid(),?,'SALES_ORDER',?)",ledger,a,ledger,b);
     BoundTestSql.execute(st,"INSERT INTO finance_receipt_lines(id,receipt_id,applied_ledger_id,currency_id,requested_sales_order_id)VALUES(?,?,?,?,?)",line,receipt,ledger,currency,b);
     st.execute("SET CONSTRAINTS ALL IMMEDIATE");
     rejected(c,"INSERT INTO finance_receipt_source_allocations(id,receipt_line_id,sales_order_id)VALUES(gen_random_uuid(),?,?)",line,a);
     rejected(c,"INSERT INTO finance_receipt_source_allocations(id,receipt_line_id,sales_order_id)VALUES(gen_random_uuid(),?,?)",line,null);
     BoundTestSql.execute(st,"UPDATE finance_receipt_lines SET requested_sales_order_id=NULL WHERE id=?",line);
     BoundTestSql.execute(st,"UPDATE finance_receipt_lines SET requested_sales_order_id=? WHERE id=?",b,line);
     rejected(c,"UPDATE finance_receipts SET order_selection_version=0 WHERE id=?",receipt);
     BoundTestSql.execute(st,"INSERT INTO finance_receipt_source_allocations(id,receipt_line_id,sales_order_id)VALUES(gen_random_uuid(),?,?)",line,b);
     BoundTestSql.execute(st,"UPDATE finance_receipts SET status=1 WHERE id=?",receipt);
     rejected(c,"UPDATE finance_receipt_lines SET requested_sales_order_id=? WHERE id=?",a,line);
     rejected(c,"UPDATE finance_receipt_lines SET applied_source_doc_no='FORGED-SHIPMENT' WHERE id=?",line);
     // Existing NULL / version-0 draft remains original evidence and is not retroactively assigned.
     UUID old=UUID.randomUUID();BoundTestSql.execute(st,"INSERT INTO finance_receipts(id,client_id,status,receipt_kind,order_selection_version)VALUES(?,?,0,'AR_SETTLEMENT',0)",old,client);
     BoundTestSql.execute(st,"INSERT INTO finance_receipt_lines(id,receipt_id,applied_ledger_id,currency_id)VALUES(gen_random_uuid(),?,?,?)",old,ledger,currency);

     // Attach the exact public function installed by the full migration chain to
     // private column copies. This isolates its SQL identity guard, including
     // corrupt NULL source states, without fabricating a full monetary lifecycle.
     st.execute("CREATE TRIGGER oracle_financial_order_guard BEFORE INSERT OR UPDATE OF sales_order_id,client_id,currency_id,receipt_kind,status "
         +"ON finance_receipts FOR EACH ROW EXECUTE FUNCTION public.fn_guard_finance_receipt_order()");
     UUID closed=UUID.randomUUID(),approved=UUID.randomUUID(),pending=UUID.randomUUID();
     BoundTestSql.execute(st,"INSERT INTO sales_orders(id,client_id,currency_id,status,is_deleted,is_stopped,is_closed)VALUES(?,?,?,1,FALSE,FALSE,TRUE)",closed,client,currency);
     prepayment(st,approved,closed,client,currency);
     prepayment(st,pending,closed,client,currency);
     BoundTestSql.execute(st,"UPDATE finance_receipts SET status=1 WHERE id=?",approved);
     BoundTestSql.execute(st,"UPDATE sales_orders SET is_stopped=TRUE WHERE id=?",closed);
     rejectedOrderGuard(c,PREPAYMENT_INSERT,UUID.randomUUID(),closed,client,currency);
     rejectedOrderGuard(c,"UPDATE finance_receipts SET status=1 WHERE id=?",pending);
     // The original approved identity can still reverse after its order stops;
     // no order reopening or replacement source is required for that history.
     BoundTestSql.execute(st,"UPDATE finance_receipts SET status=-1 WHERE id=?",approved);
     try(var query=BoundTestSql.prepare(st,"SELECT status,sales_order_id FROM finance_receipts WHERE id=?",approved);
         var row=query.executeQuery()){
      assertThat(row.next()).isTrue();assertThat(row.getInt(1)).isEqualTo(-1);assertThat(row.getObject(2,UUID.class)).isEqualTo(closed);
     }
     BoundTestSql.execute(st,"UPDATE sales_orders SET is_stopped=FALSE,status=0 WHERE id=?",closed);
     rejectedOrderGuard(c,PREPAYMENT_INSERT,UUID.randomUUID(),closed,client,currency);
     BoundTestSql.execute(st,"UPDATE sales_orders SET status=NULL WHERE id=?",closed);
     rejectedOrderGuard(c,PREPAYMENT_INSERT,UUID.randomUUID(),closed,client,currency);
     BoundTestSql.execute(st,"UPDATE sales_orders SET status=1,is_deleted=TRUE WHERE id=?",closed);
     rejectedOrderGuard(c,PREPAYMENT_INSERT,UUID.randomUUID(),closed,client,currency);
     BoundTestSql.execute(st,"UPDATE sales_orders SET is_deleted=FALSE WHERE id=?",closed);
     rejectedOrderGuard(c,PREPAYMENT_INSERT,UUID.randomUUID(),closed,UUID.randomUUID(),currency);
     rejectedOrderGuard(c,PREPAYMENT_INSERT,UUID.randomUUID(),closed,client,UUID.randomUUID());
     rejectedOrderGuard(c,PREPAYMENT_INSERT,UUID.randomUUID(),closed,null,currency);
     rejectedOrderGuard(c,PREPAYMENT_INSERT,UUID.randomUUID(),closed,client,null);
     prepayment(st,UUID.randomUUID(),closed,client,currency);
    }
    return null;
   });
   tx.setRollbackOnly();
  });
 }
 static void rejected(Connection c,String sql,Object... values)throws SQLException{
  Savepoint point=c.setSavepoint();
  try(var st=c.createStatement()){assertThatThrownBy(()->BoundTestSql.execute(st,sql,values)).isInstanceOf(SQLException.class);}
  finally{c.rollback(point);c.releaseSavepoint(point);}
 }
 static void prepayment(Statement st,UUID id,UUID order,UUID client,UUID currency)throws SQLException{
  BoundTestSql.execute(st,PREPAYMENT_INSERT,id,order,client,currency);
 }
 static void rejectedOrderGuard(Connection c,String sql,Object... values)throws SQLException{
  Savepoint point=c.setSavepoint();
  try(var st=c.createStatement()){
   try{BoundTestSql.execute(st,sql,values);fail("Expected the real finance receipt/order SQL identity guard to reject this source");}
   catch(SQLException failure){
    assertThat(failure.getSQLState()).isEqualTo("23514");
    assertThat((Throwable)failure).isInstanceOf(org.postgresql.util.PSQLException.class);
    assertThat(((org.postgresql.util.PSQLException)failure).getServerErrorMessage().getConstraint())
        .isEqualTo("finance_receipts_sales_order_identity_guard");
   }
  }finally{c.rollback(point);c.releaseSavepoint(point);}
 }
}
