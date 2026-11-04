package com.uten.imp.features.applications;
import com.uten.imp.application.port.AttachmentOwnerAccessPolicy;
import com.uten.imp.common.web.*;
import com.uten.imp.security.AuthUser;
import lombok.RequiredArgsConstructor;
import org.springframework.context.annotation.*;
import java.util.*;

@Configuration
@RequiredArgsConstructor
public class BusinessApplicationAttachmentPolicy {
    private final BusinessApplicationService service;
    @Bean AttachmentOwnerAccessPolicy applicationOriginals(){return policy(false);}
    @Bean AttachmentOwnerAccessPolicy applicationPaymentEvidence(){return policy(true);}
    private AttachmentOwnerAccessPolicy policy(boolean payment){return new AttachmentOwnerAccessPolicy(){
        @Override public String ownerType(){return payment?"BUSINESS_APPLICATION_PAYMENT":"BUSINESS_APPLICATION";}
        @Override public void requireCanView(UUID id,AuthUser u){service.readable(service.row(id,false),u);}
        @Override public void requireCanManage(UUID id,AuthUser u){manage(id,u,false);}
        @Override public void requireCanManageForUpdate(UUID id,AuthUser u){manage(id,u,true);}
        private void manage(UUID id,AuthUser u,boolean lock){
            if(u==null||u.isVisitor()||u.getEmployeeId()==null||u.getImpersonatedBy()!=null)throw new ApiException(ErrorCode.FORBIDDEN);
            var row=service.row(id,lock);boolean owner=u.getEmployeeId().equals(row.get("applicant_id"));
            if(!payment&&owner&&Set.of("DRAFT","REJECTED").contains(row.get("status"))
                &&(u.getPermissions().contains("application:apply")||u.getPermissions().contains(BusinessApplicationWorkflow.applyPermission(row.get("kind").toString()))))return;
            if(payment&&!owner&&"APPROVED".equals(row.get("status"))&&u.getPermissions().contains("application:pay")){
                if(service.canAct(row,u))return;
            }
            throw new ApiException(ErrorCode.NOT_FOUND,"当前申请不可修改附件");
        }
    };}
}
