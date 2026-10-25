package com.uten.imp.support;

import com.uten.imp.common.history.DocumentHistoryMetadata;
import com.uten.imp.common.history.ImportedBusinessDocumentPolicy;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.sales.order.SalesOrder;
import com.uten.imp.features.stock.StockBalance;
import com.uten.imp.features.stock.StockBalanceRepository;
import com.uten.imp.features.stock.StockCostMasker;
import com.uten.imp.features.stock.StockQueryService;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.springframework.data.domain.PageImpl;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.domain.Specification;

import java.math.BigDecimal;
import java.time.Instant;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

class ImportedDocumentFixtureTest {
    @Test void nativeAndProvenanceOnlyImportedIdsHaveDifferentRealPolicyOutcomes() {
        EntityManager base=mock(EntityManager.class);
        SalesOrder nativeOrder=new SalesOrder(),parentImported=new SalesOrder();
        var facts=new ImportedDocumentFixture();
        facts.document("sales_orders",nativeOrder);
        facts.document("sales_orders",parentImported);
        facts.importedId("sales_orders",parentImported.getId());
        assertThat(ImportedBusinessDocumentPolicy.mutable(facts.entityManager(base),"sales_orders",nativeOrder))
                .isSameAs(nativeOrder);
        assertThatThrownBy(()->ImportedBusinessDocumentPolicy.mutable(facts.entityManager(base),"sales_orders",parentImported))
                .isInstanceOf(ApiException.class);
        assertThat(facts.originReadCount("sales_orders",parentImported.getId())).isEqualTo(1);
        verifyNoInteractions(base);
    }

    @Test void unknownTableIdAndControlQueryNeverDefaultToNative() {
        EntityManager base=mock(EntityManager.class);
        var facts=new ImportedDocumentFixture().nativeId("sales_orders",UUID.randomUUID());
        assertThatThrownBy(()->facts.imported("sales_orders",UUID.randomUUID())).isInstanceOf(AssertionError.class);
        assertThatThrownBy(()->facts.imported("purchase_orders",UUID.randomUUID())).isInstanceOf(AssertionError.class);
        assertThatThrownBy(()->facts.query("SELECT arbitrary_origin(:id)" )).isInstanceOf(AssertionError.class);
        assertThatThrownBy(()->facts.entityManager(base).createNativeQuery("SELECT fn_imported_business_document(:table,:id) WHERE false"))
                .isInstanceOf(AssertionError.class);
        verifyNoInteractions(base);
    }

    @Test void loadedLegacyIdentityCannotBeDeclaredNativeAndEntityTableMustMatch() {
        SalesOrder legacy=new SalesOrder();legacy.setLegacyId(17);
        var facts=new ImportedDocumentFixture();facts.document("sales_orders",legacy);
        assertThat(facts.imported("sales_orders",legacy.getId())).isTrue();
        facts.nativeId("sales_orders",legacy.getId());
        assertThatThrownBy(()->facts.imported("sales_orders",legacy.getId())).isInstanceOf(AssertionError.class);
        var wrong=new ImportedDocumentFixture();wrong.document("purchase_orders",legacy);
        assertThatThrownBy(()->wrong.imported("purchase_orders",legacy.getId())).isInstanceOf(AssertionError.class);
    }

    @Test void realReaderCopiesImportedReadOnlyAndPreservesDeletionEvidence() {
        EntityManager base=mock(EntityManager.class);
        UUID imported=UUID.randomUUID(),deleted=UUID.randomUUID();
        var facts=new ImportedDocumentFixture().importedId("sales_orders",imported).nativeId("sales_orders",deleted);
        DocumentHistoryMetadata history=facts.reader(base).detail(new DocumentHistoryMetadata(),"sales_orders",imported,false,null,false);
        assertThat(history.isLegacyImported()).isTrue();
        assertThat(history.isHistoryReadOnly()).isTrue();
        assertThat(history.isDeleted()).isFalse();
        facts.deletionHistory("sales_orders",deleted,Instant.parse("2026-10-25T00:00:00Z"),"fixture actor","fixture reason");
        DocumentHistoryMetadata removed=facts.reader(base).detail(new DocumentHistoryMetadata(),"sales_orders",deleted,true,null,false);
        assertThat(removed.isDeleted()).isTrue();
        assertThat(removed.getDeletedReason()).isEqualTo("fixture reason");
        assertThat(removed.getDeletedByName()).isEqualTo("fixture actor");
        verifyNoInteractions(base);
    }

    @Test void emptyRealReaderPageDoesNotManufactureAQuery() {
        EntityManager base=mock(EntityManager.class);
        var page=new PageResponse<DocumentHistoryMetadata>(List.of(),1,20,0,0);
        assertThat(new ImportedDocumentFixture().reader(base).page(page,"sales_orders",List.<SalesOrder>of())).isSameAs(page);
        verifyNoInteractions(base);
    }

    @Test void businessSqlStillUsesTheOriginalStrictFixtureManager() {
        EntityManager base=mock(EntityManager.class);Query business=mock(Query.class);
        when(base.createNativeQuery("SELECT fixture_business_fact")).thenReturn(business);
        var facts=new ImportedDocumentFixture();
        assertThat(facts.entityManager(base).createNativeQuery("SELECT fixture_business_fact")).isSameAs(business);
        verify(base).createNativeQuery("SELECT fixture_business_fact");
    }

    @Test void registeredNativeBalanceDoesNotInventMissingMeasurementFacts() {
        EntityManager base=mock(EntityManager.class);StockBalanceRepository balances=mock(StockBalanceRepository.class);
        StockBalance balance=new StockBalance();balance.setQty(BigDecimal.ONE);
        when(balances.findAll(org.mockito.Mockito.<Specification<StockBalance>>any(),any(Pageable.class)))
                .thenReturn(new PageImpl<>(List.of(balance)));
        var facts=new ImportedDocumentFixture().nativeId("stock_balances",balance.getId());
        StockQueryService service=facts.wire(new StockQueryService(balances,base,mock(StockCostMasker.class)),base);
        assertThatThrownBy(()->service.balances(null,null,1,20,null,null)).isInstanceOf(AssertionError.class)
                .hasMessageContaining("Unregistered measurement");
        facts.measurement(balance.getId(),true,"MISSING_BASE_UNIT");
        var result=service.balances(null,null,1,20,null,null).getItems().getFirst();
        assertThat(result.isMeasurementPending()).isTrue();
        assertThat(result.getMeasurementHoldReason()).isEqualTo("MISSING_BASE_UNIT");
        verifyNoInteractions(base);
    }

    @Test void wrongBoundTableAndUnknownDeletionHistoryAreRejected() {
        EntityManager base=mock(EntityManager.class);UUID id=UUID.randomUUID();
        var facts=new ImportedDocumentFixture().nativeId("sales_orders",id);
        Query query=facts.query("SELECT id, fn_imported_business_document(:table,id) FROM public.sales_orders WHERE id IN (:ids)");
        query.setParameter("table","purchase_orders").setParameter("ids",List.of(id));
        assertThatThrownBy(query::getResultList).isInstanceOf(AssertionError.class);
        assertThatThrownBy(()->facts.reader(base).detail(new DocumentHistoryMetadata(),"sales_orders",id,true,OffsetDateTime.now(),false))
                .isInstanceOf(AssertionError.class).hasMessageContaining("Unregistered deletion history");
    }
}
