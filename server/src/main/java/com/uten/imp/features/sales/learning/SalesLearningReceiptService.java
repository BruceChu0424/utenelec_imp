package com.uten.imp.features.sales.learning;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.AiJobUsagePort;
import com.uten.imp.application.port.SalesLearningReceiptPort;
import com.uten.imp.application.port.SalesMasterLearningPort.SalesLearningRequest;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.transaction.support.TransactionTemplate;

import java.time.OffsetDateTime;
import java.util.*;
import java.util.function.Supplier;

@Service
public class SalesLearningReceiptService implements SalesLearningReceiptPort {
    private static final Logger log=LoggerFactory.getLogger(SalesLearningReceiptService.class);
    private static final Set<String> EVIDENCE_FIELDS=Set.of("key","partNo","description","descriptionAlt","contextNorm","status","selectedGoodsId","nameEnText");
    private final NamedParameterJdbcTemplate jdbc;
    private final ObjectMapper json;
    private final SecurityContextCurrentUser current;
    private final ObjectProvider<AiJobUsagePort> jobs;
    private final TransactionTemplate separate;
    private final ThreadLocal<RunningClaim> runningClaim=new ThreadLocal<>();
    public SalesLearningReceiptService(NamedParameterJdbcTemplate jdbc,ObjectMapper json,SecurityContextCurrentUser current,
            ObjectProvider<AiJobUsagePort> jobs,PlatformTransactionManager transactions) {
        this.jdbc=jdbc;this.json=json;this.current=current;this.jobs=jobs;
        separate=new TransactionTemplate(transactions);separate.setPropagationBehavior(TransactionDefinition.PROPAGATION_REQUIRES_NEW);
    }

    @Override @Transactional
    public void register(SalesLearningRequest request) {
        if(request.learningReceiptId()==null)return;
        if(!current.requireId().equals(request.actorUserId()))throw denied();
        Map<String,Object> steps=new LinkedHashMap<>();
        steps.put("MASTER",pending());steps.put("CONSUME",pending());
        for(UUID job:request.intakeJobIds()){steps.put("LAYOUT:"+job,pending());steps.put("TEMPLATE:"+job,pending());}
        Map<String,Object> p=params(request.learningReceiptId());
        p.put("type",request.docType());p.put("doc",request.docId());p.put("client",request.clientId());
        p.put("actor",request.actorUserId());p.put("request",encode(request));p.put("steps",encode(steps));
        int inserted=jdbc.update("""
                INSERT INTO sales_document_learning_receipts(id,doc_type,doc_id,client_id,actor_user_id,request_payload,steps)
                VALUES(:id,:type,:doc,:client,:actor,CAST(:request AS jsonb),CAST(:steps AS jsonb)) ON CONFLICT(id) DO NOTHING
                """,p);
        Receipt receipt=owned(request.learningReceiptId());
        if(inserted==0&&!receipt.request().equals(request))
            throw new ApiException(ErrorCode.CONFLICT,"学习任务内容与原回执不一致");
        // Reserve only the server-verified contributing sources with the document commit. No result content is read here.
        AiJobUsagePort usage=jobs.getIfAvailable();
        if(usage!=null)for(UUID job:request.intakeJobIds()) {
            if(usage.reserveLearningForSave(job,request.actorUserId(),request.docType(),request.docId(),receipt.retryUntil(),
                    sourceKeys(request,job),job.equals(request.intakeJobId())&&!request.clientFields().isEmpty()))
                jdbc.update("UPDATE sales_quote_template_candidates SET expires_at=GREATEST(expires_at,:until) WHERE job_id=:job",
                        Map.of("job",job,"until",java.sql.Timestamp.from(receipt.retryUntil().toInstant())));
        }
    }

    @Transactional
    public void purgeExpiredEvidence() {
        jdbc.update("""
                WITH candidates AS (
                    SELECT id FROM sales_document_learning_receipts receipt
                    WHERE retry_until<now() AND (evidence<>'{}'::jsonb OR request_payload->'lines'<>'[]'::jsonb
                        OR request_payload->'clientFields'<>'{}'::jsonb)
                      AND NOT EXISTS(SELECT 1 FROM jsonb_each(receipt.steps) step WHERE step.value->>'status'='RUNNING')
                    ORDER BY retry_until,id LIMIT 1000 FOR UPDATE SKIP LOCKED
                )
                UPDATE sales_document_learning_receipts receipt SET evidence='{}'::jsonb,
                    request_payload=jsonb_set(jsonb_set(receipt.request_payload,'{lines}','[]'::jsonb),'{clientFields}','{}'::jsonb),
                    updated_at=now()
                FROM candidates WHERE receipt.id=candidates.id
                """,Map.of());
    }

    @Override public void run(UUID id,String kind,UUID job,Supplier<StepResult> work) {
        if(id==null){work.get();return;}
        String step=step(kind,job);
        StepClaim claim=null;
        RunningClaim previous=runningClaim.get();
        try {
            Receipt receipt=owned(id);
            if(job!=null&&!receipt.request().intakeJobIds().contains(job))throw denied();
            claim=separate.execute(status->claim(id,step));
            if(claim==null)return;
            runningClaim.set(new RunningClaim(id,step,claim));
            if(job!=null) {
                if(priorComplete(receipt,step)){finish(id,step,claim,"SUCCEEDED",Map.of(),null);return;}
                if(!prepareSource(receipt,job,step,claim)){finish(id,step,claim,"SKIPPED",Map.of(),null);return;}
            }
            StepResult result=work.get();
            finish(id,step,claim,result.skipped()?"SKIPPED":"SUCCEEDED",result.counts(),null);
        } catch(RuntimeException failure) {
            try { if(claim!=null)finish(id,step,claim,"FAILED",Map.of(),failure.getClass().getSimpleName()); }
            catch(RuntimeException receiptFailure){log.warn("Learning receipt update failed receipt={} type={}",id,receiptFailure.getClass().getSimpleName());}
            log.warn("Confirmed learning step failed receipt={} step={} type={}",id,kind,failure.getClass().getSimpleName());
        } finally {
            if(previous==null)runningClaim.remove();else runningClaim.set(previous);
        }
    }

    private StepClaim claim(UUID id,String step) {
        Receipt receipt=locked(id);
        if(!receipt.steps().containsKey(step))throw denied();
        Map<String,Object> value=stepMap(receipt.steps().get(step));
        String status=Objects.toString(value.get("status"),"PENDING");
        if("SUCCEEDED".equals(status)||"SKIPPED".equals(status))return null;
        if("RUNNING".equals(status)&&recent(value.get("startedAt")))return null;
        if(!receipt.retryUntil().isAfter(OffsetDateTime.now()))throw new ApiException(ErrorCode.CONFLICT,"学习证据重试期限已过，请重新识别文件");
        Map<String,Object> next=new LinkedHashMap<>();next.put("status","RUNNING");
        next.put("attempts",((Number)value.getOrDefault("attempts",0)).intValue()+1);
        next.put("startedAt",OffsetDateTime.now().toString());
        updateStep(receipt,step,next);return new StepClaim((int)next.get("attempts"),next.get("startedAt").toString());
    }

    private boolean prepareSource(Receipt receipt,UUID job,String step,StepClaim claim) {
        AiJobUsagePort usage=jobs.getIfAvailable();if(usage==null)return false;
        Optional<Map<String,Object>> raw=usage.resultFor(job,receipt.request().actorUserId());
        if(raw.isEmpty())return false;
        Set<String> selected=sourceKeys(receipt.request(),job);
        boolean matching=raw.get().get("lines") instanceof List<?> lines && lines.stream()
                .anyMatch(line->line instanceof Map<?,?> values&&selected.contains(values.get("key")));
        boolean headerOnly=job.equals(receipt.request().intakeJobId())&&!receipt.request().clientFields().isEmpty();
        if(!matching&&!headerOnly)return false;
        return Boolean.TRUE.equals(separate.execute(status->{
            Receipt live=locked(receipt.id());
            if(!claim.owns(live,step))return false;
            if(!usage.reserveLearning(job,receipt.request().actorUserId(),receipt.request().docType(),receipt.request().docId(),receipt.retryUntil()))return false;
            remember(live,job,raw.get());
            jdbc.update("UPDATE sales_quote_template_candidates SET expires_at=GREATEST(expires_at,:until) WHERE job_id=:job",
                    Map.of("job",job,"until",java.sql.Timestamp.from(receipt.retryUntil().toInstant())));
            return true;
        }));
    }

    @Override public Optional<Map<String,Object>> evidence(UUID id,UUID job) {
        if(id==null)return Optional.empty();
        Receipt receipt=owned(id);Map<String,Object> p=params(id);p.put("job",job.toString());
        p.put("type",receipt.request().docType());p.put("doc",receipt.request().docId());
        p.put("actor",receipt.request().actorUserId());p.put("client",receipt.request().clientId());
        List<String> values=jdbc.query("""
                SELECT (evidence->CAST(:job AS text))::text FROM sales_document_learning_receipts
                WHERE doc_type=:type AND doc_id=:doc AND actor_user_id=:actor
                    AND client_id IS NOT DISTINCT FROM CAST(:client AS uuid) AND jsonb_exists(evidence,CAST(:job AS text))
                ORDER BY saved_sequence DESC LIMIT 1
                """,p,(rs,row)->rs.getString(1));
        return values.isEmpty()?Optional.empty():Optional.of(map(values.getFirst()));
    }
    @Override public void rememberEvidence(UUID id,UUID job,Map<String,Object> result) {
        if(id==null||result==null)return;
        separate.executeWithoutResult(status->{Receipt receipt=locked(id);requireExecutingClaim(receipt);remember(receipt,job,result);});
    }
    private void remember(Receipt receipt,UUID job,Map<String,Object> result) {
        Set<String> selected=sourceKeys(receipt.request(),job);List<Map<String,Object>> lines=new ArrayList<>();
        if(result.get("lines") instanceof List<?> source)for(Object item:source) {
            if(!(item instanceof Map<?,?> row)||!selected.contains(row.get("key")))continue;
            Map<String,Object> line=new LinkedHashMap<>();
            for(String field:EVIDENCE_FIELDS)if(row.get(field)!=null)line.put(field,row.get(field));
            lines.add(line);
        }
        Map<String,Object> minimum=new LinkedHashMap<>();minimum.put("lines",lines);
        if(result.get("extraction") instanceof Map<?,?> extraction) {
            Map<String,Object> layout=new LinkedHashMap<>();
            for(String key:List.of("layoutSource","layoutFingerprint","headerTexts","columnRoles","headerRowOffset"))
                if(extraction.get(key)!=null)layout.put(key,extraction.get(key));
            minimum.put("extraction",layout);
        }
        Map<String,Object> p=params(receipt.id());p.put("job",job.toString());p.put("value",encode(minimum));
        jdbc.update("UPDATE sales_document_learning_receipts SET evidence=jsonb_set(evidence,ARRAY[CAST(:job AS text)],CAST(:value AS jsonb)),updated_at=now() WHERE id=:id",p);
    }

    @Override @Transactional(propagation=org.springframework.transaction.annotation.Propagation.MANDATORY)
    public void requireCurrentSource(UUID id) {
        Receipt receipt=locked(id);requireExecutingClaim(receipt);SalesLearningRequest request=receipt.request();
        String table="quote".equals(request.docType())?"sales_quotes":"sales_orders";
        String items="quote".equals(request.docType())?"sales_quote_items":"sales_order_items";
        String parent="quote".equals(request.docType())?"quote_id":"order_id";
        Map<String,Object> p=params(id);p.put("doc",request.docId());p.put("type",request.docType());
        p.put("lock", "sales-learning:"+request.docType()+":"+request.docId());
        jdbc.query("SELECT pg_advisory_xact_lock(hashtextextended(:lock,751))",p,rs->null);
        List<UUID> clients=jdbc.query("SELECT client_id FROM "+table+" WHERE id=:doc AND NOT is_deleted FOR SHARE",p,(rs,row)->rs.getObject(1,UUID.class));
        if(clients.isEmpty()||!Objects.equals(clients.getFirst(),request.clientId()))throw stale();
        if(Boolean.TRUE.equals(jdbc.queryForObject("""
                SELECT EXISTS(SELECT 1 FROM sales_document_learning_receipts newer JOIN sales_document_learning_receipts original
                    ON original.id=:id WHERE newer.doc_type=:type AND newer.doc_id=:doc AND newer.saved_sequence>original.saved_sequence)
                """,p,Boolean.class)))throw stale();
        List<SourceLineIdentity> saved=jdbc.query("SELECT goods_id,client_model,client_goods_name FROM "+items+" WHERE "+parent+"=:doc AND NOT is_deleted",p,
                (rs,row)->lineKey(rs.getObject(1,UUID.class),rs.getString(2),rs.getString(3)));
        Map<SourceLineIdentity,Integer> remaining=new HashMap<>();saved.forEach(key->remaining.merge(key,1,Integer::sum));
        for(var line:request.lines()) {
            SourceLineIdentity key=lineKey(line.goodsId(),line.clientModel(),line.clientGoodsName());
            int count=remaining.getOrDefault(key,0);if(count==0)throw stale();remaining.put(key,count-1);
        }
    }
    private record SourceLineIdentity(UUID goods, String model, String name) { }
    private static SourceLineIdentity lineKey(UUID goods,String model,String name){return new SourceLineIdentity(goods,normalized(model),normalized(name));}
    private static String normalized(String value){return value==null?"":java.text.Normalizer.normalize(value,java.text.Normalizer.Form.NFKC).strip().replaceAll("\\s+"," ").toLowerCase(Locale.ROOT);}
    private static ApiException stale(){return new ApiException(ErrorCode.CONFLICT,"单据内容已变更，请重新保存并确认学习内容");}

    @Override public boolean canConsume(UUID id) {
        Receipt receipt=owned(id);
        return receipt.steps().entrySet().stream().filter(e->!"CONSUME".equals(e.getKey())).allMatch(e->{
            String status=Objects.toString(stepMap(e.getValue()).get("status"),"");
            return "SUCCEEDED".equals(status)||"SKIPPED".equals(status);
        });
    }
    @Override public Set<UUID> consumableJobs(UUID id) {
        Receipt receipt=owned(id);Set<UUID> out=new LinkedHashSet<>();
        receipt.evidence().keySet().forEach(key->{try{out.add(UUID.fromString(key));}catch(IllegalArgumentException ignored){}});
        return out;
    }

    private boolean priorComplete(Receipt receipt,String step) {
        Map<String,Object> p=params(receipt.id());p.put("step",step);p.put("actor",receipt.request().actorUserId());
        p.put("type",receipt.request().docType());p.put("doc",receipt.request().docId());p.put("client",receipt.request().clientId());
        return Boolean.TRUE.equals(jdbc.queryForObject("""
                SELECT EXISTS(SELECT 1 FROM sales_document_learning_receipts WHERE id<>:id AND doc_type=:type AND doc_id=:doc
                    AND actor_user_id=:actor AND client_id IS NOT DISTINCT FROM CAST(:client AS uuid)
                    AND steps->CAST(:step AS text)->>'status'='SUCCEEDED')
                """,p,Boolean.class));
    }
    private record StepClaim(int attempt,String startedAt) {
        boolean owns(Receipt receipt,String step) {
            Map<String,Object> value=stepMap(receipt.steps().get(step));
            return "RUNNING".equals(value.get("status"))&&value.get("attempts") instanceof Number attempts
                    &&attempts.intValue()==attempt&&Objects.equals(value.get("startedAt"),startedAt);
        }
    }
    private record RunningClaim(UUID id,String step,StepClaim claim) { }
    private void requireExecutingClaim(Receipt receipt) {
        RunningClaim running=runningClaim.get();
        if(running!=null&&running.id().equals(receipt.id())) {
            if(!running.claim().owns(receipt,running.step()))throw stale();
        } else if(!receipt.retryUntil().isAfter(OffsetDateTime.now())) {
            throw new ApiException(ErrorCode.CONFLICT,"学习证据重试期限已过，请重新识别文件");
        }
    }
    private void finish(UUID id,String step,StepClaim claim,String status,Map<String,Integer> counts,String error) {
        separate.executeWithoutResult(tx->{Receipt receipt=locked(id);
            if(!claim.owns(receipt,step))return;
            Map<String,Object> next=new LinkedHashMap<>(stepMap(receipt.steps().get(step)));
            next.put("status",status);next.put("counts",counts==null?Map.of():counts);next.remove("errorClass");
            if(error!=null)next.put("errorClass",error.replaceAll("[^A-Za-z0-9_$]", "").substring(0,Math.min(error.replaceAll("[^A-Za-z0-9_$]", "").length(),100)));
            updateStep(receipt,step,next);});
    }
    private void updateStep(Receipt receipt,String step,Map<String,Object> value) {
        if(!receipt.steps().containsKey(step))throw denied();
        Map<String,Object> steps=new LinkedHashMap<>(receipt.steps());steps.put(step,value);
        List<String> states=steps.values().stream().map(v->Objects.toString(stepMap(v).get("status"),"PENDING")).toList();
        String state=states.contains("FAILED")?(states.contains("SUCCEEDED")?"PARTIAL":"FAILED")
                :states.contains("RUNNING")?"RUNNING":states.contains("PENDING")?"PENDING":states.contains("SKIPPED")?"PARTIAL":"SUCCEEDED";
        Map<String,Object> p=params(receipt.id());p.put("steps",encode(steps));p.put("state",state);
        jdbc.update("UPDATE sales_document_learning_receipts SET steps=CAST(:steps AS jsonb),state=:state,updated_at=now() WHERE id=:id",p);
    }
    public record Receipt(UUID id,SalesLearningRequest request,Map<String,Object> evidence,Map<String,Object> steps,
                          String state,OffsetDateTime retryUntil,OffsetDateTime updatedAt) { }
    @Transactional(readOnly=true) public List<Receipt> forDocument(String type,UUID doc) {
        return jdbc.query("SELECT * FROM sales_document_learning_receipts WHERE doc_type=:type AND doc_id=:doc ORDER BY saved_sequence DESC LIMIT 20",
                Map.of("type",type,"doc",doc),(rs,row)->receipt(rs));
    }
    @Transactional(readOnly=true) public Receipt owned(UUID id) { return load(id,false); }
    private Receipt locked(UUID id) { return load(id,true); }
    private Receipt load(UUID id,boolean lock) {
        if(id==null)throw denied();
        Receipt receipt=jdbc.query("SELECT * FROM sales_document_learning_receipts WHERE id=:id"+(lock?" FOR UPDATE":""),params(id),(rs,row)->receipt(rs))
                .stream().findFirst().orElseThrow(()->new ApiException(ErrorCode.NOT_FOUND,"学习回执不存在"));
        if(!current.requireId().equals(receipt.request().actorUserId()))throw denied();return receipt;
    }
    private Receipt receipt(java.sql.ResultSet rs)throws java.sql.SQLException {
        try{return new Receipt(rs.getObject("id",UUID.class),json.readValue(rs.getString("request_payload"),SalesLearningRequest.class),
                map(rs.getString("evidence")),map(rs.getString("steps")),rs.getString("state"),rs.getObject("retry_until",OffsetDateTime.class),rs.getObject("updated_at",OffsetDateTime.class));}
        catch(java.io.IOException invalid){throw new IllegalStateException("Invalid learning receipt",invalid);}
    }
    static Set<String> sourceKeys(SalesLearningRequest request,UUID job) {
        String prefix=job+":";Set<String> keys=new LinkedHashSet<>();
        for(var line:request.lines())if(line.intakeLineKey()!=null) {
            String key=line.intakeLineKey();
            if(key.startsWith(prefix))keys.add(key.substring(prefix.length()));
            else if(job.equals(request.intakeJobId())&&!key.contains(":"))keys.add(key);
        }
        return keys;
    }
    private static boolean recent(Object value){try{return OffsetDateTime.parse(value.toString()).isAfter(OffsetDateTime.now().minusMinutes(5));}catch(RuntimeException invalid){return false;}}
    private static String step(String kind,UUID job){if(!Set.of("LAYOUT","TEMPLATE","MASTER","CONSUME").contains(kind))throw denied();return job==null?kind:kind+":"+job;}
    private static Map<String,Object> pending(){return Map.of("status","PENDING","attempts",0);}
    @SuppressWarnings("unchecked") private static Map<String,Object> stepMap(Object value){return value instanceof Map<?,?>?(Map<String,Object>)value:Map.of();}
    private static Map<String,Object> params(UUID id){return new HashMap<>(Map.of("id",id));}
    private Map<String,Object> map(String value){try{return json.readValue(value,new TypeReference<LinkedHashMap<String,Object>>(){});}catch(Exception invalid){throw new IllegalStateException("Invalid learning state",invalid);}}
    private String encode(Object value){try{return json.writeValueAsString(value);}catch(Exception invalid){throw new IllegalStateException(invalid);}}
    private static ApiException denied(){return new ApiException(ErrorCode.FORBIDDEN,"只能由原保存人处理该学习任务");}
}
