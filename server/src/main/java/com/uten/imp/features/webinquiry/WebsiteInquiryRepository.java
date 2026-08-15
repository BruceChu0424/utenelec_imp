package com.uten.imp.features.webinquiry;

import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.Optional;
import java.util.UUID;

public interface WebsiteInquiryRepository extends JpaRepository<WebsiteInquiry, UUID> {

    Optional<WebsiteInquiry> findBySourceId(String sourceId);

    @Query("""
            SELECT w FROM WebsiteInquiry w
            WHERE (:status IS NULL OR w.status = :status)
              AND (:keyword IS NULL OR :keyword = ''
                   OR lower(w.name)    LIKE lower(concat('%', :keyword, '%'))
                   OR lower(w.company) LIKE lower(concat('%', :keyword, '%'))
                   OR lower(w.email)   LIKE lower(concat('%', :keyword, '%'))
                   OR lower(w.phone)   LIKE lower(concat('%', :keyword, '%'))
                   OR lower(w.message) LIKE lower(concat('%', :keyword, '%')))
            """)
    Page<WebsiteInquiry> search(@Param("status") String status,
                                @Param("keyword") String keyword,
                                Pageable pageable);

    long countByStatus(String status);
}
