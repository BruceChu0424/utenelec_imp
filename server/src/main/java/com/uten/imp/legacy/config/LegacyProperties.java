package com.uten.imp.legacy.config;

import lombok.Getter;
import lombok.Setter;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.stereotype.Component;

/**
 * 老库（SQL Server YTDQ_2023）迁移配置。
 * 默认关闭——仅在手动触发数据迁移时显式置 enabled=true，避免误连。
 */
@Getter
@Setter
@Component
@ConfigurationProperties(prefix = "app.legacy")
public class LegacyProperties {

    /** 是否启用老库迁移数据源。 */
    private boolean enabled = false;

    /** 老库 JDBC URL（dev=LocalDB，prod=独立 SQL Server 实例）。 */
    private String datasourceUrl;

    /** 老库账号（LocalDB 集成认证时留空）。 */
    private String datasourceUsername;

    /** 老库密码。 */
    private String datasourcePassword;
}
