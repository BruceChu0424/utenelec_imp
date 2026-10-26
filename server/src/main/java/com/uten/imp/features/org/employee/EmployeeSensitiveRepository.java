package com.uten.imp.features.org.employee;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.Collection;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

public interface EmployeeSensitiveRepository extends JpaRepository<EmployeeSensitive, UUID> {

    Optional<EmployeeSensitive> findByEmployeeId(UUID employeeId);

    /** 批量取多个员工的敏感记录（通讯录/报表等批量解密场景，避免 N+1）。 */
    List<EmployeeSensitive> findAllByEmployeeIdIn(Collection<UUID> employeeIds);

    /** 按 phone_hash 查（可选：手机号查重/查人）。 */
    Optional<EmployeeSensitive> findByPhoneHash(String phoneHash);

    /** 身份证号 HMAC 查重（创建时）。 */
    boolean existsByIdCardHash(String idCardHash);

    /** 身份证号 HMAC 查重，排除指定员工（更新时）。 */
    boolean existsByIdCardHashAndEmployeeIdNot(String idCardHash, UUID employeeId);
    boolean existsByIdCardHashAndEmployeeIdIn(String idCardHash, Collection<UUID> employeeIds);

    /** 手机号 HMAC 查重，排除指定员工（更换手机号时）。 */
    boolean existsByPhoneHashAndEmployeeIdNot(String phoneHash, UUID employeeId);

    /** Serialize primary-phone claims without imposing a uniqueness rewrite on historical PII. */
    @Query(value="SELECT 1 FROM pg_advisory_xact_lock(hashtextextended('employee-primary-phone:' || CAST(:hash AS text),0))", nativeQuery=true)
    Integer lockPrimaryPhoneHash(@Param("hash") String phoneHash);
}
