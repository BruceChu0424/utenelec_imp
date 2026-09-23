package com.uten.imp.audit;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.JpaSpecificationExecutor;
import org.springframework.data.jpa.repository.Query;

import java.time.OffsetDateTime;
import java.util.UUID;

public interface AuditLogRepository
        extends JpaRepository<AuditLog, Long>, JpaSpecificationExecutor<AuditLog> {

    @Query("select coalesce(max(a.id), 0) from AuditLog a")
    long findMaxId();

    /** 查看事件去重: 同一操作人、同一会话、同一对象在窗口内是否已经记过(走操作人+时间索引)。 */
    boolean existsByActorIdAndActionAndTargetTypeAndTargetIdAndSessionIdAndCreatedAtAfter(
            UUID actorId, String action, String targetType, String targetId,
            UUID sessionId, OffsetDateTime since);

    boolean existsByActorIdAndActionAndTargetTypeAndTargetIdAndSessionIdIsNullAndCreatedAtAfter(
            UUID actorId, String action, String targetType, String targetId, OffsetDateTime since);
}
