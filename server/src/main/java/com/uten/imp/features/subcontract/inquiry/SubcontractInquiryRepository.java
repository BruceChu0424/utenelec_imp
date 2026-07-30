package com.uten.imp.features.subcontract.inquiry;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.JpaSpecificationExecutor;

import java.util.Optional;
import java.util.UUID;

/**
 * 委外询价单主表仓库。列表用 {@link JpaSpecificationExecutor} 动态筛选。
 */
public interface SubcontractInquiryRepository
        extends JpaRepository<SubcontractInquiry, UUID>, JpaSpecificationExecutor<SubcontractInquiry> {

    Optional<SubcontractInquiry> findByLegacyId(Integer legacyId);
}
