package com.uten.imp.features.suggestion;

import com.uten.imp.common.domain.BaseEntity;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Table;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.time.Instant;
import java.util.UUID;

/** 建议官方回复（人事/管理层）。回复时可顺带推进建议状态。 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "suggestion_replies")
public class SuggestionReply extends BaseEntity {

    @Column(name = "suggestion_id", nullable = false)
    private UUID suggestionId;

    @Column(name = "replier_id", nullable = false)
    private UUID replierId;

    /** 回复人姓名快照 */
    @Column(name = "replier_name", nullable = false)
    private String replierName;

    /** 回复人部门名快照（展示用，如「人事部」） */
    @Column(name = "replier_role", nullable = false)
    private String replierRole = "";

    @Column(nullable = false)
    private String content;

    @Column(name = "replied_at", nullable = false)
    private Instant repliedAt = Instant.now();
}
