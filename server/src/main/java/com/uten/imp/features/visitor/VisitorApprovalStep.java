package com.uten.imp.features.visitor;

import com.uten.imp.common.domain.BaseEntity;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Table;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.time.OffsetDateTime;
import java.util.UUID;

/**
 * 访客审批轨迹（submit/forward/hostConfirm/hostReject/approve/reject/checkIn），用于时间线展示。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "visitor_approval_steps")
public class VisitorApprovalStep extends BaseEntity {

    @Column(name = "application_id", nullable = false)
    private UUID applicationId;

    @Column(name = "actor_type")
    private String actorType;   // visitor / staff

    @Column(name = "actor_id")
    private UUID actorId;

    @Column(nullable = false)
    private String action;      // submit/forward/hostConfirm/hostReject/approve/reject/checkIn

    @Column
    private String comment;

    @Column(name = "acted_at", nullable = false)
    private OffsetDateTime actedAt = OffsetDateTime.now();
}
