package com.uten.imp.features.finance.statement;

import com.uten.imp.application.port.FinanceStatementOriginalReadPort;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.jdbc.core.JdbcTemplate;
import java.math.BigDecimal;
import java.util.*;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

class FinanceOriginalReceiptQualificationReadTest {
    private static final UUID REVIEW=new UUID(0,1),PARTY=new UUID(0,2),CURRENCY=new UUID(0,3);
    private static final String FP="1".repeat(64);
    @Test void thousandCompleteReceiptsUseBoundedReadBatchesAndAMonthlySubsetStillCannotStandForAWholeBill() {
        var db=new Receipts();var source=new ArrayList<Map<String,Object>>();
        for(int i=0;i<1001;i++) {
            UUID receipt=new UUID(10,i),item=new UUID(20,i);
            db.receiptByItem.put(item,receipt);db.allItems.put(receipt,new LinkedHashSet<>(Set.of(item)));
            source.add(Map.of("__sourceType","PURCHASE_RECEIPT","__sourceId",item.toString()));
        }
        UUID partial=new UUID(10,1000);db.allItems.get(partial).add(new UUID(99,1));
        source.add(Map.of("__sourceType","PURCHASE_RECEIPT","__sourceId",new UUID(88,1).toString()));
        var docs=mock(FinanceStatementDocumentService.class);
        when(docs.review(REVIEW)).thenReturn(review(source,"INTERNAL_CONFIRMED"));
        var provider=provider(docs);var result=new FinanceStatementOriginalReadAdapter(provider,db).requireConfirmed(REVIEW,FP);
        assertEquals(1000,result.sources().size());assertFalse(result.sources().stream().anyMatch(x->x.sourceId().equals(partial)));
        assertEquals(new BigDecimal("999999999999.123456789012345678901"),result.periodAmount());
        assertTrue(result.sources().stream().allMatch(x->x.itemIds().size()==1));
        assertEquals(6,db.reads,"1002 source IDs plus1001 receipt IDs require six <=500 batches, not1001 extra receipt queries");
        assertTrue(db.maximumBatch<=500);assertEquals(0,db.writes);
    }
    @Test void anUnconfirmedOrWrongFingerprintOriginalCannotStartReceiptQualification() {
        var db=new Receipts();var docs=mock(FinanceStatementDocumentService.class);
        when(docs.review(REVIEW)).thenReturn(review(List.of(),"SUBMITTED"));var adapter=new FinanceStatementOriginalReadAdapter(provider(docs),db);
        assertThrows(com.uten.imp.common.web.ApiException.class,()->adapter.requireConfirmed(REVIEW,FP));assertEquals(0,db.reads);
        when(docs.review(REVIEW)).thenReturn(review(List.of(),"INTERNAL_CONFIRMED"));
        assertThrows(com.uten.imp.common.web.ApiException.class,()->adapter.requireConfirmed(REVIEW,"3".repeat(64)));assertEquals(0,db.reads);assertEquals(0,db.writes);
    }
    @SuppressWarnings("unchecked") private static ObjectProvider<FinanceStatementDocumentService> provider(FinanceStatementDocumentService docs) {
        var provider=(ObjectProvider<FinanceStatementDocumentService>)mock(ObjectProvider.class);when(provider.getObject()).thenReturn(docs);return provider;
    }
    private static Map<String,Object> review(List<Map<String,Object>> rows,String status) {
        var context=Map.of("templateKey","supplierStatement","partyRole","SUPPLIER","partyId",PARTY.toString(),"currencyId",CURRENCY.toString(),"dateFrom","2026-01-01","dateTo","2026-01-31");
        return Map.of("status",status,"source_fingerprint",FP,"document_sha256","2".repeat(64),"original",Map.of("context",context,"rows",rows,"documentMetadata",Map.of("periodAmount","999999999999.123456789012345678901")));
    }
    private static final class Receipts extends JdbcTemplate {
        final Map<UUID,UUID> receiptByItem=new LinkedHashMap<>();final Map<UUID,Set<UUID>> allItems=new LinkedHashMap<>();
        int reads,maximumBatch,writes;
        @Override public List<Map<String,Object>> queryForList(String sql,Object...args) {
            reads++;var result=new ArrayList<Map<String,Object>>();
            if(sql.contains(" JOIN ")) {
                int size=args.length-2;maximumBatch=Math.max(maximumBatch,size);
                assertEquals(PARTY,args[size]);assertEquals(CURRENCY,args[size+1]);
                for(int i=0;i<size;i++) {UUID receipt=receiptByItem.get(args[i]);if(receipt!=null)result.add(Map.of("id",args[i],"receipt_id",receipt));}
            } else {
                maximumBatch=Math.max(maximumBatch,args.length);
                for(Object arg:args)for(UUID item:allItems.getOrDefault(arg,Set.of()))result.add(Map.of("id",item,"receipt_id",arg));
            }
            return result;
        }
        @Override public <T>List<T> queryForList(String sql,Class<T> type,Object...args) {
            // Valid legacy N+1 responses make the old source fail the query
            // budget assertion rather than an unconfigured mock exception.
            reads++;return allItems.getOrDefault(args[0],Set.of()).stream().map(type::cast).toList();
        }
        @Override public int update(String sql,Object...args){writes++;throw new AssertionError("Receipt read attempted a write");}
    }
}
