package com.uten.imp.features.master.goods.history;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.features.master.history.MasterVersionRow;
import com.uten.imp.features.master.lifecycle.MasterReferenceGuard;
import com.uten.imp.security.*;
import jakarta.persistence.EntityManager;
import org.junit.jupiter.api.Test;
import java.util.*;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

class GoodsFieldHistoryPermissionTest {
    @Test void historyRestorationChecksTheChangedGroupInsteadOfTheFormerBroadEditGrant() throws Exception {
        var mapper=new ObjectMapper();
        var current=mock(SecurityContextCurrentUser.class);
        var service=new GoodsOperationHistoryService(mock(EntityManager.class),mapper,current,mock(TxSessionVars.class),
                mock(MasterReferenceGuard.class),mock(OwnerVisibility.class),mock(BusinessEventPublisher.class));
        var purchase=new MasterVersionRow("goods",UUID.randomUUID(),mapper.readTree("{\"min_order_qty\":20}"),mapper.readTree("{\"min_order_qty\":10}"));
        var sales=new MasterVersionRow("goods",UUID.randomUUID(),mapper.readTree("{\"c_number\":\"B\"}"),mapper.readTree("{\"c_number\":\"A\"}"));
        when(current.get()).thenReturn(Optional.of(actor("goods:edit")));
        assertTrue(service.versionRestorePermissionReason(List.of(purchase)).contains("goods:purchase:edit"));
        assertTrue(service.versionRestorePermissionReason(List.of(sales)).contains("goods:sales:edit"));
        when(current.get()).thenReturn(Optional.of(actor("goods:purchase:edit")));
        assertNull(service.versionRestorePermissionReason(List.of(purchase)));
        assertNotNull(service.versionRestorePermissionReason(List.of(sales)));
        when(current.get()).thenReturn(Optional.of(actor("goods:sales:edit")));
        assertNull(service.versionRestorePermissionReason(List.of(sales)));
    }
    @Test void costVersionRestorationRequiresBaseEditAndCostVisibilityTogether() throws Exception {
        var mapper=new ObjectMapper();var current=mock(SecurityContextCurrentUser.class);
        var service=new GoodsOperationHistoryService(mock(EntityManager.class),mapper,current,mock(TxSessionVars.class),mock(MasterReferenceGuard.class),mock(OwnerVisibility.class),mock(BusinessEventPublisher.class));
        var cost=new MasterVersionRow("goods",UUID.randomUUID(),mapper.readTree("{\"g_total\":20}"),mapper.readTree("{\"g_total\":10}"));
        when(current.get()).thenReturn(Optional.of(actor("goods:cost:view")));
        assertTrue(service.versionRestorePermissionReason(List.of(cost)).contains("goods:edit"));
        when(current.get()).thenReturn(Optional.of(actor("goods:edit")));
        assertTrue(service.versionRestorePermissionReason(List.of(cost)).contains("goods:cost:view"));
        when(current.get()).thenReturn(Optional.of(actor("goods:edit","goods:cost:view")));
        assertNull(service.versionRestorePermissionReason(List.of(cost)));
    }
    private static AuthUser actor(String... permissions) {
        var codes=new HashSet<>(Arrays.asList(permissions));codes.add("goods:view");
        return new AuthUser(UUID.randomUUID(),UUID.randomUUID(),"field-history",codes,false,true,false);
    }
}
