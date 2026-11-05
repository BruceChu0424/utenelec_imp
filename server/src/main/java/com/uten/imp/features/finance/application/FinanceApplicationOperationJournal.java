package com.uten.imp.features.finance.application;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.features.finance.FinanceOperationJournal;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;
import java.util.*;
import java.util.function.Consumer;
import java.util.function.Supplier;

/** Application adapter; locking, fingerprints and receipts have one finance owner. */
@Component
public class FinanceApplicationOperationJournal {
    static final Set<String> SETTINGS_OPERATIONS=FinanceOperationJournal.SETTINGS_OPERATIONS;
    private final FinanceOperationJournal operations;
    @Autowired public FinanceApplicationOperationJournal(FinanceOperationJournal operations){this.operations=operations;}
    public FinanceApplicationOperationJournal(JdbcTemplate db,ObjectMapper json,SecurityContextCurrentUser current){this(new FinanceOperationJournal(db,json,current));}

    Map<String,Object> execute(UUID application,UUID request,String operation,Object payload,
            Consumer<String> authorizeReplay,Supplier<Map<String,Object>> work) {
        return operations.execute(application,request,operation,payload,authorizeReplay,work);
    }

    Map<String,Object> settingsReceipt(UUID request) {
        var stored=operations.legacyReceipt(request,SETTINGS_OPERATIONS);
        if(!Boolean.TRUE.equals(stored.get("found")))return stored;
        @SuppressWarnings("unchecked")var result=(Map<String,Object>)stored.get("result");
        if("CANCELLED_UNWRITTEN".equals(result.get("outcome")))return result;
        var response=new LinkedHashMap<>(stored);response.put("outcome","SUCCEEDED");response.put("requestId",request);return response;
    }
    Map<String,Object> cancelSettings(UUID request,FinanceOperationJournal.Cancellation cancellation){
        if(cancellation==null||cancellation.operation()==null)throw new com.uten.imp.common.web.ApiException(com.uten.imp.common.web.ErrorCode.VALIDATION_FAILED,"请保留原流程设置核对请求");
        String base="/finance/applications/settings";
        return switch(cancellation.operation()){
            case "SETTINGS_SAVE"->operations.legacyCancellation(request,cancellation,"SETTINGS_SAVE","POST",base,FinanceApplicationContracts.SettingsInput.class,body->body);
            case "ROLE_SAVE"->operations.legacyCancellation(request,cancellation,"ROLE_SAVE","POST",base+"/roles",FinanceApplicationContracts.RoleInput.class,body->body);
            case "ROLE_REMOVE"->{
                var raw=cancellation.requestBody();UUID role;
                try{role=UUID.fromString(raw.path("id").asText());}catch(Exception error){throw new com.uten.imp.common.web.ApiException(com.uten.imp.common.web.ErrorCode.VALIDATION_FAILED,"请保留原岗位编号");}
                yield operations.legacyCancellation(request,cancellation,"ROLE_REMOVE","DELETE",base+"/roles/"+role,RoleRemovalCancellation.class,
                        body->{var input=(RoleRemovalCancellation)body;return new FinanceApplicationContracts.RoleRemoval(input.id(),input.expectedVersion());});
            }
            default->throw new com.uten.imp.common.web.ApiException(com.uten.imp.common.web.ErrorCode.VALIDATION_FAILED,"原流程设置动作不正确");
        };
    }
    public record RoleRemovalCancellation(UUID requestId,UUID id,long expectedVersion) { }
}
