package com.uten.imp.features.rbac;

import com.uten.imp.common.util.IdCardUtil;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.org.employee.Employee;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.features.org.employee.EmployeeSensitiveRepository;
import com.uten.imp.features.rbac.dto.UserSummary;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.criteria.Predicate;
import lombok.RequiredArgsConstructor;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.PageRequest;
import org.springframework.data.domain.Sort;
import org.springframework.data.jpa.domain.Specification;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

/** 账号管理（HR）：锁定/启停、重置密码（重哈希身份证后六位）、角色分配、列表。 */
@Service
@RequiredArgsConstructor
public class UserService {

    private final UserAccountRepository userRepo;
    private final EmployeeRepository empRepo;
    private final EmployeeSensitiveRepository sensitiveRepo;
    private final RefreshTokenRepository refreshTokenRepo;
    private final RoleRepository roleRepo;
    private final UserRoleRepository userRoleRepo;
    private final PasswordEncoder passwordEncoder;
    private final TxSessionVars tx;
    private final SecurityContextCurrentUser currentUser;

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
        PageRequest pageable = PageRequest.of(Math.max(0, page - 1), Math.min(Math.max(1, size), 100),
                Sort.by(Sort.Direction.ASC, "loginAccount"));
        Page<UserAccount> p = userRepo.findAll(spec, pageable);
        List<UserSummary> items = p.getContent().stream().map(this::toSummary).toList();
        return new PageResponse<>(items, page, size, p.getTotalElements(), p.getTotalPages());
    }

    private UserSummary toSummary(UserAccount u) {
        Employee e = empRepo.findById(u.getEmployeeId()).orElse(null);
        List<String> roles = userRoleRepo.findRoleCodesByUserId(u.getId());
        return new UserSummary(u.getId(), u.getLoginAccount(),
                e == null ? null : e.getFullName(), e == null ? null : e.getCode(),
                u.getStatus(), u.isMustChangePassword(), u.getLastLoginAt(), roles);
    }

    @Transactional
    public void setStatus(UUID id, String status) {
        tx.bind();
        UserAccount u = require(id);
        u.setStatus(status);
        userRepo.save(u);
    }

    @Transactional
    public void unlock(UUID id) {
        tx.bind();
        UserAccount u = require(id);
        u.setStatus("active");
        u.setFailedAttempts(0);
        u.setLockedUntil(null);
        userRepo.save(u);
    }

    /** 重置密码 = 用该员工身份证后六位重新 Argon2id 哈希；强制下次登录改密；撤销所有令牌。 */
    @Transactional
    public void resetPassword(UUID id) {
        tx.bind();
        UserAccount u = require(id);
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

    @Transactional
    public void assignRoles(UUID id, List<String> roleCodes) {
        tx.bind();
        require(id);
        // 仅 admin 可授予 admin 角色（防 HR 提权，C1）
        if (roleCodes != null && roleCodes.contains("admin")
                && !currentUser.get().map(u -> u.getRoles().contains("admin")).orElse(false)) {
            throw new ApiException(ErrorCode.FORBIDDEN, "仅管理员可授予 admin 角色");
        }
        userRoleRepo.deleteByIdUserId(id);
        for (Role role : roleRepo.findByCodeIn(roleCodes)) {
            UserRole ur = new UserRole();
            ur.setId(new UserRoleId(id, role.getId()));
            userRoleRepo.save(ur);
        }
    }

    private UserAccount require(UUID id) {
        return userRepo.findById(id).filter(u -> !u.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "账号不存在"));
    }
}
