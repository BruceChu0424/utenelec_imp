package com.uten.imp.features.attachment;

import com.uten.imp.common.domain.BaseEntity;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Table;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.util.UUID;

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

    @Column(name = "size_bytes", nullable = false)
    private long sizeBytes;

    /** 服务端在 confirm 时读取对象并计算的可信 SHA-256（hex）。 */
    @Column(name = "sha256", length = 64)
    private String sha256;
}
