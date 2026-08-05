package com.uten.imp.features.org.employee;

import org.springframework.data.jpa.repository.JpaRepository;

import java.util.Optional;
import java.util.UUID;

public interface EmployeeSensitiveRepository extends JpaRepository<EmployeeSensitive, UUID> {

    Optional<EmployeeSensitive> findByEmployeeId(UUID employeeId);

    /** 按 phone_hash 查（可选：手机号查重/查人）。 */
    Optional<EmployeeSensitive> findByPhoneHash(String phoneHash);

    /** 身份证号 HMAC 查重（创建时）。 */
    boolean existsByIdCardHash(String idCardHash);

    /** 身份证号 HMAC 查重，排除指定员工（更新时）。 */
    boolean existsByIdCardHashAndEmployeeIdNot(String idCardHash, UUID employeeId);

    /** 手机号 HMAC 查重，排除指定员工（更换手机号时）。 */
    boolean existsByPhoneHashAndEmployeeIdNot(String phoneHash, UUID employeeId);
}
