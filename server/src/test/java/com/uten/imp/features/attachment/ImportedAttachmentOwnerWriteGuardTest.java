package com.uten.imp.features.attachment;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

import com.uten.imp.application.port.AttachmentOwnerAccessPolicy;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.AuthUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.aop.aspectj.annotation.AspectJProxyFactory;

class ImportedAttachmentOwnerWriteGuardTest {
    @ParameterizedTest @ValueSource(strings={"PROCUREMENT_IQC_REJECTION","EXPENSE_PAYMENT_PROOF","PRODUCTION_QUALITY_INSPECTION"})
    void registeredBusinessAliasesRejectWritesEvenWhenTheOwnerAllowsPendingActions(String type) {
        EntityManager em=mock(EntityManager.class);Query query=mock(Query.class,RETURNS_SELF);
        when(em.createNativeQuery(anyString())).thenReturn(query);when(query.getSingleResult()).thenReturn(true);
        Owner target=new Owner(type,true,true,true);Owner owner=proxy(target,em);UUID id=UUID.randomUUID();
        assertThrows(ApiException.class,()->owner.requireCanManage(id,null));
        assertThrows(ApiException.class,()->owner.requireCanManageForUpdate(id,null));
        assertThrows(ApiException.class,()->owner.requireCanUploadForUpdate(id,null));
        assertThrows(ApiException.class,()->owner.requireCanDeleteForUpdate(id,null));
        assertEquals(List.of("manage","manageUpdate","uploadUpdate","deleteUpdate"),target.actions);
        verify(query,atLeastOnce()).setParameter("ownerType",type);
        clearInvocations(em,query);
        owner.requireCanView(id,null);owner.requireCanViewHistory(id,null);
        verifyNoInteractions(em,query); // Reading originals never grants a write and remains authorized by the owner.
    }

    @ParameterizedTest @ValueSource(strings={"GOODS","EMPLOYEE","COMPANY_FILE"})
    void currentMasterAndCompanyFilePoliciesKeepTheirOwnPermittedActions(String type) {
        EntityManager em=mock(EntityManager.class);Query query=mock(Query.class,RETURNS_SELF);
        when(em.createNativeQuery(anyString())).thenReturn(query);when(query.getSingleResult()).thenReturn(false);
        Owner target=new Owner(type,true,true,true);Owner owner=proxy(target,em);UUID id=UUID.randomUUID();
        owner.requireCanManage(id,null);owner.requireCanUploadForUpdate(id,null);owner.requireCanDeleteForUpdate(id,null);
        assertEquals(List.of("manage","uploadUpdate","deleteUpdate"),target.actions);
    }

    @Test void uploadManageAndDeleteAreNotCollapsedIntoOnePermission() {
        EntityManager em=mock(EntityManager.class);Query query=mock(Query.class,RETURNS_SELF);
        when(em.createNativeQuery(anyString())).thenReturn(query);when(query.getSingleResult()).thenReturn(false);
        Owner owner=proxy(new Owner("COMPANY_FILE",false,true,false),em);UUID id=UUID.randomUUID();
        assertThrows(ApiException.class,()->owner.requireCanManage(id,null));
        verifyNoInteractions(em);
        owner.requireCanUploadForUpdate(id,null);
        clearInvocations(em,query);
        assertThrows(ApiException.class,()->owner.requireCanDeleteForUpdate(id,null));
        verifyNoInteractions(em,query);
    }

    private static Owner proxy(Owner owner,EntityManager em) {
        var factory=new AspectJProxyFactory(owner);factory.setProxyTargetClass(true);
        factory.addAspect(new ImportedAttachmentOwnerWriteGuard(em));
        return factory.getProxy();
    }

    /** Also exposes the newer upload/delete SPI names without overwriting the older interface. */
    public static class Owner implements AttachmentOwnerAccessPolicy {
        private final String type;private final boolean manage,upload,delete;
        final List<String> actions=new ArrayList<>();
        public Owner(String type,boolean manage,boolean upload,boolean delete){this.type=type;this.manage=manage;this.upload=upload;this.delete=delete;}
        public String ownerType(){return type;}
        public void requireCanView(UUID id,AuthUser user){ }
        public void requireCanManage(UUID id,AuthUser user){allowed(manage);actions.add("manage");}
        public void requireCanManageForUpdate(UUID id,AuthUser user){allowed(manage);actions.add("manageUpdate");}
        public void requireCanUploadForUpdate(UUID id,AuthUser user){allowed(upload);actions.add("uploadUpdate");}
        public void requireCanDeleteForUpdate(UUID id,AuthUser user){allowed(delete);actions.add("deleteUpdate");}
        private static void allowed(boolean value){if(!value)throw new ApiException(ErrorCode.FORBIDDEN,"owner action denied");}
    }
}
