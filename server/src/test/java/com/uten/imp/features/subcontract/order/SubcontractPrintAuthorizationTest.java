package com.uten.imp.features.subcontract.order;

import com.uten.imp.common.export.*;
import com.uten.imp.common.web.*;
import com.uten.imp.security.*;
import org.junit.jupiter.api.Test;
import java.util.*;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

class SubcontractPrintAuthorizationTest {
    private ProcurementOrderPrintDocument document(UUID id, boolean approved, String supplier) {
        return new ProcurementOrderPrintDocument(id,"WD-1",null,null,"公司","",supplier,"","","仓库",
                "人民币","CNY","月结","123456789.000001",false,"","制单员",approved?"审核员":"",
                approved?"财务已通过":"等待财务审核",List.of(),approved,"SUBCONTRACT");
    }
    @Test void pendingSnapshotsCanAuthorizeWhileChangedFactsAndOwnerScopeCannot() {
        var users=mock(SecurityContextCurrentUser.class);var scopes=mock(ReadScopeVersionAuthority.class);
        var reader=mock(SubcontractOrderPrintService.class);
        var actor=new AuthUser(UUID.randomUUID(),UUID.randomUUID(),"fixture",Set.of("subcontract_order:view"),false,true,false);
        when(users.get()).thenReturn(Optional.of(actor));
        when(scopes.scopeFor("native_subcontract_owner",actor,false)).thenReturn("scope-A");
        var controller=new SubcontractPrintAuthorizationController(reader,users,scopes);
        UUID id=UUID.randomUUID();var original=document(id,false,"原始委外商");
        var request=new SubcontractPrintAuthorizationController.Request(List.of(
                new SubcontractPrintAuthorizationController.DocumentProof(id,original.contentDigest())));
        doReturn(original).when(reader).read(id);
        var servlet=mock(jakarta.servlet.http.HttpServletRequest.class);
        assertEquals(204,controller.authorize(request,servlet).getStatusCode().value());
        when(reader.read(id)).thenReturn(document(id,true,"原始委外商"));
        assertEquals(ErrorCode.CONFLICT,assertThrows(ApiException.class,()->controller.authorize(request,servlet)).getCode());
        when(reader.read(id)).thenThrow(new ApiException(ErrorCode.NOT_FOUND));
        assertEquals(ErrorCode.NOT_FOUND,assertThrows(ApiException.class,()->controller.authorize(request,servlet)).getCode());
        doReturn(original).when(reader).read(id);
        when(scopes.scopeFor("native_subcontract_owner",actor,false)).thenReturn("scope-A","scope-B");
        assertEquals(ErrorCode.READ_SCOPE_CHANGED,assertThrows(ApiException.class,()->controller.authorize(request,servlet)).getCode());
    }
    @Test void digestBindsTheModuleEvenWhenRenderedFactsOtherwiseMatch() {
        UUID id=UUID.randomUUID();var subcontract=document(id,false,"供应商");
        var purchase=new ProcurementOrderPrintDocument(id,"WD-1",null,null,"公司","","供应商","","","仓库",
                "人民币","CNY","月结","123456789.000001",false,"","制单员","","等待财务审核",List.of(),false,"PURCHASE");
        assertNotEquals(subcontract.contentDigest(),purchase.contentDigest());
    }
}
