package com.uten.imp.features.finance;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.storage.ImmutableDocumentStore;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.finance.bank_transfer.FinanceBankTransferService;
import com.uten.imp.features.finance.expense.FinanceExpenseService;
import com.uten.imp.features.finance.expense.dto.FinanceExpenseDetail;
import com.uten.imp.features.finance.expense.dto.FinanceExpenseSaveRequest;
import com.uten.imp.features.finance.other_income.FinanceOtherIncomeService;
import com.uten.imp.features.finance.payment.FinancePaymentService;
import com.uten.imp.features.finance.receipt.FinanceReceiptService;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.validation.Validation;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.sql.Connection;
import java.time.Duration;
import java.time.Instant;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

import static org.assertj.core.api.Assertions.*;
import static org.awaitility.Awaitility.await;
import static org.mockito.Mockito.*;

/** Real migrated receipt table, locks, rollback and immutable guards. Domain services
 * are controlled accounting-work oracles; actual domain money authority stays in those services. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class FinanceBatchRecoveryPostgresTest {
    private static final PostgreSQLContainer PG=new PostgreSQLContainer("postgres:16-alpine");
    private static final ObjectMapper JSON=new ObjectMapper().findAndRegisterModules();
    private static DriverManagerDataSource source;private static JdbcTemplate db;
    private static UUID actor,otherActor;private static String legacyKey,legacyBefore;
    private static FinanceBatchEntryController.Request legacyCommand;
    private static final ThreadLocal<String> activeKey=new ThreadLocal<>();
    private TransactionTemplate tx;private FinanceBatchEntryService service;private FinanceExpenseService expenses;
    private CountDownLatch entered,release;

    @BeforeAll static void start()throws Exception {
        PG.start();source=new DriverManagerDataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword());db=new JdbcTemplate(source);
        migrate("1079");actor=user("batch-owner");otherActor=user("batch-other");
        legacyKey="legacy-"+UUID.randomUUID();legacyCommand=command(legacyKey,"legacy");
        String hash=ImmutableDocumentStore.digest(("expenses:"+FinanceBatchEntryService.canonical(JSON.valueToTree(legacyCommand.documents()))).getBytes(StandardCharsets.UTF_8));
        String result="{\"items\":[{\"id\":\""+UUID.randomUUID()+"\",\"status\":0,\"items\":[],\"amountLocal\":\"1.000000000000000000000001\"}]}";
        db.update("INSERT INTO finance_batch_entry_commands(actor_id,idempotency_key,document_type,request_hash,result)VALUES(?,?,'expenses',?,?::jsonb)",actor,legacyKey,hash,result);
        legacyBefore=db.queryForObject("SELECT to_jsonb(c)::text FROM finance_batch_entry_commands c WHERE actor_id=? AND idempotency_key=?",String.class,actor,legacyKey);
        migrate("1080");
        db.execute("CREATE TABLE batch_recovery_documents(id uuid PRIMARY KEY,command_key text NOT NULL,body jsonb NOT NULL)");
        db.execute("CREATE TABLE batch_recovery_gate(id integer PRIMARY KEY,enabled boolean NOT NULL);INSERT INTO batch_recovery_gate VALUES(1,true)");
    }
    @AfterAll static void stop(){PG.stop();}
    @BeforeEach void setup() {
        auth(actor,true,true);tx=new TransactionTemplate(new DataSourceTransactionManager(source));
        db.update("UPDATE batch_recovery_gate SET enabled=true WHERE id=1");entered=null;release=null;
        var current=mock(SecurityContextCurrentUser.class);
        when(current.requireId()).thenAnswer(call->(UUID)SecurityContextHolder.getContext().getAuthentication().getPrincipal());
        var principal=mock(AuthUser.class);when(principal.getLoginAccount()).thenReturn("anonymous-batch-recovery");when(principal.isAccountNonLocked()).thenReturn(true);when(current.get()).thenReturn(Optional.of(principal));
        expenses=mock(FinanceExpenseService.class);
        when(expenses.create(any())).thenAnswer(call->{
            if(entered!=null){entered.countDown();if(!release.await(20,TimeUnit.SECONDS))throw new IllegalStateException("work release timeout");}
            if(!Boolean.TRUE.equals(db.queryForObject("SELECT enabled FROM batch_recovery_gate WHERE id=1",Boolean.class)))
                throw new ApiException(ErrorCode.VALIDATION_FAILED,"mutable-account-refused");
            var request=(FinanceExpenseSaveRequest)call.getArgument(0);UUID id=UUID.randomUUID();
            db.update("INSERT INTO batch_recovery_documents VALUES(?,?,?::jsonb)",id,activeKey.get(),JSON.writeValueAsString(request));
            if("reject".equals(request.getRemark()))throw new ApiException(ErrorCode.VALIDATION_FAILED,"later-group-refused");
            BigDecimal total=request.getItems().stream().map(line->line.getQty()==null?BigDecimal.ZERO:line.getQty().multiply(line.getPrice())).reduce(BigDecimal.ZERO,BigDecimal::add);
            return new FinanceExpenseDetail(id,null,"ANON-"+id,request.getBillDate(),request.getAccountId(),null,request.getCurrencyId(),request.getExchangeRate(),
                    total,total,null,null,null,null,null,request.getRemark(),(short)0,false,(short)0,List.of(),"anonymous",Instant.now());
        });
        service=new FinanceBatchEntryService(new NamedParameterJdbcTemplate(source),JSON,Validation.buildDefaultValidatorFactory().getValidator(),current,
                mock(AuditService.class),mock(FinanceReceiptService.class),mock(FinancePaymentService.class),expenses,mock(FinanceOtherIncomeService.class),mock(FinanceBankTransferService.class));
    }
    @AfterEach void logout(){SecurityContextHolder.clearContext();activeKey.remove();if(release!=null)release.countDown();}

    @Test void upgradeAndLegacySuccessVerificationNeverRewriteTheOriginalReceipt() {
        assertThat(db.queryForObject("SELECT (to_jsonb(c)-ARRAY['outcome','original_body'])::text FROM finance_batch_entry_commands c WHERE actor_id=? AND idempotency_key=?",String.class,actor,legacyKey)).isEqualTo(legacyBefore);
        var read=service.receipt("expenses",legacyKey);assertThat(read).containsEntry("outcome","SUCCEEDED").containsEntry("requestBodyAvailable",false).containsEntry("requestBody",null);
        var resolved=cancel("expenses",legacyCommand);assertThat(resolved).containsEntry("outcome","SUCCEEDED").containsEntry("requestBodyAvailable",true);
        assertThat((JsonNode)resolved.get("requestBody")).isEqualTo(JSON.valueToTree(legacyCommand));
        assertThat(create(legacyCommand)).isEqualTo(resolved.get("result"));verifyNoInteractions(expenses);
        assertThat(db.queryForObject("SELECT (to_jsonb(c)-ARRAY['outcome','original_body'])::text FROM finance_batch_entry_commands c WHERE actor_id=? AND idempotency_key=?",String.class,actor,legacyKey)).isEqualTo(legacyBefore);
    }

    @Test void missingGetIsUnknownAndCancellationSurvivesLostReplyWhileEveryLateOriginalIsBlocked()throws Exception {
        var command=command(key(),"original");assertThat(service.receipt("expenses",command.idempotencyKey())).containsEntry("found",false);
        cancel("expenses",command); // Simulate the cancellation response being lost.
        var receipt=service.receipt("expenses",command.idempotencyKey());assertThat(receipt).containsEntry("outcome","CANCELLED_UNWRITTEN");
        assertThat(receipt.get("result")).isEqualTo(JSON.readTree("{\"cancelled\":true}"));
        assertThat(cancel("expenses",command)).isEqualTo(receipt);
        assertThatThrownBy(()->create(command)).isInstanceOf(FinanceBatchEntryService.CancelledBatch.class)
                .satisfies(error->assertThat(((FinanceBatchEntryService.CancelledBatch)error).details()).containsEntry("requestId",command.idempotencyKey()).containsEntry("outcome","CANCELLED_UNWRITTEN"));
        assertThat(documents(command.idempotencyKey())).isZero();verifyNoInteractions(expenses);
        assertImmutable(command.idempotencyKey());assertImmutable(legacyKey);
    }

    @Test void mutableRejectionThenAbaAndDelayedOriginalCannotCrossTheCommittedCancellationFence()throws Exception {
        var command=command(key(),"mutable");db.update("UPDATE batch_recovery_gate SET enabled=false WHERE id=1");
        var queued=new CountDownLatch(1);var deliver=new CountDownLatch(1);
        try(var workers=Executors.newSingleThreadExecutor()) {
            var original=workers.submit(()->{auth(actor,true,true);queued.countDown();if(!deliver.await(20,TimeUnit.SECONDS))throw new IllegalStateException();return create(command);});
            assertThat(queued.await(5,TimeUnit.SECONDS)).isTrue();
            assertThatThrownBy(()->create(command)).isInstanceOf(ApiException.class).hasMessageContaining("mutable-account-refused");
            assertThat(service.receipt("expenses",command.idempotencyKey())).containsEntry("found",false);
            cancel("expenses",command);db.update("UPDATE batch_recovery_gate SET enabled=true WHERE id=1");deliver.countDown();
            assertThatThrownBy(()->original.get(20,TimeUnit.SECONDS)).hasCauseInstanceOf(FinanceBatchEntryService.CancelledBatch.class);
        } finally{deliver.countDown();}
        assertThat(documents(command.idempotencyKey())).isZero();assertThat(service.receipt("expenses",command.idempotencyKey())).containsEntry("outcome","CANCELLED_UNWRITTEN");
    }

    @Test void creationHoldingTheOriginalLockWinsAndCancellationReturnsThoseExactDocuments()throws Exception {
        var command=command(key(),"create-first");entered=new CountDownLatch(1);release=new CountDownLatch(1);
        try(var workers=Executors.newFixedThreadPool(2)) {
            var creation=workers.submit(()->{auth(actor,true,true);return create(command);});assertThat(entered.await(5,TimeUnit.SECONDS)).isTrue();
            var cancellation=workers.submit(()->{auth(actor,false,true);return tx.execute(status->{db.queryForObject("SELECT set_config('application_name','batch-recovery-cancel-wait',true)",String.class);return service.cancelUnwritten("expenses",command.idempotencyKey(),cancellation(command));});});
            await().atMost(Duration.ofSeconds(5)).untilAsserted(()->assertThat(db.queryForObject("SELECT count(*) FROM pg_stat_activity WHERE application_name='batch-recovery-cancel-wait' AND wait_event='advisory'",Integer.class)).isOne());
            release.countDown();var made=creation.get(20,TimeUnit.SECONDS);var resolved=cancellation.get(20,TimeUnit.SECONDS);
            assertThat(resolved).containsEntry("outcome","SUCCEEDED");assertThat(resolved.get("result")).isEqualTo(made);
            assertThat(create(command)).isEqualTo(made);assertThat(documents(command.idempotencyKey())).isOne();
        } finally{release.countDown();}
    }

    @Test void cancellationHoldingTheOriginalLockWinsOverAnAlreadyWaitingCreate()throws Exception {
        var command=command(key(),"cancel-first");String suffix=UUID.randomUUID().toString().replace("-","");
        String trigger="zz_batch_cancel_barrier_"+suffix,function="fn_batch_cancel_barrier_"+suffix,barrier="BATCH_CANCEL_TEST:"+suffix;
        com.uten.imp.support.PostgresFixtureDdl.execute(db,"CREATE FUNCTION %I() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN PERFORM pg_advisory_xact_lock(hashtextextended(%L,0));RETURN NEW;END $$",function,barrier);
        com.uten.imp.support.PostgresFixtureDdl.execute(db,"CREATE TRIGGER %I BEFORE INSERT ON finance_batch_entry_commands FOR EACH ROW WHEN(NEW.idempotency_key=%L AND NEW.outcome='CANCELLED_UNWRITTEN') EXECUTE FUNCTION %I()",trigger,command.idempotencyKey(),function);
        try(Connection hold=source.getConnection();var statement=hold.prepareStatement("SELECT pg_advisory_xact_lock(hashtextextended(?,0))")) {
            hold.setAutoCommit(false);statement.setString(1,barrier);try(var row=statement.executeQuery()){assertThat(row.next()).isTrue();}
            try(var workers=Executors.newFixedThreadPool(2)) {
              try {
            var cancelled=workers.submit(()->{auth(actor,false,true);return tx.execute(status->{db.queryForObject("SELECT set_config('application_name','batch-recovery-cancel-barrier',true)",String.class);return service.cancelUnwritten("expenses",command.idempotencyKey(),cancellation(command));});});
            await().atMost(Duration.ofSeconds(5)).untilAsserted(()->assertThat(db.queryForObject("SELECT count(*) FROM pg_stat_activity WHERE application_name='batch-recovery-cancel-barrier' AND wait_event='advisory'",Integer.class)).isOne());
            var late=workers.submit(()->{auth(actor,true,true);return tx.execute(status->{db.queryForObject("SELECT set_config('application_name','batch-recovery-create-wait',true)",String.class);activeKey.set(command.idempotencyKey());try{return service.create("expenses",command);}finally{activeKey.remove();}});});
            await().atMost(Duration.ofSeconds(5)).untilAsserted(()->assertThat(db.queryForObject("SELECT count(*) FROM pg_stat_activity WHERE application_name='batch-recovery-create-wait' AND wait_event='advisory'",Integer.class)).isOne());
            hold.commit();assertThat(cancelled.get(20,TimeUnit.SECONDS)).containsEntry("outcome","CANCELLED_UNWRITTEN");
            assertThatThrownBy(()->late.get(20,TimeUnit.SECONDS)).hasCauseInstanceOf(FinanceBatchEntryService.CancelledBatch.class);
              } finally {hold.rollback();}
            }
        } finally{com.uten.imp.support.PostgresFixtureDdl.execute(db,"DROP TRIGGER %I ON finance_batch_entry_commands",trigger);com.uten.imp.support.PostgresFixtureDdl.execute(db,"DROP FUNCTION %I()",function);}
        assertThat(documents(command.idempotencyKey())).isZero();verifyNoInteractions(expenses);
    }

    @Test void aLaterGroupFailureRollsBackAllDocumentsAndLeavesNoFalseSuccess()throws Exception {
        String key=key();var first=entry("ok",UUID.randomUUID(),UUID.randomUUID(),"1.000000000000000000000001");
        var second=entry("reject",UUID.randomUUID(),UUID.randomUUID(),"2.000000000000000000000001");var command=new FinanceBatchEntryController.Request(key,List.of(first,second));
        assertThatThrownBy(()->create(command)).isInstanceOf(ApiException.class).hasMessageContaining("第 2 组");
        assertThat(documents(key)).isZero();assertThat(service.receipt("expenses",key)).containsEntry("found",false);
        assertThat(cancel("expenses",command)).containsEntry("outcome","CANCELLED_UNWRITTEN");
    }

    @Test void exactFortyPlusTwentyFourValuesAndMixedCurrenciesKeepTheirOriginalGroupsAndBody()throws Exception {
        UUID account=UUID.randomUUID(),currency=UUID.randomUUID(),foreign=UUID.randomUUID();String key=key();
        String large="1234567890123456789012345678901234567890.123456789012345678901234",second="2.000000000000000000000001",tiny="0.000000000000000000000001";
        var command=new FinanceBatchEntryController.Request(key,List.of(entry("exact",account,currency,large),entry("exact",account,currency,second),entry("exact",account,foreign,tiny)));
        var result=create(command);assertThat(result.path("items")).hasSize(2);assertThat(documents(key)).isEqualTo(2);
        assertThat((JsonNode)service.receipt("expenses",key).get("requestBody")).isEqualTo(JSON.valueToTree(command));
        var arguments=org.mockito.ArgumentCaptor.forClass(FinanceExpenseSaveRequest.class);verify(expenses,times(2)).create(arguments.capture());
        assertThat(arguments.getAllValues().getFirst().getItems()).hasSize(2);
        assertThat(arguments.getAllValues().getFirst().getItems().getFirst().getPrice()).isEqualByComparingTo(large);
        assertThat(arguments.getAllValues().getLast().getCurrencyId()).isEqualTo(foreign);
        assertThat(arguments.getAllValues().getLast().getItems().getFirst().getPrice()).isEqualByComparingTo(tiny);
        assertThat(cancel("expenses",command)).containsEntry("outcome","SUCCEEDED").containsEntry("result",result);
    }

    @Test void originalOwnerWithReadButNoCreateCanResolveWhileMissingReadAndWrongBodyNeverSeal()throws Exception {
        var command=command(key(),"permissions");auth(actor,false,true);assertThat(cancel("expenses",command)).containsEntry("outcome","CANCELLED_UNWRITTEN");
        auth(actor,true,false);assertThatThrownBy(()->service.receipt("expenses",command.idempotencyKey())).isInstanceOfSatisfying(ApiException.class,error->assertThat(error.getCode()).isEqualTo(ErrorCode.FORBIDDEN));
        assertThatThrownBy(()->cancel("expenses",command)).isInstanceOf(ApiException.class);
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(actor,"test",List.of(new SimpleGrantedAuthority("finance_expense:view"))));
        assertThat(service.receipt("expenses",command.idempotencyKey())).containsEntry("found",true);
        assertThatThrownBy(()->service.receipt("payments",command.idempotencyKey())).isInstanceOfSatisfying(ApiException.class,error->assertThat(error.getCode()).isEqualTo(ErrorCode.FORBIDDEN));
        auth(otherActor,false,true);assertThat(service.receipt("expenses",command.idempotencyKey())).containsEntry("found",false);
        assertThatThrownBy(()->tx.execute(status->service.cancelUnwritten("expenses",command.idempotencyKey(),new FinanceBatchEntryController.Cancellation(actor,JSON.valueToTree(command))))).isInstanceOf(ApiException.class);
        auth(actor,false,true);var changed=command(command.idempotencyKey(),"changed");assertThatThrownBy(()->cancel("expenses",changed)).isInstanceOf(ApiException.class).hasMessageContaining("不同内容");
        assertThat(service.receipt("expenses",command.idempotencyKey())).containsEntry("requestBody",JSON.valueToTree(command));
    }

    @Test void allFiveFamiliesUseTheirOwnReadAuthorityAndTheSameNonReplayableOriginalKey()throws Exception {
        for(String family:List.of("receipts","payments","expenses","incomes","bank-transfers")) {
            var command=command(key(),"family");var result=cancel(family,command);assertThat(result).containsEntry("path","/finance/"+family+"/batch").containsEntry("outcome","CANCELLED_UNWRITTEN");
            assertThatThrownBy(()->tx.execute(status->service.create(family,command))).isInstanceOf(FinanceBatchEntryService.CancelledBatch.class);
        }
        verifyNoInteractions(expenses);
    }

    private JsonNode create(FinanceBatchEntryController.Request command){return tx.execute(status->{activeKey.set(command.idempotencyKey());try{return service.create("expenses",command);}finally{activeKey.remove();}});}
    private Map<String,Object> cancel(String family,FinanceBatchEntryController.Request command){return tx.execute(status->service.cancelUnwritten(family,command.idempotencyKey(),cancellation(command)));}
    private static FinanceBatchEntryController.Cancellation cancellation(FinanceBatchEntryController.Request command){return new FinanceBatchEntryController.Cancellation(actor,JSON.valueToTree(command));}
    private static FinanceBatchEntryController.Request command(String key,String remark)throws Exception{return new FinanceBatchEntryController.Request(key,List.of(entry(remark,UUID.randomUUID(),UUID.randomUUID(),"1.000000000000000000000001")));}
    private static JsonNode entry(String remark,UUID account,UUID currency,String price)throws Exception {
        return JSON.readTree("{\"billDate\":\"2026-11-05\",\"accountId\":\""+account+"\",\"currencyId\":\""+currency+"\",\"exchangeRate\":\"1\",\"remark\":\""+remark+"\",\"items\":[{\"expenseStyleId\":\"00000000-0000-0000-0000-000000000001\",\"qty\":\"1\",\"price\":\""+price+"\"}]}");
    }
    private static String key(){return "recovery-"+UUID.randomUUID();}
    private static int documents(String key){return db.queryForObject("SELECT count(*) FROM batch_recovery_documents WHERE command_key=?",Integer.class,key);}
    private static void auth(UUID person,boolean write,boolean read) {
        var authorities=new java.util.ArrayList<SimpleGrantedAuthority>();
        for(String permission:List.of("finance_receipt","finance_payment","finance_expense","finance_other_income","finance_bank_transfer")) {
            if(read){
                authorities.add(new SimpleGrantedAuthority(permission+":view"));
            }
            if(write){
                authorities.add(new SimpleGrantedAuthority(permission+":create"));
            }

        }
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(person,"test",authorities));
    }
    private static void assertImmutable(String key) {
        assertThatThrownBy(()->db.update("UPDATE finance_batch_entry_commands SET result='{}'::jsonb WHERE actor_id=? AND idempotency_key=?",actor,key)).isInstanceOf(org.springframework.dao.DataIntegrityViolationException.class);
        assertThatThrownBy(()->db.update("DELETE FROM finance_batch_entry_commands WHERE actor_id=? AND idempotency_key=?",actor,key)).isInstanceOf(org.springframework.dao.DataIntegrityViolationException.class);
    }
    private static UUID user(String label) {
        UUID employee=UUID.randomUUID(),id=UUID.randomUUID();
        db.update("INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type) VALUES(?,?,?,'其他',(SELECT id FROM departments WHERE code='DEPT_FIN'),CURRENT_DATE,'active','regular')",employee,label+employee,label+employee);
        db.update("INSERT INTO users(id,employee_id,login_account,password_hash,status,must_change_password,is_super_admin)VALUES(?,?,?,'test-only','active',false,false)",id,employee,label+id);return id;
    }
    private static void migrate(String target){com.uten.imp.testsupport.TestFlyway.configure().dataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword()).locations("classpath:db/migration").target(target).load().migrate();}
}
