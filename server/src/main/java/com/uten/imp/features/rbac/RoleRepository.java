package com.uten.imp.features.rbac;

import org.springframework.data.jpa.repository.JpaRepository;

import java.util.Collection;
import java.util.List;
import java.util.Optional;

public interface RoleRepository extends JpaRepository<Role, java.util.UUID> {

    Optional<Role> findByCode(String code);

    List<Role> findByCodeIn(Collection<String> codes);
}
