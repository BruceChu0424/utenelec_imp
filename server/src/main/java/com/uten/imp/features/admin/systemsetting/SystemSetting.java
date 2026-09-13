package com.uten.imp.features.admin.systemsetting;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import jakarta.persistence.Table;
import lombok.AllArgsConstructor;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;
import org.hibernate.annotations.Generated;
import org.hibernate.generator.EventType;

import java.time.OffsetDateTime;
import java.util.UUID;

/**
 * 系统设置项（运行时可配的安全/业务策略阈值）。
 *
 * <p>key 为主键（如 {@code lockout_minutes}）；value 统一存字符串，按 {@link #valueType} 解析。
 * 密钥/部署类配置不在本表（见迁移注释）。
 */
@Entity
@Table(name = "system_settings")
@Getter
@Setter
@NoArgsConstructor
@AllArgsConstructor
public class SystemSetting {

    @Id
    @Column(name = "key")
    private String key;

    @Column(nullable = false)
    private String value;

    @Column(name = "value_type", nullable = false)
    private String valueType = "int";

    @Column(nullable = false)
    private String category;

    @Column(nullable = false)
    private String label;

    @Column
    private String description;

    @Column
    private String unit;

    @Column(name = "sort_order", nullable = false)
    private int sortOrder;

    // PostgreSQL DEFAULT/BEFORE UPDATE trigger owns the value. Hibernate reads
    // it from the mutation result so a flushed DTO never exposes a stale time.
    @Generated(event = {EventType.INSERT, EventType.UPDATE})
    @Column(name = "updated_at", insertable = false, updatable = false)
    private OffsetDateTime updatedAt;

    @Column(name = "updated_by")
    private UUID updatedBy;
}
