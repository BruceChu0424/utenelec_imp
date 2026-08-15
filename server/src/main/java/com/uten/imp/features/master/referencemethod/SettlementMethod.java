package com.uten.imp.features.master.referencemethod;

import com.uten.imp.common.domain.SoftDeletableEntity;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Table;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "settlement_methods")
public class SettlementMethod extends SoftDeletableEntity {
    @Column(name = "legacy_id", unique = true)
    private Integer legacyId;
    @Column(nullable = false, unique = true)
    private String code;
    @Column(name = "system_role", unique = true)
    private String systemRole;
    @Column(name = "legacy_code")
    private String legacyCode;
    @Column(nullable = false)
    private String name;
    @Column(nullable = false)
    private String status = "使用";
    @Column(name = "sort_order", nullable = false)
    private Integer sortOrder = 0;
    private String remark;
}
