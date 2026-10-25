package com.uten.imp.common.platformcolumns;

import jakarta.persistence.EntityManager;
import java.util.Map;
import java.util.UUID;

/** Used inside a domain transaction after authorizing and locking the original document. */
public final class PlatformRecordFieldForks {
    private PlatformRecordFieldForks() {}

    /** Preserve all original values and provenance under a new lawful record identity. */
    public static void copy(EntityManager em, UUID actor, Map<UUID,UUID> records) {
        for(var record:records.entrySet()) {
            if(record.getKey().equals(record.getValue()))continue;
            em.createNativeQuery("""
                    INSERT INTO platform_record_fields(scope,record_id,version,cells,
                        source_document_id,source_line_index,source_fields_version,created_by,updated_by)
                    SELECT scope,:draft,1,cells,source_document_id,source_line_index,
                        source_fields_version,created_by,:actor
                    FROM platform_record_fields WHERE record_id=:original
                    """).setParameter("draft",record.getValue()).setParameter("original",record.getKey())
                    .setParameter("actor",actor).executeUpdate();
        }
    }
}
