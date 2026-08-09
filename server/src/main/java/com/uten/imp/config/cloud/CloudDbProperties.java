package com.uten.imp.config.cloud;

import lombok.Getter;
import lombok.Setter;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.validation.annotation.Validated;
import org.springframework.context.annotation.Profile;
import org.springframework.stereotype.Component;

/**
 * 云端（{@code cloud} profile）双数据源配置：主库（on-prem，经 VPN/专线）+ 副本（云端本地只读）。
 * 由 {@link CloudDataSourceConfig} 装配为 {@link CloudRoutingDataSource}。仅 cloud profile 生效。
 */
@Getter
@Setter
@Component
@Profile("cloud")
@Validated
@ConfigurationProperties(prefix = "app.cloud.db")
public class CloudDbProperties {

    @Valid
    @NotNull
    private Target primary = new Target();
    @Valid
    @NotNull
    private Target replica = new Target();

    @Getter
    @Setter
    public static class Target {
        /** JDBC URL。主库=on-prem（经 VPN/专线）；副本=云端本地 PG。 */
        @NotBlank
        private String url;
        @NotBlank
        private String username;
        @NotBlank
        private String password;
    }
}
