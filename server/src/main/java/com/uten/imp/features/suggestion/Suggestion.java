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

/**
 * 建议本体。回复见 {@link SuggestionReply}，点赞见 suggestion_likes（纯关联表无实体）。
 * 匿名标记只控制展示：submitter_name 始终存真实姓名快照，
 * 服务端对匿名建议向「非本人且无 suggestion:reply 权限」的查看者脱敏返回。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "suggestions")
public class Suggestion extends BaseEntity {

    @Column(name = "submitter_id", nullable = false)
    private UUID submitterId;

    /** 提交人姓名快照（提交后改名不回溯） */
    @Column(name = "submitter_name", nullable = false)
    private String submitterName;

    /** product/process/welfare/environment/equipment/other */
    @Column(nullable = false)
    private String category;

    @Column(nullable = false)
    private String title;

    @Column(nullable = false)
    private String content;

    /** submitted/reviewing/resolved/rejected */
    @Column(nullable = false)
    private String status = "submitted";

    @Column(name = "is_anonymous", nullable = false)
    private boolean anonymous = false;

    @Column(name = "submitted_at", nullable = false)
    private Instant submittedAt = Instant.now();
}
