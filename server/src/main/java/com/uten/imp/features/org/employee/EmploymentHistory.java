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

import java.time.LocalDate;
import java.util.UUID;

/**
 * 任职轨迹（入职/调岗/离职）。按 eventDate 倒序即员工详情页时间线。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "employment_history")
public class EmploymentHistory extends BaseEntity {

    @ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "employee_id", nullable = false)
    private Employee employee;

    @Column(name = "event_type", nullable = false)
    private String eventType;   // onboard / transfer / resign

    @Column(name = "from_dept_id")
    private UUID fromDepartmentId;

    @Column(name = "to_dept_id")
    private UUID toDepartmentId;

    @Column(name = "from_position_id")
    private UUID fromPositionId;

    @Column(name = "to_position_id")
    private UUID toPositionId;

    @Column(name = "event_date", nullable = false)
    private LocalDate eventDate;

    private String remark;
}
