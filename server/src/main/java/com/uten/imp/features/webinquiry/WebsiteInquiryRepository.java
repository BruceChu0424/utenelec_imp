package com.uten.imp.features.webinquiry;

import com.uten.imp.common.util.KeywordSearch;
import com.uten.imp.common.util.NameRefKeyword;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.JpaSpecificationExecutor;
import org.springframework.data.jpa.domain.Specification;

import java.util.ArrayList;
import java.util.Optional;
import java.util.UUID;

public interface WebsiteInquiryRepository extends JpaRepository<WebsiteInquiry, UUID>, JpaSpecificationExecutor<WebsiteInquiry> {

    Optional<WebsiteInquiry> findBySourceId(String sourceId);

    default Page<WebsiteInquiry> search(String status, String keyword, Pageable pageable) {
        Specification<WebsiteInquiry> filter = (root, query, cb) -> {
            var states = status == null ? cb.conjunction() : cb.or(cb.equal(root.get("status"), status),
                    "ACTIVE".equals(status) ? root.get("status").in("new", "following") : cb.disjunction(),
                    "HISTORY".equals(status) ? root.get("status").in("converted", "closed") : cb.disjunction());
            var words = NameRefKeyword.match(root, query, cb, keyword, pattern -> cb.or(
                    NameRefKeyword.text(cb, root.get("name"), pattern), NameRefKeyword.text(cb, root.get("company"), pattern),
                    NameRefKeyword.text(cb, root.get("email"), pattern), NameRefKeyword.text(cb, root.get("phone"), pattern),
                    NameRefKeyword.text(cb, root.get("message"), pattern)));
            if (!KeywordSearch.terms(keyword).isEmpty() && WebsiteInquiry.class.equals(query.getResultType())) {
                String phrase = KeywordSearch.phrase(keyword);
                var names = KeywordSearch.rank(cb, KeywordSearch.exact(cb, root.get("name"), keyword),
                        cb.like(cb.lower(root.get("name")), KeywordSearch.prefixPattern(phrase), '\\'),
                        cb.like(cb.lower(root.get("name")), KeywordSearch.containsPattern(phrase), '\\'),
                        KeywordSearch.allTerms(cb, keyword, root.get("name")));
                var orders = new ArrayList<jakarta.persistence.criteria.Order>();
                orders.add(cb.asc(names)); orders.addAll(query.getOrderList()); query.orderBy(orders);
            }
            return cb.and(states, words);
        };
        var ranked = NameRefKeyword.page(filter, pageable, keyword);
        return findAll(ranked.specification(), ranked.pageable());
    }

    long countByStatus(String status);
}
