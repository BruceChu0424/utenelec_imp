package com.uten.imp.audit;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.GeneratedValue;
import jakarta.persistence.GenerationType;
import jakarta.persistence.Id;
import jakarta.persistence.Table;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;
import org.hibernate.annotations.JdbcTypeCode;
import org.hibernate.type.SqlTypes;

import java.time.OffsetDateTime;
import java.util.UUID;

/**
 * 审计日志。数据变更由 DB 触发器写入；登录/改密等事件由 auth 包各 Service 显式写入。
 * before/after 为 jsonb；数据变更场景由数据库函数先剔除凭证、PII、薪资与自由文本。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "audit_log")
public class AuditLog {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(name = "actor_id")
    private UUID actorId;

    @Column(name = "actor_account")
    private String actorAccount;

    @Column(nullable = false)
    private String action;

    @Column(name = "target_type")
    private String targetType;

    @Column(name = "target_id")
    private String targetId;

    @JdbcTypeCode(SqlTypes.JSON)
    @Column(columnDefinition = "jsonb")
    private String before;

    @JdbcTypeCode(SqlTypes.JSON)
    @Column(columnDefinition = "jsonb")
    private String after;

    private String ip;

    @Column(name = "user_agent")
    private String userAgent;

    private String result;

    @Column(name = "request_id")
    private UUID requestId;

    @Column(name = "event_source", nullable = false)
    private String eventSource = "business";

    @Column(name = "http_method")
    private String httpMethod;

    @Column(name = "http_path")
    private String httpPath;

    @Column(name = "status_code")
    private Integer statusCode;

    @Column(name = "duration_ms")
    private Long durationMs;

    @Column(name = "client_event_id")
    private UUID clientEventId;

    @Column(name = "device_installation_id")
    private UUID deviceInstallationId;

    @Column(name = "device_name")
    private String deviceName;

    @Column(name = "device_manufacturer")
    private String deviceManufacturer;

    @Column(name = "device_model")
    private String deviceModel;

    @Column(name = "device_platform")
    private String devicePlatform;

    @Column(name = "device_os_version")
    private String deviceOsVersion;

    @Column(name = "app_version")
    private String appVersion;

    @Column(name = "app_build")
    private String appBuild;

    @Column(name = "device_form_factor")
    private String deviceFormFactor;

    @Column(name = "device_browser")
    private String deviceBrowser;

    @Column(name = "device_locale")
    private String deviceLocale;

    @Column(name = "device_time_zone")
    private String deviceTimeZone;

    @Column(name = "device_time_zone_offset_minutes")
    private Integer deviceTimeZoneOffsetMinutes;

    @Column(name = "device_is_physical")
    private Boolean deviceIsPhysical;

    @Column(name = "client_event_at")
    private OffsetDateTime clientEventAt;

    @Column(name = "device_capture_status", nullable = false)
    private String deviceCaptureStatus = "missing";

    @Column(name = "device_profile_hash")
    private String deviceProfileHash;

    @Column(name = "risk_level", insertable = false, updatable = false)
    private String riskLevel;

    @Column(name = "event_category", insertable = false, updatable = false)
    private String eventCategory;

    @Column(name = "created_at")
    private OffsetDateTime createdAt = OffsetDateTime.now();
}
