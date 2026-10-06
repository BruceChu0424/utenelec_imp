package com.uten.imp.application.port;

import java.util.List;
import java.util.Set;

/**
 * The reviewed feature and page directory (ADR-153 amendment, ADR-159), owned by the permission catalog's feature: which
 * modules and pages a reader opens under the client route guard's rule. The AI assistant reads it to tell the model the
 * modules the user can open and to check the page names and menu paths an answer quotes. Only words cross this port
 * (titles, other names, module names, menu paths), never routes or permission codes.
 */
public interface AiFeatureDirectoryPort {
    /** The modules and pages a reader holding {@code permissions} opens; everything for a super administrator. */
    Openable openable(Set<String> permissions, boolean superAdmin);

    /**
     * @param modules the module names of the pages the reader opens, in directory order
     * @param labels  the titles, other names, menu steps and whole menu paths ("工作台 > 销售管理 > 销售订货单") of those pages
     */
    record Openable(List<String> modules, List<String> labels) {
        public static final Openable EMPTY = new Openable(List.of(), List.of());

        public Openable {
            modules = List.copyOf(modules);
            labels = List.copyOf(labels);
        }
    }
}
