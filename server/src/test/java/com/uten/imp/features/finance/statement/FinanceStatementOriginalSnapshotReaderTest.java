package com.uten.imp.features.finance.statement;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.read.VersionedReadSnapshotCache;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.time.Duration;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicInteger;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

class FinanceStatementOriginalSnapshotReaderTest {
    private static FinanceStatementOriginalSnapshotReader.Key key(UUID dataset,long generation,String sha,String fingerprint,int schema) {
        return new FinanceStatementOriginalSnapshotReader.Key(dataset,generation,
                UUID.fromString("00000000-0000-0000-0000-000000000001"),sha,fingerprint,schema);
    }
    private static FinanceStatementOriginalSnapshotReader.Key key() {return key(new UUID(1,1),0,"sha","fp",1);}
    private static TxSessionVars identityDecryptor() {
        TxSessionVars tx=mock(TxSessionVars.class);
        when(tx.decrypt(anyString())).thenAnswer(call->call.getArgument(0));return tx;
    }
    private static VersionedReadSnapshotCache.Limits bounds(long entry,long total,long nodes) {
        return new VersionedReadSnapshotCache.Limits(2,entry,total,Duration.ofMinutes(1),1,1,
                Duration.ofSeconds(30),32,nodes);
    }
    @SuppressWarnings("unchecked") private static List<Map<String,Object>> rows(Map<String,Object> original) {
        return (List<Map<String,Object>>)original.get("rows");
    }

    @Test void coldReadBeyondCurrentWriteLimitKeepsAllDuplicateRowsAndExactScalarsWithOneDecrypt() {
        TxSessionVars tx=identityDecryptor();var loads=new AtomicInteger();
        // Existing historical input need not be constrained by today's 20000
        // submit limit. The reader must neither add a row cap nor lose doubles.
        var text=new StringBuilder("{\"rows\":[");
        for(int i=0;i<20001;i++) {
            if(i>0)text.append(',');
            text.append("{\"caption\":\"中文重复行\",\"ordinal\":").append(i)
                .append(",\"amount\":999999999999.123456789012345678900,\"integer\":9007199254740993,\"raw\":\"0.0000\",\"nullable\":null}");
        }
        text.append("]}");String original=text.toString();
        try(var reader=new FinanceStatementOriginalSnapshotReader(new ObjectMapper(),tx)) {
            var id=key();int emitted=0;
            for(int offset=0;offset<20001;offset+=100) {
                var value=reader.read(id,()->{loads.incrementAndGet();return original;});
                var all=rows(value);assertEquals(20001,all.size());
                var batch=all.subList(offset,Math.min(all.size(),offset+100));
                for(var row:batch) {
                    assertEquals(emitted++,row.get("ordinal"));
                    assertEquals(new BigDecimal("999999999999.123456789012345678900"),row.get("amount"));
                    assertEquals(9007199254740993L,row.get("integer"));
                    assertEquals("0.0000",row.get("raw"));assertTrue(row.containsKey("nullable"));assertNull(row.get("nullable"));
                    assertEquals("中文重复行",row.get("caption"));
                }
                assertThrows(UnsupportedOperationException.class,all::clear);
            }
            assertEquals(20001,emitted);assertEquals(1,loads.get());verify(tx,times(1)).decrypt(original);
        }
    }

    @Test void everyRealmResetDocumentVersionAndSchemaDimensionSeparatesRetainedFacts() {
        TxSessionVars tx=identityDecryptor();var reads=new AtomicInteger();
        try(var reader=new FinanceStatementOriginalSnapshotReader(new ObjectMapper(),tx)) {
            var keys=List.of(key(new UUID(1,1),0,"sha1","fp1",1),key(new UUID(1,2),0,"sha1","fp1",1),
                key(new UUID(1,1),1,"sha1","fp1",1),key(new UUID(1,1),0,"sha2","fp1",1),
                key(new UUID(1,1),0,"sha1","fp2",1),key(new UUID(1,1),0,"sha1","fp1",2));
            for(int i=0;i<keys.size();i++) {
                final int expected=i;
                var value=reader.read(keys.get(i),()->"{\"rows\":[],\"source\":"+reads.getAndIncrement()+"}");
                assertEquals(expected,value.get("source"));
                assertSame(value,reader.read(keys.get(i),()->{fail("Versioned hit must not reload");return null;}));
            }
            assertEquals(keys.size(),reads.get());
        }
    }

    @Test void cacheTreeSafetyIsNotAReadRowLimitAndDoesNotDecryptTwiceOnBypass() {
        TxSessionVars tx=identityDecryptor();String original="{\"rows\":[{\"v\":1},{\"v\":1},{\"v\":1},{\"v\":1}]}";
        try(var reader=new FinanceStatementOriginalSnapshotReader(new ObjectMapper(),tx,bounds(100000,100000,3))) {
            assertEquals(4,rows(reader.read(key(),()->original)).size());
            verify(tx,times(1)).decrypt(original);
            assertEquals(4,rows(reader.read(key(),()->original)).size());
            verify(tx,times(2)).decrypt(original);
        }
    }

    @Test void cacheByteBudgetIsNotAReadRowLimitAndNeverPublishesAPrefix() {
        TxSessionVars tx=identityDecryptor();String original="{\"rows\":[{\"v\":1},{\"v\":1},{\"v\":1},{\"v\":1}]}";
        try(var reader=new FinanceStatementOriginalSnapshotReader(new ObjectMapper(),tx,bounds(8,16,100))) {
            assertEquals(4,rows(reader.read(key(),()->original)).size());
            assertEquals(4,rows(reader.read(key(),()->original)).size());
            verify(tx,times(2)).decrypt(original);
        }
    }

    @Test void failedDecryptOrMalformedOriginalDoesNotPoisonRetryAndKeepsExactSuccess() {
        TxSessionVars tx=identityDecryptor();
        when(tx.decrypt("bad-key")).thenThrow(new IllegalStateException("private synthetic failure"));
        try(var reader=new FinanceStatementOriginalSnapshotReader(new ObjectMapper(),tx)) {
            var key=key();
            ApiException failure=assertThrows(ApiException.class,()->reader.read(key,()->"bad-key"));
            assertFalse(failure.getMessage().contains("private synthetic"));
            assertThrows(ApiException.class,()->reader.read(key,()->"not-json"));
            var result=reader.read(key,()->"{\"rows\":[{\"amount\":0.100000000000000000000000}]}" );
            assertEquals(new BigDecimal("0.100000000000000000000000"),rows(result).getFirst().get("amount"));
            assertSame(result,reader.read(key,()->{fail("Accepted retry must be retained");return null;}));
        }
    }

    @Test void applicationShutdownClearsPrivateFactsAndDoesNotStartAnotherRead() {
        TxSessionVars tx=identityDecryptor();var reader=new FinanceStatementOriginalSnapshotReader(new ObjectMapper(),tx);
        reader.read(key(),()->"{\"rows\":[]}");reader.close();
        assertThrows(ApiException.class,()->reader.read(key(),()->{fail("Closed reader must not load");return null;}));
        verify(tx,times(1)).decrypt(anyString());
    }
}
