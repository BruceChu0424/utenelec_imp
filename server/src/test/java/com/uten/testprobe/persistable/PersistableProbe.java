package com.uten.testprobe.persistable;

import com.uten.imp.common.domain.BaseEntity;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Table;
import lombok.Getter;
import lombok.Setter;

/** 只给 BaseEntityPersistablePostgresTest 用的最小实体; 刻意放在应用扫描包 com.uten.imp 之外, 不进应用的实体与仓库扫描。 */
@Getter
@Setter
@Entity
@Table(name = "persistable_probe")
public class PersistableProbe extends BaseEntity {
    @Column(name = "name")
    private String name;
}
