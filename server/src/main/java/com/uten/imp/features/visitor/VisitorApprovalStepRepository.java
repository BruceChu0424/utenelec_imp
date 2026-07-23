package com.uten.imp.features.visitor;

import org.springframework.data.jpa.repository.JpaRepository;

import java.util.List;
import java.util.UUID;

public interface VisitorApprovalStepRepository extends JpaRepository<VisitorApprovalStep, UUID> {
    List<VisitorApprovalStep> findByApplicationIdOrderByActedAtAsc(UUID applicationId);
}
