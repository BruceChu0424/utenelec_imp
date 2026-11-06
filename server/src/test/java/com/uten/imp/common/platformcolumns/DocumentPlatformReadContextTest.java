package com.uten.imp.common.platformcolumns;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.*;
import com.uten.imp.security.*;
import jakarta.persistence.*;
import org.junit.jupiter.api.*;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.transaction.support.*;
import java.math.BigDecimal;
import java.sql.Connection;
import java.util.*;
import java.util.concurrent.atomic.AtomicInteger;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class DocumentPlatformReadContextTest {
    private final UUID actor=UUID.randomUUID(),parent=UUID.randomUUID(),otherParent=UUID.randomUUID();
    private final List<UUID> rows=new ArrayList<>();
    private final Map<UUID,UUID> parents=new LinkedHashMap<>();
    private final AtomicInteger details=new AtomicInteger(),history=new AtomicInteger(),memberships=new AtomicInteger();
    private final AtomicInteger labelReads=new AtomicInteger();
    private boolean observeLabels;
    private final EntityManager em=mock(EntityManager.class);
    private final SecurityContextCurrentUser current=mock(SecurityContextCurrentUser.class);
    private final ObjectMapper json=new ObjectMapper();
    @BeforeEach void setup(){
        login(actor,new HashSet<>(Set.of("test:view","test:edit","test:price")));begin();
        when(current.get()).thenAnswer(call->Optional.of((AuthUser)SecurityContextHolder.getContext().getAuthentication().getPrincipal()));
        for(int i=0;i<401;i++){UUID row=UUID.randomUUID();rows.add(row);parents.put(row,parent);}
        when(em.createNativeQuery(anyString())).thenAnswer(call->{
            Query query=mock(Query.class);var requested=new HashSet<UUID>();
            when(query.setParameter(eq("ids"),any())).thenAnswer(binding->{for(Object id:(Set<?>)binding.getArgument(1)){
                requested.add((UUID)id);
            }
            return query;});
            when(query.getResultList()).thenAnswer(read->{memberships.incrementAndGet();return requested.stream().filter(parents::containsKey).map(id->new Object[]{id,parents.get(id)}).toList();});return query;
        });
        when(em.find(eq(Object.class),any(UUID.class),eq(LockModeType.PESSIMISTIC_WRITE))).thenReturn(new Object());
    }
    @AfterEach void clear(){finish(TransactionSynchronization.STATUS_ROLLED_BACK);SecurityContextHolder.clearContext();}
    private void login(UUID user,Set<String> permissions){var principal=new AuthUser(user,UUID.randomUUID(),"anonymous-reader",permissions,false,true,false);SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(principal,"",principal.getAuthorities()));}
    private static void begin(){TransactionSynchronizationManager.setActualTransactionActive(true);TransactionSynchronizationManager.setCurrentTransactionReadOnly(true);TransactionSynchronizationManager.setCurrentTransactionIsolationLevel(Connection.TRANSACTION_REPEATABLE_READ);TransactionSynchronizationManager.initSynchronization();}
    private static void finish(int status){if(TransactionSynchronizationManager.isSynchronizationActive()){var callbacks=TransactionSynchronizationManager.getSynchronizations();callbacks.forEach(callback->callback.afterCompletion(status));TransactionSynchronizationManager.clearSynchronization();}TransactionSynchronizationManager.clear();}
    private Map<String,Object> detail(UUID id){
        details.incrementAndGet();AuthUser principal=(AuthUser)SecurityContextHolder.getContext().getAuthentication().getPrincipal();
        if(!principal.getId().equals(actor))throw new ApiException(ErrorCode.NOT_FOUND);
        if(observeLabels)labels(em,Set.of(parent,otherParent));
        return Map.of("id",id,"status",0,"items",parents.entrySet().stream().filter(entry->entry.getValue().equals(id)).map(entry->Map.of("id",entry.getKey(),"amountOriginalExact","0.123456789012345678901234")).toList());
    }
    private DocumentPlatformColumnAdapter adapter(){
        return new DocumentPlatformColumnAdapter("test_item","匿名行",current,em,json,Set.of("test:view"),Set.of("test:edit"),Set.of("test:price"),Object.class,"SELECT id,parent FROM fixture WHERE id IN(:ids)",this::detail,(id,header)->true,List.of(new PlatformColumnResourceAdapter.FactDefinition("amountOriginal","原币金额",true)))
            .history(id->{history.incrementAndGet();return detail(id);},"SELECT id,parent FROM fixture_history WHERE id IN(:ids)");
    }
    private Map<UUID,String> labels(Object owner,Set<UUID> ids){return DocumentPlatformReadContext.referencedLabels(DocumentPlatformReadContextTest.class,owner,ids,()->{labelReads.incrementAndGet();var values=new HashMap<UUID,String>();ids.forEach(id->values.put(id,id.equals(parent)?"当前名称":"旧删除名称"));return values;});}
    @Test void nestedSameTransactionScopesShareOnlyTheExactReferenceLabelBatchUntilTheOuterScopeCloses(){
        Object owner=new Object();try(var outer=DocumentPlatformReadContext.open()){
            assertThat(labels(owner,Set.of(parent,otherParent))).containsEntry(otherParent,"旧删除名称");
            try(var nested=DocumentPlatformReadContext.open()){labels(owner,Set.of(otherParent,parent));assertThat(labelReads).hasValue(1);}
            labels(owner,Set.of(parent,otherParent));assertThat(labelReads).hasValue(1);
            labels(owner,Set.of(parent));labels(new Object(),Set.of(parent,otherParent));assertThat(labelReads).hasValue(3);
        }
        labels(owner,Set.of(parent,otherParent));assertThat(labelReads).hasValue(4);
    }
    @Test void referenceLabelsNeverCrossActorEffectivePermissionsRollbackOrAnotherTransaction(){
        Object owner=new Object();Set<String> permissions=new HashSet<>(Set.of("test:view","test:price"));login(actor,permissions);
        try(var outer=DocumentPlatformReadContext.open()){
            labels(owner,Set.of(parent));permissions.remove("test:price");labels(owner,Set.of(parent));assertThat(labelReads).hasValue(2);
            login(UUID.randomUUID(),Set.of("test:view"));labels(owner,Set.of(parent));assertThat(labelReads).hasValue(3);
            finish(TransactionSynchronization.STATUS_ROLLED_BACK);begin();labels(owner,Set.of(parent));labels(owner,Set.of(parent));assertThat(labelReads).hasValue(5);
        }
    }
    @Test void nativeWriteAndHistoryAuthorizersNeverUseThePureReferenceReadCache(){
        observeLabels=true;var adapter=adapter();try(var scope=DocumentPlatformReadContext.open()){
            adapter.authorize(Set.of(rows.getFirst()),false);adapter.authorize(Set.of(rows.getFirst()),false);assertThat(labelReads).hasValue(1);
            adapter.authorizeHistory(Set.of(rows.getFirst()));adapter.authorizeHistory(Set.of(rows.getFirst()));
            adapter.authorize(Set.of(rows.getFirst()),true);adapter.authorize(Set.of(rows.getFirst()),true);
            assertThat(details).hasValue(5);assertThat(labelReads).hasValue(5);
            adapter.authorize(Set.of(rows.getFirst()),false);assertThat(labelReads).hasValue(5);
        }
    }
    @Test void batchesKeepEveryMembershipCheckButAuthorizeAndIndexTheParentOnlyOnce(){
        var adapter=adapter();try(var scope=DocumentPlatformReadContext.open()){
            for(int offset=0;offset<401;offset+=200){var ids=new LinkedHashSet<>(rows.subList(offset,Math.min(401,offset+200)));var values=adapter.authorize(ids,false);assertThat(values.keySet()).containsExactlyInAnyOrderElementsOf(ids);values.values().forEach(value->assertThat(value.facts().get("amountOriginal")).isEqualByComparingTo(new BigDecimal("0.123456789012345678901234")));}
        }
        assertThat(memberships).hasValue(3);assertThat(details).hasValue(1);
        adapter.authorize(Set.of(rows.getFirst()),false);assertThat(details).hasValue(2);
    }
    @Test void cacheNeverCrossesEffectiveActorOrPermissionStateAndCannotBypassTheOriginalAuthorizer(){
        var adapter=adapter();Set<String> original=new HashSet<>(Set.of("test:view","test:edit","test:price"));login(actor,original);
        try(var scope=DocumentPlatformReadContext.open()){
            assertThat(adapter.authorize(Set.of(rows.getFirst()),false).get(rows.getFirst()).priceVisible()).isTrue();
            original.remove("test:price");var masked=adapter.authorize(Set.of(rows.getFirst()),false).get(rows.getFirst());assertThat(masked.priceVisible()).isFalse();assertThat(masked.facts()).isEmpty();assertThat(details).hasValue(2);
            login(UUID.randomUUID(),Set.of("test:view","test:price"));assertThatThrownBy(()->adapter.authorize(Set.of(rows.getFirst()),false)).isInstanceOf(ApiException.class);assertThat(details).hasValue(3);
            login(actor,Set.of("test:view","test:price"));adapter.authorize(Set.of(rows.getFirst()),false);assertThat(details).hasValue(4);
        }
    }
    @Test void adapterAndParentIdentityRemainSeparateAndForeignMembershipStillFailsEveryBatch(){
        UUID foreign=UUID.randomUUID();parents.put(foreign,otherParent);var first=adapter();var second=adapter();
        try(var scope=DocumentPlatformReadContext.open()){
            first.authorize(Set.of(rows.getFirst()),false);first.authorize(Set.of(foreign),false);second.authorize(Set.of(rows.getFirst()),false);assertThat(details).hasValue(3);
            assertThatThrownBy(()->first.authorize(Set.of(UUID.randomUUID()),false)).isInstanceOf(ApiException.class);assertThat(details).hasValue(3);assertThat(memberships).hasValue(4);
        }
    }
    @Test void writesAndHistoryAlwaysRunTheirExistingAuthorizerRatherThanTheReadCache(){
        var adapter=adapter();try(var scope=DocumentPlatformReadContext.open()){
            adapter.authorize(Set.of(rows.getFirst()),false);adapter.authorize(Set.of(rows.getFirst()),true);adapter.authorize(Set.of(rows.getFirst()),true);
            adapter.authorizeHistory(Set.of(rows.getFirst()));adapter.authorizeHistory(Set.of(rows.getFirst()));
        }
        assertThat(details).hasValue(5);assertThat(history).hasValue(2);verify(em,times(2)).refresh(any(),eq(LockModeType.PESSIMISTIC_WRITE));
    }
    @Test void rollbackAndAnotherTransactionCannotReuseTheOldProjectionEvenBeforeScopeClose(){
        var adapter=adapter();try(var scope=DocumentPlatformReadContext.open()){
            adapter.authorize(Set.of(rows.getFirst()),false);finish(TransactionSynchronization.STATUS_ROLLED_BACK);begin();
            adapter.authorize(Set.of(rows.getFirst()),false);adapter.authorize(Set.of(rows.getFirst()),false);assertThat(details).hasValue(3);
            try(var fresh=DocumentPlatformReadContext.open()){adapter.authorize(Set.of(rows.getFirst()),false);adapter.authorize(Set.of(rows.getFirst()),false);assertThat(details).hasValue(4);}
        }
    }
    @Test void openingOutsideTheReadonlyRepeatableReadTransactionIsRejected(){
        finish(TransactionSynchronization.STATUS_COMMITTED);assertThatThrownBy(DocumentPlatformReadContext::open).isInstanceOf(IllegalStateException.class);
        begin();TransactionSynchronizationManager.setCurrentTransactionReadOnly(false);assertThatThrownBy(DocumentPlatformReadContext::open).isInstanceOf(IllegalStateException.class);
        TransactionSynchronizationManager.setCurrentTransactionReadOnly(true);TransactionSynchronizationManager.setCurrentTransactionIsolationLevel(Connection.TRANSACTION_READ_COMMITTED);assertThatThrownBy(DocumentPlatformReadContext::open).isInstanceOf(IllegalStateException.class);
    }
}
