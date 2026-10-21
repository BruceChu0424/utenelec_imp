package com.uten.imp.features.master.goods.pricing;

import com.uten.imp.application.port.MasterReferenceValidationPort;
import com.uten.imp.audit.AuditService;
import com.uten.imp.features.master.goods.GoodsMarketBindingWriteAccess;
import com.uten.imp.security.*;
import org.junit.jupiter.api.*;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import java.util.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;
import static com.uten.imp.features.master.goods.pricing.MaterialForecastContracts.*;

class GoodsMarketReferenceServiceTest {
    final UUID id=UUID.randomUUID();
    GoodsPriceAccess access;MasterReferenceValidationPort references;GoodsPriceSourceReader goods;
    GoodsMarketBindingWriteAccess write;GoodsMarketReferenceStore store;MaterialForecastSnapshotReader snapshots;
    SecurityContextCurrentUser current;TxSessionVars tx;AuditService audit;GoodsMarketReferenceService service;
    @BeforeEach void setup(){
        access=mock(GoodsPriceAccess.class);references=mock(MasterReferenceValidationPort.class);goods=mock(GoodsPriceSourceReader.class);write=mock(GoodsMarketBindingWriteAccess.class);store=mock(GoodsMarketReferenceStore.class);snapshots=mock(MaterialForecastSnapshotReader.class);current=mock(SecurityContextCurrentUser.class);tx=mock(TxSessionVars.class);audit=mock(AuditService.class);
        var actor=new AuthUser(UUID.randomUUID(),UUID.randomUUID(),"market-test",Set.of("goods:view","goods:edit","goods:price_analysis:view","purchase_order:view","purchase_order:price:view"),false,true,false);
        when(current.get()).thenReturn(Optional.of(actor));SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(actor,"",actor.getAuthorities()));
        when(store.find(id)).thenReturn(new GoodsMarketReferenceStore.Binding(null,0,null));when(snapshots.enabled()).thenReturn(true);
        service=new GoodsMarketReferenceService(access,references,goods,write,store,snapshots,current,tx,audit);
    }
    @AfterEach void clear(){SecurityContextHolder.clearContext();}
    @Test void everyReadChecksGoodsAndPurchaseAuthorityBeforeAnyMarketFile(){service.get(id);verify(access).require(GoodsPriceContracts.Kind.PURCHASE);verify(references).requireVisibleGoods(id);verify(goods).goods(id);assertThat(service.get(id).status()).isEqualTo("UNMAPPED");verify(snapshots,never()).read(any());}
    @Test void revokedPurchaseAuthorityCannotReadACatalog(){doThrow(new com.uten.imp.common.web.ApiException(com.uten.imp.common.web.ErrorCode.FORBIDDEN)).when(access).require(GoodsPriceContracts.Kind.PURCHASE);assertThatThrownBy(()->service.catalog(id)).isInstanceOf(com.uten.imp.common.web.ApiException.class);verifyNoInteractions(snapshots,store);}
    @Test void unlinkRetainsANewVersionAndRecordsATransactionalAudit(){when(store.find(id)).thenReturn(new GoodsMarketReferenceStore.Binding("copper",4,"a".repeat(64)));var result=service.put(id,new BindingRequest(null,4L));verify(write).requireWritableAndLock(id);verify(store).compareAndSet(eq(id),isNull(),isNull(),eq(4L),any());assertThat(result.bindingVersion()).isEqualTo(5);assertThat(result.status()).isEqualTo("UNMAPPED");verify(audit).logCommittedChange(any(),anyString(),eq("update_goods_market_reference"),eq("goods"),eq(id.toString()),anyString(),anyMap());}
    @Test void foreignWritableScopeDenialStopsBindingAndAudit(){doThrow(new com.uten.imp.common.web.ApiException(com.uten.imp.common.web.ErrorCode.NOT_FOUND)).when(write).requireWritableAndLock(id);assertThatThrownBy(()->service.put(id,new BindingRequest(null,0L))).isInstanceOf(com.uten.imp.common.web.ApiException.class);verify(store,never()).compareAndSet(any(),any(),any(),anyLong(),any());verifyNoInteractions(audit);}
    @Test void staleVersionCannotOverwriteARelinkedTombstone(){when(store.find(id)).thenReturn(new GoodsMarketReferenceStore.Binding(null,3,null));assertThatThrownBy(()->service.put(id,new BindingRequest(null,0L))).hasMessageContaining("刷新");verify(store,never()).compareAndSet(any(),any(),any(),anyLong(),any());}
    @Test void changedInstrumentIdentityRequiresExplicitRelinking(){
        var snapshot=mock(Snapshot.class);when(snapshots.read("copper")).thenReturn(new MaterialForecastSnapshotReader.Read("READY",snapshot,List.of()));when(snapshots.identityDigest(snapshot)).thenReturn("new");when(store.find(id)).thenReturn(new GoodsMarketReferenceStore.Binding("copper",4,"old"));
        var result=service.get(id);assertThat(result.status()).isEqualTo("UNAVAILABLE");assertThat(result.current()).isNull();assertThat(result.reasonCodes()).containsExactly("MARKET_REFERENCE_IDENTITY_CHANGED");
    }
    @Test void requestWithoutEditAuthorityIsRejectedEvenOutsideController(){SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken("reader","",List.of()));assertThatThrownBy(()->service.put(id,new BindingRequest(null,0L))).hasMessageContaining("goods:edit");verifyNoInteractions(tx,write,audit);}
}
