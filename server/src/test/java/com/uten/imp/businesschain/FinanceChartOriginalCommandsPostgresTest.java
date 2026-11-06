package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.uten.imp.common.storage.ImmutableDocumentStore;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.finance.FinanceOperationJournal;
import com.uten.imp.features.finance.gl.FinanceChartContracts.*;
import com.uten.imp.features.finance.gl.FinanceChartService;
import com.uten.imp.security.AuthUser;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;
import java.time.Duration;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.function.Supplier;
import static org.assertj.core.api.Assertions.*;

/** Real hierarchy/chart/binding transactions, immutable original receipts and late-write fencing. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false","uten.features.goods-owner-scope-enabled=false",
        "uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
@FinanceScopedChain
@TestInstance(TestInstance.Lifecycle.PER_CLASS)
class FinanceChartOriginalCommandsPostgresTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry r){FinanceScopedChainDatabase.register(r,FinanceChartOriginalCommandsPostgresTest.class);}
    private static final String CREATE="CHART_ACCOUNT_CREATE",MAP="CHART_MAPPING_REPLACE",TARGET="CHART_TARGET_CREATE";
    private static final Set<String> READ=Set.of("finance_report:view","finance:view:all");
    private static final Set<String> WRITE=Set.of("finance_report:view","finance:view:all","payment_style:edit","payment_style:create");
    private static final AtomicInteger CODES=new AtomicInteger(991000);
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired FinanceChartService chart;
    @Autowired ObjectMapper json;
    @Autowired JdbcTemplate db;
    @Autowired PlatformTransactionManager manager;
    @Autowired com.uten.imp.features.master.currency.CurrencyService currencies;
    private FullChainEndToEndTest.World a,b;
    @BeforeAll void owners(){var seed=new FullChainEndToEndTest();beans.autowireBean(seed);a=seed.seedWorld("chart-original-a");b=seed.seedWorld("chart-original-b");}
    @BeforeEach void login(){login(a,WRITE);}
    @AfterEach void logout(){SecurityContextHolder.clearContext();}

    @Test void threeSuccessfulOriginalsReplayTheirOwnCompactProofAfterLaterChangesAndLostResponse()throws Exception {
        String code=code();var create=account(UUID.randomUUID(),code);
        var created=chart.createAccountCommand(create); // A committed response may be lost before the caller persists it.
        assertThat(chart.operationReceipt(id(create))).isEqualTo(created);
        assertThat(chart.createAccountCommand(create)).isEqualTo(created);
        assertThat(created).containsEntry("proofScope","RAW_BODY");
        assertThat(((Map<?,?>)created.get("result")).get("status")).isEqualTo("CREATED");
        var target=target(UUID.randomUUID(),chart.account(code).version());
        var targeted=chart.createTargetCommand(code,target);
        var saved=chart.account(code);assertThat(saved.lineKeys()).containsExactlyInAnyOrder("BS_51","PL_PRIOR_ADJUSTMENT");
        var map=mapping(UUID.randomUUID(),saved,"BS_51","PL_PRIOR_ADJUSTMENT");var mapped=chart.mapCommand(code,map);
        chart.updateAccount(code,new UpdateAccount(UUID.randomUUID(),chart.account(code).version(),"匿名后续改名","独立后续原依据"));
        login(a,READ);
        for(var receipt:List.of(created,targeted,mapped)) {
            UUID request=UUID.fromString(receipt.get("requestId").toString());String before=receiptBytes(request);
            assertThat(chart.operationReceipt(request)).isEqualTo(receipt);
            assertThat(chart.cancelOperation(request,cancel(receipt.get("operation").toString(),code,json.valueToTree(receipt.get("requestBody"))))).isEqualTo(receipt);
            assertThat(receiptBytes(request)).isEqualTo(before);
            assertThat(json.writeValueAsString(receipt)).hasSizeLessThan(4000).doesNotContain("\"items\"");
            assertThat(chart.metadataReceipt(code,request)).containsEntry("found",false);
        }
        login(a,WRITE);
        assertThat(chart.createTargetCommand(code,target)).isEqualTo(targeted);assertThat(chart.mapCommand(code,map)).isEqualTo(mapped);
        var metadata=new UpdateAccount(UUID.randomUUID(),chart.account(code).version(),"匿名元数据原回执","独立修改依据");chart.updateAccount(code,metadata);
        assertThat(chart.operationReceipt(metadata.requestId())).containsEntry("found",false);
        assertThat(chart.account(code).name()).isEqualTo(metadata.name());
    }

    @Test void newRawBodiesDistinguishMissingNullTypesAndClassificationAndCurrency() {
        var body=account(UUID.randomUUID(),code());var receipt=chart.createAccountCommand(body);
        var omitted=body.deepCopy();omitted.remove("currencyId");
        assertThatThrownBy(()->chart.createAccountCommand(omitted)).isInstanceOf(ApiException.class);
        for(String field:List.of("classification","currencyId")) {
            var changed=body.deepCopy();changed.put(field,field.equals("classification")?"LIABILITY":b.currencyId().toString());
            assertThatThrownBy(()->chart.cancelOperation(id(body),cancel(CREATE,null,changed))).isInstanceOf(ApiException.class);
        }
        var wrongType=account(UUID.randomUUID(),code());wrongType.put("name",42);
        assertThatThrownBy(()->chart.createAccountCommand(wrongType)).isInstanceOf(ApiException.class);
        var unknown=account(UUID.randomUUID(),code());unknown.put("unpublishedField","x");
        assertThatThrownBy(()->chart.createAccountCommand(unknown)).isInstanceOf(ApiException.class);
        var reordered=json.createObjectNode();body.properties().stream().sorted(Map.Entry.<String,JsonNode>comparingByKey().reversed()).forEach(e->reordered.set(e.getKey(),e.getValue()));
        assertThat(chart.createAccountCommand(reordered)).isEqualTo(receipt);
    }

    @Test void historicalSixFieldAndEightFieldCreatesUseTheOriginalTypedHashWithoutRewritingBytes()throws Exception {
        for(boolean six:List.of(true,false)) {
            String code=code();UUID request=UUID.randomUUID();
            var typed=new CreateAccount(request,code,"匿名历史科目","","EQUITY","匿名历史创建依据",null,null);
            var persisted=(ObjectNode)json.valueToTree(typed);persisted.put("requestId",UUID.randomUUID().toString());chart.createAccountCommand(persisted);
            // This literal is the original published8-field writer order,
            // independent of the current record/marker implementation.
            String encoded="{\"requestId\":\""+request+"\",\"code\":\""+code+"\",\"name\":\"匿名历史科目\",\"currencyName\":\"\",\"category\":\"EQUITY\",\"sourceReference\":\"匿名历史创建依据\",\"classification\":null,\"currencyId\":null}";
            assertThat(json.writeValueAsString(typed)).isEqualTo(encoded);
            String oldResult="{\"requestId\":\""+request+"\",\"code\":\""+code+"\",\"status\":\"CREATED\"}";
            db.update("INSERT INTO finance_chart_manual_operations(request_id,actor_id,fingerprint,result)VALUES(?,?,?,?::jsonb)",request,a.superAdminUserId(),ImmutableDocumentStore.digest(encoded.getBytes(java.nio.charset.StandardCharsets.UTF_8)),oldResult);
            var original=(ObjectNode)json.valueToTree(typed);if(six){original.remove("classification");original.remove("currencyId");}
            String before=receiptBytes(request);var partial=chart.operationReceipt(request);
            assertThat(partial).containsEntry("requiresOriginalRequestProof",true).containsEntry("proofScope","LEGACY_TYPED_BODY").doesNotContainKey("requestBody");
            var confirmed=chart.cancelOperation(request,cancel(CREATE,null,original));
            assertThat(confirmed).containsEntry("outcome","SUCCEEDED").containsEntry("proofScope","LEGACY_TYPED_BODY");
            assertThat(chart.createAccountCommand(original)).isEqualTo(confirmed);
            for(String field:List.of("classification","currencyId","name")) {
                var changed=original.deepCopy();changed.put(field,field.equals("classification")?"ASSET":field.equals("currencyId")?a.currencyId().toString():"其他名称");
                assertThatThrownBy(()->chart.cancelOperation(request,cancel(CREATE,null,changed))).isInstanceOf(ApiException.class);
            }
            var missing=original.deepCopy();missing.remove("currencyName");
            assertThatThrownBy(()->chart.cancelOperation(request,cancel(CREATE,null,missing))).isInstanceOf(ApiException.class);
            var unknown=original.deepCopy();unknown.put("unpublishedField",true);
            assertThatThrownBy(()->chart.cancelOperation(request,cancel(CREATE,null,unknown))).isInstanceOf(ApiException.class);
            assertThat(receiptBytes(request)).isEqualTo(before);
        }
    }

    @Test void staleSameMappingFromAnotherRequestAndAbaNeverBecomeAnOriginalSuccess() {
        String code=code();chart.createAccountCommand(account(UUID.randomUUID(),code));chart.createTargetCommand(code,target(UUID.randomUUID(),chart.account(code).version()));
        var before=chart.account(code);var stale=mapping(UUID.randomUUID(),before,"BS_51","PL_PRIOR_ADJUSTMENT");
        chart.mapCommand(code,mapping(UUID.randomUUID(),before,"BS_51","PL_PRIOR_ADJUSTMENT"));
        assertThatThrownBy(()->chart.mapCommand(code,stale)).isInstanceOf(ApiException.class);assertThat(chart.operationReceipt(id(stale))).containsEntry("found",false);
        chart.mapCommand(code,mapping(UUID.randomUUID(),chart.account(code),null,null));
        chart.mapCommand(code,mapping(UUID.randomUUID(),chart.account(code),"BS_51","PL_PRIOR_ADJUSTMENT"));
        var stopped=chart.cancelOperation(id(stale),cancel(MAP,code,stale));assertThat(stopped).containsEntry("outcome","CANCELLED_UNWRITTEN");
        String current=rowBytes(code);assertThatThrownBy(()->chart.mapCommand(code,stale)).isInstanceOf(ApiException.class).hasMessageContaining("已停止");
        assertThat(rowBytes(code)).isEqualTo(current);assertThat(chart.operationReceipt(id(stale))).isEqualTo(stopped);
        var staleTarget=target(UUID.randomUUID(),before.version());staleTarget.putNull("balanceLineKey");staleTarget.putNull("profitLineKey");
        assertThatThrownBy(()->chart.createTargetCommand(code,staleTarget)).isInstanceOf(ApiException.class);
    }

    @Test void failedValidationThenMasterAbaStillRequiresAnOriginalStopBeforeSafeEditing() {
        var body=account(UUID.randomUUID(),code());body.put("currencyName","匿名明确外币属性");body.put("currencyId",b.currencyId().toString());
        assertThat(db.queryForObject("SELECT is_base_currency FROM currencies WHERE id=?",Boolean.class,b.currencyId())).isFalse();
        // The ordinary current master visibility predicate excludes deleted
        // currencies. No chart version, guard, original body or receipt is reset.
        db.update("UPDATE currencies SET is_deleted=true WHERE id=?",b.currencyId());
        assertThatThrownBy(()->chart.createAccountCommand(body)).isInstanceOfSatisfying(ApiException.class,error->assertThat(error.getCode()).isEqualTo(com.uten.imp.common.web.ErrorCode.VALIDATION_FAILED));
        assertThat(chart.operationReceipt(id(body))).containsEntry("found",false);
        for(boolean deleted:List.of(false,true,false))db.update("UPDATE currencies SET is_deleted=? WHERE id=?",deleted,b.currencyId());
        login(a,READ);var stopped=chart.cancelOperation(id(body),cancel(CREATE,null,body));assertThat(stopped).containsEntry("outcome","CANCELLED_UNWRITTEN");
        login(a,WRITE);assertThatThrownBy(()->chart.createAccountCommand(body)).isInstanceOf(ApiException.class).hasMessageContaining("已停止");
        assertThat(db.queryForObject("SELECT count(*) FROM finance_chart_codes WHERE code=?",Long.class,body.path("code").asText())).isZero();
        var replacement=body.deepCopy();replacement.put("requestId",UUID.randomUUID().toString());assertThat(chart.createAccountCommand(replacement)).containsEntry("outcome","SUCCEEDED");
    }

    @Test void historicalMetadataMayExplicitlyMapAnInactiveCurrencyWithoutActivatingItOrCreatingFunds() {
        UUID foreign=UUID.randomUUID(),other=UUID.randomUUID();
        for(UUID currency:List.of(foreign,other))db.update("INSERT INTO currencies(id,code,name,exchange_rate,status)VALUES(?,?,?,1,'使用')",currency,"FC-"+currency,"匿名外币");
        String code=code();var original=account(UUID.randomUUID(),code);original.put("category","EQUITY");original.put("currencyName","匿名外币");original.put("currencyId",foreign.toString());
        var receipt=chart.createAccountCommand(original);String receiptBefore=receiptBytes(id(original));
        var masterPermissions=new HashSet<>(WRITE);masterPermissions.add("currency:status");login(a,masterPermissions);
        currencies.changeStatus(foreign,new com.uten.imp.features.master.dto.MasterStatusChangeRequest("禁用",null));
        try {
            login(a,WRITE);assertThat(chart.operationReceipt(id(original))).isEqualTo(receipt);assertThat(chart.createAccountCommand(original)).isEqualTo(receipt);
            var saved=chart.account(code);assertThat(saved.currencyId()).isEqualTo(foreign);
            chart.mapCommand(code,mapping(UUID.randomUUID(),saved,"BS_51","PL_PRIOR_ADJUSTMENT"));
            chart.updateAccount(code,new UpdateAccount(UUID.randomUUID(),chart.account(code).version(),"匿名停用币别历史科目","只维护名称保原币别"));
            assertThat(chart.account(code).currencyId()).isEqualTo(foreign);
            int entries=db.queryForObject("SELECT count(*) FROM gl_entries",Integer.class),bankAccounts=db.queryForObject("SELECT count(*) FROM accounts",Integer.class);
            var historical=account(UUID.randomUUID(),code());historical.put("category","EQUITY");historical.put("currencyName","匿名外币");historical.put("currencyId",foreign.toString());
            var created=chart.createAccountCommand(historical);assertThat(created).containsEntry("outcome","SUCCEEDED");
            assertThat(chart.account(historical.path("code").asText()).currencyId()).isEqualTo(foreign);
            String differentCode=code();var different=account(UUID.randomUUID(),differentCode);different.put("category","EQUITY");different.put("currencyName","匿名外币");different.put("currencyId",other.toString());chart.createAccountCommand(different);
            var change=mapping(UUID.randomUUID(),chart.account(differentCode),"BS_51","PL_PRIOR_ADJUSTMENT");change.put("currencyId",foreign.toString());
            assertThat(chart.mapCommand(differentCode,change)).containsEntry("outcome","SUCCEEDED");assertThat(chart.account(differentCode).currencyId()).isEqualTo(foreign);
            assertThat(db.queryForObject("SELECT status FROM currencies WHERE id=?",String.class,foreign)).isEqualTo("禁用");
            assertThat(db.queryForObject("SELECT count(*) FROM gl_entries",Integer.class)).isEqualTo(entries);
            assertThat(db.queryForObject("SELECT count(*) FROM accounts",Integer.class)).isEqualTo(bankAccounts);
            assertThat(receiptBytes(id(original))).isEqualTo(receiptBefore);
        }finally{login(a,masterPermissions);currencies.changeStatus(foreign,new com.uten.imp.features.master.dto.MasterStatusChangeRequest("使用",null));}
    }

    @Test void versionsAreExplicitIntegralLongsAndLegacyBlankTargetDoesNotClearBindings() {
        String code=code();chart.createAccountCommand(account(UUID.randomUUID(),code));chart.createTargetCommand(code,target(UUID.randomUUID(),chart.account(code).version()));
        var saved=chart.account(code);chart.createTarget(code,new CreateTarget(saved.version(),"EQUITY","EQUITY",null));assertThat(chart.account(code)).isEqualTo(saved);
        for(String invalid:List.of("missing","null","text","huge","fraction")) {
            var body=mapping(UUID.randomUUID(),saved,"BS_51","PL_PRIOR_ADJUSTMENT");
            switch(invalid){case "missing"->body.remove("expectedVersion");case "null"->body.putNull("expectedVersion");case "text"->body.put("expectedVersion",saved.version()+"");case "huge"->body.put("expectedVersion",new java.math.BigInteger("9223372036854775808"));default->body.put("expectedVersion",new java.math.BigDecimal("0.5"));}
            assertThatThrownBy(()->chart.mapCommand(code,body)).isInstanceOf(ApiException.class);assertThat(chart.operationReceipt(id(body))).containsEntry("found",false);
        }
        var current=saved;for(int i=0;i<130;i++){chart.mapCommand(code,mapping(UUID.randomUUID(),current,"BS_51","PL_PRIOR_ADJUSTMENT"));current=chart.account(code);}
        assertThat(current.version()).isGreaterThan(128);chart.mapCommand(code,mapping(UUID.randomUUID(),current,"BS_51","PL_PRIOR_ADJUSTMENT"));
    }

    @ParameterizedTest @ValueSource(strings={CREATE,MAP,TARGET})
    void readOnlyOwnerCanStopAnUnwrittenOriginalAndLateWritingCanNeverReviveIt(String operation) {
        var intent=intent(operation);login(a,READ);
        assertThat(chart.operationReceipt(id(intent.body))).containsEntry("found",false);
        var stopped=chart.cancelOperation(id(intent.body),cancel(operation,intent.code,intent.body));String before=receiptBytes(id(intent.body));
        assertThat(stopped).containsEntry("outcome","CANCELLED_UNWRITTEN");assertThat(chart.cancelOperation(id(intent.body),cancel(operation,intent.code,intent.body))).isEqualTo(stopped);
        login(a,WRITE);assertThatThrownBy(()->dispatch(operation,intent.code,intent.body)).isInstanceOf(ApiException.class).hasMessageContaining("已停止");
        assertThat(receiptBytes(id(intent.body))).isEqualTo(before);
        login(b,READ);assertThat(chart.operationReceipt(id(intent.body))).containsEntry("found",false);
        assertThatThrownBy(()->chart.cancelOperation(id(intent.body),cancelAs(operation,intent.code,intent.body,b.superAdminUserId()))).isInstanceOf(ApiException.class);
        login(a,Set.of());assertThatThrownBy(()->chart.operationReceipt(id(intent.body))).isInstanceOf(ApiException.class);
        assertThatThrownBy(()->chart.cancelOperation(id(intent.body),cancel(operation,intent.code,intent.body))).isInstanceOf(ApiException.class);
        login(a,READ);assertThatThrownBy(()->dispatch(operation,intent.code,intent.body)).isInstanceOf(ApiException.class).hasMessageContaining("payment_style:edit");
    }

    @ParameterizedTest @ValueSource(strings={CREATE,MAP,TARGET})
    void sameOriginalWriteAndStopSerializeInBothOrders(String operation)throws Exception {
        for(boolean cancelFirst:List.of(true,false)) {
            var intent=intent(operation);var entered=new CountDownLatch(1);var release=new CountDownLatch(1);var pool=Executors.newFixedThreadPool(2);
            try {
                var first=pool.submit(()->{login(a,cancelFirst?READ:WRITE);try{return new TransactionTemplate(manager).execute(status->{var receipt=cancelFirst?chart.cancelOperation(id(intent.body),cancel(operation,intent.code,intent.body)):dispatch(operation,intent.code,intent.body);entered.countDown();await(release);return receipt;});}finally{SecurityContextHolder.clearContext();}});
                assertThat(entered.await(30,TimeUnit.SECONDS)).isTrue();
                var second=pool.submit(()->{login(a,cancelFirst?WRITE:READ);try{return attempt(()->cancelFirst?dispatch(operation,intent.code,intent.body):chart.cancelOperation(id(intent.body),cancel(operation,intent.code,intent.body)));}finally{SecurityContextHolder.clearContext();}});
                org.awaitility.Awaitility.await().atMost(Duration.ofSeconds(20)).until(()->db.queryForObject("SELECT count(*) FROM pg_locks WHERE locktype='advisory' AND NOT granted",Long.class)>0);
                release.countDown();var original=first.get(40,TimeUnit.SECONDS);var other=second.get(40,TimeUnit.SECONDS);
                if(cancelFirst){assertThat(original).containsEntry("outcome","CANCELLED_UNWRITTEN");assertThat(other).isInstanceOf(ApiException.class);}
                else{assertThat(original).containsEntry("outcome","SUCCEEDED");assertThat(other).isEqualTo(original);}
                login(a,READ);assertThat(chart.operationReceipt(id(intent.body))).isEqualTo(original);
            }finally{release.countDown();pool.shutdownNow();}
            login(a,WRITE);
        }
    }

    @Test void failedCompoundTargetAndRolledBackStopKeepAllChartNativeAndBindingFactsAtomic() {
        String code=code();var body=account(UUID.randomUUID(),code);body.put("category","EQUITY");
        var nativeIds=new java.util.concurrent.atomic.AtomicReference<List<UUID>>();int nativeBefore=db.queryForObject("SELECT count(*) FROM payment_styles",Integer.class);
        new TransactionTemplate(manager).executeWithoutResult(status->{chart.createAccountCommand(body);nativeIds.set(db.queryForList("SELECT style_id FROM finance_chart_code_styles WHERE code=?",UUID.class,code));assertThat(nativeIds.get()).hasSize(1);status.setRollbackOnly();});
        assertThat(chart.operationReceipt(id(body))).containsEntry("found",false);assertThat(db.queryForObject("SELECT count(*) FROM finance_chart_codes WHERE code=?",Long.class,code)).isZero();
        for(UUID nativeId:nativeIds.get())assertThat(db.queryForObject("SELECT count(*) FROM payment_styles WHERE id=?",Long.class,nativeId)).isZero();
        assertThat(db.queryForObject("SELECT count(*) FROM payment_styles",Integer.class)).isEqualTo(nativeBefore);
        chart.createAccountCommand(body);var current=chart.account(code);int styles=db.queryForObject("SELECT count(*) FROM payment_styles",Integer.class);String before=rowBytes(code);
        var bad=target(UUID.randomUUID(),current.version());bad.put("category","ACCOUNT");bad.put("classification","ASSET");
        assertThatThrownBy(()->chart.createTargetCommand(code,bad)).isInstanceOf(ApiException.class);assertThat(chart.operationReceipt(id(bad))).containsEntry("found",false);
        assertThat(rowBytes(code)).isEqualTo(before);assertThat(db.queryForObject("SELECT count(*) FROM payment_styles",Integer.class)).isEqualTo(styles);
        var stopped=account(UUID.randomUUID(),code());new TransactionTemplate(manager).executeWithoutResult(status->{chart.cancelOperation(id(stopped),cancel(CREATE,null,stopped));status.setRollbackOnly();});
        assertThat(chart.operationReceipt(id(stopped))).containsEntry("found",false);chart.createAccountCommand(stopped);
    }

    @Test void originalPrivateBodyIsRecoverableOnlyByItsOwnerAndNeverAppearsInAuditValues() {
        var body=account(UUID.randomUUID(),code());String marker="PRIVATE-CHART-"+UUID.randomUUID();body.put("sourceReference",marker);chart.createAccountCommand(body);
        assertThat(json.valueToTree(chart.operationReceipt(id(body))).path("requestBody").path("sourceReference").asText()).isEqualTo(marker);
        String audit=db.queryForObject("SELECT jsonb_agg(to_jsonb(a) ORDER BY id)::text FROM audit_log a WHERE target_type='finance_chart_manual_operations' AND target_id=?",String.class,id(body).toString());
        assertThat(audit).isNotNull().doesNotContain(marker,"requestBody","chartProof");
        login(b,READ);assertThat(chart.operationReceipt(id(body))).containsEntry("found",false);
    }

    @Test void cancellationCannotBeUsedByRestrictedOrImpersonatedIdentities() {
        var body=account(UUID.randomUUID(),code());
        var restricted=List.of(new AuthUser(a.superAdminUserId(),a.employeeId(),"anonymous",READ,true,true,false),
                new AuthUser(a.superAdminUserId(),a.employeeId(),"anonymous",READ,false,false,false),
                new AuthUser(a.superAdminUserId(),a.employeeId(),"anonymous",READ,false,true,false,false,b.superAdminUserId()),
                AuthUser.visitor(a.superAdminUserId(),"anonymous","anonymous",READ));
        for(var user:restricted){SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(user,"",user.getAuthorities()));
            assertThatThrownBy(()->chart.cancelOperation(id(body),cancel(CREATE,null,body))).isInstanceOf(ApiException.class);
        }
        login(a,READ);assertThat(chart.operationReceipt(id(body))).containsEntry("found",false);
    }

    @Test void nullAndMissingCancellationIdentitiesFailWithoutSealingOrThrowingNullPointers()throws Exception {
        var body=account(UUID.randomUUID(),code());login(a,READ);
        var valid=cancel(CREATE,null,body);
        for(String field:List.of("operation","requestId","actorId","method","path","requestBody"))for(boolean missing:List.of(true,false)) {
            var raw=(ObjectNode)json.valueToTree(valid);if(missing)raw.remove(field);else raw.putNull(field);
            var broken=json.treeToValue(raw,FinanceOperationJournal.Cancellation.class);
            assertThatThrownBy(()->chart.cancelOperation(id(body),broken)).isInstanceOf(ApiException.class);
        }
        assertThatThrownBy(()->chart.cancelOperation(id(body),null)).isInstanceOf(ApiException.class);
        assertThat(chart.operationReceipt(id(body))).containsEntry("found",false);
    }

    @Test void existingTargetCannotIgnoreAnExplicitDifferentCurrencyAndOriginalReplayStillUsesItsSavedProof() {
        UUID one=UUID.randomUUID(),two=UUID.randomUUID();for(UUID currency:List.of(one,two))db.update("INSERT INTO currencies(id,code,name,exchange_rate,status)VALUES(?,?,?,1,'使用')",currency,"TC-"+currency,"匿名目标币别");
        String code=code();var account=account(UUID.randomUUID(),code);account.put("currencyName","匿名目标币别");account.put("currencyId",one.toString());chart.createAccountCommand(account);
        var target=target(UUID.randomUUID(),chart.account(code).version());target.put("currencyId",one.toString());var original=chart.createTargetCommand(code,target);String oldReceipt=receiptBytes(id(target));
        var mapping=mapping(UUID.randomUUID(),chart.account(code),"BS_51","PL_PRIOR_ADJUSTMENT");mapping.put("currencyId",two.toString());chart.mapCommand(code,mapping);
        var current=chart.account(code);assertThat(current.currencyId()).isEqualTo(two);String before=rowBytes(code);
        var rejected=target(UUID.randomUUID(),current.version());rejected.putNull("balanceLineKey");rejected.putNull("profitLineKey");rejected.put("currencyId",one.toString());
        assertThatThrownBy(()->chart.createTargetCommand(code,rejected)).isInstanceOf(ApiException.class).hasMessageContaining("修改对应关系");
        assertThat(chart.operationReceipt(id(rejected))).containsEntry("found",false);assertThat(rowBytes(code)).isEqualTo(before);
        for(UUID same:Arrays.asList(null,two)){
            var noop=target(UUID.randomUUID(),current.version());noop.putNull("balanceLineKey");noop.putNull("profitLineKey");if(same==null)noop.putNull("currencyId");else noop.put("currencyId",same.toString());
            assertThat(chart.createTargetCommand(code,noop)).containsEntry("outcome","SUCCEEDED");assertThat(chart.account(code)).isEqualTo(current);
        }
        assertThat(chart.createTargetCommand(code,target)).isEqualTo(original);assertThat(receiptBytes(id(target))).isEqualTo(oldReceipt);
        assertThat(chart.account(code)).isEqualTo(current);
    }

    @Test void metadataHttpShapeRequiresAnExplicitVersionAndPreservesThePublishedTyped4HashAndBytes()throws Exception {
        String code=code();chart.createAccountCommand(account(UUID.randomUUID(),code));assertThat(chart.account(code).version()).isZero();String before=rowBytes(code);
        for(String invalid:List.of("missing","null","text","fraction","huge","unknown","nameType")){
            var body=(ObjectNode)json.valueToTree(new UpdateAccount(UUID.randomUUID(),0,"匿名明确新名称","匿名原修改依据"));
            switch(invalid){case "missing"->body.remove("expectedVersion");case "null"->body.putNull("expectedVersion");case "text"->body.put("expectedVersion","0");case "fraction"->body.put("expectedVersion",new java.math.BigDecimal("0.1"));case "huge"->body.put("expectedVersion",new java.math.BigInteger("9223372036854775808"));case "unknown"->body.put("unpublishedField",true);default->body.put("name",123);}
            assertThatThrownBy(()->chart.updateAccountCommand(code,body)).isInstanceOf(ApiException.class);assertThat(chart.metadataReceipt(code,id(body))).containsEntry("found",false);assertThat(rowBytes(code)).isEqualTo(before);
        }
        UUID request=UUID.randomUUID();var typed=new UpdateAccount(request,0,"  匿名完整原文新名称  ","  匿名完整原文依据  ");var original=(ObjectNode)json.valueToTree(typed);
        String oldEncoding="{\"requestId\":\""+request+"\",\"expectedVersion\":0,\"name\":\"  匿名完整原文新名称  \",\"sourceReference\":\"  匿名完整原文依据  \"}";
        assertThat(json.writeValueAsString(typed)).isEqualTo(oldEncoding);
        var result=chart.updateAccountCommand(code,original);assertThat(result.name()).isEqualTo(typed.name().strip());
        assertThat(db.queryForObject("SELECT fingerprint FROM finance_chart_manual_operations WHERE request_id=?",String.class,request)).isEqualTo(ImmutableDocumentStore.digest(("UPDATE_METADATA:"+code+":"+oldEncoding).getBytes(java.nio.charset.StandardCharsets.UTF_8)));
        String oldBytes=receiptBytes(request);chart.updateAccount(code,new UpdateAccount(UUID.randomUUID(),1,"匿名后续名称","匿名后续独立依据"));
        assertThat(chart.updateAccountCommand(code,original)).isEqualTo(result);login(a,READ);
        var cancelled=chart.cancelMetadata(code,request,new FinanceOperationJournal.Cancellation(request,a.superAdminUserId(),"CHART_METADATA_UPDATE","PUT","/finance/chart/"+code+"/metadata",original));
        assertThat(cancelled).containsEntry("outcome","SUCCEEDED");assertThat(chart.metadataReceipt(code,request)).containsEntry("result",result);assertThat(receiptBytes(request)).isEqualTo(oldBytes);
    }

    @Test void legacyRawNullBaseCurrencyNoopUsesTheSameEffectiveProofWithoutChangingRawInputsOrBindings() {
        String code=code();var created=account(UUID.randomUUID(),code);created.put("category","EQUITY");chart.createAccountCommand(created);
        chart.mapCommand(code,mapping(UUID.randomUUID(),chart.account(code),"BS_51","PL_PRIOR_ADJUSTMENT"));
        db.update("UPDATE finance_chart_codes SET currency_id=NULL WHERE code=?",code); // Actual legacy unset identity, no GL or bank facts.
        var account=chart.account(code);assertThat(account.currencyId()).isNotNull();String original=rowBytes(code);
        var mappings=db.queryForList("SELECT * FROM finance_chart_code_styles WHERE code=?",code);var bindings=db.queryForList("SELECT * FROM finance_chart_owned_bindings WHERE code=? ORDER BY line_key",code);
        var body=target(UUID.randomUUID(),account.version());body.put("currencyId",account.currencyId().toString());body.putNull("balanceLineKey");body.putNull("profitLineKey");
        var receipt=chart.createTargetCommand(code,body);var result=(Map<?,?>)receipt.get("result");
        assertThat(result.get("currencyId")).isEqualTo(account.currencyId().toString());
        assertThat(result.get("styleIds")).isEqualTo(account.targets().stream().map(target->target.id().toString()).toList());
        assertThat(result.get("lineKeys")).isEqualTo(account.lineKeys());
        assertThat(rowBytes(code)).isEqualTo(original);assertThat(db.queryForObject("SELECT currency_id FROM finance_chart_codes WHERE code=?",UUID.class,code)).isNull();
        chart.createTarget(code,new CreateTarget(account.version(),"EQUITY","EQUITY",null));
        assertThat(rowBytes(code)).isEqualTo(original);assertThat(db.queryForList("SELECT * FROM finance_chart_code_styles WHERE code=?",code)).isEqualTo(mappings);
        assertThat(db.queryForList("SELECT * FROM finance_chart_owned_bindings WHERE code=? ORDER BY line_key",code)).isEqualTo(bindings);
        String stored=receiptBytes(id(body));chart.updateAccount(code,new UpdateAccount(UUID.randomUUID(),account.version(),"独立后续科目名称","独立后续依据"));
        assertThat(chart.createTargetCommand(code,body)).isEqualTo(receipt);assertThat(receiptBytes(id(body))).isEqualTo(stored);
    }

    @Test void newTargetCommandCannotClaimAnUnmappedNativeAsAppliedAndExplicitMappingCompletesTheRealCorrespondence() {
        String code=code();var created=account(UUID.randomUUID(),code);created.put("category","EQUITY");chart.createAccountCommand(created);
        UUID nativeId=db.queryForObject("SELECT native_style_id FROM finance_chart_codes WHERE code=?",UUID.class,code);
        var mapped=chart.account(code);var clear=(ObjectNode)json.valueToTree(new Mapping(UUID.randomUUID(),mapped.version(),List.of(),null,null,"EQUITY",mapped.currencyId()));chart.mapCommand(code,clear);
        var empty=chart.account(code);String original=rowBytes(code);int nativeCount=db.queryForObject("SELECT count(*) FROM payment_styles",Integer.class);
        chart.createTarget(code,new CreateTarget(empty.version(),"EQUITY","EQUITY",null));assertThat(rowBytes(code)).isEqualTo(original);assertThat(chart.account(code).targets()).isEmpty();
        var body=target(UUID.randomUUID(),empty.version());body.putNull("balanceLineKey");body.putNull("profitLineKey");body.put("currencyId",empty.currencyId().toString());
        assertThatThrownBy(()->chart.createTargetCommand(code,body)).isInstanceOf(ApiException.class).hasMessageContaining("对应已有科目");
        assertThat(chart.operationReceipt(id(body))).containsEntry("found",false);assertThat(rowBytes(code)).isEqualTo(original);
        assertThat(db.queryForObject("SELECT count(*) FROM payment_styles",Integer.class)).isEqualTo(nativeCount);
        chart.cancelOperation(id(body),cancel(TARGET,code,body));
        var choose=(ObjectNode)json.valueToTree(new Mapping(UUID.randomUUID(),empty.version(),List.of(nativeId),"BS_51","PL_PRIOR_ADJUSTMENT","EQUITY",empty.currencyId()));chart.mapCommand(code,choose);
        var current=chart.account(code);assertThat(current.targets()).extracting(Target::id).containsExactly(nativeId);assertThat(current.lineKeys()).containsExactlyInAnyOrder("BS_51","PL_PRIOR_ADJUSTMENT");
        var fresh=target(UUID.randomUUID(),current.version());fresh.putNull("balanceLineKey");fresh.putNull("profitLineKey");fresh.put("currencyId",current.currencyId().toString());
        var success=chart.createTargetCommand(code,fresh);assertThat(success).containsEntry("outcome","SUCCEEDED");assertThat(((Map<?,?>)success.get("result")).get("styleIds")).isEqualTo(List.of(nativeId.toString()));
        assertThat(db.queryForObject("SELECT count(*) FROM payment_styles",Integer.class)).isEqualTo(nativeCount);assertThat(chart.account(code)).isEqualTo(current);
        assertThatThrownBy(()->chart.createTargetCommand(code,body)).isInstanceOf(ApiException.class).hasMessageContaining("已停止");
    }

    private record Intent(String code,ObjectNode body) { }
    private Intent intent(String operation){String code=code();if(CREATE.equals(operation))return new Intent(null,account(UUID.randomUUID(),code));chart.createAccountCommand(account(UUID.randomUUID(),code));if(TARGET.equals(operation))return new Intent(code,target(UUID.randomUUID(),chart.account(code).version()));chart.createTargetCommand(code,target(UUID.randomUUID(),chart.account(code).version()));return new Intent(code,mapping(UUID.randomUUID(),chart.account(code),"BS_51","PL_PRIOR_ADJUSTMENT"));}
    private ObjectNode account(UUID request,String code){return (ObjectNode)json.valueToTree(new CreateAccount(request,code,"匿名科目原名","",null,"匿名明确创建依据","EQUITY",null));}
    private ObjectNode target(UUID request,long version){return (ObjectNode)json.valueToTree(new CreateTarget(request,version,"EQUITY","EQUITY",null,"BS_51","PL_PRIOR_ADJUSTMENT"));}
    private ObjectNode mapping(UUID request,Account account,String balance,String profit){return (ObjectNode)json.valueToTree(new Mapping(request,account.version(),account.targets().stream().map(Target::id).toList(),balance,profit,account.classification(),account.currencyId()));}
    private Map<String,Object> dispatch(String operation,String code,JsonNode body){return switch(operation){case CREATE->chart.createAccountCommand(body);case MAP->chart.mapCommand(code,body);case TARGET->chart.createTargetCommand(code,body);default->throw new AssertionError(operation);};}
    private FinanceOperationJournal.Cancellation cancel(String operation,String code,JsonNode body){return cancelAs(operation,code,body,a.superAdminUserId());}
    private FinanceOperationJournal.Cancellation cancelAs(String operation,String code,JsonNode body,UUID actor){return new FinanceOperationJournal.Cancellation(id(body),actor,operation,MAP.equals(operation)?"PUT":"POST",CREATE.equals(operation)?"/finance/chart":"/finance/chart/"+code+(TARGET.equals(operation)?"/create-target":""),body);}
    private static UUID id(JsonNode body){return UUID.fromString(body.path("requestId").asText());}
    private static String code(){return Integer.toString(CODES.incrementAndGet());}
    private String receiptBytes(UUID id){return db.queryForObject("SELECT to_jsonb(r)::text FROM finance_chart_manual_operations r WHERE request_id=?",String.class,id);}
    private String rowBytes(String code){return db.queryForObject("SELECT to_jsonb(c)::text FROM finance_chart_codes c WHERE code=?",String.class,code);}
    private static Object attempt(Supplier<?> work){try{return work.get();}catch(ApiException error){return error;}}
    private static void await(CountDownLatch gate){try{if(!gate.await(40,TimeUnit.SECONDS))throw new AssertionError("commit gate timeout");}catch(InterruptedException error){Thread.currentThread().interrupt();throw new IllegalStateException(error);}}
    private static void login(FullChainEndToEndTest.World owner,Set<String> permissions){var user=new AuthUser(owner.superAdminUserId(),owner.employeeId(),"anonymous-chart-original",permissions,false,true,false);SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(user,"",user.getAuthorities()));}
}
