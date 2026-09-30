package com.uten.imp.features.sales.template;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.MasterIntakeLookupPort;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.sales.intake.SalesIntakeUsedEvent;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.OffsetDateTime;
import java.util.*;

/** Per-customer serialized classification, immutable presentation versions and exactly-once learning evidence. */
@Service
public class SalesQuoteTemplateStore {
    private final NamedParameterJdbcTemplate jdbc;
    private final ObjectMapper json;
    private final MasterIntakeLookupPort lookup;
    private final SecurityContextCurrentUser currentUser;
    private final AuditService audit;
    private final SalesQuoteTemplateStorage storage;

    public SalesQuoteTemplateStore(NamedParameterJdbcTemplate jdbc, ObjectMapper json, MasterIntakeLookupPort lookup,
                                   SecurityContextCurrentUser currentUser, AuditService audit, SalesQuoteTemplateStorage storage) {
        this.jdbc = jdbc; this.json = json; this.lookup = lookup;
        this.currentUser = currentUser; this.audit = audit; this.storage = storage;
    }

    @Transactional(propagation = Propagation.REQUIRES_NEW)
    public void stage(UUID job, UUID actor, String name, QuoteTemplateWorkbook.Candidate candidate) {
        if (job == null || actor == null || candidate == null || currentUser.id().filter(actor::equals).isEmpty()) return;
        Map<String, Object> args = new HashMap<>();
        args.put("job", job); args.put("actor", actor);
        lockJob(args);
        if (!Boolean.TRUE.equals(jdbc.queryForObject("""
                SELECT EXISTS(SELECT 1 FROM ai_jobs WHERE id=:job AND submitted_by_user=:actor AND status='RUNNING')
                """, args, Boolean.class))) return;
        var object = storage.save(candidate.xlsx());
        bindObject(args, object);
        args.put("name", sourceName(name)); args.put("fingerprint", candidate.fingerprint());
        args.put("mapping", encode(candidate.mapping())); args.put("features", encode(candidate.features()));
        jdbc.update("""
                INSERT INTO sales_quote_template_candidates(job_id,actor_user_id,source_name,fingerprint,mapping,features,
                    storage_provider,storage_key,storage_version,storage_size,storage_sha256)
                VALUES(:job,:actor,:name,:fingerprint,CAST(:mapping AS jsonb),CAST(:features AS jsonb),
                    :provider,:key,:objectVersion,:size,:sha)
                ON CONFLICT(job_id) DO UPDATE SET workbook_bytes=NULL,mapping=EXCLUDED.mapping,
                    features=EXCLUDED.features,fingerprint=EXCLUDED.fingerprint,source_name=EXCLUDED.source_name,
                    storage_provider=EXCLUDED.storage_provider,storage_key=EXCLUDED.storage_key,
                    storage_version=EXCLUDED.storage_version,storage_size=EXCLUDED.storage_size,
                    storage_sha256=EXCLUDED.storage_sha256,expires_at=now()+interval '7 days'
                """, args);
        // Generated payloads are already sanitized; the existing exact-identity outbox clears the upload copy after commit.
        jdbc.update("""
                INSERT INTO attachment_object_outbox(operation,storage_provider,storage_key,storage_version,dedupe_key)
                VALUES('DELETE_STAGING',:provider,:key,:objectVersion,
                    :provider || '|DELETE_STAGING|' || :key || '|' || COALESCE(CAST(:objectVersion AS text),'<local>'))
                ON CONFLICT(dedupe_key) DO NOTHING
                """, args);
    }

    @Transactional(propagation = Propagation.REQUIRES_NEW)
    public void adopt(SalesIntakeUsedEvent event) {
        if (event == null || event.jobId() == null || event.userId() == null || event.docId() == null
                || event.clientId() == null || !("quote".equals(event.docType()) || "order".equals(event.docType()))
                || currentUser.id().filter(event.userId()::equals).isEmpty()
                || !lookup.canLearnClientDocument(event.clientId())) return;
        if (event.sourceLineKeys() != null && event.sourceLineKeys().isEmpty()) return;
        Map<String, Object> p = new HashMap<>();
        p.put("verifyLines", event.sourceLineKeys() != null);
        p.put("sourceKeys", event.sourceLineKeys() == null ? List.of("__legacy_internal_event__") : event.sourceLineKeys());
        p.put("job", event.jobId()); p.put("actor", event.userId()); p.put("client", event.clientId());
        p.put("type", event.docType()); p.put("doc", event.docId());
        lockJob(p);
        jdbc.query("SELECT pg_advisory_xact_lock(hashtextextended(CAST(:client AS text),745))", p, rs -> null);
        if (jdbc.queryForObject("SELECT count(*) FROM sales_quote_template_evidence WHERE job_id=:job", p, Integer.class) != 0) return;
        List<Payload> candidates = jdbc.query("""
                SELECT c.workbook_bytes,c.mapping::text,c.features::text,c.fingerprint,c.source_name,
                    c.storage_provider,c.storage_key,c.storage_version,c.storage_size,c.storage_sha256
                FROM sales_quote_template_candidates c JOIN ai_jobs j ON j.id=c.job_id
                WHERE c.job_id=:job AND c.actor_user_id=:actor AND c.expires_at>now()
                  AND j.submitted_by_user=:actor AND j.status='SUCCEEDED' AND j.result IS NOT NULL
                  AND (j.used_doc_id IS NULL OR (j.used_doc_id=:doc AND j.used_doc_type=:type))
                  AND (NOT :verifyLines OR EXISTS (
                    SELECT 1 FROM jsonb_array_elements(CASE WHEN jsonb_typeof(j.result->'lines')='array'
                        THEN j.result->'lines' ELSE '[]'::jsonb END) AS source(line)
                    WHERE source.line->>'key' IN (:sourceKeys)))
                FOR UPDATE OF c
                """, p, (rs, i) -> payload(rs));
        if (candidates.isEmpty()) return;
        Payload candidate = candidates.getFirst();
        List<TemplateMatch> existing = jdbc.query("""
                SELECT id,current_version,features::text,fingerprint FROM sales_quote_customer_templates WHERE client_id=:client
                ORDER BY last_used_at DESC,id FOR UPDATE
                """, p, (rs, i) -> new TemplateMatch(rs.getObject(1, UUID.class), rs.getInt(2), parseFeatures(rs.getString(3)), rs.getString(4)));
        TemplateMatch match = existing.stream().filter(t -> compatible(t.features(), candidate.features()))
                .max(Comparator.comparingDouble(t -> t.fingerprint().equals(candidate.fingerprint()) ? 2
                        : QuoteTemplateWorkbook.similarity(t.features(), candidate.features()))).orElse(null);
        UUID id = match == null ? UUID.randomUUID() : match.id();
        int version = match == null ? 1 : match.version();
        // Repeated uploads with the same layout have different ZIP timestamps/row counts but are not new versions.
        boolean newVersion = match == null || !match.fingerprint().equals(candidate.fingerprint());
        if (match != null && newVersion) version++;
        p.put("id", id); p.put("fingerprint", candidate.fingerprint()); p.put("features", encode(candidate.features()));
        p.put("name", "客户报价模板 " + (existing.size() + 1)); p.put("source", candidate.sourceName());
        p.put("bytes", candidate.legacyBytes()); p.put("mapping", encode(candidate.mapping())); p.put("version", version);
        bindObject(p, candidate.object());
        p.put("payloadSha", candidate.object() == null ? SalesQuoteTemplateStorage.digest(candidate.legacyBytes()) : candidate.object().sha256());
        if (match == null) {
            jdbc.update("""
                    INSERT INTO sales_quote_customer_templates(id,client_id,name,fingerprint,features)
                    VALUES(:id,:client,:name,:fingerprint,CAST(:features AS jsonb))
                    """, p);
        } else {
            jdbc.update("""
                    UPDATE sales_quote_customer_templates SET current_version=:version,use_count=use_count+1,
                        fingerprint=:fingerprint,features=CAST(:features AS jsonb),last_used_at=now(),updated_at=now() WHERE id=:id
                    """, p);
        }
        if (newVersion) jdbc.update("""
                INSERT INTO sales_quote_template_versions(template_id,version,source_name,source_job_id,
                    workbook_bytes,mapping,payload_sha256,captured_by,
                    storage_provider,storage_key,storage_version,storage_size,storage_sha256)
                VALUES(:id,:version,:source,:job,:bytes,CAST(:mapping AS jsonb),:payloadSha,:actor,
                    :provider,:key,:objectVersion,:size,:sha)
                """, p);
        jdbc.update("""
                INSERT INTO sales_quote_template_evidence(job_id,template_id,client_id,doc_type,doc_id)
                VALUES(:job,:id,:client,:type,:doc)
                """, p);
        // V747's cleanup trigger only releases objects not referenced by an immutable template version.
        jdbc.update("DELETE FROM sales_quote_template_candidates WHERE job_id=:job", p);
        audit.logCommittedSideEffect(event.userId(), null, "learn_sales_quote_template", "sales_quote_customer_templates",
                id.toString(), "保存客户报价样式 v" + version);
    }

    static boolean compatible(Set<String> a, Set<String> b) {
        Set<String> rolesA = new TreeSet<>(), rolesB = new TreeSet<>();
        for (String f : a) if (semantic(f)) rolesA.add(f);
        for (String f : b) if (semantic(f)) rolesB.add(f);
        return rolesA.equals(rolesB) && QuoteTemplateWorkbook.similarity(a, b) >= 0.92;
    }
    private static boolean semantic(String feature) {
        return feature.startsWith("role:") || feature.startsWith("extra:") || feature.startsWith("header:")
                || feature.startsWith("field:") || feature.startsWith("block:");
    }

    public record TemplateView(UUID id, String name, int version, String sourceName, OffsetDateTime lastUsedAt,
                               int useCount, String fileExtension) { }
    public record Stored(byte[] bytes, Map<String, Object> mapping, Set<String> features, String fingerprint, String sourceName) { }
    private record TemplateMatch(UUID id, int version, Set<String> features, String fingerprint) { }
    private record Payload(byte[] legacyBytes, Map<String, Object> mapping, Set<String> features,
                           String fingerprint, String sourceName, SalesQuoteTemplateStorage.ObjectRef object) { }

    @Transactional(readOnly = true)
    public List<TemplateView> list(UUID client) {
        if (client == null) return List.of();
        return jdbc.query("""
                SELECT t.id,t.name,t.current_version,v.source_name,t.last_used_at,t.use_count
                FROM sales_quote_customer_templates t JOIN sales_quote_template_versions v
                  ON v.template_id=t.id AND v.version=t.current_version
                WHERE t.client_id=:client ORDER BY t.last_used_at DESC,t.id
                """, Map.of("client", client), (rs,i) -> new TemplateView(rs.getObject(1,UUID.class),rs.getString(2),
                rs.getInt(3),rs.getString(4),rs.getObject(5,OffsetDateTime.class),rs.getInt(6),"xlsx"));
    }

    @Transactional(readOnly = true)
    public Stored load(UUID client, UUID id) {
        if (client == null || id == null) throw new ApiException(ErrorCode.NOT_FOUND, "报价模板不存在或不属于此客户");
        Payload payload = jdbc.query("""
                SELECT v.workbook_bytes,v.mapping::text,t.features::text,t.fingerprint,v.source_name,
                    v.storage_provider,v.storage_key,v.storage_version,v.storage_size,v.storage_sha256
                FROM sales_quote_customer_templates t JOIN sales_quote_template_versions v
                  ON v.template_id=t.id AND v.version=t.current_version
                WHERE t.id=:id AND t.client_id=:client
                """, Map.of("client",client,"id",id), (rs,i) -> payload(rs)).stream().findFirst()
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND,"报价模板不存在或不属于此客户"));
        return new Stored(payload.object() == null ? payload.legacyBytes() : storage.read(payload.object()),
                payload.mapping(), payload.features(), payload.fingerprint(), payload.sourceName());
    }

    @Transactional(readOnly=true)
    public boolean learnedFrom(SalesIntakeUsedEvent event) {
        if(event.clientId()==null)return false;
        return Boolean.TRUE.equals(jdbc.queryForObject("""
                SELECT EXISTS(SELECT 1 FROM sales_quote_template_evidence WHERE job_id=:job AND client_id=:client
                    AND doc_type=:type AND doc_id=:doc)
                """,Map.of("job",event.jobId(),"client",event.clientId(),"type",event.docType(),"doc",event.docId()),Boolean.class));
    }

    @Transactional
    public void purgeExpired() {
        jdbc.update("""
                DELETE FROM sales_quote_template_candidates c WHERE c.expires_at<now() OR EXISTS (
                    SELECT 1 FROM ai_jobs j WHERE j.id=c.job_id AND (j.status IN ('FAILED','CANCELLED') OR j.used_at IS NOT NULL))
                """, Map.of());
    }
    private void lockJob(Map<String, Object> parameters) {
        jdbc.query("SELECT pg_advisory_xact_lock(hashtextextended(CAST(:job AS text),747))", parameters, rs -> null);
    }
    private Payload payload(ResultSet rs) throws SQLException {
        String provider = rs.getString("storage_provider");
        SalesQuoteTemplateStorage.ObjectRef object = provider == null ? null : new SalesQuoteTemplateStorage.ObjectRef(provider,
                rs.getString("storage_key"),rs.getString("storage_version"),rs.getLong("storage_size"),rs.getString("storage_sha256"));
        return new Payload(rs.getBytes("workbook_bytes"), parseMap(rs.getString("mapping")), parseFeatures(rs.getString("features")),
                rs.getString("fingerprint"), rs.getString("source_name"), object);
    }
    private static void bindObject(Map<String, Object> args, SalesQuoteTemplateStorage.ObjectRef object) {
        args.put("provider", object == null ? null : object.provider()); args.put("key", object == null ? null : object.key());
        args.put("objectVersion", object == null ? null : object.version()); args.put("size", object == null ? null : object.size());
        args.put("sha", object == null ? null : object.sha256());
    }
    private String encode(Object value) { try { return json.writeValueAsString(value); } catch (Exception e) { throw new IllegalStateException(e); } }
    private Map<String,Object> parseMap(String value) { try { return json.readValue(value,new TypeReference<LinkedHashMap<String,Object>>(){}); } catch (Exception e) { throw new IllegalStateException(e); } }
    private Set<String> parseFeatures(String value) { try { return json.readValue(value,new TypeReference<TreeSet<String>>(){}); } catch (Exception e) { throw new IllegalStateException(e); } }
    private static String sourceName(String name) {
        String n = name == null ? "客户表格.xlsx" : name.replaceAll("[\\p{Cntrl}\\\\/]", "_");
        return n.substring(0,Math.min(n.length(),255));
    }
}
