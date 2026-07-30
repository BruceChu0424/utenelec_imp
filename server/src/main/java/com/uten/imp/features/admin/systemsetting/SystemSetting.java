package com.uten.imp.features.admin.systemsetting;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import jakarta.persistence.Table;
import lombok.AllArgsConstructor;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.time.OffsetDateTime;
import java.util.UUID;

/**
 * 系统设置项（运行时可配的安全/业务策略阈值）。
 *
 * <p>key 为主键（如 {@code lockout_minutes}）；value 统一存字符串，按 {@link #valueType} 解析。
 * 密钥/部署类配置不在本表（见 V72 迁移注释）。
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

    @Column(name = "updated_at", insertable = false) // 由 DB 触发器维护（更新时）
    private OffsetDateTime updatedAt;

    @Column(name = "updated_by")
    private UUID updatedBy;
}
