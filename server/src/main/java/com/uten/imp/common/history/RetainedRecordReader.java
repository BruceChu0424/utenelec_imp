package com.uten.imp.common.history;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.domain.SoftDeletableEntity;
import com.uten.imp.common.web.PageResponse;
import jakarta.persistence.EntityManager;
import java.time.Instant;
import java.time.OffsetDateTime;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;

/** Internal reader. Callers MUST first enforce the owning domain's current read
 * and sensitive-original permissions; this intentionally has no generic HTTP route. */
@Component
@RequiredArgsConstructor
@Transactional(readOnly = true)
public class RetainedRecordReader {
    private final EntityManager em;
    private final ObjectMapper mapper;

    public record DocumentRef(UUID id, boolean deleted, OffsetDateTime deletedAt) { }

    public Map<UUID, DocumentHistoryMetadata> metadata(String table, List<DocumentRef> documents,
                                                       boolean historyReadOnly) {
        Map<UUID, DocumentHistoryMetadata> result = new LinkedHashMap<>();
        for (DocumentRef ref : documents) {
            DocumentHistoryMetadata value = new DocumentHistoryMetadata();
            value.setDeleted(ref.deleted());
            value.setDeletedAt(ref.deletedAt() == null ? null : ref.deletedAt().toInstant());
            value.setHistoryReadOnly(historyReadOnly || ref.deleted());
            result.put(ref.id(), value);
        }
        List<String> ids = documents.stream().filter(DocumentRef::deleted)
                .map(ref -> ref.id().toString()).distinct().toList();
        if (ids.isEmpty()) return result;
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                SELECT DISTINCT ON (source_id) source_id, recorded_at, actor_name,
                       payload->>'deleted_reason'
                FROM business_record_history
                WHERE source_table=:table AND source_id IN (:ids) AND operation='SOFT_DELETE'
                ORDER BY source_id,id DESC
                """).setParameter("table", table).setParameter("ids", ids).getResultList();
        for (Object[] row : rows) {
            DocumentHistoryMetadata value = result.get(UUID.fromString((String) row[0]));
            if (value.getDeletedAt() == null) value.setDeletedAt(instant(row[1]));
            value.setDeletedByName((String) row[2]);
            value.setDeletedReason((String) row[3]);
        }
        return result;
    }

    public <T extends DocumentHistoryMetadata> T detail(T view, String table, UUID id,
            boolean deleted, OffsetDateTime deletedAt, boolean historyReadOnly) {
        view.copyHistoryFrom(metadata(table, List.of(new DocumentRef(id, deleted, deletedAt)),
                historyReadOnly).get(id));
        return view;
    }

    public <T extends DocumentHistoryMetadata, E extends SoftDeletableEntity> PageResponse<T> page(
            PageResponse<T> page, String table, List<E> entities) {
        if (page.getItems().size() != entities.size()) throw new IllegalArgumentException("History page mapping differs");
        Map<UUID, DocumentHistoryMetadata> values = metadata(table, entities.stream()
                .map(row -> new DocumentRef(row.getId(), row.isDeleted(), row.getDeletedAt())).toList(), false);
        for (int i = 0; i < entities.size(); i++) page.getItems().get(i).copyHistoryFrom(values.get(entities.get(i).getId()));
        return page;
    }

    public record RetainedRow(long id, String sourceTable, String sourceId, String operation,
                              Instant recordedAt, String actorName, JsonNode original, String originalJson) { }

    /** Bounded cursor page, queried only after domain authorization of the parent. */
    public List<RetainedRow> children(String parentTable, UUID parentId, Long beforeId, int size) {
        return children(parentTable,parentId,beforeId,size,null);
    }

    /** Domain-owned namespaces, never a client-supplied permission selector. The
     * allowlist must include any intermediate retained parent needed by the domain. */
    public List<RetainedRow> children(String parentTable, UUID parentId, Long beforeId, int size,
                                     java.util.Set<String> sourceTables) {
        if(sourceTables!=null && sourceTables.isEmpty())return List.of();
        java.util.Set<String> allowed=sourceTables==null?null:java.util.Set.copyOf(sourceTables);
        int bounded = Math.max(1, Math.min(size, 100));
        String sql="""
                WITH RECURSIVE owned(id,source_table,source_id) AS (
                    SELECT id,source_table,source_id FROM business_record_history
                    WHERE parent_table=:table AND parent_id=:id %s
                    UNION
                    SELECT child.id,child.source_table,child.source_id
                    FROM business_record_history child JOIN owned parent
                      ON child.parent_table=parent.source_table AND child.parent_id=parent.source_id
                    %s
                )
                SELECT h.id,h.source_table,h.source_id,h.operation,h.recorded_at,h.actor_name,CAST(h.payload AS text)
                FROM business_record_history h JOIN owned o ON h.id=o.id
                WHERE (CAST(:before AS bigint) IS NULL OR h.id < CAST(:before AS bigint))
                ORDER BY h.id DESC LIMIT :size
                """.formatted(allowed==null?"":"AND source_table IN (:allowed)",
                        allowed==null?"":"WHERE child.source_table IN (:allowed)");
        var query=em.createNativeQuery(sql).setParameter("table",parentTable).setParameter("id",parentId.toString())
                .setParameter("before",beforeId).setParameter("size",bounded);
        if(allowed!=null)query.setParameter("allowed",allowed);
        @SuppressWarnings("unchecked")
        List<Object[]> rows=query.getResultList();
        return rows.stream().map(row -> new RetainedRow(((Number)row[0]).longValue(),(String)row[1],
                (String)row[2],(String)row[3],instant(row[4]),(String)row[5],parse((String)row[6]),(String)row[6])).toList();
    }

    private JsonNode parse(String json) {
        try { return mapper.reader()
                .with(com.fasterxml.jackson.databind.DeserializationFeature.USE_BIG_DECIMAL_FOR_FLOATS)
                .with(com.fasterxml.jackson.databind.DeserializationFeature.USE_BIG_INTEGER_FOR_INTS)
                .readTree(json); }
        catch (com.fasterxml.jackson.core.JsonProcessingException e) { throw new IllegalStateException("Invalid retained record",e); }
    }

    private static Instant instant(Object value) {
        if (value instanceof Instant instant) return instant;
        if (value instanceof OffsetDateTime offset) return offset.toInstant();
        if (value instanceof java.sql.Timestamp timestamp) return timestamp.toInstant();
        throw new IllegalStateException("Invalid retained record timestamp");
    }
}
