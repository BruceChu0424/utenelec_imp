package com.uten.imp.features.profilechange;

import com.uten.imp.common.domain.BaseEntity;
import com.uten.imp.features.org.employee.Employee;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Index;
import jakarta.persistence.Table;
import jakarta.persistence.UniqueConstraint;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.time.OffsetDateTime;
import java.util.UUID;

/**
 * 员工个人信息修改申请。
 * <p>
 * 一次提交多字段共用 {@code batchId}；HR 整批批准 / 驳回。
 * <ul>
 *   <li>{@link #status}：pending / approved / rejected / cancelled / applied</li>
 *   <li>{@link #employeeVersion}：提交时 {@code employees.version} 快照；审批时再校验</li>
 *   <li>{@link #idemKey}：客户端幂等键；唯一约束防重复提交</li>
 * </ul>
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(
    name = "profile_change_requests",
    uniqueConstraints = @UniqueConstraint(columnNames = "idem_key"),
    indexes = {
        @Index(name = "pcr_employee_status_idx", columnList = "employee_id, status"),
        @Index(name = "pcr_batch_idx", columnList = "batch_id"),
        @Index(name = "pcr_submitted_at_idx", columnList = "submitted_at DESC"),
    }
)
public class ProfileChangeRequest extends BaseEntity {

    /** 目标员工。 */
    @Column(name = "employee_id", nullable = false)
    private UUID employeeId;

    /** 提交批次（一次提交多字段共用）。 */
    @Column(name = "batch_id", nullable = false)
    private UUID batchId;

    /** 字段机器码（phone / fullName / hujiAddress / emergencyContact.0.phone …）。 */
    @Column(name = "field_code", nullable = false, length = 64)
    private String fieldCode;

    /** 字段显示名（i18n 快照，HR 端直接展示，避免依赖客户端语言）。 */
    @Column(name = "field_label", nullable = false, length = 128)
    private String fieldLabel;

    /** 字段分组：identity / contact / address / emergency / compensation。 */
    @Column(name = "field_group", nullable = false, length = 32)
    private String fieldGroup;

    /** 旧值（pgcrypto 加密；非敏感字段也可能明文）。 */
    @Column(name = "old_value_enc")
    private String oldValueEnc;

    /** 新值（pgcrypto 加密）。 */
    @Column(name = "new_value_enc", nullable = false)
    private String newValueEnc;

    @Column(name = "status", nullable = false, length = 16)
    private String status = "pending";

    /** 提交人 = 员工本人；保留为冗余字段便于审计。 */
    @Column(name = "submitted_by", nullable = false)
    private UUID submittedBy;

    @Column(name = "submitted_at", nullable = false)
    private OffsetDateTime submittedAt = OffsetDateTime.now();

    @Column(name = "reviewed_by")
    private UUID reviewedBy;

    @Column(name = "reviewed_at")
    private OffsetDateTime reviewedAt;

    @Column(name = "review_comment")
    private String reviewComment;

    @Column(name = "employee_version", nullable = false)
    private Integer employeeVersion;

    @Column(name = "idem_key", nullable = false, length = 64, unique = true)
    private String idemKey;
}