package com.uten.imp.features.notice;
import com.uten.imp.application.port.EmployeeApplicationNoticePort;
import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.auth.model.UserAccountRepository;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.*;
import java.util.UUID;
@Component
@RequiredArgsConstructor
class EmployeeApplicationNoticeAdapter implements EmployeeApplicationNoticePort {
    private final NoticeService notices;
    private final UserAccountRepository users;
    private final PermissionResolver permissions;
    @Override @Transactional(propagation=Propagation.MANDATORY)
    public void result(UUID employee,UUID application,String message){
        users.findByEmployeeId(employee).filter(a->!a.isDeleted()&&"active".equals(a.getStatus()))
            .ifPresent(a->notices.publishForUser(a.getId(),"申请办理结果",message,"workflow","审批中心","/applications/"+application));
    }
    @Override @Transactional(propagation=Propagation.MANDATORY)
    public void pending(UUID user,UUID application,String stage){
        users.findById(user).filter(a->!a.isDeleted()&&"active".equals(a.getStatus()))
            .filter(a->permissions.grantedPermsOf(a).contains("notice:read"))
            .ifPresent(a->notices.publishForUser(a.getId(),"有申请待办理","你有一张申请进入"+stage+"，请在审批中心核对。","workflow","审批中心","/applications/"+application));
    }
}
