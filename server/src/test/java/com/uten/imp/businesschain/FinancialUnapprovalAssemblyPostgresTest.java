package com.uten.imp.businesschain;

import com.uten.imp.common.finance.BusinessPrecisionContext;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.features.documents.DocumentUnapprovalService;
import com.uten.imp.features.finance.payment.FinancePaymentService;
import com.uten.imp.features.finance.payment.dto.FinancePaymentSaveRequest;
import com.uten.imp.features.finance.receipt.FinanceReceiptService;
import com.uten.imp.features.finance.receipt.dto.FinanceReceiptSaveRequest;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.ConnectionCallback;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.transaction.support.TransactionTemplate;

import java.math.BigDecimal;
import java.sql.*;
import java.util.*;

import static org.assertj.core.api.Assertions.assertThat;

/** Actual service-created financial sources and their real same-transaction
 * clones. No fabricated native cash snapshot or approved business row is used. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
    "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
    "uten.production.readiness-reconcile.enabled=false","uten.features.goods-owner-scope-enabled=false",
    "uten.inventory.value-work.enabled=false","uten.workshop-material.auto-close.enabled=false",
    "uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only"})
@FinanceScopedChain
class FinancialUnapprovalAssemblyPostgresTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry){
        FinanceScopedChainDatabase.register(registry,FinancialUnapprovalAssemblyPostgresTest.class);
    }
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired TransactionTemplate transaction;
    @Autowired DocumentUnapprovalService unapproval;
    @Autowired FinancePaymentService payments;
    @Autowired FinanceReceiptService receipts;
    private FinanceUnapprovalEligibilityEndToEndTest factory;
    private FinanceUnapprovalEligibilityEndToEndTest.Fixture fixture;
    private FullChainEndToEndTest harness;

    @BeforeEach void prepare(){
        factory=new FinanceUnapprovalEligibilityEndToEndTest();beans.autowireBean(factory);factory.prepare();
        fixture=factory.fixture("financial-assembly-"+UUID.randomUUID().toString().substring(0,8));
        harness=(FullChainEndToEndTest)ReflectionTestUtils.getField(factory,"harness");
        assertThat(harness).isNotNull();
    }
    @AfterEach void clear(){SecurityContextHolder.clearContext();}

    @ParameterizedTest @ValueSource(booleans={false,true})
    void anImmediateCallerCanAssembleOnlyTheOriginalFactsAndCannotEditAfterForcingCompletion(boolean receipt){
        String family=receipt?"financeReceipt":"financePayment";
        String header=receipt?"finance_receipts":"finance_payments";
        String lines=receipt?"finance_receipt_lines":"finance_payment_lines";
        String parent=receipt?"receipt_id":"payment_id";
        String authority=receipt?"settlement_authority_version":"amount_authority_version";
        Object input;
        UUID original;
        try(var selection=BusinessPrecisionContext.use(choices(4,"HALF_UP"))){
            harness.loginAs(fixture.world().superAdminUserId());
            if(receipt){
                Object ar=ReflectionTestUtils.invokeMethod(factory,"salesReceivable",fixture);
                UUID ledger=ReflectionTestUtils.invokeMethod(Objects.requireNonNull(ar),"ledger");
                FinanceReceiptSaveRequest request=harness.receiptRequest(fixture.world(),ledger,fixture.bank(),fixture.expenseStyle(),
                        "20","18","1","1",BigDecimal.ONE,BusinessTime.today());
                request.setCurrencyId(fixture.currency());request.setExchangeRate(BigDecimal.ONE);
                request.setAmountOriginal(new BigDecimal("20"));
                request.getItems().getFirst().setCurrencyId(fixture.currency());
                input=request;original=receipts.create(request).getId();
                harness.loginAs(fixture.reviewer());receipts.approve(original);
            }else{
                var request=factory.payment(fixture,"25");
                request.setAccountAmount(new BigDecimal("26"));request.setBankFeeAccountAmount(BigDecimal.ONE);
                input=request;original=payments.create(request).getId();
                harness.loginAs(fixture.reviewer());payments.approve(original);
            }
        }
        String sourceLines=lineFacts(lines,parent,original);
        String sourcePolicy=policies(lines,parent,original);
        assertThat(sourcePolicy).contains("HALF_UP").contains("4");
        UUID draft;
        try(var selection=BusinessPrecisionContext.use(choices(17,"DOWN"))){
            draft=transaction.execute(status->{
                unrelatedDeferredGuard();
                db.execute("SET CONSTRAINTS ALL IMMEDIATE");
                harness.loginAs(fixture.reviewer());
                unapproval.unapprove(family,original,new DocumentUnapprovalService.UnapproveRequest(
                        "financial-assembly-"+UUID.randomUUID(),"按实际原来源组装并验证完整初始事务"));
                UUID clone=db.queryForObject("SELECT draft_id FROM document_unapprovals WHERE family=? AND original_id=?",UUID.class,family,original);
                UUID line=db.queryForObject("SELECT id FROM "+lines+" WHERE "+parent+"=? AND NOT is_deleted",UUID.class,clone);
                String source=db.queryForObject("SELECT to_jsonb(h)::text FROM "+header+" h WHERE id=?",String.class,original);
                String successor=db.queryForObject("SELECT to_jsonb(h)::text FROM "+header+" h WHERE id=?",String.class,clone);
                assertThat(headersMatch(lines,source,successor,"{}",original,true)).isTrue();
                if(receipt){
                    assertThat(headersMatch(lines,source,successor,"{\"settlement_authority_version\":0}",original,false)).isTrue();
                    for(String patch:List.of("{\"settlement_authority_version\":0}","{\"settlement_authority_version\":null}",
                            "{\"settlement_authority_version\":1}")){
                        assertThat(headersMatch(lines,source,successor,patch,original,true)).isFalse();
                    }
                    assertThat(headersMatch(lines,source,successor,"{\"settlement_authority_version\":null}",original,false)).isFalse();
                }
                for(String patch:List.of("{\"currency_id\":null}","{\"account_amount\":999}",
                        "{\"bank_fee_local\":999,\"bank_fee\":999}","{\"gl_account_style_id\":null}")){
                    assertThat(headersMatch(lines,source,successor,patch,original,false)).isFalse();
                    assertThat(headersMatch(lines,source,successor,patch,original,true)).isFalse();
                }
                assertThat(policies(lines,parent,clone)).isEqualTo(sourcePolicy);
                // This session-local sentinel checks only constraint timing;
                // it supplies no financial or source/approval business facts.
                rejects(connection->update(connection,"INSERT INTO pg_temp.financial_assembly_other_guard(accepted) VALUES(false)"));
                // Complete the actual deferred owner now, then try to bypass it.
                // All of these real writes must still fail in this creation TX.
                db.execute("SET CONSTRAINTS document_unapproval_financial_source_complete IMMEDIATE");
                String cloneLine=db.queryForObject("SELECT to_jsonb(l)::text FROM "+lines+" l WHERE id=?",String.class,line);
                rejects(connection->update(connection,"UPDATE "+header+" SET "+authority+"=0 WHERE id=?",clone));
                rejects(connection->update(connection,"UPDATE "+header+" SET is_deleted=true WHERE id=?",clone));
                rejects(connection->update(connection,"DELETE FROM "+header+" WHERE id=?",clone));
                rejects(connection->update(connection,"UPDATE "+header+" SET gl_account_style_id=? WHERE id=?",UUID.randomUUID(),clone));
                rejects(connection->update(connection,"UPDATE "+header+" SET account_amount=account_amount+1 WHERE id=?",clone));
                rejects(connection->update(connection,"UPDATE "+header+" SET "+(receipt?"bank_fee":"bank_fee_local")+"=99 WHERE id=?",clone));
                rejects(connection->update(connection,"UPDATE "+header+" SET exchange_rate=exchange_rate+1 WHERE id=?",clone));
                rejects(connection->update(connection,"UPDATE "+header+" SET created_by=? WHERE id=?",UUID.randomUUID(),clone));
                rejects(connection->update(connection,"UPDATE "+lines+" SET amount_original=amount_original+1 WHERE id=?",line));
                rejects(connection->update(connection,"UPDATE "+lines+" SET amount_original=amount_original+1 WHERE "+parent+"=?",original));
                rejects(connection->update(connection,"UPDATE "+lines+" SET business_precision_policy=NULL WHERE id=?",line));
                rejects(connection->update(connection,"UPDATE "+lines+" SET unapproval_source_item_id=NULL WHERE id=?",line));
                rejects(connection->update(connection,"UPDATE "+lines+" SET id=? WHERE id=?",UUID.randomUUID(),line));
                rejects(connection->update(connection,"UPDATE "+lines+" SET updated_by=? WHERE id=?",UUID.randomUUID(),line));
                rejects(connection->update(connection,"UPDATE "+lines+" SET "+parent+"=? WHERE id=?",original,line));
                rejects(connection->update(connection,"UPDATE "+lines+" SET is_deleted=true WHERE id=?",line));
                rejects(connection->update(connection,"DELETE FROM "+lines+" WHERE id=?",line));
                rejects(connection->update(connection,"INSERT INTO "+lines+" SELECT (jsonb_populate_record(NULL::public."+lines+
                        ",?::jsonb||jsonb_build_object('id',?::uuid,'unapproval_source_item_id',NULL))).*",cloneLine,UUID.randomUUID()));
                db.update("UPDATE "+header+" SET updated_at=updated_at,updated_by=updated_by WHERE id=?",clone);
                assertThat(policies(lines,parent,clone)).isEqualTo(sourcePolicy);
                assertThat(lineFacts(lines,parent,original)).isEqualTo(sourceLines);
                return clone;
            });
        }
        assertThat(draft).isNotNull();
        assertThat(db.queryForObject("SELECT balance_current FROM accounts WHERE id=?",BigDecimal.class,fixture.bank())).isEqualByComparingTo("500");
        // New work in a later TX is still legal: it adopts the editor's explicit
        // decision, replaces the old draft rows, and can really be approved.
        harness.loginAs(fixture.world().superAdminUserId());
        try(var selection=BusinessPrecisionContext.use(choices(17,"DOWN"))){
            if(receipt){
                var request=(FinanceReceiptSaveRequest)input;request.setExpectedVersion(receipts.detail(draft).getVersion());
                request.setAmountOriginal(new BigDecimal("21"));request.setAccountAmount(new BigDecimal("19"));
                request.getItems().getFirst().setAmountOriginal(new BigDecimal("21"));receipts.update(draft,request);
            }else{
                var request=(FinancePaymentSaveRequest)input;request.setExpectedVersion(payments.detail(draft).getVersion());
                request.setAmountOriginal(new BigDecimal("26"));request.setAccountAmount(new BigDecimal("27"));
                request.getItems().getFirst().setAmountOriginal(new BigDecimal("26"));payments.update(draft,request);
            }
            assertThat(policies(lines,parent,draft)).contains("DOWN").contains("17");
            assertThat(db.queryForObject("SELECT count(*) FROM "+lines+" WHERE "+parent+"=? AND NOT is_deleted AND unapproval_source_item_id IS NOT NULL",Integer.class,draft)).isZero();
            harness.loginAs(fixture.reviewer());
            if(receipt)receipts.approve(draft);else payments.approve(draft);
        }
        assertThat(db.queryForObject("SELECT status FROM "+header+" WHERE id=?",Integer.class,draft)).isEqualTo(1);
        assertThat(lineFacts(lines,parent,original)).isEqualTo(sourceLines);
    }

    @Test void quantityAndFinancialStrategiesKeepTheirDistinctOwnersAndAlwaysGuards(){
        assertThat(db.queryForList("SELECT family FROM fn_unapproval_source_profiles() ORDER BY family",String.class))
                .containsExactly("purchaseOrder","purchaseReceipt","purchaseReturn","salesReturn","subcontractMaterialReturn","subcontractOrder","subcontractReceipt");
        assertThat(db.queryForList("SELECT family FROM fn_financial_unapproval_owner(NULL) ORDER BY family",String.class))
                .containsExactly("financePayment","financeReceipt");
        assertThat(db.queryForObject("SELECT count(*) FROM pg_trigger WHERE NOT tgisinternal AND tgenabled='A' AND tgname IN('trg_000_financial_unapproval_initial_header','trg_000_financial_unapproval_initial_line')",Integer.class)).isEqualTo(4);
    }

    private static Map<String,BusinessPrecisionContext.Choice> choices(int scale,String mode){
        return Map.of("money.cumulative-share",new BusinessPrecisionContext.Choice(scale,mode));
    }
    private void unrelatedDeferredGuard(){
        db.execute("CREATE TEMP TABLE financial_assembly_other_guard(accepted boolean NOT NULL) ON COMMIT DROP");
        db.execute("""
                CREATE OR REPLACE FUNCTION pg_temp.fn_financial_assembly_other_guard() RETURNS trigger
                LANGUAGE plpgsql AS $$BEGIN
                  IF NEW.accepted IS DISTINCT FROM true THEN
                    RAISE EXCEPTION 'unrelated completion must remain immediate' USING ERRCODE='23514';
                  END IF;
                  RETURN NEW;
                END; $$
                """);
        db.execute("""
                CREATE CONSTRAINT TRIGGER financial_assembly_other_guard AFTER INSERT ON pg_temp.financial_assembly_other_guard
                DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION pg_temp.fn_financial_assembly_other_guard()
                """);
    }
    private String lineFacts(String table,String parent,UUID id){
        return db.queryForObject("SELECT jsonb_agg(to_jsonb(l) ORDER BY line_no,id)::text FROM "+table+" l WHERE "+parent+"=? AND NOT is_deleted",String.class,id);
    }
    private String policies(String table,String parent,UUID id){
        return db.queryForObject("SELECT jsonb_agg(business_precision_policy ORDER BY line_no,id)::text FROM "+table+" WHERE "+parent+"=? AND NOT is_deleted",String.class,id);
    }
    private boolean headersMatch(String table,String source,String successor,String patch,UUID original,boolean complete){
        return Boolean.TRUE.equals(db.queryForObject("SELECT fn_unapproval_financial_headers_match(?,?::jsonb,?::jsonb||?::jsonb,?,?)",Boolean.class,table,source,successor,patch,original,complete));
    }
    @FunctionalInterface private interface SqlAction {void run(Connection connection)throws SQLException;}
    private void rejects(SqlAction action){
        db.execute((ConnectionCallback<Void>)connection->{
            Savepoint saved=connection.setSavepoint();
            try{
                SQLException failure=Assertions.assertThrows(SQLException.class,()->action.run(connection));
                assertThat(failure.getSQLState()).isIn("23514","55000");
            }finally{connection.rollback(saved);connection.releaseSavepoint(saved);}
            return null;
        });
    }
    private static void update(Connection connection,String sql,Object...args)throws SQLException{
        try(PreparedStatement statement=connection.prepareStatement(sql)){
            for(int i=0;i<args.length;i++)statement.setObject(i+1,args[i]);
            assertThat(statement.executeUpdate()).isEqualTo(1);
        }
    }
}
