package com.uten.imp.features.finance.application;
import com.uten.imp.application.port.AttachmentOwnerAccessPolicy;
import com.uten.imp.security.AuthUser;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import java.util.*;

@Component @RequiredArgsConstructor
public class FinanceApplicationEvidencePolicy implements AttachmentOwnerAccessPolicy {
    private final FinanceApplicationService applications;private final FinanceApplicationLegacyPolicy legacy;
    @Override public String ownerType(){return "FINANCE_APPLICATION";}
    @Override public void requireCanView(UUID id,AuthUser actor){applications.readable(applications.row(id,false),actor);}
    @Override public void requireCanManage(UUID id,AuthUser actor){var app=applications.row(id,false);applications.owner(app,actor);applications.editable(app);legacy.requireEditableOriginal(app);}
    @Override public void requireCanManageForUpdate(UUID id,AuthUser actor){var app=applications.lockSourceAndRow(id);applications.owner(app,actor);applications.editable(app);legacy.requireEditableOriginal(app);}
}
