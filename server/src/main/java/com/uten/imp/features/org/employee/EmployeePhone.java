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

/** 员工备用手机号（1:N，加密存储，不参与登录；主手机号仍在 employee_sensitive）。 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "employee_phones")
public class EmployeePhone extends BaseEntity {

    @ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "employee_id", nullable = false)
    private Employee employee;

    @Column(nullable = false)
    private String label = "备用";

    @Column(name = "phone_enc", nullable = false)
    private String phoneEnc;

    @Column(name = "phone_hash")
    private String phoneHash;

    @Column(name = "sort_order")
    private Integer sortOrder = 0;
}
