package com.uten.imp.features.sales.learning;

import com.uten.imp.application.port.SalesMasterLearningPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.sales.intake.SalesIntakeUsedEvent;
import com.uten.imp.features.sales.order.SalesOrderService;
import com.uten.imp.features.sales.quote.SalesQuoteService;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.springframework.context.ApplicationEventPublisher;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;
import org.springframework.web.bind.annotation.*;

import java.time.OffsetDateTime;
import java.util.*;

/** Status is visible with the saved document. Only the original actor may explicitly retry. */
@RestController
@RequestMapping("/api/sales/{documentKind}/{docId}/learning")
public class SalesLearningReceiptController {
    private final SalesLearningReceiptService receipts;
    private final SalesMasterLearningPort learning;
    private final ApplicationEventPublisher events;
    private final SalesQuoteService quotes;
    private final SalesOrderService orders;
    private final SecurityContextCurrentUser current;
    private final TransactionTemplate transaction;
    public SalesLearningReceiptController(SalesLearningReceiptService receipts,SalesMasterLearningPort learning,
            ApplicationEventPublisher events,SalesQuoteService quotes,SalesOrderService orders,
            SecurityContextCurrentUser current,PlatformTransactionManager transactions) {
        this.receipts=receipts;this.learning=learning;this.events=events;this.quotes=quotes;this.orders=orders;this.current=current;
        transaction=new TransactionTemplate(transactions);
    }
    public record StepView(String kind,int sourceIndex,String status,int attempts,Map<String,Integer> counts,String errorClass) { }
    public record ReceiptView(UUID id,String state,String message,boolean canRetry,OffsetDateTime updatedAt,
                              OffsetDateTime retryUntil,List<StepView> steps) { }

    @GetMapping
    public List<ReceiptView> list(@PathVariable String documentKind,@PathVariable UUID docId) {
        String type=authorize(documentKind,docId);
        List<SalesLearningReceiptService.Receipt> values=receipts.forDocument(type,docId);
        UUID latest=values.isEmpty()?null:values.getFirst().id();
        return values.stream().map(receipt->view(receipt,Objects.equals(latest,receipt.id()))).toList();
    }
    @PostMapping("/{receiptId}/retry")
    public List<ReceiptView> retry(@PathVariable String documentKind,@PathVariable UUID docId,@PathVariable UUID receiptId) {
        String type=authorize(documentKind,docId);
        var actor=current.get().orElseThrow();
        var receipt=receipts.owned(receiptId);
        if(actor.getImpersonatedBy()!=null||!receipt.request().intakeJobIds().isEmpty()
                &&!actor.getAuthorities().stream().anyMatch(a->"ai:use".equals(a.getAuthority())))
            throw new ApiException(ErrorCode.FORBIDDEN,"当前账号不能重试文件学习");
        if(!receipt.request().docId().equals(docId)||!receipt.request().docType().equals(type))
            throw new ApiException(ErrorCode.NOT_FOUND,"学习回执不属于当前单据");
        if(receipt.retryUntil().isBefore(OffsetDateTime.now()))throw new ApiException(ErrorCode.CONFLICT,"学习证据重试期限已过，请重新识别文件");
        transaction.executeWithoutResult(status->{
            receipts.requireCurrentSource(receiptId);
            learning.learnAfterCommit(receipt.request());
            for(UUID job:receipt.request().intakeJobIds())events.publishEvent(new SalesIntakeUsedEvent(job,
                    receipt.request().actorUserId(),type,docId,receipt.request().clientId(),
                    List.copyOf(SalesLearningReceiptService.sourceKeys(receipt.request(),job)),receiptId));
        });
        return list(documentKind,docId);
    }
    private String authorize(String kind,UUID doc) {
        String type=switch(kind){case "quotes"->"quote";case "orders"->"order";default->throw new ApiException(ErrorCode.NOT_FOUND);};
        String permission="sales_"+type+":view";
        var actor=current.get().orElseThrow(()->new ApiException(ErrorCode.UNAUTHORIZED));
        if(actor.isVisitor()||actor.getAuthorities().stream().noneMatch(a->permission.equals(a.getAuthority())))throw new ApiException(ErrorCode.FORBIDDEN);
        if("quote".equals(type))quotes.detail(doc);else orders.detail(doc);
        return type;
    }
    @SuppressWarnings("unchecked")
    private ReceiptView view(SalesLearningReceiptService.Receipt receipt,boolean latest) {
        var request=receipt.request();List<StepView> steps=new ArrayList<>();boolean failed=false,stale=false;
        for(var entry:receipt.steps().entrySet()) {
            if(!(entry.getValue() instanceof Map<?,?> raw))continue;
            String key=entry.getKey();int separator=key.indexOf(':');String kind=separator<0?key:key.substring(0,separator);
            int source=separator<0?0:request.intakeJobIds().indexOf(UUID.fromString(key.substring(separator+1)))+1;
            String status=Objects.toString(raw.get("status"),"PENDING");failed|="FAILED".equals(status);
            if("RUNNING".equals(status))try{stale|=OffsetDateTime.parse(Objects.toString(raw.get("startedAt"))).isBefore(OffsetDateTime.now().minusMinutes(5));}catch(RuntimeException invalid){stale=true;}
            Map<String,Integer> counts=new LinkedHashMap<>();if(raw.get("counts") instanceof Map<?,?> values)
                values.forEach((name,value)->{if(name instanceof String text&&value instanceof Number number)counts.put(text,number.intValue());});
            steps.add(new StepView(kind,source,status,raw.get("attempts") instanceof Number n?n.intValue():0,counts,
                    raw.get("errorClass") instanceof String error?error:null));
        }
        boolean canRetry=latest&&(failed||stale||"PENDING".equals(receipt.state()))&&receipt.retryUntil().isAfter(OffsetDateTime.now())
                &&current.id().filter(request.actorUserId()::equals).isPresent()
                &&current.get().filter(actor->actor.getImpersonatedBy()==null&&(request.intakeJobIds().isEmpty()||actor.getAuthorities().stream().anyMatch(a->"ai:use".equals(a.getAuthority())))).isPresent();
        String message=switch(receipt.state()) {
            case "SUCCEEDED"->"学习已完成";
            case "PARTIAL"->failed?"部分学习未完成，可重试":"已处理可学习的信息，未采用或不支持的文件步骤已跳过";
            case "FAILED"->"学习未完成，可重试";
            case "RUNNING"->"正在学习";
            default->"等待学习";
        };
        if(!latest&&failed)message="此学习记录已被后续保存替代";
        if(receipt.retryUntil().isBefore(OffsetDateTime.now())&&(failed||"PENDING".equals(receipt.state())||"RUNNING".equals(receipt.state())))
            message="学习重试期限已过，可从附件重新识别文件";
        return new ReceiptView(receipt.id(),receipt.state(),message,canRetry,receipt.updatedAt(),receipt.retryUntil(),steps);
    }
}
