package com.uten.imp.common.finance;

import com.uten.imp.support.MigratedProjectionSchema;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import java.math.BigDecimal;
import java.util.*;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.*;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.postgresql.PostgreSQLContainer;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;
import static org.mockito.ArgumentMatchers.*;

/** Actual expectation writes on migrated column shapes; physical chain tested separately. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class ProcurementOrderExpectationPrecisionPostgresTest {
    static final PostgreSQLContainer PG=new PostgreSQLContainer("postgres:16-alpine");
    static JdbcTemplate db;static NamedParameterJdbcTemplate named;static TransactionTemplate tx;static EntityManager em;
    UUID item,expectation,line;
    @BeforeAll static void start(){
        PG.start();var source=new DriverManagerDataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword());db=new JdbcTemplate(source);named=new NamedParameterJdbcTemplate(db);tx=new TransactionTemplate(new DataSourceTransactionManager(source));
        MigratedProjectionSchema.createCurrentTables(db,"purchase_order_items","inbound_expectations","inbound_expectation_items",
                "purchase_receipts","purchase_receipt_items","purchase_returns","purchase_return_items","procurement_inspection_items",
                "procurement_iqc_rejection_cases","procurement_arrival_exceptions","stock_movements");
        MigratedProjectionSchema.createCurrentFunctions(db,"fn_business_decimal_from_integer","fn_business_exact_divide_with_policy",
                "fn_iqc_frozen_cumulative","fn_iqc_frozen_interval","fn_iqc_reject_split_choice","fn_iqc_stock_in_frozen_share");
        em=mock(EntityManager.class);when(em.createNativeQuery(anyString())).thenAnswer(call->query(call.getArgument(0)));
    }
    @AfterAll static void stop(){PG.stop();}
    @BeforeEach void seed(){
        db.execute("TRUNCATE inbound_expectation_items,inbound_expectations,purchase_order_items,purchase_receipts,purchase_receipt_items,purchase_returns,purchase_return_items,procurement_inspection_items,procurement_iqc_rejection_cases,procurement_arrival_exceptions,stock_movements");item=UUID.randomUUID();expectation=UUID.randomUUID();line=UUID.randomUUID();
        db.update("INSERT INTO purchase_order_items(id,unit_id,unit_rate,qty,received_qty,returned_qty,arrival_overage_posted_qty,is_deleted) VALUES(?,?,1,1,0,0,0,false)",item,UUID.randomUUID());
        db.update("INSERT INTO inbound_expectations(id,order_type,status) VALUES(?,'PURCHASE','OPEN')",expectation);
        db.update("INSERT INTO inbound_expectation_items(id,expectation_id,order_item_id,unit_rate,ordered_qty,accepted_qty) VALUES(?,?,?,1,9,0)",line,expectation,item);
    }
    @Test void finiteTwentyFourPlaceAcceptedQuantityKeepsAnActuallyOpenExpectation(){
        synchronize("1","0.999999999999999999999999");
        assertThat(amount("accepted_qty")).isEqualByComparingTo("0.999999999999999999999999");assertThat(amount("ordered_qty")).isEqualByComparingTo("1");
        assertThat(db.queryForObject("SELECT status FROM inbound_expectations WHERE id=?",String.class,expectation)).isEqualTo("OPEN");
    }
    @Test void insufficientChoiceRejectsBeforeAnyWriteAndExplicitCoveringChoiceSucceeds()throws Exception {
        db.update("UPDATE inbound_expectation_items SET unit_rate=3 WHERE id=?",line);
        assertThatThrownBy(()->synchronize("3","2")).isInstanceOf(BusinessPrecisionRequiredException.class);
        try(var selected=BusinessPrecisionContext.use(Map.of("procurement.expectation.accepted-quantity",new BusinessPrecisionContext.Choice(0,"DOWN")))){
            assertThatThrownBy(()->synchronize("3","2")).isInstanceOfSatisfying(BusinessPrecisionRequiredException.class,error->assertThat(error.details()).containsEntry("selectionRejected",true));
        }
        assertThat(amount("ordered_qty")).isEqualByComparingTo("9");assertThat(amount("accepted_qty")).isZero();
        try(var selected=BusinessPrecisionContext.use(Map.of("procurement.expectation.accepted-quantity",new BusinessPrecisionContext.Choice(2,"HALF_UP")))){synchronize("3","2");}
        assertThat(amount("ordered_qty")).isEqualByComparingTo("1");assertThat(amount("accepted_qty")).isEqualByComparingTo("0.67");
    }
    @Test void explicitlySelectedAcceptedProjectionCannotBeClampedToTheSelectedOrderProjection()throws Exception {
        db.update("UPDATE inbound_expectation_items SET unit_rate=7 WHERE id=?",line);
        try(var selected=BusinessPrecisionContext.use(Map.of("procurement.expectation.ordered-quantity",new BusinessPrecisionContext.Choice(2,"HALF_UP"),"procurement.expectation.accepted-quantity",new BusinessPrecisionContext.Choice(0,"HALF_UP")))){
            assertThatThrownBy(()->synchronize("6","5")).isInstanceOfSatisfying(BusinessPrecisionRequiredException.class,error->assertThat(error.details()).containsEntry("selectionRejected",true));
        }
        assertThat(amount("ordered_qty")).isEqualByComparingTo("9");assertThat(amount("accepted_qty")).isZero();
    }
    @Test void actualRemainingAndExpectationUseAdoptedBaseInsteadOfTheUnadoptedLongProduct(){
        UUID receipt=UUID.randomUUID();db.update("INSERT INTO purchase_receipts(id,status,is_deleted) VALUES(?,1,false)",receipt);
        db.update("UPDATE purchase_order_items SET received_qty=0.333366666666666666666666 WHERE id=?",item);
        db.update("INSERT INTO purchase_receipt_items(id,receipt_id,order_item_id,qty,unit_id,unit_rate,quantity_semantics,charged_base_qty,gift_base_qty,is_deleted) VALUES(gen_random_uuid(),?,?,1.0001,?,0.333333333333333333333333,'CHARGED_PLUS_GIFT_V1',0.333366666666666666666666,0,false)",receipt,item,UUID.randomUUID());
        var bound=tx.execute(status->ProcurementOrderQuantityBounds.receipts(em,"PURCHASE",item));
        assertThat(bound.retainedBase()).isGreaterThan(new BigDecimal("0.333366666666666666666666"));
        assertThat(bound.retainedOrderedQty(BigDecimal.ONE)).isEqualByComparingTo("0.333366666666666666666666");
        tx.executeWithoutResult(status->ProcurementOrderQuantityBounds.synchronizeExpectation(em,"PURCHASE",item,BigDecimal.ONE,BigDecimal.ONE,bound));
        assertThat(amount("accepted_qty")).isEqualByComparingTo("0.333366666666666666666666");
    }
    @Test void missingActualLegacyEvidenceDoesNotDiscardTheConservativeBoundOrInventZero(){
        UUID receipt=UUID.randomUUID();db.update("INSERT INTO purchase_receipts(id,status,is_deleted) VALUES(?,1,false)",receipt);
        db.update("UPDATE purchase_order_items SET received_qty=.5 WHERE id=?",item);
        db.update("INSERT INTO purchase_receipt_items(id,receipt_id,order_item_id,qty,unit_id,unit_rate,quantity_semantics,is_deleted) VALUES(gen_random_uuid(),?,?,.5,?,1,'LEGACY_RECORDED',false)",receipt,item,UUID.randomUUID());
        var bound=tx.execute(status->ProcurementOrderQuantityBounds.receipts(em,"PURCHASE",item));
        assertThat(bound.minimumOrderedQty(BigDecimal.ONE)).isEqualByComparingTo(".5");
        assertThatThrownBy(()->bound.retainedOrderedQty(BigDecimal.ONE)).hasMessageContaining("冻结数量证据");
    }
    @Test void frozenIqcProofKeepsLegacyFourPlacesAndUsesActualPriorWithItsOwnExactPolicy(){
        assertThat(db.queryForObject("SELECT fn_iqc_frozen_interval(1.0001,3,0,1,1,NULL,'money.cumulative-share')",BigDecimal.class)).isEqualByComparingTo(".3334");
        String frozen="{\"version\":1,\"choices\":{\"money.cumulative-share\":{\"scale\":2,\"rounding\":\"HALF_UP\"}}}";
        var amount=tx.execute(status->{db.queryForObject("SELECT set_config('app.business_precision_choices',?,true)",String.class,"{\"version\":1,\"choices\":{\"money.cumulative-share\":{\"scale\":0,\"rounding\":\"DOWN\"}}}");return db.queryForObject("SELECT fn_iqc_stock_in_frozen_share(1,3,1,1,.3334,2,?::jsonb,'money.cumulative-share')",BigDecimal.class,frozen);});
        assertThat(amount).isEqualByComparingTo(".3366");
        assertThat(db.queryForObject("SELECT fn_iqc_frozen_interval(1e-24,3,0,3,2,'{\"version\":1,\"choices\":{}}','money.cumulative-share')",BigDecimal.class)).isEqualByComparingTo("1e-24");
    }
    @Test void iqcExactProofCannotUseNullLegacyPolicyOrClampAnInsufficientChoice(){
        assertThatThrownBy(()->db.queryForObject("SELECT fn_iqc_frozen_interval(1,3,0,3,2,NULL,'money.cumulative-share')",BigDecimal.class)).hasMessageContaining("frozen operation policy");
        assertThatThrownBy(()->db.queryForObject("SELECT fn_iqc_stock_in_frozen_share(1,3,1,1,.3333,2,'{\"version\":1,\"choices\":{\"money.cumulative-share\":{\"scale\":0,\"rounding\":\"DOWN\"}}}','money.cumulative-share')",BigDecimal.class))
                .satisfies(error->assertThat(BusinessPrecisionRequiredException.from(error).orElseThrow().details()).containsEntry("selectionRejected",true).containsEntry("calculationKey","money.cumulative-share"));
    }
    private void synchronize(String orderedBase,String retainedBase){tx.executeWithoutResult(status->ProcurementOrderQuantityBounds.synchronizeExpectation(em,"PURCHASE",item,new BigDecimal(orderedBase),BigDecimal.ONE,new ProcurementOrderQuantityBounds.ReceiptBound(new BigDecimal(retainedBase),BigDecimal.ZERO,null)));}
    private BigDecimal amount(String field){return db.queryForObject("SELECT "+field+" FROM inbound_expectation_items WHERE id=?",BigDecimal.class,line);}
    private static Query query(String sql){var query=mock(Query.class);Map<String,Object> params=new HashMap<>();when(query.setParameter(anyString(),any())).thenAnswer(call->{params.put(call.getArgument(0),call.getArgument(1));return query;});java.util.function.Supplier<List<Object[]>> read=()->named.query(sql,params,(row,index)->{Object[] result=new Object[row.getMetaData().getColumnCount()];for(int i=0;i<result.length;i++){result[i]=row.getObject(i+1);}return result;});when(query.getResultList()).thenAnswer(call->read.get());when(query.getSingleResult()).thenAnswer(call->read.get().getFirst());when(query.executeUpdate()).thenAnswer(call->named.update(sql,params));return query;}
}
