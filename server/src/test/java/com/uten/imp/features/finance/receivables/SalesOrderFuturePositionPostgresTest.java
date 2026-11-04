package com.uten.imp.features.finance.receivables;

import com.uten.imp.common.finance.BusinessPrecisionRequiredException;
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

/** Native query oracle on migrated column shapes; not a substitute for actual shipment/credit UAT. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class SalesOrderFuturePositionPostgresTest {
    static final PostgreSQLContainer PG=new PostgreSQLContainer("postgres:16-alpine");
    static JdbcTemplate db;static NamedParameterJdbcTemplate named;static TransactionTemplate tx;static SalesOrderMoneyPositionQuery service;
    @BeforeAll static void start(){
        PG.start();var data=new DriverManagerDataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword());db=new JdbcTemplate(data);named=new NamedParameterJdbcTemplate(db);tx=new TransactionTemplate(new DataSourceTransactionManager(data));
        MigratedProjectionSchema.createCurrentTables(db,"sales_orders","sales_order_items");
        MigratedProjectionSchema.createCurrentFunctions(db,"fn_business_decimal_from_integer","fn_business_exact_divide_with_policy","fn_business_exact_divide");
        var em=mock(EntityManager.class);when(em.createNativeQuery(anyString())).thenAnswer(call->query(call.getArgument(0)));service=new SalesOrderMoneyPositionQuery(em);
    }
    @AfterAll static void stop(){PG.stop();}
    @BeforeEach void clean(){db.execute("TRUNCATE sales_order_items,sales_orders");}
    @Test void exactRemainingQuantityAndOriginalCurrencyAmountKeepTwentyFourPlaces(){
        UUID order=order("10","0.123456789012345678901234","4","1","2");order("10","999","0","0","0");
        var result=service.future(order);assertThat(result.original()).isEqualByComparingTo("0.061728394506172839450617");assertThat(result.unresolvedCount()).isZero();assertThat(result.itemCount()).isEqualTo(1);
    }
    @Test void nonTerminatingProjectionRequiresAndUsesOnlyTheExplicitRequestChoice(){
        UUID order=order("3","1","2","0","0");
        assertThatThrownBy(()->service.future(order)).satisfies(error->assertThat(BusinessPrecisionRequiredException.from(error).orElseThrow().details()).containsEntry("calculationKey","finance.sales-order.future-original").containsEntry("maxScale",30));
        var result=tx.execute(status->{db.queryForObject("SELECT set_config('app.business_precision_choices',?,true)",String.class,"{\"version\":1,\"choices\":{\"finance.sales-order.future-original\":{\"scale\":24,\"rounding\":\"DOWN\"}}}");return service.future(order);});
        assertThat(result.original()).isEqualByComparingTo("0.333333333333333333333333");assertThat(result.unresolvedCount()).isZero();
        assertThatThrownBy(()->service.future(order)).satisfies(error->assertThat(BusinessPrecisionRequiredException.from(error)).isPresent());
        assertThat(db.queryForObject("SELECT count(*) FROM sales_order_items",Integer.class)).isEqualTo(1);
        assertThat(db.queryForObject("SELECT amount_original FROM sales_order_items",BigDecimal.class)).isEqualByComparingTo("1");
    }
    @Test void stoppedAndUnapprovedOrdersHaveNoFutureAmountAndInvalidSourcesRemainUnresolved(){
        UUID stopped=order("3","1","2","0","0");db.update("UPDATE sales_orders SET is_stopped=true WHERE id=?",stopped);assertThat(service.future(stopped).original()).isZero();
        db.update("UPDATE sales_orders SET is_stopped=false,status=0 WHERE id=?",stopped);assertThat(service.future(stopped).original()).isZero();
        db.update("UPDATE sales_order_items SET qty=0,amount_original=NULL WHERE order_id=?",stopped);var result=service.future(stopped);assertThat(result.original()).isZero();assertThat(result.unresolvedCount()).isEqualTo(1);
    }
    private UUID order(String qty,String amount,String shipped,String returned,String flagged){
        UUID id=UUID.randomUUID();db.update("INSERT INTO sales_orders(id,status,is_stopped,is_deleted) VALUES(?,1,false,false)",id);
        db.update("INSERT INTO sales_order_items(id,order_id,qty,amount_original,shipped_qty,returned_qty,flag_qty,is_deleted) VALUES(gen_random_uuid(),?,?,?,?,?,?,false)",id,new BigDecimal(qty),new BigDecimal(amount),new BigDecimal(shipped),new BigDecimal(returned),new BigDecimal(flagged));return id;
    }
    private static Query query(String sql){var query=mock(Query.class);Map<String,Object> params=new HashMap<>();when(query.setParameter(anyString(),any())).thenAnswer(call->{params.put(call.getArgument(0),call.getArgument(1));return query;});when(query.getSingleResult()).thenAnswer(call->named.queryForObject(sql,params,(row,index)->{Object[] result=new Object[row.getMetaData().getColumnCount()];for(int i=0;i<result.length;i++){result[i]=row.getObject(i+1);}return result;}));return query;}
}
