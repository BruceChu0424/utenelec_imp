package com.uten.imp.features.applications;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.security.AuthUser;
import org.junit.jupiter.api.Test;
import java.util.*;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

class BusinessApplicationAttachmentPolicyTest {
    @Test void originalEvidenceOnlyApplicantCanChangeEditableDraftWithMatchingKindGrant(){
        UUID id=UUID.randomUUID(),employee=UUID.randomUUID();var service=mock(BusinessApplicationService.class);
        var policy=new BusinessApplicationAttachmentPolicy(service).applicationOriginals();
        var row=new HashMap<String,Object>(Map.of("id",id,"applicant_id",employee,"status","DRAFT","kind","TRAVEL"));
        when(service.row(id,true)).thenReturn(row);
        var owner=new AuthUser(UUID.randomUUID(),employee,"fixture",Set.of("application:apply:travel"),false,true,false);
        policy.requireCanManageForUpdate(id,owner);
        row.put("status","REJECTED");policy.requireCanManageForUpdate(id,owner);
        row.put("status","SUBMITTED");assertThrows(ApiException.class,()->policy.requireCanManageForUpdate(id,owner));
        row.put("status","DRAFT");
        var wrongKind=new AuthUser(UUID.randomUUID(),employee,"fixture",Set.of("application:apply:payment"),false,true,false);
        assertThrows(ApiException.class,()->policy.requireCanManageForUpdate(id,wrongKind));
        var stranger=new AuthUser(UUID.randomUUID(),UUID.randomUUID(),"fixture",Set.of("application:apply"),false,true,false);
        assertThrows(ApiException.class,()->policy.requireCanManageForUpdate(id,stranger));
        var readOnly=new AuthUser(UUID.randomUUID(),employee,"fixture",Set.of("application:apply"),false,true,false,false,UUID.randomUUID());
        assertThrows(ApiException.class,()->policy.requireCanManageForUpdate(id,readOnly));
    }
    @Test void paymentEvidenceRequiresLivePaymentCapabilityAndNeverApplicantOwnership(){
        UUID id=UUID.randomUUID(),applicant=UUID.randomUUID(),payer=UUID.randomUUID();var service=mock(BusinessApplicationService.class);
        var policy=new BusinessApplicationAttachmentPolicy(service).applicationPaymentEvidence();
        var row=new HashMap<String,Object>(Map.of("id",id,"applicant_id",applicant,"status","APPROVED","kind","PAYMENT"));
        when(service.row(id,true)).thenReturn(row);
        var cashier=new AuthUser(UUID.randomUUID(),payer,"fixture",Set.of("application:pay"),false,true,false);
        assertThrows(ApiException.class,()->policy.requireCanManageForUpdate(id,cashier));
        when(service.canAct(row,cashier)).thenReturn(true);policy.requireCanManageForUpdate(id,cashier);
        row.put("status","PAID");assertThrows(ApiException.class,()->policy.requireCanManageForUpdate(id,cashier));
        row.put("status","APPROVED");
        var owner=new AuthUser(UUID.randomUUID(),applicant,"fixture",Set.of("application:pay"),false,true,false);
        when(service.canAct(row,owner)).thenReturn(true);
        assertThrows(ApiException.class,()->policy.requireCanManageForUpdate(id,owner));
    }
    @Test void originalAndPaymentDownloadDelegateToExactlyTheSameObjectReadPolicy(){
        UUID id=UUID.randomUUID();var service=mock(BusinessApplicationService.class);var row=new HashMap<String,Object>();
        var actor=new AuthUser(UUID.randomUUID(),UUID.randomUUID(),"fixture",Set.of(),false,true,false);
        when(service.row(id,false)).thenReturn(row);var factory=new BusinessApplicationAttachmentPolicy(service);
        factory.applicationOriginals().requireCanView(id,actor);factory.applicationPaymentEvidence().requireCanDownload(id,actor);
        verify(service,times(2)).readable(row,actor);
    }
}
