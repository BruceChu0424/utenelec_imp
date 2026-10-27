package com.uten.imp.common.export;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.PageResponse;
import jakarta.persistence.*;
import jakarta.persistence.criteria.*;
import org.junit.jupiter.api.*;
import org.springframework.data.domain.*;
import org.springframework.data.jpa.domain.Specification;
import org.springframework.data.jpa.repository.JpaSpecificationExecutor;
import org.springframework.transaction.support.TransactionSynchronizationManager;

import java.sql.Connection;
import java.math.BigDecimal;
import java.util.*;
import java.util.concurrent.CancellationException;
import java.util.concurrent.atomic.*;
import java.util.stream.IntStream;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class MasterExportSourceTest {
    record Item(int id) { }
    final EntityManager em = mock(EntityManager.class);
    final List<ExportColumn> columns = List.of(new ExportColumn("value", "原值", ExportColumn.QTY));
    @AfterEach void clearTransaction() { TransactionSynchronizationManager.clear(); Thread.interrupted(); }

    private static Map<String,Object> row(Item item) {
        Map<String,Object> row = new LinkedHashMap<>();
        row.put("_platformRecordId", item.id());
        row.put("value", new BigDecimal("12345678901234567890.000100"));
        row.put("unknown", null);
        row.put("original", "=1+1");
        return row;
    }
    private static PageResponse<Item> legacyPage(int page, int size, int count) {
        return new PageResponse<>(IntStream.range((page-1)*size, Math.min(count,page*size)).mapToObj(Item::new).toList(),
                page,size,count,(count+size-1)/size);
    }
    private static void snapshot() {
        TransactionSynchronizationManager.setActualTransactionActive(true);
        TransactionSynchronizationManager.setCurrentTransactionReadOnly(true);
        TransactionSynchronizationManager.setCurrentTransactionIsolationLevel(Connection.TRANSACTION_REPEATABLE_READ);
    }

    @Test void smallCompatibilityKeepsEveryExactValueAndRealCount() {
        var result = MasterExportSource.exportEntities(em,columns,1000,(page,size)->legacyPage(page,size,201),MasterExportSourceTest::row);
        assertThat(result.total()).isEqualTo(201); assertThat(result.rows()).hasSize(201);
        assertThat(result.rows().getLast()).containsEntry("_platformRecordId",200).containsEntry("unknown",null)
                .containsEntry("value",new BigDecimal("12345678901234567890.000100")).containsEntry("original","=1+1");
        verify(em,never()).clear(); // The bounded compatibility path does not own the caller's persistence context.
    }
    @Test void largeCompatibilityRejectsBeforeMappingInsteadOfReturningFirstFiveHundred() {
        AtomicInteger mapped=new AtomicInteger();
        assertThatThrownBy(()->MasterExportSource.exportEntities(em,columns,1000,(page,size)->legacyPage(page,size,501),item->{mapped.incrementAndGet();return row(item);}))
                .isInstanceOf(ApiException.class).hasMessageContaining("后台导出任务");
        assertThat(mapped).hasValue(0);
    }
    @Test void exportCannotDiscardPendingWritesFromAnOuterWriteTransaction() {
        TransactionSynchronizationManager.setActualTransactionActive(true);
        TransactionSynchronizationManager.setCurrentTransactionReadOnly(false);
        assertThatThrownBy(()->MasterExportSource.exportEntities(em,columns,1000,
                (page,size)->legacyPage(page,size,1),MasterExportSourceTest::row))
                .isInstanceOf(IllegalStateException.class).hasMessageContaining("write transaction");
        verifyNoInteractions(em);
    }
    @Test void streamedHundredThousandRowsUseOneCursorOneCountAndOneHundredManagedEntities() {
        snapshot(); var fixture=cursor(100_000); AtomicInteger emitted=new AtomicInteger();
        try(var ignored=ExportPageSink.open(page->{
            assertThat(page.rows()).hasSize(100); emitted.addAndGet(page.rows().size());
            assertThat(page.total()).isEqualTo(emitted.get());
        })) {
            var result=MasterExportSource.exportEntities(em,columns,100_000,fixture::page,MasterExportSourceTest::row);
            assertThat(result.rows()).isEmpty(); assertThat(result.total()).isEqualTo(100_000);
        }
        assertThat(emitted).hasValue(100_000); assertThat(fixture.closed).isTrue();
        verify(fixture.repository,times(1)).count(fixture.specification);
        verify(fixture.repository,never()).findAll(org.mockito.ArgumentMatchers.<Specification<Item>>notNull(),any(Pageable.class));
        verify(em,times(1001)).clear();
    }
    @Test void sinkFailureClosesCursorAndRestoresOrdinaryListMode() {
        snapshot(); var fixture=cursor(500); AtomicInteger pages=new AtomicInteger();
        try(var ignored=ExportPageSink.open(page->{if(pages.incrementAndGet()==2)throw new IllegalStateException("disk fixture");})) {
            assertThatThrownBy(()->MasterExportSource.exportEntities(em,columns,1000,fixture::page,MasterExportSourceTest::row))
                    .isInstanceOf(IllegalStateException.class).hasMessage("disk fixture");
        }
        assertThat(fixture.closed).isTrue();
        Pageable page=PageRequest.of(0,100);
        Page<Item> ordinary=new PageImpl<>(List.of(new Item(7)),page,1);
        when(fixture.repository.findAll(fixture.specification,page)).thenReturn(ordinary);
        assertThat(MasterExportSource.page(fixture.repository,em,Item.class,fixture.specification,page)).isSameAs(ordinary);
    }
    @Test void aMutableFilterCannotChangeBetweenBatchesWhileKeepingTheSameCount() {
        snapshot(); var fixture=cursor(250); Map<String,Object> filter=new LinkedHashMap<>(Map.of("code","original"));
        try(var ignored=ExportPageSink.open(page->filter.put("code","changed"))) {
            assertThatThrownBy(()->MasterExportSource.exportEntities(em,columns,1000,
                    (page,size)->fixture.page(page,size,filter),MasterExportSourceTest::row))
                    .isInstanceOf(IllegalStateException.class).hasMessageContaining("conditions changed");
        }
        assertThat(fixture.closed).isTrue();
    }
    @Test void cancellationAndMissingSnapshotNeverLeaveAnActiveSource() {
        try(var ignored=ExportPageSink.open(page->{})) {
            assertThatThrownBy(()->MasterExportSource.exportEntities(em,columns,1000,(page,size)->legacyPage(page,size,1),MasterExportSourceTest::row))
                    .isInstanceOf(IllegalStateException.class).hasMessageContaining("repeatable-read");
        }
        snapshot(); var fixture=cursor(500);
        try(var ignored=ExportPageSink.open(page->Thread.currentThread().interrupt())) {
            assertThatThrownBy(()->MasterExportSource.exportEntities(em,columns,1000,fixture::page,MasterExportSourceTest::row))
                    .isInstanceOf(CancellationException.class);
        }
        assertThat(fixture.closed).isTrue();
    }

    @SuppressWarnings({"unchecked","rawtypes"})
    private Fixture cursor(int count) {
        var repository=mock(JpaSpecificationExecutor.class);
        Specification<Item> specification=(root,query,cb)->null;
        when(repository.count(specification)).thenReturn((long)count);
        CriteriaBuilder cb=mock(CriteriaBuilder.class); CriteriaQuery<Item> criteria=mock(CriteriaQuery.class);
        Root<Item> root=mock(Root.class); Path<Object> id=mock(Path.class);
        jakarta.persistence.criteria.Order order=mock(jakarta.persistence.criteria.Order.class);
        TypedQuery<Item> typed=mock(TypedQuery.class); org.hibernate.query.Query<Item> query=mock(org.hibernate.query.Query.class);
        when(em.getCriteriaBuilder()).thenReturn(cb); when(cb.createQuery(Item.class)).thenReturn(criteria);
        when(criteria.from(Item.class)).thenReturn(root); when(criteria.getOrderList()).thenReturn(List.of());
        when(root.get("id")).thenReturn(id); when(cb.asc(id)).thenReturn(order); when(em.createQuery(criteria)).thenReturn(typed);
        when(typed.unwrap(org.hibernate.query.Query.class)).thenReturn(query);
        when(query.setReadOnly(true)).thenReturn(query); when(query.setCacheable(false)).thenReturn(query); when(query.setFetchSize(100)).thenReturn(query);
        AtomicBoolean closed=new AtomicBoolean(); AtomicInteger managed=new AtomicInteger();
        when(query.getResultStream()).thenAnswer(call->IntStream.range(0,count).mapToObj(index->{managed.incrementAndGet();return new Item(index);}).onClose(()->closed.set(true)));
        doAnswer(call->{assertThat(managed.getAndSet(0)).isLessThanOrEqualTo(100);return null;}).when(em).clear();
        return new Fixture(em,repository,specification,closed);
    }
    record Fixture(EntityManager em,JpaSpecificationExecutor<Item> repository,Specification<Item> specification,AtomicBoolean closed) {
        PageResponse<Item> page(int page,int size) {
            return page(page,size,null);
        }
        PageResponse<Item> page(int page,int size,Object filter) {
            Page<Item> entities=MasterExportSource.page(repository,em,Item.class,specification,PageRequest.of(page-1,size),filter);
            return new PageResponse<>(entities.getContent(),entities);
        }
    }
}
