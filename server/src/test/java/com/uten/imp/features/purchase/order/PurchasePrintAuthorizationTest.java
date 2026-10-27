package com.uten.imp.features.purchase.order;

import com.uten.imp.common.web.*;
import com.uten.imp.security.*;
import org.junit.jupiter.api.Test;
import java.time.LocalDate;
import java.util.*;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

class PurchasePrintAuthorizationTest {
    private com.uten.imp.common.export.ProcurementOrderPrintDocument document(UUID id,String supplier,boolean masked) {
        return new com.uten.imp.common.export.ProcurementOrderPrintDocument(id,"CD-1",LocalDate.of(2026,10,26),null,"合成公司","000",supplier,"原始联系人","123","仓库",
                masked?"":"人民币",masked?"":"CNY","现金",masked?null:"1234567890123456.00000001",masked,"原文","制单员","财务审核员","财务已通过",List.of(),true,"PURCHASE");
    }
    @Test void theOpaqueDigestIsStableAndBindsOriginalContentAndPriceMask() throws Exception {
        UUID id=UUID.randomUUID();var original=document(id,"合成供应商",false);
        assertTrue(original.contentDigest().matches("[0-9a-f]{64}"));
        assertEquals(original.contentDigest(),document(id,"合成供应商",false).contentDigest());
        assertNotEquals(original.contentDigest(),document(id,"已修改供应商",false).contentDigest());
        assertNotEquals(original.contentDigest(),document(id,"合成供应商",true).contentDigest());
        String json=new com.fasterxml.jackson.databind.ObjectMapper().findAndRegisterModules().writeValueAsString(original);
        assertTrue(json.contains("\"contentDigest\":\""+original.contentDigest()+"\""));
    }
    @Test void changedOrUnauthorizedSnapshotsCannotAuthorizeTheBatchOrReplaceAnAlreadyRenderedPdf() {
        var reader=mock(PurchaseOrderPrintService.class);var users=mock(SecurityContextCurrentUser.class);var scopes=mock(ReadScopeVersionAuthority.class);
        var actor=new AuthUser(UUID.randomUUID(),UUID.randomUUID(),"fixture",Set.of("purchase_order:view"),false,true,false);
        when(users.get()).thenReturn(Optional.of(actor));when(scopes.scopeFor("native_purchase_owner",actor,false)).thenReturn("scope-A");
        var service=new PurchasePrintAuthorizationService(reader,users,scopes);
        UUID first=UUID.randomUUID(),second=UUID.randomUUID();
        var a=document(first,"原始供应商",false);var b=document(second,"原始供应商",false);
        var proofs=List.of(new PurchasePrintAuthorizationController.DocumentProof(first,a.contentDigest()),new PurchasePrintAuthorizationController.DocumentProof(second,b.contentDigest()));
        when(reader.read(first)).thenReturn(a);when(reader.read(second)).thenReturn(b);
        assertDoesNotThrow(()->service.authorize(proofs));
        when(reader.read(second)).thenReturn(document(second,"已修改供应商",false));
        assertEquals(ErrorCode.CONFLICT,assertThrows(ApiException.class,()->service.authorize(proofs)).getCode());
        when(reader.read(second)).thenThrow(new ApiException(ErrorCode.FORBIDDEN));
        assertEquals(ErrorCode.FORBIDDEN,assertThrows(ApiException.class,()->service.authorize(proofs)).getCode());
        when(scopes.scopeFor("native_purchase_owner",actor,false)).thenReturn("scope-A","scope-B");
        assertEquals(ErrorCode.READ_SCOPE_CHANGED,assertThrows(ApiException.class,()->service.authorize(proofs.subList(0,1))).getCode());
    }
    @Test void duplicateDocumentIdentitiesAreRejectedBeforeAnyFactsAreRead() {
        var reader=mock(PurchaseOrderPrintService.class);var service=new PurchasePrintAuthorizationService(reader,mock(SecurityContextCurrentUser.class),mock(ReadScopeVersionAuthority.class));
        var proof=new PurchasePrintAuthorizationController.DocumentProof(UUID.randomUUID(),"a".repeat(64));
        assertThrows(ApiException.class,()->service.authorize(List.of(proof,proof)));verifyNoInteractions(reader);
    }
}
