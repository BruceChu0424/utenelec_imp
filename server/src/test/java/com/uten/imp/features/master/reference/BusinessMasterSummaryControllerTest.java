package com.uten.imp.features.master.reference;

import com.uten.imp.application.port.CurrentStaffAuthorityPort;
import com.uten.imp.common.readsnapshot.*;
import com.uten.imp.common.web.*;
import com.uten.imp.config.Jackson2ObjectMapperAutoConfiguration;
import com.uten.imp.features.master.client.ClientService;
import com.uten.imp.features.master.supplier.SupplierService;
import com.uten.imp.features.master.goods.GoodsService;
import com.uten.imp.features.master.goods.dto.*;
import org.junit.jupiter.api.Test;
import org.springframework.mock.web.*;
import org.springframework.security.access.prepost.PreAuthorize;
import java.math.BigDecimal;
import java.util.*;
import java.util.function.Supplier;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class BusinessMasterSummaryControllerTest {
    @Test void businessOnlyReadersRetainNarrowPartyAndGoodsProjectionWithoutMasterPermission() throws Exception {
        var json=Jackson2ObjectMapperAutoConfiguration.domainObjectMapper();var pages=mock(VersionedSummaryPages.class);
        var proofs=new ArrayList<VersionedSummaryPages.Request>();
        when(pages.read(any(),any(Runnable.class),any())).thenAnswer(call->{proofs.add(call.getArgument(0));call.getArgument(1,Runnable.class).run();return new VersionedSummaryPages.Snapshot<>(call.getArgument(2,Supplier.class).get(),"a".repeat(64),"b".repeat(64),"c".repeat(64));});
        var staff=mock(CurrentStaffAuthorityPort.class);when(staff.currentStaffPermissions()).thenReturn(Set.of("sales_order:create","purchase_order:create"));
        var clients=mock(ClientService.class);var suppliers=mock(SupplierService.class);var goods=mock(GoodsService.class);
        var party=new PartyReference(UUID.randomUUID(),"P001","中文引用",UUID.randomUUID(),"使用",null,true);
        when(clients.referencePage(any(),any(),anyBoolean(),anyBoolean(),eq(1),eq(100))).thenReturn(new PageResponse<>(List.of(party),1,100,1,1));
        when(suppliers.referencePage(any(),any(),anyBoolean(),eq(1),eq(100))).thenReturn(new PageResponse<>(List.of(party),1,100,1,1));
        var row=mock(GoodsListItem.class);when(row.getId()).thenReturn(UUID.randomUUID());when(row.getName()).thenReturn("业务货品");when(row.getStockQty()).thenReturn(new BigDecimal("1.000001"));when(row.getStockQtyDisplayText()).thenReturn("1.000001");
        when(goods.list(any(),eq(1),eq(100),isNull(),isNull())).thenReturn(new PageResponse<>(List.of(row),1,100,1,1));
        var access=new BusinessMasterReferenceAccess(staff);var controller=new BusinessMasterSummaryController(access,clients,suppliers,goods,new MasterSummaryReadSupport(pages,json));
        var search=new BusinessMasterReferenceController.PartySearch("中文%_",party.categoryId(),null,null);
        var partyBody=new BusinessMasterSummaryController.PartyQuery(search,1,100);
        var clientResult=controller.clients(partyBody,null,new MockHttpServletRequest(),new MockHttpServletResponse());
        var supplierResult=controller.suppliers(partyBody,null,new MockHttpServletRequest(),new MockHttpServletResponse());
        assertThat(clientResult.value().items()).containsExactly(party);assertThat(supplierResult.value().items()).containsExactly(party);
        String encoded=json.writeValueAsString(clientResult);assertThat(encoded).doesNotContain("mobile","bankAccount","credit","writable");
        verify(clients).referencePage(party.categoryId(),"中文%_",true,true,1,100);verify(suppliers).referencePage(party.categoryId(),"中文%_",true,1,100);
        var query=json.convertValue(Map.of("filter",Map.of("excludeDisabled",true),"page",1,"size",100),GoodsSearchRequest.class);
        var projected=controller.goods(query,null,new MockHttpServletRequest(),new MockHttpServletResponse()).value().items().getFirst();
        assertThat(projected).doesNotContainKeys("stockQty","stockQtyDisplayText","paper","requireRemark","ownerEmployeeId");assertThat(projected.get("writable")).isEqualTo(false);
        when(staff.currentStaffPermissions()).thenReturn(Set.of("sales_order:create","goods:view"));
        var stock=controller.goods(query,null,new MockHttpServletRequest(),new MockHttpServletResponse()).value().items().getFirst();
        assertThat(stock.get("stockQtyDisplayText")).isEqualTo("1.000001");
        assertThat(proofs).extracting(VersionedSummaryPages.Request::authorizationDomain).containsExactly("client","supplier","master_goods","master_goods");
        assertThat(json.writeValueAsString(proofs.get(0).queryIdentity())).contains("business-reference-client");
        assertThat(BusinessMasterSummaryController.class.getAnnotation(PreAuthorize.class).value()).isEqualTo("isAuthenticated() and !principal.visitor");
        when(staff.currentStaffPermissions()).thenReturn(Set.of());
        assertThatThrownBy(()->controller.clients(partyBody,null,new MockHttpServletRequest(),new MockHttpServletResponse())).isInstanceOf(ApiException.class);
    }
}
