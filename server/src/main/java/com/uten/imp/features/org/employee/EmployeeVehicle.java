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

/** 员工车辆（1:N，全部非必填）。plateNorm=大写去空白，用于查重与「按车牌找人」。 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "employee_vehicles")
public class EmployeeVehicle extends BaseEntity {

    @ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "employee_id", nullable = false)
    private Employee employee;

    @Column(name = "plate_no", nullable = false)
    private String plateNo;

    @Column(name = "plate_norm", nullable = false)
    private String plateNorm;

    @Column(name = "vehicle_type")
    private String vehicleType;

    @Column(name = "brand_model")
    private String brandModel;

    private String color;

    private String remark;

    @Column(name = "sort_order")
    private Integer sortOrder = 0;

    /** 车牌规范化：去空白、全大写（中文省份字保留）。 */
    public static String normalizePlate(String raw) {
        return raw == null ? null : raw.replaceAll("\\s+", "").toUpperCase(java.util.Locale.ROOT);
    }
}
