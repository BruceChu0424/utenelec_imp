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

    /** NORMAL = 普通通知；TODO = 进入接收人的工作台待办。 */
    @Column(nullable = false)
    private String kind = "NORMAL";

    /** TODO 可选的站内办理入口；只能是以 / 开头的应用路由。 */
    @Column(name = "action_route", length = 500)
    private String actionRoute;

    /** 业务事件来源标记（如 PRODUCTION_FINISHED_INBOUND/PRODUCTION_REPORTED），供按事件类型统计未读徽章；NULL=人工/非链路通知。 */
    @Column(name = "source_event", length = 80)
    private String sourceEvent;

    /** TODO 可选截止时间。 */
    @Column(name = "due_at")
    private Instant dueAt;

    @JdbcTypeCode(SqlTypes.JSON)
    @Column(nullable = false, columnDefinition = "jsonb")
    private String attachments = "[]";

    /**
     * 定向投递目标（users.id）。null = 广播（全员可见）；
     * 非空 = 仅该用户可见（approval/task/workflow 类个人业务结果通知用，防隐私泄露）。
     */
    @Column(name = "audience_user_id")
    private java.util.UUID audienceUserId;

    /** all = 全员动态广播；selected = 发布时固化接收人快照。 */
    @Column(name = "audience_scope", nullable = false)
    private String audienceScope = "all";

    /** 发布时生成的可读范围摘要，例如「生产部等 2 个部门、张三等 3 人」。 */
    @Column(name = "audience_summary", nullable = false)
    private String audienceSummary = "全体员工";

    /** selected 模式下去重后的实际接收人数；all 模式为 null。 */
    @Column(name = "audience_count")
    private Integer audienceCount;

    /** 发布时直接选择的部门 id 快照；部门子树解析结果见 notice_user_states。 */
    @JdbcTypeCode(SqlTypes.JSON)
    @Column(name = "target_department_ids", nullable = false, columnDefinition = "jsonb")
    private String targetDepartmentIds = "[]";

    /** 发布时直接选择的员工 id 快照；实际有账号的接收人见 notice_user_states。 */
    @JdbcTypeCode(SqlTypes.JSON)
    @Column(name = "target_employee_ids", nullable = false, columnDefinition = "jsonb")
    private String targetEmployeeIds = "[]";
}
