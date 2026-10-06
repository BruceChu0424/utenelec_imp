package com.uten.imp.features.ai.chat;

import com.uten.imp.application.port.AiFeatureDirectoryPort;
import com.uten.imp.application.port.AiFeatureDirectoryPort.Openable;
import com.uten.imp.security.AuthUser;
import org.springframework.stereotype.Component;

import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * What the current user may open, from the reviewed feature directory ({@link AiFeatureDirectoryPort}: each page's
 * module, title, menu paths and the client route guard's rule, ADR-153 amendment) and the user's own permissions. It
 * gives the system prompt the modules the user can open, and the navigation guard the page titles and menu paths an
 * answer may name. Nothing about the person (name, id, department) is involved.
 */
@Component
public class AiChatUserScope {
    /** No directory: no module line and no directory titles (unit tests, a build without the directory). */
    static final AiChatUserScope NONE = new AiChatUserScope((permissions, superAdmin) -> Openable.EMPTY);
    /** Chat domains in the words the user knows them by. */
    private static final Map<String, String> DOMAIN_NAMES = Map.ofEntries(Map.entry("SELF", "个人事务"),
            Map.entry("SALES", "销售"), Map.entry("PRODUCTION", "生产"), Map.entry("PURCHASE", "采购"),
            Map.entry("WAREHOUSE", "仓库"), Map.entry("FINANCE", "财务"), Map.entry("QUALITY", "品质"),
            Map.entry("SUBCONTRACT", "委外"), Map.entry("HR", "人事"), Map.entry("RD", "研发"), Map.entry("ADMIN", "系统管理"));
    private static final List<String> DOMAIN_ORDER = List.of("SELF", "SALES", "PRODUCTION", "PURCHASE", "SUBCONTRACT",
            "WAREHOUSE", "QUALITY", "FINANCE", "HR", "RD", "ADMIN");

    private final AiFeatureDirectoryPort directory;

    public AiChatUserScope(AiFeatureDirectoryPort directory) {
        this.directory = directory;
    }

    /** The modules the user can open and the page titles and menu paths of the pages they can open. */
    Openable of(AuthUser actor) {
        if (actor == null) return Openable.EMPTY;
        return directory.openable(actor.getPermissions(), actor.isSuperAdmin());
    }

    /** The chat domains in plain words, in a fixed order ("个人事务、销售、仓库"). */
    static List<String> domainNames(Set<String> domains) {
        return DOMAIN_ORDER.stream().filter(domains::contains).map(DOMAIN_NAMES::get).toList();
    }
}
