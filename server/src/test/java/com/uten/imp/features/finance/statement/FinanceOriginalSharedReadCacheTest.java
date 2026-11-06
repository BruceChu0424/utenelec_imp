package com.uten.imp.features.finance.statement;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.features.finance.FinanceDocumentAccessPolicy;
import com.uten.imp.security.OwnerVisibility;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.*;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.transaction.support.TransactionSynchronizationManager;
import java.util.*;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class FinanceOriginalSharedReadCacheTest {
    private static final UUID ID=new UUID(0,1),DATASET=new UUID(0,2);
    private static final String ORIGINAL="{\"rows\":[{\"amount\":\"999999999999.123456789012345678900\"}],\"documentMetadata\":{}}";
    private final ReviewRows db=new ReviewRows();
    private FinanceStatementDocumentService service;
    private FinanceStatementOriginalSnapshotReader reader;
    private TxSessionVars tx;
    private FinanceDocumentAccessPolicy access;
    @BeforeEach void prepare() {
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken("reader",null,
            List.of(new SimpleGrantedAuthority("finance_report:view"))));
        service=mock(FinanceStatementDocumentService.class,CALLS_REAL_METHODS);
        tx=mock(TxSessionVars.class);when(tx.decrypt("synthetic-cipher")).thenReturn(ORIGINAL);
        var json=new ObjectMapper();reader=spy(new FinanceStatementOriginalSnapshotReader(json,tx));
        access=mock(FinanceDocumentAccessPolicy.class);when(access.scope()).thenReturn(new OwnerVisibility.OwnerScope(true,Set.of(),Set.of()));
        ReflectionTestUtils.setField(service,"db",db);ReflectionTestUtils.setField(service,"tx",tx);
        ReflectionTestUtils.setField(service,"json",json);ReflectionTestUtils.setField(service,"access",access);
        ReflectionTestUtils.setField(service,"originalSnapshots",reader);
    }
    @AfterEach void clear() {reader.close();SecurityContextHolder.clearContext();TransactionSynchronizationManager.setCurrentTransactionReadOnly(false);}
    @Test void readOnlyReviewConsumersReuseOneImmutableParseButConfirmationAndAuthorityAreAlwaysFresh() {
        TransactionSynchronizationManager.setCurrentTransactionReadOnly(true);
        var first=service.review(ID);assertEquals("reviewer-one",first.get("approved_name"));
        db.approvedName="reviewer-two";var second=service.review(ID);
        assertEquals("reviewer-two",second.get("approved_name"));assertSame(first.get("original"),second.get("original"));
        assertEquals(2,db.publicMetadataReads);assertEquals(1,db.ciphertextReads);
        verify(tx,times(1)).decrypt("synthetic-cipher");
        assertFalse(second.containsKey("snapshot_cipher"));assertFalse(second.containsKey("counterpart_file_key"));
        when(access.scope()).thenReturn(new OwnerVisibility.OwnerScope(false,Set.of(),Set.of()));
        assertThrows(com.uten.imp.common.web.ApiException.class,()->service.review(ID));
        assertEquals(2,db.publicMetadataReads);assertEquals(1,db.ciphertextReads);assertEquals(0,db.writes);
    }
    @Test void aCommandTransactionRetainsItsOriginalDecodePathEvenWhenReadCacheCannotAdmitAnything() {
        TransactionSynchronizationManager.setCurrentTransactionReadOnly(false);reader.close();
        var result=service.review(ID);assertNotNull(result.get("original"));
        assertEquals(0,db.publicMetadataReads);assertEquals(1,db.ciphertextReads);
        verify(reader,never()).read(any(),any());verify(tx,times(1)).decrypt("synthetic-cipher");assertEquals(0,db.writes);
    }
    private static final class ReviewRows extends JdbcTemplate {
        int publicMetadataReads,ciphertextReads,writes;String approvedName="reviewer-one";
        @Override public Map<String,Object> queryForMap(String sql) {return queryForMap(sql,new Object[0]);}
        @Override public List<Map<String,Object>> queryForList(String sql,Object...args) {
            if(sql.startsWith("SELECT snapshot_cipher")) {ciphertextReads++;return List.of(Map.of("snapshot_cipher","synthetic-cipher"));}
            if(!sql.contains("FROM finance_statement_document_reviews"))throw new AssertionError("Unexpected review fixture query");
            var row=new LinkedHashMap<String,Object>();row.put("id",ID);row.put("status","INTERNAL_CONFIRMED");
            row.put("document_sha256","1".repeat(64));row.put("source_fingerprint","2".repeat(64));
            row.put("approved_name",approvedName);row.put("approved_at",java.sql.Timestamp.valueOf("2026-01-02 12:00:00"));
            if(sql.startsWith("SELECT *")) {
                ciphertextReads++;row.put("snapshot_cipher","synthetic-cipher");
                row.put("counterpart_file_provider","private");row.put("counterpart_file_key","synthetic-private-key");row.put("counterpart_file_version","1");
            } else publicMetadataReads++;
            return List.of(row);
        }
        @Override public Map<String,Object> queryForMap(String sql,Object...args) {
            if(sql.contains("authorization_state"))return Map.of("business_dataset_id",DATASET,"business_reset_generation",0L);
            throw new AssertionError("Unexpected realm fixture query");
        }
        @Override public int update(String sql,Object...args){writes++;throw new AssertionError("Review read attempted a write");}
    }
}
