package com.uten.imp.features.org.employee;

import com.uten.imp.common.domain.BaseEntity;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.FetchType;
import jakarta.persistence.JoinColumn;
import jakarta.persistence.ManyToOne;
import jakarta.persistence.Table;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

/** 紧急联系人（1:N）。 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "emergency_contacts")
public class EmergencyContact extends BaseEntity {

    @ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "employee_id", nullable = false)
    private Employee employee;

    @Column(nullable = false)
    private String name;

    @Column(name = "phone_enc")
    private String phoneEnc;

    private String relationship;

    @Column(name = "sort_order")
    private Integer sortOrder = 0;
}
