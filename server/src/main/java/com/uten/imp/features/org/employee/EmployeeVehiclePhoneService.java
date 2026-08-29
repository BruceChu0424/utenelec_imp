package com.uten.imp.features.org.employee;

import com.uten.imp.common.util.ChinaMobileNumber;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.org.employee.dto.NestedDtos;
import com.uten.imp.security.TxSessionVars;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;

import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.UUID;

import static com.uten.imp.common.util.Strings.isBlank;

/**
 * 员工车辆 / 备用手机号的共享写入逻辑（ADR-021 §二）。
 * HR 编辑（employee:edit / employee:pii:edit）与员工自助（/api/profile/me/**）共用，
 * 权限在各入口 Controller/Service 校验，本类只做校验 + 整体替换写入。
 */
@Service
@RequiredArgsConstructor
public class EmployeeVehiclePhoneService {

    /** 车牌：中文省份字 + 字母数字，普通 7 位 / 新能源 8 位。 */
    private static final java.util.regex.Pattern PLATE =
            java.util.regex.Pattern.compile("^[\\u4e00-\\u9fa5A-Z0-9]{7,8}$");

    private final EmployeeVehicleRepository vehicleRepo;
    private final EmployeePhoneRepository phoneRepo;
    private final EmployeeRepository empRepo;
    private final TxSessionVars tx;

    // ===== 车辆 =====

    public List<NestedDtos.VehicleDto> listVehicles(UUID employeeId) {
        return vehicleRepo.findByEmployeeIdOrderBySortOrderAsc(employeeId).stream()
                .map(v -> new NestedDtos.VehicleDto(v.getId(), v.getPlateNo(),
                        v.getVehicleType(), v.getBrandModel(), v.getColor(), v.getRemark()))
                .toList();
    }

    /** 整体替换车辆列表（空数组 = 清空）。 */
    public void replaceVehicles(Employee employee, List<NestedDtos.VehicleInput> inputs) {
        vehicleRepo.deleteByEmployeeId(employee.getId());
        // 派生删除在 Hibernate 动作队列里排在 INSERT 之后——立即 flush，
        // 否则同事务内重插相同车牌会撞 (employee_id, plate_norm) 唯一索引
        vehicleRepo.flush();
        if (inputs == null) return;
        Set<String> seen = new HashSet<>();
        int order = 0;
        for (NestedDtos.VehicleInput in : inputs) {
            String norm = EmployeeVehicle.normalizePlate(in.plateNo());
            if (isBlank(norm) || !PLATE.matcher(norm).matches()) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED,
                        "车牌号格式不正确(7-8 位，如 粤T12345 / 粤TD12345)");
            }
            if (!seen.add(norm)) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "车牌号重复：" + norm);
            }
            EmployeeVehicle v = new EmployeeVehicle();
            v.setEmployee(employee);
            v.setPlateNo(in.plateNo().trim());
            v.setPlateNorm(norm);
            v.setVehicleType(trimToNull(in.vehicleType()));
            v.setBrandModel(trimToNull(in.brandModel()));
            v.setColor(trimToNull(in.color()));
            v.setRemark(trimToNull(in.remark()));
            v.setSortOrder(in.sortOrder() == null ? order : in.sortOrder());
            vehicleRepo.save(v);
            order++;
        }
    }

    // ===== 备用手机号 =====

    /** 列表：phone 明文由调用方按权限决定（本方法解密，调用方负责掩码）。 */
    public List<PhoneRow> listPhones(UUID employeeId) {
        return phoneRepo.findByEmployeeIdOrderBySortOrderAsc(employeeId).stream()
                .map(p -> new PhoneRow(p.getId(), p.getLabel(), tx.decrypt(p.getPhoneEnc())))
                .toList();
    }

    /** 整体替换备用手机号（空数组 = 清空）；号码规范化 + 员工内查重。 */
    public void replacePhones(Employee employee, List<NestedDtos.PhoneInput> inputs) {
        phoneRepo.deleteByEmployeeId(employee.getId());
        phoneRepo.flush(); // 同 replaceVehicles：先落删除再插入，避免撞唯一索引
        if (inputs == null) return;
        Set<String> seen = new HashSet<>();
        int order = 0;
        for (NestedDtos.PhoneInput in : inputs) {
            String normalized = ChinaMobileNumber.normalize(in.phone())
                    .orElseThrow(() -> new ApiException(
                            ErrorCode.VALIDATION_FAILED, "备用手机号格式不正确"));
            if (!seen.add(normalized)) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "备用手机号重复");
            }
            EmployeePhone p = new EmployeePhone();
            p.setEmployee(employee);
            p.setLabel(isBlank(in.label()) ? "备用" : in.label().trim());
            p.setPhoneEnc(tx.encrypt(normalized));
            p.setPhoneHash(tx.hmac(normalized));
            p.setSortOrder(in.sortOrder() == null ? order : in.sortOrder());
            phoneRepo.save(p);
            order++;
        }
    }

    /** 取本人员工档案（自助入口 /api/profile/me/** 用；未绑定或已删→404）。 */
    public Employee requireEmployee(UUID employeeId) {
        return empRepo.findById(employeeId)
                .filter(e -> !e.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "当前账号未绑定员工档案"));
    }

    public record PhoneRow(UUID id, String label, String phonePlain) {}

    private static String trimToNull(String s) {
        return isBlank(s) ? null : s.trim();
    }
}
