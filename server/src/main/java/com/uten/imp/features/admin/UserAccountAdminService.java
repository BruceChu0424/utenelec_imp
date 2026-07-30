package com.uten.imp.features.admin;

import com.uten.imp.common.util.IdCardUtil;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.features.admin.dto.UserSummary;
import com.uten.imp.features.auth.model.RefreshTokenRepository;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.org.department.Department;
import com.uten.imp.features.org.employee.Employee;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.features.org.employee.EmployeeSensitiveRepository;
import com.uten.imp.features.rbac.UserRoleRepository;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.criteria.Predicate;
import lombok.RequiredArgsConstructor;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.data.domain.Sort;
import org.springframework.data.jpa.domain.Specification;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

/** 账号管理（HR）：列表、锁定/启停/解锁、重置密码（重哈希身份证后六位）。 */
@Service
@RequiredArgsConstructor
public class UserAccountAdminService {

    private final UserAccountRepository userRepo;
    private final EmployeeRepository empRepo;
    private final EmployeeSensitiveRepository sensitiveRepo;
    private final RefreshTokenRepository refreshTokenRepo;
    private final UserRoleRepository userRoleRepo;
    private final PasswordEncoder passwordEncoder;
    private final TxSessionVars tx;
    private final AdminUserSupport support;

    @Transactional(readOnly = true)
    public PageResponse<UserSummary> list(int page, int size, String search, String status) {
        Specification<UserAccount> spec = (root, q, cb) -> {
            List<Predicate> ps = new ArrayList<>();
            ps.add(cb.isFalse(root.get("deleted")));
            if (search != null && !search.isBlank()) {
                ps.add(cb.like(cb.lower(root.get("loginAccount")), "%" + search.toLowerCase() + "%"));
            }
            if (status != null && !status.isBlank()) {
                ps.add(cb.equal(root.get("status"), status));
            }
            return cb.and(ps.toArray(new Predicate[0]));
        };
        Pageable pageable = Pageables.of(page, size, Sort.by(Sort.Direction.ASC, "loginAccount"));
        Page<UserAccount> p = userRepo.findAll(spec, pageable);
        List<UserSummary> items = p.getContent().stream().map(this::toSummary).toList();
        return new PageResponse<>(items, page, size, p.getTotalElements(), p.getTotalPages());
    }

    private UserSummary toSummary(UserAccount u) {
        Employee e = empRepo.findById(u.getEmployeeId()).orElse(null);
        Department dept = e == null ? null : e.getDepartment();
        List<String> roles = userRoleRepo.findRoleCodesByUserId(u.getId());
        return new UserSummary(u.getId(), u.getLoginAccount(),
                e == null ? null : e.getFullName(), e == null ? null : e.getCode(),
                dept == null ? null : dept.getId(), dept == null ? null : dept.getName(),
                u.getStatus(), u.isMustChangePassword(), u.getLastLoginAt(), roles);
    }

    @Transactional
    public void setStatus(UUID id, String status) {
        tx.bind();
        UserAccount u = support.require(id);
        u.setStatus(status);
        if ("locked".equals(status)) {
            // 管理员手动锁 = 无限期：清掉暴力破解的临时锁时间戳，
            // 避免 lockedUntil 到期后登录成功路径把 status 恢复为 active
            u.setLockedUntil(null);
        }
        userRepo.save(u);
    }

    @Transactional
    public void unlock(UUID id) {
        tx.bind();
        UserAccount u = support.require(id);
        u.setStatus("active");
        u.setFailedAttempts(0);
        u.setLockedUntil(null);
        userRepo.save(u);
    }

    /** 重置密码 = 用该员工身份证后六位重新 Argon2id 哈希；强制下次登录改密；撤销所有令牌。 */
    @Transactional
    public void resetPassword(UUID id) {
        tx.bind();
        UserAccount u = support.require(id);
        String idPlain = sensitiveRepo.findByEmployeeId(u.getEmployeeId())
                .map(s -> tx.decrypt(s.getIdCardEnc()))
                .orElseThrow(() -> new ApiException(ErrorCode.CONFLICT, "该员工无身份证记录，无法重置为默认密码"));
        u.setPasswordHash(passwordEncoder.encode(IdCardUtil.last6(idPlain)));
        u.setMustChangePassword(true);
        u.setFailedAttempts(0);
        u.setLockedUntil(null);
        u.setStatus("active");
        userRepo.save(u);
        refreshTokenRepo.revokeAllByUserId(id);
    }
}
