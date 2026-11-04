package com.uten.imp.features.notice;
import com.uten.imp.application.port.FinanceApplicationNoticePort;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.*;
import java.util.*;

@Component @RequiredArgsConstructor
public class FinanceApplicationNoticeAdapter implements FinanceApplicationNoticePort {
    private final NoticeService notices;
    @Override @Transactional(propagation=Propagation.MANDATORY)
    public void review(UUID id,String title,String applicant,String step,List<UUID> recipients){for(UUID user:recipients)notices.publishForUser(user,title+"待办理",applicant+"提交了"+title+"，当前步骤："+step,"task","财务","/finance/applications/"+id,"FINANCE_APPLICATION_REVIEW_REQUIRED","important",id);}
    @Override @Transactional(propagation=Propagation.MANDATORY)
    public void payment(UUID id,String title,List<UUID> recipients){for(UUID user:recipients)notices.publishForUser(user,title+"待登记付款",title+"已批准支付，请凭真实付款凭据登记实际付款。","task","财务","/finance/applications/"+id,"FINANCE_APPLICATION_PAYMENT_REQUIRED","important",id);}
    @Override @Transactional(propagation=Propagation.MANDATORY)
    public void returned(UUID id,String title,String reason,UUID user){if(user!=null)notices.publishForUser(user,title+"已退回",reason,"task","财务","/finance/applications/"+id,"FINANCE_APPLICATION_RETURNED","important",id);}
    @Override @Transactional(propagation=Propagation.MANDATORY)
    public void resolve(UUID id,String reason){notices.resolveReviewNotices("FINANCE_APPLICATION",id,reason);}
}
