package com.uten.imp.features.org.department;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.org.department.dto.*;
import com.uten.imp.features.org.employee.Employee;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.OffsetDateTime;
import java.util.*;

@Service
@RequiredArgsConstructor
public class DepartmentService {

    private final DepartmentRepository deptRepo;
    private final EmployeeRepository empRepo;
    private final EntityManager em;
    private final TxSessionVars tx;

    @Transactional(readOnly = true)
    public List<DepartmentNode> tree() {
        return buildTree(deptRepo.findByDeletedFalseOrderById(), null);
    }

    @Transactional(readOnly = true)
    public List<DepartmentNode> subtree(UUID rootId) {
        requireDept(rootId);
        return buildTree(deptRepo.findSubtree(rootId), rootId);
    }

    @Transactional(readOnly = true)
    public DepartmentDetail detail(UUID id) {
        Department d = requireDept(id);
        UUID parentId = d.getParent() == null ? null : d.getParent().getId();
        String parentName = d.getParent() == null ? null : d.getParent().getName();
        UUID managerId = d.getManager() == null ? null : d.getManager().getId();
        String managerName = d.getManager() == null ? null : d.getManager().getFullName();
        long childCount = deptRepo.findByParentIdOrderBySortOrderAscNameAsc(id).size();
        long empCount = empRepo.countByDepartmentIdAndDeletedFalse(id);
        return new DepartmentDetail(d.getId(), d.getCode(), d.getName(), d.getLevel(),
                parentId, parentName, managerId, managerName, d.getSortOrder(), d.getHeadcount(),
                d.getPath(), childCount, empCount);
    }

    @Transactional
    public DepartmentDetail create(DepartmentSaveRequest req) {
        tx.bind();
        if (deptRepo.existsByCode(req.getCode())) {
            throw new ApiException(ErrorCode.CONFLICT, "部门编码已存在");
        }
        Department d = new Department();
        d.setCode(req.getCode());
        d.setName(req.getName());
        d.setLevel(req.getLevel());
        d.setSortOrder(req.getSortOrder() == null ? 0 : req.getSortOrder());
        if (req.getParentId() != null) {
            d.setParent(requireDept(req.getParentId()));
        }
        if (req.getManagerId() != null) {
            d.setManager(empRepo.findById(req.getManagerId())
                    .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "负责人员工不存在")));
        }
        deptRepo.save(d);
        em.flush();
        em.refresh(d);   // 触发器计算 path 后刷新
        return detail(d.getId());
    }

    @Transactional
    public DepartmentDetail update(UUID id, DepartmentUpdateRequest req) {
        tx.bind();
        Department d = requireDept(id);
        d.setName(req.getName());
        if (req.getSortOrder() != null) {
            d.setSortOrder(req.getSortOrder());
        }
        if (req.getManagerId() != null) {
            d.setManager(empRepo.findById(req.getManagerId())
                    .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "负责人员工不存在")));
        }
        if (req.getParentId() != null) {
            if (req.getParentId().equals(id)) {
                throw new ApiException(ErrorCode.CONFLICT, "上级不能是自己");
            }
            if (deptRepo.isDescendant(id, req.getParentId())) {
                throw new ApiException(ErrorCode.CONFLICT, "不能将部门挂到其子部门下（会成环）");
            }
            d.setParent(requireDept(req.getParentId()));
        }
        deptRepo.save(d);
        em.flush();
        em.refresh(d);
        return detail(id);
    }

    @Transactional
    public void delete(UUID id) {
        tx.bind();
        Department d = requireDept(id);
        if (!deptRepo.findByParentIdOrderBySortOrderAscNameAsc(id).isEmpty()) {
            throw new ApiException(ErrorCode.CONFLICT, "请先删除该部门的子部门");
        }
        if (empRepo.countByDepartmentIdAndDeletedFalse(id) > 0) {
            throw new ApiException(ErrorCode.CONFLICT, "请先转移该部门的员工");
        }
        d.setDeleted(true);
        d.setDeletedAt(OffsetDateTime.now());
        deptRepo.save(d);
    }

    private Department requireDept(UUID id) {
        return deptRepo.findById(id)
                .filter(d -> !d.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "部门不存在"));
    }

    /** 把扁平部门列表组装为树；rootId 非 null 时仅返回以该节点为根的子树。 */
    private List<DepartmentNode> buildTree(List<Department> all, UUID rootId) {
        Map<UUID, DepartmentNode> map = new LinkedHashMap<>();
        for (Department d : all) {
            map.put(d.getId(), toNode(d));
        }
        List<DepartmentNode> roots = new ArrayList<>();
        for (Department d : all) {
            DepartmentNode node = map.get(d.getId());
            Department parent = d.getParent();
            if (parent == null || !map.containsKey(parent.getId())) {
                if (rootId == null || d.getId().equals(rootId)) {
                    roots.add(node);
                }
            } else {
                map.get(parent.getId()).getChildren().add(node);
            }
        }
        return roots;
    }

    private DepartmentNode toNode(Department d) {
        DepartmentNode n = new DepartmentNode();
        n.setId(d.getId());
        n.setCode(d.getCode());
        n.setName(d.getName());
        n.setLevel(d.getLevel());
        n.setParentId(d.getParent() == null ? null : d.getParent().getId());
        n.setSortOrder(d.getSortOrder());
        n.setHeadcount(d.getHeadcount());
        return n;
    }
}
