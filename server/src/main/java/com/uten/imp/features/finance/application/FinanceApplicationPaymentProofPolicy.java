package com.uten.imp.features.finance.application;
import com.uten.imp.application.port.AttachmentOwnerAccessPolicy;
import com.uten.imp.common.web.*;
import com.uten.imp.security.AuthUser;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import java.util.*;

@Component @RequiredArgsConstructor
public class FinanceApplicationPaymentProofPolicy implements AttachmentOwnerAccessPolicy {
    private final FinanceApplicationLegacyPolicy legacy;private final FinanceApplicationService applications;private final FinanceApplicationRoles roles;
    @Override public String ownerType(){return "FINANCE_APPLICATION_PAYMENT_PROOF";}
    @Override public void requireCanView(UUID id,AuthUser actor){applications.readable(applications.row(id,false),actor);}
    @Override public void requireCanManage(UUID id,AuthUser actor){manage(id,actor,false);}
    @Override public void requireCanManageForUpdate(UUID id,AuthUser actor){manage(id,actor,true);}
    private void manage(UUID id,AuthUser actor,boolean lock){roles.live(FinanceApplicationPermissions.EXECUTE);var app=lock?applications.lockSourceAndRow(id):applications.row(id,false);applications.readable(app,actor);legacy.requireRound(app);legacy.requireUninvolvedPayer(app,actor.getEmployeeId());
        if(!"APPROVED".equals(app.get("status"))||applications.same(actor.getEmployeeId(),(UUID)app.get("applicant_id"))||applications.same(actor.getEmployeeId(),(UUID)app.get("approved_by")))throw new ApiException(ErrorCode.FORBIDDEN,"只有已批准申请的实际支付人员可维护付款凭据，申请人和最终批准人不能自付");}
}
