package com.uten.imp;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

/**
 * Uten IMP 后端入口。
 *
 * <p>人事 / 鉴权 / 组织模块。技术栈：Spring Boot 3 + Spring Security 6 (stateless JWT) +
 * Spring Data JPA + Flyway + PostgreSQL (pgcrypto)。
 *
 * <p>启动后由 Flyway 自动执行 {@code db/migration} 下的迁移建表与种子。
 * 引导超管账号（admin）由 BootstrapRunner 在首次启动时按 {@code BOOTSTRAP_ADMIN_PASSWORD}
 * 用 Argon2id 哈希创建，首登强制改密。
 */
@SpringBootApplication
public class UtenImpApplication {

    public static void main(String[] args) {
        SpringApplication.run(UtenImpApplication.class, args);
    }
}
