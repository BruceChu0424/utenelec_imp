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
 * 系统设置的当前值 (一行一个设置项)。
 *
 * <p>类型、默认值、取值范围、分组、名称与说明只登记在 {@link SystemSettingKey}; 本表只存值与
 * 最后修改人/时间 (ADR-110)。密钥/部署类配置不在本表。</p>
 */
@Entity
@Table(name = "system_settings")
@Getter
@Setter
@NoArgsConstructor
@AllArgsConstructor
class SystemSetting {

    @Id
    @Column(name = "key")
    private String key;

    @Column(nullable = false)
    private String value;

    // PostgreSQL DEFAULT/BEFORE UPDATE trigger owns the value. Hibernate reads
    // it from the mutation result so a flushed DTO never exposes a stale time.
    @Generated(event = {EventType.INSERT, EventType.UPDATE})
    @Column(name = "updated_at", insertable = false, updatable = false)
    private OffsetDateTime updatedAt;

    @Column(name = "updated_by")
    private UUID updatedBy;
}
