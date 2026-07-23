package com.uten.imp.common.domain;

import jakarta.persistence.Column;
import jakarta.persistence.Id;
import jakarta.persistence.MappedSuperclass;
import lombok.Getter;
import lombok.Setter;

import java.util.UUID;

/**
 * 带 UUID 主键 + 审计字段的业务实体基类。
 * 主键在 Java 端生成（{@link UUID#randomUUID()}）；DB 列的 gen_random_uuid() 仅作原始 SQL 插入的兜底。
 */
@Getter
@Setter
@MappedSuperclass
public abstract class BaseEntity extends AuditableEntity {

    @Id
    @Column(updatable = false, nullable = false)
    private UUID id = UUID.randomUUID();
}
