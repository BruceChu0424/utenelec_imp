package com.uten.imp.features.finance.gl;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.storage.ImmutableDocumentStore;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.finance.FinanceOperationJournal;
import com.uten.imp.security.*;
import com.uten.imp.support.FinanceReportTestAccess;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.postgresql.PostgreSQLContainer;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.Supplier;
import static com.uten.imp.features.finance.gl.FinanceChartContracts.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

/** Actual owning V999_1 table shapes, V1049/V1053 and immutable function over
 * anonymous identity fixtures. Not a full ERP or global audit-pipeline claim. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class FinanceChartMetadataCancellationPostgresTest {
    private static final PostgreSQLContainer PG=new PostgreSQLContainer("postgres:16-alpine");
    private static final ObjectMapper JSON=com.uten.imp.config.Jackson2ObjectMapperAutoConfiguration.domainObjectMapper();
    private static final UUID A=UUID.fromString("00000000-0000-0000-0000-000000000501"),B=UUID.fromString("00000000-0000-0000-0000-000000000502");
    private static final UUID OLD=UUID.fromString("00000000-0000-0000-0000-000000000503");
    private static final Set<String> READ=Set.of("finance_report:view","finance:view:all"),WRITE=Set.of("finance_report:view","finance:view:all","payment_style:edit");
    private static JdbcTemplate db;
    private static TransactionTemplate transactions;
    private static String historical;
    private final SecurityContextCurrentUser current=new SecurityContextCurrentUser();
    private FinanceChartService chart;
    private com.uten.imp.application.port.FinancialChartCurrencyReadPort currencies;

    @BeforeAll static void start()throws Exception{
        PG.start();var source=new DriverManagerDataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword());
        db=new JdbcTemplate(source);transactions=new TransactionTemplate(new DataSourceTransactionManager(source));
        db.execute("CREATE TABLE users(id uuid PRIMARY KEY);CREATE TABLE payment_styles(id uuid PRIMARY KEY);CREATE TABLE currencies(id uuid PRIMARY KEY);CREATE TABLE finance_applications(id uuid PRIMARY KEY)");
        db.update("INSERT INTO users(id)VALUES(?),(?)",A,B);
        String chart=resource("V999_1__finance_chart_code_imports.sql"),applications=resource("V999_11__financial_application_original_six_workflows.sql");
        for(String table:List.of("finance_chart_imports","finance_chart_codes","finance_chart_manual_operations"))db.execute(tableDdl(chart,table));
        db.execute(tableDdl(applications,"finance_application_operations"));
        int first=applications.indexOf("CREATE FUNCTION fn_finance_application_events_immutable()"),last=applications.indexOf("$$;",first);
        db.execute(applications.substring(first,last+3));
        db.execute(statement(applications,"CREATE TRIGGER finance_application_operations_immutable"));
        seedOld();historical=oldBytes();
        db.execute(resource("V1072__finance_application_settings_operation_receipts.sql"));
        db.execute(resource("V1074__shared_finance_command_receipts.sql"));
        assertThat(oldBytes()).isEqualTo(historical);
    }
    @AfterAll static void stop(){PG.stop();}
    @BeforeEach void reset(){
        db.execute("TRUNCATE finance_chart_codes,finance_chart_manual_operations");seedOld();
        db.update("INSERT INTO finance_chart_codes(code,name,sort_order,source_row,source_kind,source_reference,classification,updated_by)VALUES('1001','匿名原科目名',1,1,'MANUAL','匿名原目录来源','ASSET',?)",A);
        currencies=mock(com.uten.imp.application.port.FinancialChartCurrencyReadPort.class);chart=service();login(A,WRITE);
    }
    @AfterEach void logout(){SecurityContextHolder.clearContext();}

    @Test void actualForwardGuardPreservesHistoricalBytesAndRejectsReceiptMutation(){
        assertThat(oldBytes()).isEqualTo(historical);
        assertThatThrownBy(()->db.update("UPDATE finance_chart_manual_operations SET result='{}' WHERE request_id=?",OLD)).hasMessageContaining("immutable");
        assertThatThrownBy(()->db.update("DELETE FROM finance_chart_manual_operations WHERE request_id=?",OLD)).hasMessageContaining("immutable");
        assertThat(db.queryForObject("SELECT count(*) FROM pg_trigger WHERE tgrelid='finance_chart_manual_operations'::regclass AND tgname='finance_chart_manual_operations_immutable' AND NOT tgisinternal",Integer.class)).isEqualTo(1);
    }

    @Test void oldSuccessfulMetadataResultIsVerifiedWithoutChangingItsBytesOrTheLaterName(){
        UUID id=UUID.randomUUID();var original=request(id,0,"匿名最初修改名称");var saved=tx(()->chart.updateAccount("1001",original));String bytes=receiptBytes(id);
        login(B,WRITE);tx(()->chart.updateAccount("1001",request(UUID.randomUUID(),1,"匿名另一人后来名称")));
        login(A,READ);var verified=tx(()->chart.cancelMetadata("1001",id,cancel(id,original)));
        assertThat(verified).containsEntry("outcome","SUCCEEDED");same(verified.get("result"),saved);same(verified.get("requestBody"),original);
        assertThat(receiptBytes(id)).isEqualTo(bytes);assertThat(chart.metadata("1001")).containsEntry("name","匿名另一人后来名称");
        login(A,WRITE);assertThat(tx(()->chart.updateAccount("1001",original))).isEqualTo(saved);
        assertThat(((Number)chart.metadata("1001").get("version")).longValue()).isEqualTo(2);
    }

    @Test void cancelledUnwrittenNameSurvivesServiceReconstructionAndLateWriteDoesNotChangeMetadata(){
        UUID id=UUID.randomUUID();var original=request(id,0,"匿名原输入继续保留");login(A,READ);
        var stopped=tx(()->chart.cancelMetadata("1001",id,cancel(id,original)));
        assertThat(stopped).containsEntry("outcome","CANCELLED_UNWRITTEN");same(stopped,service().metadataReceipt("1001",id));
        assertThat(((Map<?,?>)stopped.get("result")).get("cancelled")).isEqualTo(true);
        same(stopped,tx(()->service().cancelMetadata("1001",id,cancel(id,original))));
        login(A,WRITE);assertThat(tx(()->chart.updateAccount("1001",original)).status()).isEqualTo("CANCELLED_UNWRITTEN");
        assertThat(chart.metadata("1001")).containsEntry("name","匿名原科目名");assertThat(((Number)chart.metadata("1001").get("version")).longValue()).isZero();
        assertThat(db.queryForObject("SELECT count(*) FROM finance_chart_manual_operations WHERE request_id=?",Integer.class,id)).isEqualTo(1);
    }

    @Test void wrongActorBodyPathAndLostReadAuthorityCannotAcknowledgeOrCancelAnotherIntent(){
        UUID id=UUID.randomUUID();var original=request(id,0,"匿名同一原请求名称");login(A,READ);tx(()->chart.cancelMetadata("1001",id,cancel(id,original)));
        assertThatThrownBy(()->tx(()->chart.cancelMetadata("1001",id,cancel(id,request(id,0,"匿名不同正文名称"))))).isInstanceOf(ApiException.class).hasMessageContaining("同一修改请求");
        assertThatThrownBy(()->tx(()->chart.cancelMetadata("1002",id,cancel(id,original)))).isInstanceOf(ApiException.class);
        login(B,READ);assertThat(chart.metadataReceipt("1001",id)).containsEntry("found",false);
        assertThatThrownBy(()->tx(()->chart.cancelMetadata("1001",id,cancel(id,original)))).isInstanceOf(ApiException.class).hasMessageContaining("本人原请求");
        login(A,Set.of());assertThatThrownBy(()->chart.metadataReceipt("1001",id)).isInstanceOf(ApiException.class);
        assertThatThrownBy(()->tx(()->chart.cancelMetadata("1001",id,cancel(id,original)))).isInstanceOf(ApiException.class);
        login(A,READ);assertThatThrownBy(()->tx(()->chart.updateAccount("1001",original))).isInstanceOf(ApiException.class).hasMessageContaining("payment_style:edit");
    }

    @Test void cancellationAndMetadataCommitSerializeInBothOrders()throws Exception{
        for(boolean cancelFirst:List.of(true,false)){
            long version=((Number)chart.metadata("1001").get("version")).longValue();UUID id=UUID.randomUUID();var original=request(id,version,"匿名并发名称"+cancelFirst);
            var entered=new CountDownLatch(1);var release=new CountDownLatch(1);ExecutorService pool=Executors.newFixedThreadPool(2);
            try{
                var first=pool.submit(()->{login(A,cancelFirst?READ:WRITE);try{return transactions.execute(status->{Object result=cancelFirst?chart.cancelMetadata("1001",id,cancel(id,original)):chart.updateAccount("1001",original);entered.countDown();await(release);return result;});}finally{SecurityContextHolder.clearContext();}});
                assertThat(entered.await(20,TimeUnit.SECONDS)).isTrue();
                var second=pool.submit(()->{login(A,cancelFirst?WRITE:READ);try{return tx(()->cancelFirst?chart.updateAccount("1001",original):chart.cancelMetadata("1001",id,cancel(id,original)));}finally{SecurityContextHolder.clearContext();}});
                org.awaitility.Awaitility.await().atMost(java.time.Duration.ofSeconds(10)).until(()->db.queryForObject("SELECT count(*) FROM pg_locks WHERE locktype='advisory' AND NOT granted",Long.class)>0);
                release.countDown();Object one=first.get(30,TimeUnit.SECONDS),two=second.get(30,TimeUnit.SECONDS);
                if(cancelFirst){assertThat(((UpdateAccountResult)two).status()).isEqualTo("CANCELLED_UNWRITTEN");assertThat(((Map<?,?>)((Map<?,?>)one).get("result")).get("requestId")).isEqualTo(id.toString());}
                else{assertThat(((Map<?,?>)two).get("outcome")).isEqualTo("SUCCEEDED");same(((Map<?,?>)two).get("result"),one);}
            }finally{release.countDown();pool.shutdownNow();}
            login(A,WRITE);assertThat(((Number)chart.metadata("1001").get("version")).longValue()).isEqualTo(version+(cancelFirst?0:1));
        }
    }

    @Test void rolledBackCancellationDoesNotSealTheIdAndSingleMetadataReadAvoidsTheLargeDirectory(){
        UUID id=UUID.randomUUID();var original=request(id,0,"匿名取消事务回滚名称");
        transactions.executeWithoutResult(status->{chart.cancelMetadata("1001",id,cancel(id,original));status.setRollbackOnly();});
        assertThat(db.queryForObject("SELECT count(*) FROM finance_chart_manual_operations WHERE request_id=?",Integer.class,id)).isZero();
        tx(()->chart.updateAccount("1001",original));
        db.update("INSERT INTO finance_chart_codes(code,name,sort_order,source_row,source_kind,source_reference,classification,updated_by) SELECT '8'||n,'匿名大目录项目',n,1,'MANUAL','匿名大目录来源','ASSET',? FROM generate_series(1,10003)n",A);
        assertThat(chart.metadata("1001")).containsEntry("code","1001").containsEntry("name",original.name());
        assertThat(db.queryForObject("SELECT count(*) FROM finance_chart_codes",Integer.class)).isEqualTo(10004);verifyNoInteractions(currencies);
    }

    private FinanceChartService service(){
        var variables=mock(TxSessionVars.class);doAnswer(call->{db.queryForObject("SELECT set_config('app.actor_id',?,true)",String.class,current.requireId().toString());return null;}).when(variables).bind();
        var value=new FinanceChartService(db,null,JSON,null,current,FinanceReportTestAccess.company(),null,variables,null,currencies);
        ReflectionTestUtils.setField(value,"operations",new FinanceOperationJournal(db,JSON,current));return value;
    }
    private static UpdateAccount request(UUID id,long version,String name){return new UpdateAccount(id,version,name,"匿名原名称修改核对依据");}
    private static FinanceOperationJournal.Cancellation cancel(UUID id,UpdateAccount body){return new FinanceOperationJournal.Cancellation(id,A,"CHART_METADATA_UPDATE","PUT","/finance/chart/1001/metadata",JSON.valueToTree(body));}
    private static void login(UUID actor,Set<String> permissions){var user=new AuthUser(actor,actor,"anonymous-chart-operator",permissions,false,true,false);SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(user,"",user.getAuthorities()));}
    private static <T>T tx(Supplier<T> work){return transactions.execute(status->work.get());}
    private static void same(Object actual,Object expected){try{assertThat(JSON.readTree(JSON.writeValueAsBytes(actual))).isEqualTo(JSON.readTree(JSON.writeValueAsBytes(expected)));}catch(Exception error){throw new AssertionError(error);}}
    private static void await(CountDownLatch gate){try{if(!gate.await(20,TimeUnit.SECONDS))throw new AssertionError("commit gate timeout");}catch(InterruptedException error){Thread.currentThread().interrupt();throw new IllegalStateException(error);}}
    private static String receiptBytes(UUID id){return db.queryForObject("SELECT to_jsonb(receipt)::text FROM finance_chart_manual_operations receipt WHERE request_id=?",String.class,id);}
    private static String oldBytes(){return receiptBytes(OLD);}
    private static void seedOld(){db.update("INSERT INTO finance_chart_manual_operations(request_id,actor_id,fingerprint,result,created_at)VALUES(?,?,repeat('0',64),?::jsonb,TIMESTAMPTZ '2026-01-01 00:00:00Z')",OLD,A,"{\"requestId\":\""+OLD+"\",\"code\":\"1009\",\"status\":\"CREATED\"}");}
    private static String resource(String name)throws Exception{try(var input=FinanceChartMetadataCancellationPostgresTest.class.getResourceAsStream("/db/migration/"+name)){return new String(Objects.requireNonNull(input,name).readAllBytes(),StandardCharsets.UTF_8);}}
    private static String tableDdl(String sql,String table){int start=sql.indexOf("CREATE TABLE "+table+" ("),end=sql.indexOf("\n);",start);if(start<0||end<0)throw new AssertionError("Original table missing: "+table);return sql.substring(start,end+3);}
    private static String statement(String sql,String prefix){int start=sql.indexOf(prefix),end=sql.indexOf(';',start);if(start<0||end<0)throw new AssertionError("Original statement missing: "+prefix);return sql.substring(start,end+1);}
}
