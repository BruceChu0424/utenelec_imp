package com.uten.imp.config;

import com.uten.imp.security.SecurityContextCurrentUser;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.data.domain.AuditorAware;
import org.springframework.data.jpa.repository.config.EnableJpaAuditing;

import java.util.Optional;
import java.util.UUID;

/** JPA 审计：@CreatedDate/@LastModifiedDate + @CreatedBy/@LastModifiedBy 自动填充。 */
@Configuration
@EnableJpaAuditing(auditorAwareRef = "auditorProvider")
public class JpaAuditingConfig {

    @Bean
    public AuditorAware<UUID> auditorProvider(SecurityContextCurrentUser currentUser) {
        return () -> currentUser.id();
    }
}
