package com.uten.imp.features.attachment;

import com.uten.imp.common.domain.BaseEntity;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.EnumType;
import jakarta.persistence.Enumerated;
import jakarta.persistence.Table;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.util.UUID;
import java.time.Instant;

@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "attachments")
public class Attachment extends BaseEntity {

    /** 业务单据类型，如 EXPENSE_CLAIM（报销单）。 */
    @Column(name = "owner_type", nullable = false)
    private String ownerType;

    /** 业务单据 id（软关联，不建外键以保持通用）。 */
    @Column(name = "owner_id", nullable = false)
    private UUID ownerId;

    /** 不透明存储键（UUID+扩展名），二进制在对象存储中的定位。 */
    @Column(name = "storage_key", nullable = false)
    private String storageKey;

    @Column(name = "storage_provider", nullable = false, length = 24)
    private String storageProvider;

    @Column(name = "stored_size_bytes")
    private Long storedSizeBytes;

    @Column(name = "storage_encoding", length = 16)
    private String storageEncoding;

    /** OSS versioning 开启时固定到 confirm 校验过的版本；本地存储为 null。 */
    @Column(name = "storage_version")
    private String storageVersion;

    /** 对象存储返回的 ETag，仅作审计/诊断；可信内容指纹仍是服务端 SHA-256。 */
    @Column(name = "storage_etag")
    private String storageEtag;

    @Column(name = "original_name", nullable = false)
    private String originalName;

    @Column(name = "content_type")
    private String contentType;

    /** 文档分类（员工档案：合同/身份证件/学历证书/照片/其他）；报销等旧附件为 null。 */
    @Column(name = "category", length = 48)
    private String category;

    /** 是否作为员工头像（同员工至多一条，由应用层保证）。 */
    @Column(name = "is_avatar", nullable = false)
    private boolean avatar;

    @Column(name = "size_bytes", nullable = false)
    private long sizeBytes;

    /** 服务端在 confirm 时读取对象并计算的可信 SHA-256（hex）。 */
    @Column(name = "sha256", length = 64)
    private String sha256;

    @Enumerated(EnumType.STRING)
    @Column(name = "lifecycle_state", nullable = false, length = 32)
    private AttachmentLifecycleState lifecycleState = AttachmentLifecycleState.LEGACY_UNVERIFIED;

    @Column(name = "scan_engine", length = 64)
    private String scanEngine;

    @Column(name = "scan_signature")
    private String scanSignature;

    @Column(name = "scanned_at")
    private Instant scannedAt;

    @Column(name = "promoted_at")
    private Instant promotedAt;

    @Column(name = "delete_requested_at")
    private Instant deleteRequestedAt;

    @Column(name = "delete_requested_by")
    private UUID deleteRequestedBy;

    @Column(name = "delete_failure")
    private String deleteFailure;
}
