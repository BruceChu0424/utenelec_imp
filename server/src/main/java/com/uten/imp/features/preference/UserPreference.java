package com.uten.imp.features.preference;

import jakarta.persistence.Column;
import jakarta.persistence.EmbeddedId;
import jakarta.persistence.Entity;
import jakarta.persistence.Table;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;
import org.hibernate.annotations.JdbcTypeCode;
import org.hibernate.type.SqlTypes;

import java.time.Instant;

/**
 * 用户偏好（每用户键值 JSON）。pref_value 以 JSON 字符串存储，映射 PostgreSQL JSONB；
 * 读写两端的 JSON 序列化/解析在服务层用 ObjectMapper 完成。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "user_preferences")
public class UserPreference {

    @EmbeddedId
    private UserPreferenceId id;

    @JdbcTypeCode(SqlTypes.JSON)
    @Column(name = "pref_value", nullable = false, columnDefinition = "jsonb")
    private String prefValue;

    @Column(name = "updated_at", nullable = false)
    private Instant updatedAt = Instant.now();
}
