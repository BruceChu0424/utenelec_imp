package com.uten.imp.features.master.learning;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.json.JsonMapper;
import com.uten.imp.application.port.MasterIntakeLookupPort.AliasKind;
import com.uten.imp.application.port.MasterIntakeLookupPort.AliasScope;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.*;

/** Per-document evidence is authoritative; last_source_doc_* remains descriptive only. */
@Component
@RequiredArgsConstructor
class ClientGoodsAliasLedger {
    private static final JsonMapper JSON=JsonMapper.builder().build();
    private final EntityManager em;
    record EvidenceKey(AliasKind kind,String norm,UUID goodsId) { }
    record Retraction(int changed,Set<EvidenceKey> touched,Set<UUID> releasedGlobalIds) {
        static Retraction none(){return new Retraction(0,Set.of(),Set.of());}
    }

    boolean hasActiveEvidence(String docType,UUID docId) {
        if(docType==null||docId==null)return false;
        return Boolean.TRUE.equals(em.createNativeQuery("SELECT EXISTS(SELECT 1 FROM sales_alias_document_evidence WHERE doc_type=:type AND doc_id=:id AND active)")
                .setParameter("type",docType).setParameter("id",docId).getSingleResult());
    }

    /** Reconcile the complete current document, including an explicitly empty alias set. */
    @SuppressWarnings("unchecked")
    Retraction retractChangedMappings(String docType,UUID docId,List<SalesLearningPlanner.AliasUpsert> aliases) {
        return retractChangedMappings(docType,docId,aliases,List.of());
    }

    @SuppressWarnings("unchecked")
    Retraction retractChangedMappings(String docType,UUID docId,List<SalesLearningPlanner.AliasUpsert> aliases,
            List<SalesLearningPlanner.RetainedAlias> retained) {
        em.createNativeQuery("SELECT pg_advisory_xact_lock(hashtextextended(:key,0))")
                .setParameter("key","sales-alias-document:"+docType+":"+docId).getSingleResult();
        List<String> previous=em.createNativeQuery("SELECT DISTINCT alias_kind || ':' || alias_norm FROM sales_alias_document_evidence WHERE doc_type=:type AND doc_id=:id AND active")
                .setParameter("type",docType).setParameter("id",docId).getResultList();
        Set<String> locks=new TreeSet<>(previous);aliases.forEach(a->locks.add(a.kind().name()+":"+a.norm()));
        lockNames(locks);
        List<Map<String,Object>> keep=new ArrayList<>();
        for(var source:retained) {
            Map<String,Object> row=new LinkedHashMap<>();row.put("client_id",source.clientId());row.put("kind",source.kind().name());
            row.put("norm",source.norm());row.put("goods_id",source.goodsId());keep.add(row);
        }
        List<Object[]> removed=em.createNativeQuery("""
                WITH wanted AS (SELECT r.identity FROM jsonb_to_recordset(CAST(:rows AS jsonb)) AS r(identity text)),
                unchanged AS (SELECT * FROM jsonb_to_recordset(CAST(:retained AS jsonb)) AS r(client_id uuid,kind text,norm text,goods_id uuid))
                UPDATE sales_alias_document_evidence e SET active=false,retracted_at=now(),retraction_reason='DOCUMENT_CHANGED',
                    retracted_by=NULLIF(current_setting('app.actor_id',true),'')::uuid
                WHERE e.doc_type=:type AND e.doc_id=:id AND e.active
                  AND NOT EXISTS(SELECT 1 FROM wanted WHERE wanted.identity=e.alias_identity)
                  AND NOT EXISTS(SELECT 1 FROM unchanged k WHERE k.client_id IS NOT DISTINCT FROM e.client_id
                    AND k.kind=e.alias_kind AND k.norm=e.alias_norm AND k.goods_id=e.goods_id)
                RETURNING e.alias_id,e.client_id,e.alias_kind,e.alias_norm,e.goods_id
                """).setParameter("rows",json(rows(aliases))).setParameter("retained",json(keep)).setParameter("type",docType).setParameter("id",docId).getResultList();
        if(removed.isEmpty())return Retraction.none();
        Set<EvidenceKey> touched=new LinkedHashSet<>();Set<UUID> aliasIds=new HashSet<>(),globalIds=new HashSet<>();
        for(Object[] row:removed){aliasIds.add((UUID)row[0]);touched.add(new EvidenceKey(AliasKind.valueOf((String)row[2]),(String)row[3],(UUID)row[4]));if(row[1]==null)globalIds.add((UUID)row[0]);}
        refreshClientConfidence(aliasIds);
        return new Retraction(removed.size(),Set.copyOf(touched),Set.copyOf(globalIds));
    }

    /** Explicit corrections supersede only automatic mappings, never another explicit decision. */
    @SuppressWarnings("unchecked")
    Set<EvidenceKey> supersedeAutoLearned(List<SalesLearningPlanner.AliasUpsert> aliases) {
        List<SalesLearningPlanner.AliasUpsert> explicit=aliases.stream().filter(a->a.scope()==AliasScope.CLIENT&&a.clientId()!=null&&a.explicit()).toList();
        if(explicit.isEmpty())return Set.of();
        List<Object[]> removed=em.createNativeQuery("""
                WITH wanted AS (SELECT * FROM jsonb_to_recordset(CAST(:rows AS jsonb))
                    AS r(client_id uuid,kind text,norm text,context text,goods_id uuid))
                DELETE FROM client_goods_aliases a USING wanted r
                WHERE a.client_id=r.client_id AND a.alias_kind=r.kind AND a.alias_norm=r.norm
                  AND a.context_norm=r.context AND a.goods_id<>r.goods_id AND a.explicit_count=0
                RETURNING a.alias_kind,a.alias_norm,a.goods_id
                """).setParameter("rows",json(rows(explicit))).getResultList();
        Set<EvidenceKey> touched=new LinkedHashSet<>();
        for(Object[] row:removed)touched.add(new EvidenceKey(AliasKind.valueOf((String)row[0]),(String)row[1],(UUID)row[2]));
        return touched;
    }

    @SuppressWarnings("unchecked")
    int upsert(String docType,UUID docId,UUID actor,List<SalesLearningPlanner.AliasUpsert> aliases) {
        if(aliases.isEmpty())return 0;
        String payload=json(rows(aliases));
        List<UUID> ids=em.createNativeQuery("""
                INSERT INTO client_goods_aliases(client_id,alias_kind,alias_text,alias_norm,context_norm,goods_id,
                    confirm_count,explicit_count,first_confirmed_at,last_confirmed_at,last_confirmed_by,last_source_doc_type,last_source_doc_id)
                SELECT r.client_id,r.kind,r.text,r.norm,r.context,r.goods_id,1,0,now(),now(),:actor,:type,:doc
                FROM jsonb_to_recordset(CAST(:rows AS jsonb)) AS r(client_id uuid,kind text,text text,norm text,context text,goods_id uuid)
                ORDER BY r.kind,r.norm,r.goods_id,r.client_id NULLS FIRST,r.context
                ON CONFLICT ON CONSTRAINT uq_client_goods_aliases_key DO UPDATE SET
                    alias_text=EXCLUDED.alias_text,last_confirmed_at=GREATEST(client_goods_aliases.last_confirmed_at,EXCLUDED.last_confirmed_at),
                    last_confirmed_by=EXCLUDED.last_confirmed_by,last_source_doc_type=EXCLUDED.last_source_doc_type,
                    last_source_doc_id=EXCLUDED.last_source_doc_id,updated_at=now()
                RETURNING id
                """).setParameter("rows",payload).setParameter("actor",actor).setParameter("type",docType).setParameter("doc",docId).getResultList();
        em.createNativeQuery("""
                INSERT INTO sales_alias_document_evidence(doc_type,doc_id,alias_identity,alias_id,client_id,alias_kind,
                    alias_text,alias_norm,context_norm,goods_id,explicit_confirmed,last_confirmed_by)
                SELECT :type,:doc,r.identity,a.id,r.client_id,r.kind,r.text,r.norm,r.context,r.goods_id,r.explicit,:actor
                FROM jsonb_to_recordset(CAST(:rows AS jsonb))
                    AS r(identity text,client_id uuid,kind text,text text,norm text,context text,goods_id uuid,explicit boolean)
                JOIN client_goods_aliases a ON a.client_id IS NOT DISTINCT FROM r.client_id
                    AND a.alias_kind=r.kind AND a.alias_norm=r.norm AND a.context_norm=r.context AND a.goods_id=r.goods_id
                ORDER BY r.identity
                ON CONFLICT(doc_type,doc_id,alias_identity) DO UPDATE SET
                    alias_id=EXCLUDED.alias_id,alias_text=EXCLUDED.alias_text,active=true,
                    explicit_confirmed=CASE WHEN sales_alias_document_evidence.active
                        THEN sales_alias_document_evidence.explicit_confirmed OR EXCLUDED.explicit_confirmed ELSE EXCLUDED.explicit_confirmed END,
                    last_confirmed_at=now(),last_confirmed_by=EXCLUDED.last_confirmed_by,retracted_at=NULL,retracted_by=NULL,retraction_reason=NULL
                """).setParameter("rows",payload).setParameter("actor",actor).setParameter("type",docType).setParameter("doc",docId).executeUpdate();
        refreshClientConfidence(new HashSet<>(ids));
        return ids.size();
    }

    /** Do not double-count an opaque historical baseline plus a re-saved old document. */
    private void refreshClientConfidence(Set<UUID> ids) {
        if(ids.isEmpty())return;
        em.createNativeQuery("""
                WITH scored AS (
                    SELECT a.id,GREATEST(a.legacy_confirm_count,count(e.id)::integer) AS confirmations,
                        GREATEST(a.legacy_explicit_count,count(e.id) FILTER(WHERE e.explicit_confirmed)::integer) AS explicit_confirmations
                    FROM client_goods_aliases a LEFT JOIN sales_alias_document_evidence e ON e.alias_id=a.id AND e.active
                    WHERE a.id IN(:ids) AND a.client_id IS NOT NULL
                    GROUP BY a.id,a.legacy_confirm_count,a.legacy_explicit_count
                ), with_source AS (
                    SELECT s.*,latest.doc_type,latest.doc_id FROM scored s LEFT JOIN LATERAL
                      (SELECT e.doc_type,e.doc_id FROM sales_alias_document_evidence e
                       WHERE e.alias_id=s.id AND e.active ORDER BY e.last_confirmed_at DESC,e.id DESC LIMIT 1) latest ON true
                ), removed AS (
                    DELETE FROM client_goods_aliases a USING scored s WHERE a.id=s.id AND s.confirmations=0 RETURNING a.id
                )
                UPDATE client_goods_aliases a SET confirm_count=s.confirmations,explicit_count=s.explicit_confirmations,updated_at=now(),
                    last_source_doc_type=COALESCE(s.doc_type,a.legacy_source_doc_type),last_source_doc_id=COALESCE(s.doc_id,a.legacy_source_doc_id)
                FROM with_source s WHERE a.id=s.id AND s.confirmations>0
                  AND (a.confirm_count<>s.confirmations OR a.explicit_count<>s.explicit_confirmations
                    OR a.last_source_doc_id IS DISTINCT FROM COALESCE(s.doc_id,a.legacy_source_doc_id)
                    OR a.last_source_doc_type IS DISTINCT FROM COALESCE(s.doc_type,a.legacy_source_doc_type))
                """).setParameter("ids",ids).executeUpdate();
    }

    /** Global authority counts different customers, never the number of save commands. */
    int refreshGlobalConfidence(Collection<EvidenceKey> keys,Collection<UUID> releasedGlobalIds) {
        if(keys.isEmpty())return 0;
        List<Map<String,Object>> rows=new ArrayList<>();
        for(EvidenceKey key:new LinkedHashSet<>(keys))rows.add(Map.of("kind",key.kind().name(),"norm",key.norm(),"goods_id",key.goodsId()));
        // Take the global-row lock in a separate command so a waiter computes its
        // customer count from a fresh READ COMMITTED snapshot after acquiring it.
        em.createNativeQuery("""
                SELECT a.id FROM client_goods_aliases a
                JOIN jsonb_to_recordset(CAST(:keys AS jsonb)) AS k(kind text,norm text,goods_id uuid)
                  ON a.alias_kind=k.kind AND a.alias_norm=k.norm AND a.goods_id=k.goods_id
                WHERE a.client_id IS NULL ORDER BY a.id FOR UPDATE OF a
                """).setParameter("keys",json(rows)).getResultList();
        Object[] counts=(Object[])em.createNativeQuery("""
                WITH wanted AS (SELECT * FROM jsonb_to_recordset(CAST(:keys AS jsonb)) AS r(kind text,norm text,goods_id uuid)),
                targets AS (SELECT a.*,a.id=ANY(CAST(string_to_array(CAST(:released AS text),',') AS uuid[])) AS released
                    FROM client_goods_aliases a JOIN wanted k
                    ON a.alias_kind=k.kind AND a.alias_norm=k.norm AND a.goods_id=k.goods_id WHERE a.client_id IS NULL),
                scored AS (
                    SELECT g.id,g.legacy_confirm_count,g.released,
                      (SELECT count(DISTINCT c.client_id)::integer FROM client_goods_aliases c
                       WHERE c.client_id IS NOT NULL AND c.alias_kind=g.alias_kind AND c.alias_norm=g.alias_norm AND c.goods_id=g.goods_id) AS clients,
                      (SELECT count(DISTINCT c.client_id)::integer FROM client_goods_aliases c
                       WHERE c.client_id IS NOT NULL AND c.alias_kind=g.alias_kind AND c.alias_norm=g.alias_norm AND c.goods_id=g.goods_id AND c.explicit_count>0) AS explicit_clients,
                      EXISTS(SELECT 1 FROM sales_alias_document_evidence e WHERE e.alias_id=g.id AND e.active) AS has_source
                    FROM targets g
                ), with_source AS (
                    SELECT s.*,latest.doc_type,latest.doc_id FROM scored s LEFT JOIN LATERAL
                      (SELECT e.doc_type,e.doc_id FROM sales_alias_document_evidence e
                       WHERE e.alias_id=s.id AND e.active ORDER BY e.last_confirmed_at DESC,e.id DESC LIMIT 1) latest ON true
                ), removed AS (
                    DELETE FROM client_goods_aliases a USING scored s WHERE a.id=s.id
                      AND s.clients=0 AND (NOT s.has_source OR s.released) AND s.legacy_confirm_count=0 RETURNING a.id
                ), refreshed AS (
                    UPDATE client_goods_aliases a SET confirm_count=GREATEST(1,s.clients),explicit_count=s.explicit_clients,updated_at=now(),
                        last_source_doc_type=COALESCE(s.doc_type,a.legacy_source_doc_type),last_source_doc_id=COALESCE(s.doc_id,a.legacy_source_doc_id)
                    FROM with_source s WHERE a.id=s.id AND (s.clients>0 OR (s.has_source AND NOT s.released) OR s.legacy_confirm_count>0)
                      AND (a.confirm_count<>GREATEST(1,s.clients) OR a.explicit_count<>s.explicit_clients
                        OR a.last_source_doc_id IS DISTINCT FROM COALESCE(s.doc_id,a.legacy_source_doc_id)
                        OR a.last_source_doc_type IS DISTINCT FROM COALESCE(s.doc_type,a.legacy_source_doc_type)) RETURNING a.id
                ) SELECT (SELECT count(*) FROM removed),(SELECT count(*) FROM refreshed)
                """).setParameter("keys",json(rows)).setParameter("released",releasedGlobalIds.stream().map(UUID::toString)
                    .collect(java.util.stream.Collectors.joining(","))).getSingleResult();
        return ((Number)counts[0]).intValue()+((Number)counts[1]).intValue();
    }

    private void lockNames(Set<String> names) {
        if(names.isEmpty())return;
        em.createNativeQuery("""
                WITH names AS MATERIALIZED(SELECT value FROM jsonb_array_elements_text(CAST(:names AS jsonb)) ORDER BY value)
                SELECT pg_advisory_xact_lock(hashtextextended('sales-alias-name:' || value,0)) FROM names
                """).setParameter("names",json(names)).getResultList();
        // Manual dictionary deletion locks a client alias before its global
        // projection. Keep the same order before touching any evidence rows.
        em.createNativeQuery("""
                SELECT a.id FROM client_goods_aliases a
                WHERE a.alias_kind || ':' || a.alias_norm IN
                    (SELECT value FROM jsonb_array_elements_text(CAST(:names AS jsonb)))
                ORDER BY (a.client_id IS NULL),a.id FOR UPDATE
                """).setParameter("names",json(names)).getResultList();
    }
    private static List<Map<String,Object>> rows(List<SalesLearningPlanner.AliasUpsert> aliases) {
        Map<String,Map<String,Object>> unique=new LinkedHashMap<>();
        for(var alias:aliases) {
            Map<String,Object> row=new LinkedHashMap<>();
            row.put("client_id",alias.scope()==AliasScope.GLOBAL?null:alias.clientId());row.put("kind",alias.kind().name());
            row.put("norm",alias.norm());row.put("context",alias.context());row.put("goods_id",alias.goodsId());
            String identity=sha256(json(row));row.put("identity",identity);row.put("text",alias.text());row.put("explicit",alias.explicit());
            var previous=unique.get(identity);if(previous!=null&&Boolean.TRUE.equals(previous.get("explicit")))row.put("explicit",true);
            unique.put(identity,row);
        }
        return List.copyOf(unique.values());
    }
    private static String sha256(String value){try{return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(value.getBytes(StandardCharsets.UTF_8)));}catch(NoSuchAlgorithmException impossible){throw new IllegalStateException(impossible);}}
    private static String json(Object value){try{return JSON.writeValueAsString(value);}catch(JsonProcessingException failure){throw new IllegalStateException("Unable to encode alias evidence",failure);}}
}
