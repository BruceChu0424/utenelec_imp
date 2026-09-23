package com.uten.imp.common.domain;

import com.fasterxml.jackson.annotation.JsonIgnore;
import jakarta.persistence.Column;
import jakarta.persistence.Id;
import jakarta.persistence.MappedSuperclass;
import jakarta.persistence.PostLoad;
import jakarta.persistence.PostPersist;
import jakarta.persistence.Transient;
import lombok.AccessLevel;
import lombok.Getter;
import lombok.Setter;
import org.springframework.data.domain.Persistable;

import java.util.UUID;

/**
 * 带 UUID 主键 + 审计字段的业务实体基类。
 * 主键在 Java 端生成（{@link UUID#randomUUID()}）；DB 列的 gen_random_uuid() 仅作原始 SQL 插入的兜底。
 *
 * <p>实现 {@link Persistable}: 新 new 出来的实体 {@code isNew()} 为真, Spring Data 的 {@code save()}
 * 直接 persist(一条 INSERT), 不再因为主键预先有值就走 merge 先按主键查一次再插入(ADR-107)。
 * 从库里读出(@PostLoad)或已插入(@PostPersist)后为假, 再 save 走 merge 更新。
 * 主键重复由数据库主键唯一约束拒绝, 不做应用层预查。</p>
 */
@Getter
@Setter
@MappedSuperclass
public abstract class BaseEntity extends AuditableEntity implements Persistable<UUID> {

    @Id
    @Column(updatable = false, nullable = false)
    private UUID id = UUID.randomUUID();

    @Transient
    @JsonIgnore
    @Getter(AccessLevel.NONE)
    @Setter(AccessLevel.NONE)
    private boolean newEntity = true;

    @Override
    @JsonIgnore
    public boolean isNew() {
        return newEntity;
    }

    @PostLoad
    @PostPersist
    void markPersisted() {
        this.newEntity = false;
    }
}
