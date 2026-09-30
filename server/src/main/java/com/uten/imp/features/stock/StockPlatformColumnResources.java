package com.uten.imp.features.stock;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.platformcolumns.DocumentPlatformColumnAdapter;
import com.uten.imp.common.platformcolumns.PlatformColumnResourceAdapter;
import com.uten.imp.common.platformcolumns.PlatformColumnResourceAdapter.FactDefinition;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import java.util.*;

@Configuration
@RequiredArgsConstructor
public class StockPlatformColumnResources {
    private final EntityManager em;
    private final ObjectMapper json;
    private final SecurityContextCurrentUser current;
    private final StockDocService documents;

    @Bean PlatformColumnResourceAdapter stockDocumentFields() { return resource(false); }
    @Bean PlatformColumnResourceAdapter stockDocumentLineFields() {
        return resource(true).documentRows("SELECT id FROM stock_document_items WHERE doc_id=:document AND NOT is_deleted");
    }

    private DocumentPlatformColumnAdapter resource(boolean lines) {
        return new DocumentPlatformColumnAdapter(lines ? "stock_doc_item" : "stock_doc",
                lines ? "仓库单据明细" : "仓库单据", current, em, json,
                Set.of("stock_doc:view"), Set.of("stock_doc:edit"), Set.of("goods:cost:view"), StockDocument.class,
                lines ? "SELECT id, doc_id FROM stock_document_items WHERE id IN (:ids) AND NOT is_deleted" : null,
                documents::detail, (id, header) -> DocumentPlatformColumnAdapter.draft(header)
                        && header.path("canEdit").asBoolean(false) && !header.path("productionLinked").asBoolean(false),
                List.of(new FactDefinition("qty", "数量 / 盘点账面数量", false), new FactDefinition("weight", "重量(kg)", false),
                        new FactDefinition("countQty", "实盘数量", false), new FactDefinition("countWeight", "实盘重量(kg)", false),
                        new FactDefinition("bookWeight", "账面重量(kg)", false)))
                .documentCreateAuthorities(Set.of("stock_doc:create"));
    }
}
