package com.uten.imp.features.finance.payables;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.FinanceStatementOriginalReadPort;
import com.uten.imp.application.port.FinancePayableStatementAdjustmentPort;
import com.uten.imp.common.readsnapshot.VersionedSummaryPages;
import com.uten.imp.features.finance.FinanceDocumentAccessPolicy;
import com.uten.imp.security.OwnerVisibility;
import org.junit.jupiter.api.*;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.util.ReflectionTestUtils;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.*;
import java.util.function.Supplier;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class FinancePayableChoicePartReadTest {
    private static final UUID REVIEW=new UUID(0,1),PARTY=new UUID(0,2),CURRENCY=new UUID(0,3),DOC=new UUID(0,4);
    private static final String FP="1".repeat(64);
    private final Reads db=new Reads();
    private FinancePayableStatementAdjustmentService service;
    private FinanceDocumentAccessPolicy access;
    private FinanceStatementOriginalReadPort originals;
    @BeforeEach void prepare() {
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken("reader",null,
            List.of(new SimpleGrantedAuthority("finance_report:view"),new SimpleGrantedAuthority("ar_ap_ledger:view"))));
        service=mock(FinancePayableStatementAdjustmentService.class,CALLS_REAL_METHODS);
        access=mock(FinanceDocumentAccessPolicy.class);
        when(access.scope()).thenReturn(new OwnerVisibility.OwnerScope(true,Set.of(),Set.of()));
        originals=mock(FinanceStatementOriginalReadPort.class);
        when(originals.requireConfirmed(REVIEW,FP)).thenReturn(new FinanceStatementOriginalReadPort.Original(REVIEW,"supplierStatement","SUPPLIER",PARTY,CURRENCY,
            LocalDate.of(2026,1,1),LocalDate.of(2026,1,31),FP,"2".repeat(64),new BigDecimal("1000.000000000000000001"),
            List.of(new FinanceStatementOriginalReadPort.SourceDocument("PURCHASE_RECEIPT",DOC,List.of(new UUID(0,5))))));
        var pages=mock(VersionedSummaryPages.class);
        when(pages.<Object>read(any(),any(Runnable.class),org.mockito.ArgumentMatchers.<Supplier<Object>>any())).thenAnswer(call->{
            call.getArgument(1,Runnable.class).run();
            Supplier<?> loader=call.getArgument(2);Object value=loader.get();
            return new VersionedSummaryPages.Snapshot<>(value,"auth-current","query-current","facts-current");
        });
        ReflectionTestUtils.setField(service,"db",db);ReflectionTestUtils.setField(service,"json",new ObjectMapper());
        ReflectionTestUtils.setField(service,"access",access);ReflectionTestUtils.setField(service,"originals",originals);
        ReflectionTestUtils.setField(service,"summaryPages",pages);
    }
    @AfterEach void clear(){SecurityContextHolder.clearContext();}
    private static FinancePayableStatementAdjustmentPort.Context context(){return new FinancePayableStatementAdjustmentPort.Context(REVIEW,FP);}
    @Test void targetsPartNeverQueriesOrPublishesTheAdjustmentPrefix() {
        var result=service.versionedChoices(context(),1,100,1,"targets",null);
        assertEquals(2,db.targetReads);assertEquals(0,db.adjustmentReads);
        assertEquals(1L,result.get("total"));assertEquals(1,((List<?>)result.get("targets")).size());
        assertFalse(result.containsKey("adjustments"));assertFalse(result.containsKey("adjustmentTotal"));
        assertEquals("facts-current",result.get("readDataVersion"));assertTrue(result.containsKey("original"));assertTrue(result.containsKey("accounts"));assertTrue(result.containsKey("currency"));
        assertEquals(0,db.writes);
    }
    @Test void adjustmentsPartNeverQueriesOrPublishesTheTargetPrefixAndLegacyStillReturnsBoth() {
        var result=service.versionedChoices(context(),1,50,3,"adjustments",null);
        assertEquals(0,db.targetReads);assertEquals(2,db.adjustmentReads);assertEquals(3,result.get("adjustmentPage"));
        assertEquals(50,result.get("adjustmentSize"));assertEquals(101L,result.get("adjustmentTotal"));assertFalse(result.containsKey("targets"));
        var legacy=service.choices(context(),1,100,1);
        assertTrue(legacy.containsKey("targets"));assertTrue(legacy.containsKey("adjustments"));
        assertEquals(2,db.targetReads);assertEquals(4,db.adjustmentReads);assertEquals(0,db.writes);
    }
    @Test void revokedCompanyAuthorityFailsBeforeEitherAxisOrOriginalIsRead() {
        when(access.scope()).thenReturn(new OwnerVisibility.OwnerScope(false,Set.of(),Set.of()));
        assertThrows(com.uten.imp.common.web.ApiException.class,()->service.versionedChoices(context(),1,100,1,"targets",null));
        assertEquals(0,db.targetReads);assertEquals(0,db.adjustmentReads);verifyNoInteractions(originals);assertEquals(0,db.writes);
    }
    private static final class Reads extends JdbcTemplate {
        int targetReads,adjustmentReads,writes;
        @Override public List<Map<String,Object>> queryForList(String sql) {return queryForList(sql,new Object[0]);}
        @Override public <T>T queryForObject(String sql,Class<T> type,Object...args) {
            if(sql.contains("FROM ar_ap_ledger")){targetReads++;return type.cast(1L);}
            if(sql.contains("finance_payable_statement_adjustments")){adjustmentReads++;return type.cast(101L);}
            throw new AssertionError("Unexpected count fixture route");
        }
        @Override public List<Map<String,Object>> queryForList(String sql,Object...args) {
            if(sql.contains("FROM ar_ap_ledger")){
                targetReads++;var row=new LinkedHashMap<String,Object>();row.put("id",new UUID(1,1));row.put("supplier_id",PARTY);row.put("currency_id",CURRENCY);
                row.put("amount_balance_original",new BigDecimal("9007199254740993.000000000000000001"));row.put("amount_balance",new BigDecimal("37.125"));return List.of(row);
            }
            if(sql.contains("FROM finance_payable_statement_adjustments")){adjustmentReads++;return List.of(Map.of("id",new UUID(1,2)));}
            if(sql.contains("FROM finance_chart_code_styles"))return List.of();
            throw new AssertionError("Unexpected rows fixture route");
        }
        @Override public Map<String,Object> queryForMap(String sql,Object...args) {
            if(sql.contains("FROM currencies"))return Map.of("code","USD","name","original currency");
            throw new AssertionError("Unexpected singleton fixture route");
        }
        @Override public int update(String sql,Object...args){writes++;throw new AssertionError("Read operation attempted a write");}
    }
}
