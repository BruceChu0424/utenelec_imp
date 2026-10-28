package com.uten.imp.features.finance.payables;

import com.uten.imp.application.port.TaskAudiencePort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.support.MigratedProjectionSchema;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.test.util.ReflectionTestUtils;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.math.BigDecimal;
import java.util.*;
import java.util.concurrent.atomic.AtomicReference;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class ProcurementIqcRejectionHeaderPostgresTest {
    private static final PostgreSQLContainer PG=new PostgreSQLContainer("postgres:16-alpine");
    @BeforeAll static void start(){PG.start();}
    @AfterAll static void stop(){PG.stop();}

    @Test
    void headerRowsCountsReasonsAndMaskedMoneyUseTheSameAuthorizedFactsBeforePaging() {
        var source=new DriverManagerDataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword());
        var db=new JdbcTemplate(source);var named=new NamedParameterJdbcTemplate(source);
        MigratedProjectionSchema.createCurrentTables(db,"procurement_iqc_rejection_cases","suppliers","goods",
                "procurement_inspection_items","units","currencies","colors");
        UUID owner=UUID.randomUUID(),supplier=UUID.randomUUID(),goods=UUID.randomUUID(),unit=UUID.randomUUID(),currency=UUID.randomUUID();
        db.update("INSERT INTO suppliers(id,code,name) VALUES (?,'S','检索供应商')",supplier);
        db.update("INSERT INTO goods(id,code,name) VALUES (?,'G-001','不合格检索原料')",goods);
        db.update("INSERT INTO units(id,name) VALUES (?,'件')",unit);
        db.update("INSERT INTO currencies(id,code,name) VALUES (?,'CNY','人民币')",currency);
        seed(db,owner,supplier,goods,unit,currency,"PENDING_RETURN","1.0001","25.0001",null);
        seed(db,owner,supplier,goods,unit,currency,"FINANCE_EXCEPTION","2.0001","26.0001","  编码待修复  ");
        seed(db,owner,supplier,goods,unit,currency,"CREDIT_CONFIRMED","4","29",null);
        seed(db,UUID.randomUUID(),supplier,goods,unit,currency,"FINANCE_EXCEPTION","9","99","编码待修复");
        var actor=new AtomicReference<>(user(owner,true));
        var current=mock(SecurityContextCurrentUser.class);
        when(current.get()).thenAnswer(call->Optional.of(actor.get()));when(current.requireId()).thenReturn(owner);
        List<String> executed=new ArrayList<>();var em=mock(EntityManager.class);
        when(em.createNativeQuery(anyString())).thenAnswer(call->query(named,call.getArgument(0),executed));
        var service=new ProcurementIqcRejectionService(em,null,current,null,null,null,null,null,null,null,null);
        ReflectionTestUtils.setField(service,"taskAudience",new TaskAudiencePort(){
            @Override public <T>T read(ReadQuery<T> work){return work.read();}
            @Override public <T>T browsingRead(ReadQuery<T> work){return work.read();}
        });
        var row=service.list("PURCHASE","ACTIVE",null,2,1,Map.of("search.goodsName","检索","sort","failedQty","order","desc"));
        assertThat(row.total()).isEqualTo(2);assertThat(row.items()).singleElement().satisfies(item->{
            assertThat(item.failedQty()).isEqualTo("1.0001");
            assertThat(item.failedAmountLocal()).isEqualTo("25.0001");
            assertThat(item.displayReason()).isEqualTo("IQC不合格实物退回及供应商贷项尚未闭环");
        });
        var reason=service.list(null,"ACTIVE",null,1,20,Map.of("search.holdReason","待修复","search.amount",">=26.0001"));
        assertThat(reason.total()).isEqualTo(1);assertThat(reason.items().getFirst().displayReason()).isEqualTo("编码待修复");
        var counts=service.counts(null,null,Map.of("search.holdReason","闭环"));
        assertThat(counts.total()).isEqualTo(2); // pending generic hold + the completed credit label
        assertThat(counts.pendingReturn()).isEqualTo(1);assertThat(counts.creditConfirmed()).isEqualTo(1);
        actor.set(user(owner,false));
        var masked=service.list(null,"TERMINAL",null,1,20,Map.of("search.holdReason","贷项已闭环"));
        assertThat(masked.items()).singleElement().satisfies(item->{
            assertThat(item.priceMasked()).isTrue();assertThat(item.failedAmountLocal()).isNull();
            assertThat(item.failedAmountOriginal()).isNull();assertThat(item.displayReason()).isEqualTo("供应商贷项已闭环");
        });
        int before=executed.size();
        for(var input:List.of(Map.of("search.amount","NaN"),Map.of("search.amount",">0"),Map.of("sort","amount"))){
            assertThatThrownBy(()->service.list(null,"ACTIVE",null,1,20,input))
                    .isInstanceOfSatisfying(ApiException.class,error->assertThat(error.getCode()).isEqualTo(ErrorCode.FORBIDDEN));
            assertThatThrownBy(()->service.counts(null,null,input))
                    .isInstanceOfSatisfying(ApiException.class,error->assertThat(error.getCode()).isEqualTo(ErrorCode.FORBIDDEN));
        }
        assertThat(executed).hasSize(before);
    }

    private static AuthUser user(UUID id,boolean money){return new AuthUser(id,UUID.randomUUID(),"iqc-header",
            money?Set.of("procurement_iqc_rejection:view","procurement_iqc_rejection:amount:view")
                    :Set.of("procurement_iqc_rejection:view"),false,true,false);}
    private static void seed(JdbcTemplate db,UUID owner,UUID supplier,UUID goods,UUID unit,UUID currency,
                             String status,String qty,String amount,String message){
        UUID inspection=UUID.randomUUID();db.update("INSERT INTO procurement_inspection_items(id,status) VALUES (?,'RESOLVED')",inspection);
        db.update("""
                INSERT INTO procurement_iqc_rejection_cases(id,receipt_type,receipt_id,receipt_item_id,inspection_item_id,
                    receipt_bill_no,order_bill_no,supplier_id,goods_id,unit_id,currency_id,failed_base_qty,failed_qty,
                    failed_amount_original,failed_amount_local,exchange_rate,status,row_version,owner_user_id,
                    finance_exception_message,is_deleted,created_at)
                VALUES (?,'PURCHASE',?,?,?,'RCV-1','PO-1',?,?,?,?,?,?,?, ?,1,?,0,?,?,FALSE,now())
                """,UUID.randomUUID(),UUID.randomUUID(),UUID.randomUUID(),inspection,supplier,goods,unit,currency,
                new BigDecimal(qty),new BigDecimal(qty),new BigDecimal(amount),new BigDecimal(amount),status,owner,message);
    }
    private static Query query(NamedParameterJdbcTemplate named,String sql,List<String> executed){
        Map<String,Object> values=new LinkedHashMap<>();
        return mock(Query.class,call->{
            return switch(call.getMethod().getName()){
                case "setParameter" -> {values.put(call.getArgument(0),call.getArgument(1));yield call.getMock();}
                case "getResultList" -> {executed.add(sql);yield named.query(sql,values,(rs,index)->{
                    Object[] row=new Object[rs.getMetaData().getColumnCount()];for(int i=0;i<row.length;i++)row[i]=rs.getObject(i+1);return row;});}
                case "getSingleResult" -> {executed.add(sql);yield sql.startsWith("SELECT COUNT(*) FROM")
                        ?named.queryForObject(sql,values,Long.class)
                        :named.queryForObject(sql,values,(rs,index)->{
                            Object[] row=new Object[rs.getMetaData().getColumnCount()];for(int i=0;i<row.length;i++)row[i]=rs.getObject(i+1);return row;});}
                default -> null;
            };
        });
    }
}
