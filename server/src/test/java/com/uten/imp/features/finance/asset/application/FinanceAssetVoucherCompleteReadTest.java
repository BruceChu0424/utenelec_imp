package com.uten.imp.features.finance.asset.application;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.finance.FinanceDocumentAccessPolicy;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.context.SecurityContextHolder;
import java.time.LocalDate;
import java.util.*;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

class FinanceAssetVoucherCompleteReadTest {
    @AfterEach void clearActor(){SecurityContextHolder.clearContext();}
    @Test void everyExactNumberVoucherAndItsOriginalEntriesSurviveBeyondTenWithBoundedEntryQueries(){
        var db=new VoucherReads();
        var auth=mock(FinanceAssetAuthorization.class);
        var policy=mock(FinanceDocumentAccessPolicy.class,RETURNS_DEEP_STUBS);
        when(policy.scope().seeAll()).thenReturn(true);
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken("fixture",null,List.of(new SimpleGrantedAuthority("finance_report:view"))));
        var service=new FinanceAssetOpeningGroupService(db,new ObjectMapper(),null,auth,null,null,policy);
        @SuppressWarnings("unchecked") var rows=(List<Map<String,Object>>)service.voucher(" SAME-NUMBER ").get("items");
        assertEquals(1001,rows.size());assertEquals(new UUID(1,1000),rows.getLast().get("id"));
        for(int n=0;n<rows.size();n++){
            assertEquals(new UUID(1,n),rows.get(n).get("id"));
            @SuppressWarnings("unchecked") var entries=(List<Map<String,Object>>)rows.get(n).get("entries");
            assertEquals(2,entries.size());
            assertEquals("999999999999.123456789012345678901",entries.getFirst().get("amount"));
            assertEquals(new UUID(8,n),entries.getLast().get("claimedGroupId"));
            assertFalse(entries.getFirst().containsKey("__voucherId"));
        }
        assertEquals(4,db.reads,"One exact-number lookup and three <=500 entry batches, never one entry query per voucher");
        assertTrue(db.maximumBatch<=500);assertEquals(0,db.writes);
        verify(auth).require(FinanceAssetAuthorization.EDIT);
    }
    @Test void nonCompanyReadersCannotStartTheExactVoucherRead(){
        var db=new VoucherReads();var auth=mock(FinanceAssetAuthorization.class);
        var policy=mock(FinanceDocumentAccessPolicy.class,RETURNS_DEEP_STUBS);
        when(policy.scope().seeAll()).thenReturn(false);
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken("fixture",null,List.of(new SimpleGrantedAuthority("finance_report:view"))));
        var service=new FinanceAssetOpeningGroupService(db,new ObjectMapper(),null,auth,null,null,policy);
        assertThrows(ApiException.class,()->service.voucher("SAME-NUMBER"));assertEquals(0,db.reads);
    }
    @Test void assetOpeningVoucherChoiceRetainsEveryExactMatchInsteadOfTwo(){
        var em=mock(EntityManager.class);var query=mock(Query.class);var auth=mock(FinanceAssetAuthorization.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter(anyString(),any())).thenReturn(query);
        int[] requestedLimit={Integer.MAX_VALUE};
        when(query.setMaxResults(anyInt())).thenAnswer(call->{requestedLimit[0]=call.getArgument(0);return query;});
        var matches=new ArrayList<Object[]>();for(int n=0;n<1001;n++)matches.add(new Object[]{new UUID(2,n),"SAME-NUMBER",LocalDate.of(2026,1,31)});
        when(query.getResultList()).thenAnswer(call->matches.subList(0,Math.min(matches.size(),requestedLimit[0])));
        var result=new FinanceAssetQueryService(em,auth,null,null).openingVouchers(" SAME-NUMBER ");
        assertEquals(1001,result.size());assertEquals(new UUID(2,1000),result.getLast().id());
        verify(query).setParameter("number","SAME-NUMBER");verify(query,never()).setMaxResults(anyInt());
        verify(auth).require(FinanceAssetAuthorization.EDIT);
    }
    private static final class VoucherReads extends JdbcTemplate {
        int reads,maximumBatch,writes;
        @Override public List<Map<String,Object>> queryForList(String sql,Object...args){
            reads++;var rows=new ArrayList<Map<String,Object>>();
            if(sql.contains("FROM gl_vouchers")){
                assertEquals("SAME-NUMBER",args[0]);int total=sql.contains("LIMIT 10")?10:1001;
                for(int n=0;n<total;n++){var row=new LinkedHashMap<String,Object>();row.put("id",new UUID(1,n));row.put("voucherNo","SAME-NUMBER");rows.add(row);}
            }else{
                maximumBatch=Math.max(maximumBatch,args.length);
                boolean batched=sql.contains("e.voucher_id IN(");
                for(Object owner:args){int n=(int)((UUID)owner).getLeastSignificantBits();for(int line=0;line<2;line++){
                    var row=new LinkedHashMap<String,Object>();if(batched)row.put("__voucherId",owner);
                    row.put("id",new UUID(3+line,n));row.put("amount","999999999999.123456789012345678901");row.put("claimedGroupId",line==0?null:new UUID(8,n));rows.add(row);
                }}
            }
            return rows;
        }
        @Override public int update(String sql,Object...args){writes++;throw new AssertionError("Voucher lookup attempted a write");}
    }
}
