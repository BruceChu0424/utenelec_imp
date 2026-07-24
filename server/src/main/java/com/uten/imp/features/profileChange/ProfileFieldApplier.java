package com.uten.imp.features.profilechange;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.org.employee.EmergencyContact;
import com.uten.imp.features.org.employee.EmergencyContactRepository;
import com.uten.imp.features.org.employee.Employee;
import com.uten.imp.features.org.employee.EmployeeSensitive;
import com.uten.imp.features.org.employee.EmployeeSensitiveRepository;
import com.uten.imp.security.TxSessionVars;
import org.springframework.stereotype.Component;

import java.util.List;
import java.util.Map;
import java.util.function.BiConsumer;
import java.util.function.Function;

/**
 * 字段读取/应用映射表：fieldCode → reader / 直改 writer / 审核 writer。
 * 紧急联系人子字段（emergencyContact.N.xxx）不走映射表，单独分支处理。
 */
@Component
public class ProfileFieldApplier {

    private final EmergencyContactRepository emergencyRepo;
    private final EmployeeSensitiveRepository sensitiveRepo;
    private final TxSessionVars tx;

    private record FieldAccess(
            Function<Employee, String> reader,
            BiConsumer<Employee, String> directWriter,
            BiConsumer<Employee, String> reviewWriter) {}

    private final Map<String, FieldAccess> fields;

    public ProfileFieldApplier(EmergencyContactRepository emergencyRepo,
                               EmployeeSensitiveRepository sensitiveRepo, TxSessionVars tx) {
        this.emergencyRepo = emergencyRepo;
        this.sensitiveRepo = sensitiveRepo;
        this.tx = tx;
        BiConsumer<Employee, String> phoneWriter = (emp, newValue) -> {
            EmployeeSensitive s = sensitiveRepo.findByEmployeeId(emp.getId())
                    .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "敏感信息不存在"));
            s.setPhoneEnc(safeEncrypt(newValue));
            sensitiveRepo.save(s);
        };
        this.fields = Map.ofEntries(
                Map.entry(ProfileFieldPolicy.Field.FULL_NAME,
                        new FieldAccess(Employee::getFullName, null, Employee::setFullName)),
                Map.entry(ProfileFieldPolicy.Field.ETHNICITY,
                        new FieldAccess(Employee::getEthnicity, Employee::setEthnicity, null)),
                Map.entry(ProfileFieldPolicy.Field.POLITICAL_STATUS,
                        new FieldAccess(Employee::getPoliticalStatus, Employee::setPoliticalStatus, null)),
                Map.entry(ProfileFieldPolicy.Field.MARITAL_STATUS,
                        new FieldAccess(Employee::getMaritalStatus, Employee::setMaritalStatus, null)),
                Map.entry(ProfileFieldPolicy.Field.HUJI_ADDRESS,
                        new FieldAccess(Employee::getHujiAddress, null, Employee::setHujiAddress)),
                Map.entry(ProfileFieldPolicy.Field.RESIDENCE_ADDRESS,
                        new FieldAccess(Employee::getResidenceAddress, Employee::setResidenceAddress, null)),
                Map.entry(ProfileFieldPolicy.Field.OFFICE_PHONE,
                        new FieldAccess(Employee::getOfficePhone, Employee::setOfficePhone, null)),
                Map.entry(ProfileFieldPolicy.Field.EMAIL,
                        new FieldAccess(Employee::getEmail, Employee::setEmail, null)),
                Map.entry(ProfileFieldPolicy.Field.SEAT_NO,
                        new FieldAccess(Employee::getSeatNo, Employee::setSeatNo, null)),
                Map.entry(ProfileFieldPolicy.Field.PHONE,
                        new FieldAccess(this::readPhone, phoneWriter, phoneWriter)));
    }

    private String readPhone(Employee emp) {
        EmployeeSensitive s = sensitiveRepo.findByEmployeeId(emp.getId()).orElse(null);
        return s == null || s.getPhoneEnc() == null ? null : safeDecrypt(s.getPhoneEnc());
    }

    /** 把数据库里的当前值（解密）取出来作为 oldValue。敏感字段走 decrypt。 */
    public String readCurrentValue(Employee emp, String fieldCode) {
        if (fieldCode == null) return null;
        if (ProfileFieldPolicy.isEmergencyContactSubfield(fieldCode)) {
            int idx = ProfileFieldPolicy.emergencyContactIndex(fieldCode);
            String sub = ProfileFieldPolicy.emergencyContactSubfield(fieldCode);
            List<EmergencyContact> list = emergencyRepo.findByEmployeeIdOrderBySortOrderAsc(emp.getId());
            if (idx < 0 || idx >= list.size()) return null;
            EmergencyContact ec = list.get(idx);
            return switch (sub) {
                case "name" -> ec.getName();
                case "relationship" -> ec.getRelationship();
                case "phone" -> ec.getPhoneEnc() == null ? null : safeDecrypt(ec.getPhoneEnc());
                default -> null;
            };
        }
        FieldAccess fa = fields.get(fieldCode);
        return fa == null || fa.reader() == null ? null : fa.reader().apply(emp);
    }

    /** 直改：直接写 employees / employee_sensitive / emergency_contacts。 */
    public void applyDirectEdit(Employee emp, String fieldCode, String newValue) {
        if (ProfileFieldPolicy.isEmergencyContactSubfield(fieldCode)) {
            int idx = ProfileFieldPolicy.emergencyContactIndex(fieldCode);
            String sub = ProfileFieldPolicy.emergencyContactSubfield(fieldCode);
            List<EmergencyContact> list = emergencyRepo.findByEmployeeIdOrderBySortOrderAsc(emp.getId());
            if (idx >= list.size()) throw new ApiException(ErrorCode.VALIDATION_FAILED, "紧急联系人不存在");
            EmergencyContact ec = list.get(idx);
            switch (sub) {
                case "name" -> ec.setName(newValue);
                case "relationship" -> ec.setRelationship(newValue);
                case "phone" -> ec.setPhoneEnc(safeEncrypt(newValue));
                default -> throw new ApiException(ErrorCode.VALIDATION_FAILED, "未知紧急联系人字段：" + sub);
            }
            emergencyRepo.save(ec);
            return;
        }
        FieldAccess fa = fields.get(fieldCode);
        if (fa == null || fa.directWriter() == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "非直改字段：" + fieldCode);
        }
        fa.directWriter().accept(emp, newValue);
    }

    /** 审核通过后应用字段变更。 */
    public void applyReviewedChange(Employee emp, ProfileChangeRequest row) {
        String newValue = row.getNewValueEnc();
        String fieldCode = row.getFieldCode();
        if (ProfileFieldPolicy.isEmergencyContactSubfield(fieldCode)) {
            int idx = ProfileFieldPolicy.emergencyContactIndex(fieldCode);
            String sub = ProfileFieldPolicy.emergencyContactSubfield(fieldCode);
            List<EmergencyContact> list = emergencyRepo.findByEmployeeIdOrderBySortOrderAsc(emp.getId());
            if (idx >= list.size()) throw new ApiException(ErrorCode.VALIDATION_FAILED, "紧急联系人不存在");
            EmergencyContact ec = list.get(idx);
            switch (sub) {
                case "name" -> ec.setName(newValue);
                case "relationship" -> ec.setRelationship(newValue);
                case "phone" -> ec.setPhoneEnc(safeEncrypt(newValue));
            }
            emergencyRepo.save(ec);
            return;
        }
        FieldAccess fa = fields.get(fieldCode);
        if (fa == null || fa.reviewWriter() == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "不支持的审核字段：" + fieldCode);
        }
        fa.reviewWriter().accept(emp, newValue);
    }

    String safeDecrypt(String cipher) {
        try {
            return tx.decrypt(cipher);
        } catch (Exception e) {
            return null;
        }
    }

    private String safeEncrypt(String plain) {
        if (plain == null || plain.isBlank()) return null;
        return tx.encrypt(plain);
    }
}
