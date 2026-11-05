package com.uten.imp.features.finance;

import com.uten.imp.application.port.FinancialDocumentUnapprovalCommandPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.application.port.DocumentUnapprovalExecutionPort;
import com.uten.imp.features.finance.receipt.FinanceReceiptService;
import com.uten.imp.features.finance.payment.FinancePaymentService;
import com.uten.imp.features.finance.expense.FinanceExpenseService;
import com.uten.imp.features.finance.other_income.FinanceOtherIncomeService;
import com.uten.imp.features.finance.bank_transfer.FinanceBankTransferService;
import com.uten.imp.security.*;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import lombok.RequiredArgsConstructor;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.*;
import java.util.*;

/** HTTP review commands only. Original domain methods retain every money,
 * source, employee/role and native-application authority check and lock order. */
@Service @RequiredArgsConstructor
public class FinanceDocumentActions implements FinancialDocumentUnapprovalCommandPort {
    public record ApprovalCommand(UUID requestId,Long expectedVersion,String expectedSnapshot) { }
    public record UpdateCommand(UUID requestId,Long expectedVersion,String expectedSnapshot,
            @com.fasterxml.jackson.databind.annotation.JsonDeserialize(using=com.uten.imp.common.finance.FinancialJsonNodeDeserializer.class) JsonNode document) { }
    private record Family(String permission,String segment) { }
    private static final Map<String,Family> FAMILIES=Map.of(
            "financeReceipt",new Family("finance_receipt","receipts"),"financePayment",new Family("finance_payment","payments"),
            "financeExpense",new Family("finance_expense","expenses"),"financeOtherIncome",new Family("finance_other_income","incomes"),
            "financeBankTransfer",new Family("finance_bank_transfer","bank-transfers"));
    private static final Set<String> OPERATIONS=Set.of("FINANCE_DOCUMENT_APPROVE","FINANCE_DOCUMENT_UNAPPROVE","FINANCE_DOCUMENT_UPDATE","FINANCE_DOCUMENT_GL_CONFIRM","FINANCE_DOCUMENT_DELETE");
    private final FinanceOperationJournal journal;
    private final FinanceDocumentReviewSnapshots snapshots;
    private final SecurityContextCurrentUser current;
    private final TxSessionVars tx;
    private final ObjectProvider<FinanceReceiptService> receipts;
    private final ObjectProvider<FinancePaymentService> payments;
    private final ObjectProvider<FinanceExpenseService> expenses;
    private final ObjectProvider<FinanceOtherIncomeService> incomes;
    private final ObjectProvider<FinanceBankTransferService> transfers;
    private final ObjectProvider<DocumentUnapprovalExecutionPort> documents;
    private final ObjectProvider<FinanceDocumentActions> self;
    private final ObjectMapper json;
    private final jakarta.validation.Validator validator;
    private final com.uten.imp.audit.AuditService audit;
    @Override public boolean supports(String family){return family!=null&&FAMILIES.containsKey(family);}
    private Family family(String value){var result=value==null?null:FAMILIES.get(value);if(result==null)throw invalid("财务单据类型无效");return result;}
    private String path(String family,UUID id,String action){return "/finance/"+family(family).segment()+"/"+id+"/"+action;}
    private void readAuthority(String family){CurrentAuthorityGuard.requireAll(family(family).permission()+":view");}
    private void writeAuthority(String family,String action){readAuthority(family);CurrentAuthorityGuard.requireAll(family(family).permission()+":"+action);
        var user=current.get().orElseThrow(()->new ApiException(ErrorCode.FORBIDDEN));
        if(user.isVisitor()||user.getEmployeeId()==null||user.isMustChangePassword()||!user.isAccountNonLocked()||user.getImpersonatedBy()!=null)
            throw new ApiException(ErrorCode.FORBIDDEN,"当前身份不能执行财务审核或反审");
    }
    @Transactional(readOnly=true,isolation=Isolation.REPEATABLE_READ,propagation=Propagation.REQUIRES_NEW)
    public <T extends FinanceReviewMetadata>T reviewedDetail(String family,UUID id,boolean history){
        readAuthority(family);
        if(history)return com.uten.imp.common.platformcolumns.DocumentPlatformReadContext.withoutReuse(()->nativeDetail(family,id,true));
        try(var readContext=com.uten.imp.common.platformcolumns.DocumentPlatformReadContext.open()){
            T detail=nativeDetail(family,id,false);
            return detail.isHistoryReadOnly()||detail.isLegacyImported()?detail:snapshots.decorate(family,id,detail);
        }
    }
    @Transactional(readOnly=true,isolation=Isolation.REPEATABLE_READ,propagation=Propagation.REQUIRES_NEW)
    public void checkReadable(String family,UUID id){readAuthority(family);nativeDetail(family,id,true);}
    @SuppressWarnings("unchecked") private <T extends FinanceReviewMetadata>T nativeDetail(String family,UUID id,boolean history){
        return (T)switch(family){
            case "financeReceipt"->history?receipts.getObject().detailHistory(id):receipts.getObject().detail(id);
            case "financePayment"->history?payments.getObject().detailHistory(id):payments.getObject().detail(id);
            case "financeExpense"->history?expenses.getObject().detailHistory(id):expenses.getObject().detail(id);
            case "financeOtherIncome"->history?incomes.getObject().detailHistory(id):incomes.getObject().detail(id);
            case "financeBankTransfer"->history?transfers.getObject().detailHistory(id):transfers.getObject().detail(id);
            default->throw invalid("财务单据类型无效");
        };
    }
    public Map<String,Object> approve(String family,UUID id,ApprovalCommand command){
        writeAuthority(family,"approve");
        if(id==null||command==null||command.requestId()==null||command.expectedSnapshot()==null||!command.expectedSnapshot().matches("[a-f0-9]{64}"))
            throw invalid("请保留原审核请求编号，并读取本次实际展示的完整单据快照");
        // A separate read transaction authorizes replay without polluting the
        // domain write persistence context with earlier cached detail/lines.
        self.getObject().checkReadable(family,id);return self.getObject().runApproval(family,id,command);
    }
    @Transactional(propagation=Propagation.REQUIRES_NEW)
    public Map<String,Object> runApproval(String family,UUID id,ApprovalCommand command){
        writeAuthority(family,"approve");tx.bind();
        return journal.command(command.requestId(),"FINANCE_DOCUMENT_APPROVE","POST",path(family,id,"approve"),command,()->
                FinanceDocumentReviewContext.run(family,id,"APPROVE",()->snapshots.require(family,id,command.expectedVersion(),command.expectedSnapshot()),()->{
                    FinanceReviewMetadata result=switch(family){
                        case "financeReceipt"->receipts.getObject().approve(id);case "financePayment"->payments.getObject().approve(id);
                        case "financeExpense"->expenses.getObject().approve(id);case "financeOtherIncome"->incomes.getObject().approve(id);
                        case "financeBankTransfer"->transfers.getObject().approve(id);default->throw invalid("财务单据类型无效");
                    };
                    auditSuccess(family,id,"approve");
                    return result;
                }),ignored->nativeDetail(family,id,true));
    }
    public Map<String,Object> update(String family,UUID id,UpdateCommand command){
        writeAuthority(family,"edit");
        if(id==null||command==null||command.requestId()==null||command.expectedSnapshot()==null||!command.expectedSnapshot().matches("[a-f0-9]{64}")
                ||command.document()==null||!command.document().isObject())throw invalid("请保留原完整业务输入、编辑请求编号和本次所见单据快照");
        self.getObject().checkReadable(family,id);return self.getObject().runUpdate(family,id,command);
    }
    public Map<String,Object> glConfirm(UUID id,ApprovalCommand command){
        writeAuthority("financeExpense","gl_confirm");
        if(id==null||command==null||command.requestId()==null||command.expectedSnapshot()==null||!command.expectedSnapshot().matches("[a-f0-9]{64}"))
            throw invalid("请保留原财务确认请求编号，并读取本次实际展示的完整费用单快照");
        self.getObject().checkReadable("financeExpense",id);return self.getObject().runGlConfirmation(id,command);
    }
    public Map<String,Object> delete(String family,UUID id,ApprovalCommand command){
        writeAuthority(family,"delete");
        if(id==null||command==null||command.requestId()==null||command.expectedSnapshot()==null||!command.expectedSnapshot().matches("[a-f0-9]{64}"))
            throw invalid("请保留原删除请求编号，并读取本次实际展示的完整草稿快照");
        self.getObject().checkReadable(family,id);return self.getObject().runDeletion(family,id,command);
    }
    @Transactional(propagation=Propagation.REQUIRES_NEW)
    public Map<String,Object> runDeletion(String family,UUID id,ApprovalCommand command){
        writeAuthority(family,"delete");tx.bind();
        return journal.command(command.requestId(),"FINANCE_DOCUMENT_DELETE","DELETE",resource(family,id),command,()->
                FinanceDocumentReviewContext.run(family,id,"DELETE",()->snapshots.require(family,id,command.expectedVersion(),command.expectedSnapshot()),()->{
                    switch(family){
                        case "financeReceipt"->receipts.getObject().delete(id);case "financePayment"->payments.getObject().delete(id);
                        case "financeExpense"->expenses.getObject().delete(id);case "financeOtherIncome"->incomes.getObject().delete(id);
                        case "financeBankTransfer"->transfers.getObject().delete(id);default->throw invalid("财务单据类型无效");
                    }
                    auditSuccess(family,id,"delete");
                    return nativeDetail(family,id,true);
                }),ignored->nativeDetail(family,id,true));
    }
    @Transactional(propagation=Propagation.REQUIRES_NEW)
    public Map<String,Object> runGlConfirmation(UUID id,ApprovalCommand command){
        writeAuthority("financeExpense","gl_confirm");tx.bind();
        return journal.command(command.requestId(),"FINANCE_DOCUMENT_GL_CONFIRM","POST",path("financeExpense",id,"gl-confirm"),command,()->
                FinanceDocumentReviewContext.run("financeExpense",id,"GL_CONFIRM",()->snapshots.require("financeExpense",id,command.expectedVersion(),command.expectedSnapshot()),()->{
                    var result=expenses.getObject().glConfirm(id);
                    auditSuccess("financeExpense",id,"gl_confirm");
                    return result;
                }),ignored->nativeDetail("financeExpense",id,true));
    }
    @Transactional(propagation=Propagation.REQUIRES_NEW)
    public Map<String,Object> runUpdate(String family,UUID id,UpdateCommand command){
        writeAuthority(family,"edit");tx.bind();
        return journal.command(command.requestId(),"FINANCE_DOCUMENT_UPDATE","PUT",resource(family,id),command,()->
                FinanceDocumentReviewContext.run(family,id,"UPDATE",()->snapshots.require(family,id,command.expectedVersion(),command.expectedSnapshot()),()->{
                    return switch(family){
                        case "financeReceipt"->{var request=updateInput(command,com.uten.imp.features.finance.receipt.dto.FinanceReceiptSaveRequest.class);if(!Objects.equals(request.getExpectedVersion(),command.expectedVersion()))throw invalid("收款编辑的原版本依据不一致");yield receipts.getObject().update(id,request);}
                        case "financePayment"->{var request=updateInput(command,com.uten.imp.features.finance.payment.dto.FinancePaymentSaveRequest.class);if(!Objects.equals(request.getExpectedVersion(),command.expectedVersion()))throw invalid("付款编辑的原版本依据不一致");yield payments.getObject().update(id,request);}
                        case "financeExpense"->expenses.getObject().update(id,updateInput(command,com.uten.imp.features.finance.expense.dto.FinanceExpenseSaveRequest.class));
                        case "financeOtherIncome"->incomes.getObject().update(id,updateInput(command,com.uten.imp.features.finance.other_income.dto.FinanceOtherIncomeSaveRequest.class));
                        case "financeBankTransfer"->transfers.getObject().update(id,updateInput(command,com.uten.imp.features.finance.bank_transfer.dto.FinanceBankTransferSaveRequest.class));
                        default->throw invalid("财务单据类型无效");
                    };
                }),ignored->nativeDetail(family,id,true));
    }
    private <T>T updateInput(UpdateCommand command,Class<T> type){
        T request;try{request=com.uten.imp.common.finance.FinancialJsonResults.value(json,json.writeValueAsString(command.document()),type);}catch(Exception error){throw invalid("原业务输入格式无效，请保留原文核对");}
        var violations=validator.validate(request);
        if(!violations.isEmpty())throw invalid(violations.stream().map(value->value.getPropertyPath()+" "+value.getMessage()).sorted().collect(java.util.stream.Collectors.joining("；")));
        return request;
    }
    private String resource(String family,UUID id){return "/finance/"+family(family).segment()+"/"+id;}
    @Override
    public Object execute(String family,UUID id,Command command){return unapprove(family,id,command,"/documents/"+family+"/"+id+"/unapprove");}
    public Map<String,Object> unapprove(String family,UUID id,Command command){return unapprove(family,id,command,path(family,id,"reverse"));}
    private Map<String,Object> unapprove(String family,UUID id,Command command,String commandPath){
        writeAuthority(family,"reverse");
        if(id==null||command==null||command.requestId()==null||!command.requestId().toString().equals(command.idempotencyKey())
                ||command.expectedSnapshot()==null||!command.expectedSnapshot().matches("[a-f0-9]{64}")||command.reason()==null||command.reason().isBlank())
            throw invalid("请保留原反审编号、原因和实际核对快照，不能另换提交编号");
        self.getObject().checkReadable(family,id);return self.getObject().runUnapproval(family,id,command,commandPath);
    }
    @Transactional(propagation=Propagation.REQUIRES_NEW)
    public Map<String,Object> runUnapproval(String family,UUID id,Command command,String commandPath){
        writeAuthority(family,"reverse");tx.bind();
        return journal.command(command.requestId(),"FINANCE_DOCUMENT_UNAPPROVE","POST",commandPath,command,()->
                FinanceDocumentReviewContext.run(family,id,"UNAPPROVE",()->{
                    var actual=documents.getObject().currentFactsSnapshot(family,id);
                    if(!command.expectedSnapshot().equals(actual))throw new ApiException(ErrorCode.CONFLICT,"原锁后反审条件或代次已变化，请核对原请求和当前单据");
                },()->{
                    Object result=documents.getObject().unapproveTrusted(family,id,command.idempotencyKey(),command.reason(),command.expectedSnapshot(),command.requestId());
                    auditSuccess(family,id,"reverse");
                    return result;
                }),ignored->nativeDetail(family,id,true));
    }
    public Map<String,Object> receipt(String family,UUID id,UUID request){
        self.getObject().checkReadable(family,id);return self.getObject().readReceipt(family,id,request);
    }
    @Transactional(readOnly=true)
    public Map<String,Object> readReceipt(String family,UUID id,UUID request){
        readAuthority(family);nativeDetail(family,id,true);var result=journal.commandReceipt(request,OPERATIONS);
        return Boolean.TRUE.equals(result.get("found"))&&!allowedPath(family,id,Objects.toString(result.get("operation"),""),Objects.toString(result.get("path"),""))?Map.of("found",false):result;
    }
    public Map<String,Object> cancel(String family,UUID id,UUID request,FinanceOperationJournal.Cancellation cancellation){
        self.getObject().checkReadable(family,id);return self.getObject().cancelInside(family,id,request,cancellation);
    }
    @Transactional(propagation=Propagation.REQUIRES_NEW)
    public Map<String,Object> cancelInside(String family,UUID id,UUID request,FinanceOperationJournal.Cancellation cancellation){
        readAuthority(family);tx.bind();
        if(cancellation==null||!allowedPath(family,id,cancellation.operation(),cancellation.path()))throw invalid("原财务审核或反审目标不一致");
        boolean edit="FINANCE_DOCUMENT_UPDATE".equals(cancellation.operation());
        boolean deletion="FINANCE_DOCUMENT_DELETE".equals(cancellation.operation());
        return journal.cancelCommand(request,cancellation,cancellation.operation(),edit?"PUT":deletion?"DELETE":"POST",cancellation.path(),
                edit?UpdateCommand.class:Set.of("FINANCE_DOCUMENT_APPROVE","FINANCE_DOCUMENT_GL_CONFIRM","FINANCE_DOCUMENT_DELETE").contains(cancellation.operation())?ApprovalCommand.class:Command.class,ignored->nativeDetail(family,id,true));
    }
    private boolean allowedPath(String family,UUID id,String operation,String candidate){
        if("FINANCE_DOCUMENT_UPDATE".equals(operation))return resource(family,id).equals(candidate);
        if("FINANCE_DOCUMENT_DELETE".equals(operation))return resource(family,id).equals(candidate);
        if("FINANCE_DOCUMENT_APPROVE".equals(operation))return path(family,id,"approve").equals(candidate);
        if("FINANCE_DOCUMENT_GL_CONFIRM".equals(operation))return "financeExpense".equals(family)&&path(family,id,"gl-confirm").equals(candidate);
        return "FINANCE_DOCUMENT_UNAPPROVE".equals(operation)&&(path(family,id,"reverse").equals(candidate)||("/documents/"+family+"/"+id+"/unapprove").equals(candidate));
    }
    /** Only real journal work records the committed business action. A receipt
     * read, replay or cancellation verification never invokes this callback. */
    private void auditSuccess(String family,UUID id,String action){
        var actor=current.get().orElseThrow(()->new ApiException(ErrorCode.FORBIDDEN));
        String permission=family(family).permission();
        audit.logCommitted(actor.getId(),actor.getLoginAccount(),permission+"_"+action,permission,id.toString(),"success");
    }
    private static ApiException invalid(String message){return new ApiException(ErrorCode.VALIDATION_FAILED,message);}
}
