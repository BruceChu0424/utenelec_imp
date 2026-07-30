package com.uten.imp.features.notice;

import com.uten.imp.common.domain.BaseEntity;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Table;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;
import org.hibernate.annotations.JdbcTypeCode;
import org.hibernate.type.SqlTypes;

import java.time.Instant;

/**
 * 通知本体（广播型）。已读/删除是每用户状态，见 {@link NoticeUserState}。
 * attachments 以 JSON 字符串存储文件名数组（映射 JSONB），序列化在服务层完成。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "notices")
public class Notice extends BaseEntity {

    @Column(nullable = false)
    private String title;

    @Column(nullable = false)
    private String content;

    /** announcement/policy/benefit/system/urgent/task/approval/workflow */
    @Column(nullable = false)
    private String type;

    /** 发布人姓名快照（发布后改名不回溯） */
    @Column(nullable = false)
    private String publisher;

    @Column(name = "published_at", nullable = false)
    private Instant publishedAt = Instant.now();

    @Column(name = "top_priority", nullable = false)
    private boolean topPriority = false;

    /** normal/important/urgent */
    @Column(nullable = false)
    private String priority = "normal";

    @JdbcTypeCode(SqlTypes.JSON)
    @Column(nullable = false, columnDefinition = "jsonb")
    private String attachments = "[]";

    /**
     * 定向投递目标（users.id）。null = 广播（全员可见）；
     * 非空 = 仅该用户可见（approval/task/workflow 类个人业务结果通知用，防隐私泄露）。
     */
    @Column(name = "audience_user_id")
    private java.util.UUID audienceUserId;
}
