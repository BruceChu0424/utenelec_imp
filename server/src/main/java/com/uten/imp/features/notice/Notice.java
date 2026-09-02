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

    /** announcement/policy/benefit/system/urgent/task/approval/workflow + birthday/anniversary/wedding/newborn */
    @Column(nullable = false)
    private String type;

    /**
     * 互动模式：none=无互动（task/approval/workflow） /
     * acknowledge=回执（announcement/policy/system/urgent/benefit） /
     * bless=祝福（birthday/anniversary/wedding/newborn）。由 {@link NoticeService#interactionModeFor} 派生。
     */
    @Column(name = "interaction_mode", nullable = false)
    private String interactionMode = "none";

    /** 庆典对象员工 ID（仅 bless 类通知）；非庆典类为 null。改名/离职后保留快照不回溯。 */
    @Column(name = "subject_employee_id")
    private java.util.UUID subjectEmployeeId;

    /** 庆典对象姓名快照（与 subject_employee_id 冗余，发布后改名不回溯）。 */
    @Column(name = "subject_name", length = 100)
    private String subjectName;

    /** 节日标签快照（如 生日快乐 / 入职5周年 / 新婚快乐）；非庆典类为 null。 */
    @Column(name = "event_label", length = 100)
    private String eventLabel;

    /** 发布时预设的祝福语模板（字符串数组，前端可一键填充）。null=未预设。 */
    @JdbcTypeCode(SqlTypes.JSON)
    @Column(name = "blessing_templates", columnDefinition = "jsonb")
    private String blessingTemplates;

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

    /** V459：待办聚合类型（如 SALES_ORDER / PROCUREMENT_APPROVAL_CASE）；非空时办结撤回按 (kind,id) 定位。 */
    @Column(name = "aggregate_kind", length = 40)
    private String aggregateKind;

    /** V459：待办聚合主键；历史行为 NULL=不参与撤回。 */
    @Column(name = "aggregate_id")
    private java.util.UUID aggregateId;

    /** V459：业务办结时间；非空=全部接收人弹卡停止展示、通知中心灰显「已办结」。 */
    @Column(name = "resolved_at")
    private Instant resolvedAt;

    /** V459：办结原因短码（APPROVED/REJECTED/CANCELED/COMPLETED/OUTBOUND_CREATED 等）。 */
    @Column(name = "resolved_reason", length = 40)
    private String resolvedReason;
}
