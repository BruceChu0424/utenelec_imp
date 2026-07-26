package com.uten.imp.features.subcontract.inquiry;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;
import java.util.UUID;

/**
 * 委外询价明细仓库。明细独立管理（不走主表 @OneToMany）。
 */
public interface SubcontractInquiryItemRepository extends JpaRepository<SubcontractInquiryItem, UUID> {

    List<SubcontractInquiryItem> findByInquiryIdOrderByLineNoAsc(UUID inquiryId);

    @Modifying
    @Query("DELETE FROM SubcontractInquiryItem i WHERE i.inquiryId = :rid")
    void deleteByInquiryId(@Param("rid") UUID inquiryId);
}
