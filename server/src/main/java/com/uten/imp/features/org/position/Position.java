package com.uten.imp.features.org.position;

import com.uten.imp.common.domain.SoftDeletableEntity;
import com.uten.imp.features.org.department.Department;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.FetchType;
import jakarta.persistence.JoinColumn;
import jakarta.persistence.ManyToOne;
import jakarta.persistence.Table;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

/** 岗位（挂在部门下）。 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "positions")
public class Position extends SoftDeletableEntity {

    private String code;

    private String name;

    @ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "department_id")
    private Department department;

    private String level;

    @Column(name = "sort_order")
    private Integer sortOrder = 0;
}
