package com.uten.imp.features.companyfiles;

import com.uten.imp.application.port.AttachmentAccessPort;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.companyfiles.CompanyFileDtos.*;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;

import lombok.RequiredArgsConstructor;

import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.ResultSetExtractor;
import org.springframework.jdbc.core.RowMapper;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.Instant;
import java.util.*;

/**
 * Metadata tree only. All bytes, quarantine, quotas, scan and physical retention belong to
 * attachments.
 */
@Service
@RequiredArgsConstructor(onConstructor_ = @org.springframework.beans.factory.annotation.Autowired)
@Transactional(readOnly = true)
public class CompanyFileService {
    public static final String OWNER_TYPE = "COMPANY_FILE";
    /** V958 synthetic ACL subject marking an entry as visible to everyone. */
    public static final String EVERYONE_SUBJECT_TYPE = "ALL";
    public static final UUID EVERYONE_SUBJECT_ID =
            UUID.fromString("00000000-0000-0000-0000-000000000000");
    static final List<String> ACTIONS =
            List.of(
                    "view",
                    "download",
                    "upload",
                    "create",
                    "edit",
                    "move",
                    "delete",
                    "restore",
                    "manage_permissions");
    private static final Map<String, String> PERMISSIONS =
            Map.of(
                    "view",
                    "company_file:view",
                    "upload",
                    "company_file:upload",
                    "create",
                    "company_file:create",
                    "edit",
                    "company_file:edit",
                    "move",
                    "company_file:move",
                    "delete",
                    "company_file:delete",
                    "restore",
                    "company_file:restore",
                    "manage_permissions",
                    "company_file:manage_permissions");
    /** Reading actions stay default-open along the chain; writes need an explicit grant. */
    private static final Set<String> DEFAULT_OPEN_ACTIONS = Set.of("view", "download");
    private static final int MAX_CHILDREN = 500, MAX_DEPTH = 32, MAX_SUBTREE = 5000;
    private final JdbcTemplate jdbc;
    private final SecurityContextCurrentUser currentUser;
    private final AttachmentAccessPort attachments;
    private final AuditService audit;
    private final CompanyFileUnlocks unlocks;
    private final CompanyFileCreationFingerprint creationFingerprints;

    /** Existing callers without initial access settings keep their constructor contract. */
    public CompanyFileService(JdbcTemplate jdbc, SecurityContextCurrentUser currentUser,
            AttachmentAccessPort attachments, AuditService audit, CompanyFileUnlocks unlocks) {
        this(jdbc, currentUser, attachments, audit, unlocks, null);
    }

    public Listing list(
            UUID parentId,
            String search,
            String sort,
            String direction,
            boolean trash,
            int page,
            int size) {
        return list(parentId, search, sort, direction, trash, page, size, Map.of());
    }

    public Listing list(UUID parentId, String search, String sort, String direction,
            boolean trash, int page, int size, Map<String, String> columnSearches) {
        AuthUser user = user();
        requireGlobal(user, "view");
        Scope scope = new Scope(user);
        Node folder = parentId == null ? null : scope.node(parentId);
        if (folder != null) {
            requireFolder(folder);
            scope.require(folder, "view", trash, false);
        }
        List<Breadcrumb> breadcrumbs =
                folder == null
                        ? List.of()
                        : scope.chain(folder).stream()
                                .map(
                                        n ->
                                                new Breadcrumb(
                                                        n.id,
                                                        n.name,
                                                        n.passwordHash != null,
                                                        scope.locked(n)))
                                .toList();
        List<String> rootActions =
                folder == null ? rootActions(user) : scope.actions(folder, trash);
        if (folder != null && scope.locked(folder))
            return new Listing(
                    scope.entry(folder, trash),
                    breadcrumbs,
                    List.of(),
                    0,
                    0,
                    Math.clamp(size, 1, 200),
                    rootActions,
                    false);
        CompanyFileHeaderQuery headers = new CompanyFileHeaderQuery(columnSearches);
        if (trash)
            return listTrash(scope, folder, breadcrumbs, search, sort, direction, page, size, rootActions, headers);
        String query =
                "SELECT n.* FROM company_file_nodes n WHERE n.parent_id IS NOT DISTINCT FROM ? AND"
                        + " n.deleted=?";
        Object[] args = {parentId, trash};
        List<Node> candidates =
                jdbc.query(query + " ORDER BY " + ordering(sort, direction) + " LIMIT 501", NODE, args);
        if (candidates.size() > MAX_CHILDREN)
            throw new ApiException(ErrorCode.CONFLICT, "这个目录内容过多，请联系管理员整理后再打开");
        scope.prime(candidates);
        String needle = search == null ? "" : search.strip().toLowerCase(Locale.ROOT);
        if (needle.length() > 180)
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "搜索内容最多 180 个字符");
        List<Node> visible =
                candidates.stream()
                        .filter(n -> scope.can(n, "view", trash, false))
                        .filter(n -> n.name.toLowerCase(Locale.ROOT).contains(needle))
                        .filter(n -> headerMatches(scope, n, headers))
                        .toList();
        int limit = Math.clamp(size, 1, 200), current = Math.max(0, page);
        long start = Math.min((long) current * limit, visible.size());
        List<Entry> entries =
                visible.subList((int) start, (int) Math.min(start + limit, visible.size())).stream()
                        .map(n -> scope.entry(n, trash))
                        .toList();
        boolean canReorder =
                !trash
                        && needle.isEmpty()
                        && headers.isEmpty()
                        && current == 0
                        && visible.size() <= limit
                        && visible.size() == candidates.size()
                        && (sort == null || sort.equals("manual"))
                        && (direction == null || direction.equals("asc"))
                        && has(user, "move")
                        && candidates.stream().allMatch(n -> scope.can(n, "move", false, true));
        return new Listing(
                folder == null ? null : scope.entry(folder, trash),
                breadcrumbs,
                entries,
                visible.size(),
                current,
                limit,
                rootActions,
                canReorder);
    }

    /** Past deletion batches are not bounded by a directory's current live-item capacity. */
    private Listing listTrash(Scope scope, Node folder, List<Breadcrumb> breadcrumbs,
            String search, String sort, String direction, int page, int size, List<String> rootActions,
            CompanyFileHeaderQuery headers) {
        String needle = search == null ? "" : search.strip().toLowerCase(Locale.ROOT);
        if (needle.length() > 180) throw invalid("搜索内容最多 180 个字符");
        int limit = Math.clamp(size, 1, 200), current = Math.max(0, page);
        long start = (long) current * limit;
        Entry folderEntry = folder == null ? null : scope.entry(folder, true);
        String sql = (folder == null
                ? "SELECT n.* FROM company_file_nodes n LEFT JOIN company_file_nodes p ON"
                    + " p.id=n.parent_id WHERE n.deleted AND (p.id IS NULL OR NOT p.deleted)"
                : "SELECT n.* FROM company_file_nodes n WHERE n.deleted AND n.parent_id=?")
                + " ORDER BY " + ordering(sort, direction);
        return jdbc.query(connection -> {
            var statement = connection.prepareStatement(sql);
            if (folder != null) statement.setObject(1, folder.id);
            statement.setFetchSize(200);
            return statement;
        }, (ResultSetExtractor<Listing>) rows -> {
            long total = 0;
            List<Entry> entries = new ArrayList<>();
            boolean more = true;
            while (more) {
                List<Node> batch = new ArrayList<>(200);
                while (batch.size() < 200 && (more = rows.next())) batch.add(NODE.mapRow(rows, 0));
                // Keep ancestry/ACL/name memory bounded while the transaction's shared lock
                // preserves one policy snapshot for the entire cursor.
                scope.cache.clear();
                scope.aclCache.clear();
                scope.actorNames.clear();
                scope.prime(batch);
                for (Node n : batch) {
                    if (!scope.can(n, "view", true, false)
                            || !n.name.toLowerCase(Locale.ROOT).contains(needle)
                            || !headerMatches(scope, n, headers)) continue;
                    if (total >= start && entries.size() < limit) entries.add(scope.entry(n, true));
                    total++;
                }
            }
            return new Listing(folderEntry, breadcrumbs, List.copyOf(entries), total, current, limit,
                    rootActions, false);
        });
    }

    private static boolean headerMatches(Scope scope, Node n, CompanyFileHeaderQuery headers) {
        Long knownSize = "FILE".equals(n.kind) && !n.pending && n.attachmentId != null ? n.sizeBytes : null;
        return headers.matches(n.kind, n.name, knownSize, scope.actor(n.updatedBy), n.updatedAt);
    }

    public Entry detail(UUID id) {
        Scope s = new Scope(user());
        Node n = s.node(id);
        s.require(n, "view", n.deleted, false);
        return s.entry(n, n.deleted);
    }

    @Transactional
    public Entry createFolder(Create request) {
        return create(request, "FOLDER");
    }

    @Transactional
    public Entry reserveFile(Create request) {
        return create(request, "FILE");
    }

    private Entry create(Create request, String kind) {
        AuthUser user = user();
        requireGlobal(user, "view");
        String action = kind.equals("FOLDER") ? "create" : "upload";
        // Root level has no folder ACL; only a global administration code opens it.
        if (request.parentId() == null) requireGlobal(user, action);
        String name = validName(request.name());
        String description = validDescription(request.description());
        InitialAccess access = request.access();
        Map<String, Acl> initialRules = access == null ? Map.of() : validatedRules(access.rules(), true);
        if (access != null && access.inheritPermissions() == null) throw invalid("请选择访问权限的继承方式");
        String fingerprint = creationFingerprint(user, request, kind, name, description, initialRules);
        List<Map<String, Object>> previous = previousCreation(user.getId(), request.requestId());
        // BCrypt must not hold the exclusive tree lock: one password should not pause every
        // employee's listing, download authorization or unrelated upload confirmation. An
        // already committed receipt also must not rehash on an unknown-result retry.
        String passwordHash = access == null || !previous.isEmpty() ? null : unlocks.hash(access.password());
        treeLock();
        if (request.requestId() != null) {
            // Identity/fingerprint cannot change after insertion. Only new requests need a
            // second lookup to catch another creator that committed during password hashing.
            if (previous.isEmpty()) previous = previousCreation(user.getId(), request.requestId());
            if (!previous.isEmpty()) {
                Map<String, Object> receipt = previous.getFirst();
                if (!fingerprint.equals(receipt.get("request_fingerprint")))
                    throw conflict("这次上传标识已用于不同内容，请重新选择文件");
                Scope existingScope = new Scope(user);
                Node existing = existingScope.node((UUID) receipt.get("id"));
                // A retry is a metadata receipt, not permission/password replacement or a fresh unlock.
                existingScope.require(existing, "view", false, false);
                return existingScope.entry(existing, false);
            }
        }
        Scope scope = new Scope(user);
        Node parent = request.parentId() == null ? null : scope.node(request.parentId());
        if (parent != null) {
            requireFolder(parent);
            scope.require(parent, action, false, true);
            if (scope.chain(parent).size() >= MAX_DEPTH) throw invalid("文件夹最多支持 32 层");
        }
        capacity(request.parentId());
        boolean inherit = access == null || access.inheritPermissions();
        if (access != null && !inherit) {
            List<String> creatorActions = ACTIONS.stream()
                    .filter(a -> parent == null ? has(user, a) : scope.can(parent, a, false, true)).toList();
            String creatorKey = aclKey("USER", user.getId(), "ALLOW");
            Acl selected = initialRules.get(creatorKey);
            Set<String> combined = new TreeSet<>(creatorActions);
            if (selected != null) combined.addAll(selected.actions);
            initialRules.put(creatorKey, new Acl("USER", user.getId(), "ALLOW", List.copyOf(combined)));
            if (initialRules.size() > 100)
                throw invalid("最多设置 100 条访问规则，请为创建人的访问规则保留一个位置");
        }
        UUID id = UUID.randomUUID();
        try {
            jdbc.update(
                    """
                    INSERT INTO company_file_nodes(id,parent_id,kind,name,description,position,pending,created_by,updated_by,request_id,request_fingerprint,inherit_permissions,password_hash)
                    VALUES(?,?,?,?,?,coalesce((SELECT max(position)+1024 FROM company_file_nodes WHERE parent_id IS NOT DISTINCT FROM ?),1024),?,?,?,?,?,?,?)
                    """,
                    id,
                    request.parentId(),
                    kind,
                    name,
                    description,
                    request.parentId(),
                    kind.equals("FILE"),
                    user.getId(),
                    user.getId(),
                    request.requestId(),
                    fingerprint,
                    inherit,
                    passwordHash);
        } catch (DataIntegrityViolationException e) {
            throw conflict("同一目录已存在这个名称，请换一个名称");
        }
        for (Acl rule : initialRules.values()) {
            jdbc.update("INSERT INTO company_file_acl(node_id,subject_type,subject_id,effect,actions) VALUES(?,?,?,?,?::text[])",
                    id, rule.subjectType, rule.subjectId, rule.effect, arrayLiteral(rule.actions));
        }
        Scope createdScope = new Scope(user);
        Node created = createdScope.node(id);
        if (!createdScope.can(created, "view", false, false)
                || (kind.equals("FILE") && !createdScope.canPendingUpload(created))) {
            throw invalid("这些访问设置会使您无法访问或完成新资料，请保留本人所需的访问权限");
        }
        event(user, kind.equals("FOLDER") ? "create" : "upload_reserve", id);
        return createdScope.entry(created, false);
    }

    private List<Map<String, Object>> previousCreation(UUID actor, UUID requestId) {
        return requestId == null ? List.of() : jdbc.queryForList(
                "SELECT id,request_fingerprint FROM company_file_nodes WHERE created_by=? AND request_id=?",
                actor, requestId);
    }

    @Transactional
    public Entry complete(UUID id, Complete request) {
        treeLock();
        AuthUser user = user();
        Scope s = new Scope(user);
        Node n = s.node(id);
        if (!n.kind.equals("FILE")) throw invalid("只能确认文件上传");
        if (!n.createdBy.equals(user.getId()))
            throw new ApiException(ErrorCode.FORBIDDEN, "只能完成自己发起的上传");
        if (!n.pending) {
            requireGlobal(user, "upload");
            s.require(n, "view", false, false);
            if (request.attachmentId().equals(n.attachmentId)) return s.entry(n, false);
            throw conflict("这个文件已完成，不能替换原件");
        }
        s.requirePendingUpload(n);
        checkVersion(n, request.version());
        AttachmentAccessPort.AttachmentView original =
                attachments.listVisible(OWNER_TYPE, id).stream()
                        .filter(a -> a.id().equals(request.attachmentId()) && !a.deleted())
                        .findFirst()
                        .orElseThrow(() -> conflict("文件尚未完成安全检查，请完成上传确认后再重试"));
        requireSameFileExtension(original.originalName(), n.name);
        jdbc.update(
                "UPDATE company_file_nodes SET"
                    + " attachment_id=?,size_bytes=?,content_type=?,pending=false,version=version+1,updated_at=now(),updated_by=?"
                    + " WHERE id=?",
                original.id(),
                original.sizeBytes(),
                original.contentType(),
                user.getId(),
                id);
        event(user, "upload_complete", id);
        return new Scope(user).entry(load(id), false);
    }

    @Transactional
    public Entry edit(UUID id, Edit request) {
        treeLock();
        AuthUser u = user();
        Scope s = new Scope(u);
        Node n = s.node(id);
        s.require(n, "edit", false, true);
        checkVersion(n, request.version());
        String name = validName(request.name());
        if (n.kind.equals("FILE")) requireSameFileExtension(n.name, name);
        try {
            jdbc.update(
                    "UPDATE company_file_nodes SET"
                        + " name=?,description=?,version=version+1,updated_at=now(),updated_by=?"
                        + " WHERE id=?",
                    name,
                    validDescription(request.description()),
                    u.getId(),
                    id);
        } catch (DataIntegrityViolationException e) {
            throw conflict("同一目录已存在这个名称，请换一个名称");
        }
        event(u, "edit", id);
        return new Scope(u).entry(load(id), false);
    }

    @Transactional
    public Entry move(UUID id, Move request) {
        treeLock();
        AuthUser u = user();
        Scope s = new Scope(u);
        Node n = s.node(id);
        s.require(n, "move", false, true);
        checkVersion(n, request.version());
        if (Objects.equals(n.parentId, request.parentId())) return s.entry(n, false);
        Node target = request.parentId() == null ? null : s.node(request.parentId());
        if (target != null) {
            requireFolder(target);
            s.require(target, "move", false, true);
            s.require(target, n.kind.equals("FOLDER") ? "create" : "upload", false, true);
        } else {
            requireGlobal(u, "move");
            requireGlobal(u, n.kind.equals("FOLDER") ? "create" : "upload");
        }
        List<Node> subtree = subtree(id, null);
        s.prime(subtree);
        if (subtree.stream().anyMatch(child -> child.id.equals(request.parentId())))
            throw invalid("不能把文件夹移到自身或其子文件夹内");
        int targetDepth = target == null ? 0 : s.chain(target).size();
        for (Node child : subtree) {
            s.require(child, "move", child.deleted, true);
            if (targetDepth + s.chain(child).size() - s.chain(n).size() + 1 > MAX_DEPTH)
                throw invalid("移动后目录层数超过 32 层");
        }
        capacity(request.parentId());
        try {
            jdbc.update(
                    "UPDATE company_file_nodes SET parent_id=?,position=coalesce((SELECT"
                        + " max(position)+1024 FROM company_file_nodes WHERE parent_id IS NOT"
                        + " DISTINCT FROM ?),1024),version=version+1,updated_at=now(),updated_by=?"
                        + " WHERE id=?",
                    request.parentId(),
                    request.parentId(),
                    u.getId(),
                    id);
        } catch (DataIntegrityViolationException e) {
            throw conflict("目标目录已有同名内容，不能覆盖");
        }
        event(u, "move", id);
        return new Scope(u).entry(load(id), false);
    }

    @Transactional
    public void reorder(Reorder request) {
        treeLock();
        AuthUser u = user();
        Scope s = new Scope(u);
        // Root order has no folder ACL; only a global administration code opens it.
        if (request.parentId() == null) requireGlobal(u, "move");
        if (request.parentId() != null) s.require(s.node(request.parentId()), "move", false, true);
        List<Node> nodes =
                jdbc.query(
                        "SELECT * FROM company_file_nodes WHERE parent_id IS NOT DISTINCT FROM ?"
                                + " AND NOT deleted ORDER BY position,id",
                        NODE,
                        request.parentId());
        Set<UUID> expected = new HashSet<>(nodes.stream().map(n -> n.id).toList());
        if (expected.size() != request.orderedIds().size()
                || !expected.equals(new HashSet<>(request.orderedIds())))
            throw conflict("目录内容已变化，请刷新后重新排列");
        if (request.versions() == null || !expected.equals(request.versions().keySet()))
            throw conflict("目录版本不完整，请刷新后重新排列");
        for (Node n : nodes) checkVersion(n, request.versions().get(n.id));
        s.prime(nodes);
        for (Node n : nodes) s.require(n, "move", false, true);
        for (int i = 0; i < request.orderedIds().size(); i++)
            jdbc.update(
                    "UPDATE company_file_nodes SET"
                        + " position=?,version=version+1,updated_at=now(),updated_by=? WHERE id=?",
                    (long) (i + 1) * 1024,
                    u.getId(),
                    request.orderedIds().get(i));
        event(u, "reorder", request.parentId());
    }

    @Transactional
    public void delete(UUID id, long version) {
        treeLock();
        AuthUser u = user();
        Scope s = new Scope(u);
        Node n = s.node(id);
        checkVersion(n, version);
        if (n.deleted) throw conflict("该内容已在回收站，请刷新");
        List<Node> values = subtree(id, false);
        s.prime(values);
        for (Node child : values) {
            if (child.pending && child.createdBy.equals(u.getId()))
                s.requirePendingUpload(child);
            else s.require(child, "delete", false, true);
        }
        UUID batch = UUID.randomUUID();
        for (Node child : values)
            jdbc.update(
                    "UPDATE company_file_nodes SET"
                        + " deleted=true,deleted_at=now(),deleted_by=?,deletion_batch=?,version=version+1,updated_at=now(),updated_by=?"
                        + " WHERE id=?",
                    u.getId(),
                    batch,
                    u.getId(),
                    child.id);
        event(u, "recycle", id);
    }

    @Transactional
    public Entry restore(UUID id, Version request) {
        treeLock();
        AuthUser u = user();
        Scope s = new Scope(u);
        Node n = s.node(id);
        s.require(n, "restore", true, true);
        checkVersion(n, request.version());
        if (!n.deleted) throw conflict("这个内容已经还原");
        if (n.parentId != null) {
            Node parent = s.node(n.parentId);
            if (parent.deleted) throw conflict("请先还原上层文件夹");
            s.require(parent, "restore", false, true);
        }
        List<Node> values =
                subtree(id, true).stream()
                        .filter(child -> Objects.equals(child.deletionBatch, n.deletionBatch))
                        .toList();
        s.prime(values);
        for (Node child : values) s.require(child, "restore", true, true);
        capacity(n.parentId);
        try {
            for (Node child : values)
                jdbc.update(
                        "UPDATE company_file_nodes SET"
                            + " deleted=false,deleted_at=null,deleted_by=null,deletion_batch=null,version=version+1,updated_at=now(),updated_by=?"
                            + " WHERE id=?",
                        u.getId(),
                        child.id);
        } catch (DataIntegrityViolationException e) {
            throw conflict("原位置已有同名内容，请先重命名或移动同名内容再还原");
        }
        event(u, "restore", id);
        return new Scope(u).entry(load(id), false);
    }

    public Permissions permissions(UUID id) {
        Scope s = new Scope(user());
        Node n = s.node(id);
        s.require(n, "manage_permissions", false, true);
        List<Acl> rules = s.rules(n.id);
        Map<String, Principal> principals = loadPrincipals(rules);
        return new Permissions(
                n.inheritPermissions,
                rules.stream().map(rule -> ruleDto(rule, principals)).toList(),
                n.version);
    }

    @Transactional
    public Entry setPermissions(UUID id, Permissions request) {
        treeLock();
        AuthUser u = user();
        Scope s = new Scope(u);
        Node n = s.node(id);
        s.require(n, "manage_permissions", false, true);
        checkVersion(n, request.version());
        if (u.getImpersonatedBy() != null)
            throw new ApiException(ErrorCode.IMPERSONATION_READ_ONLY);
        Map<String, Acl> desired = validatedRules(request.rules(), false);
        Map<String, Acl> existing = new LinkedHashMap<>();
        for (Acl rule : s.rules(id))
            existing.put(
                    aclKey(rule.subjectType, rule.subjectId, rule.effect),
                    new Acl(
                            rule.subjectType,
                            rule.subjectId,
                            rule.effect,
                            rule.actions.stream().sorted().toList()));
        if (n.inheritPermissions == request.inheritPermissions() && existing.equals(desired))
            return s.can(n, "view", false, false) ? s.entry(n, false) : receipt(n);
        for (var row : existing.entrySet())
            if (!desired.containsKey(row.getKey())) {
                Acl rule = row.getValue();
                jdbc.update(
                        "DELETE FROM company_file_acl WHERE node_id=? AND subject_type=? AND"
                                + " subject_id=? AND effect=?",
                        id,
                        rule.subjectType,
                        rule.subjectId,
                        rule.effect);
            }
        for (var row : desired.entrySet()) {
            Acl rule = row.getValue();
            if (rule.equals(existing.get(row.getKey()))) continue;
            jdbc.update(
                    "INSERT INTO company_file_acl(node_id,subject_type,subject_id,effect,actions)"
                            + " VALUES(?,?,?,?,?::text[]) ON"
                            + " CONFLICT(node_id,subject_type,subject_id,effect) DO UPDATE SET"
                            + " actions=EXCLUDED.actions",
                    id,
                    rule.subjectType,
                    rule.subjectId,
                    rule.effect,
                    arrayLiteral(rule.actions));
        }
        jdbc.update(
                "UPDATE company_file_nodes SET"
                    + " inherit_permissions=?,version=version+1,updated_at=now(),updated_by=? WHERE"
                    + " id=?",
                request.inheritPermissions(),
                u.getId(),
                id);
        // A change never reuses a password capability to bypass current ACL. Every request
        // reevaluates ACL.
        event(u, "permissions_set", id);
        Node updated = load(id);
        Scope refreshed = new Scope(u);
        // Recovery authority or revoking one's own access never grants metadata visibility.
        return refreshed.can(updated, "view", false, false)
                ? refreshed.entry(updated, false)
                : receipt(updated);
    }

    @Transactional
    public Entry setPassword(UUID id, Password request) {
        AuthUser u = user();
        requireGlobal(u, "view");
        if (u.getImpersonatedBy() != null)
            throw new ApiException(ErrorCode.IMPERSONATION_READ_ONLY);
        String hash = unlocks.hash(request.password());
        treeLock();
        Scope s = new Scope(u);
        Node n = s.node(id);
        s.require(n, "manage_permissions", false, true);
        checkVersion(n, request.version());
        jdbc.update(
                "UPDATE company_file_nodes SET"
                    + " password_hash=?,password_revision=password_revision+1,version=version+1,updated_at=now(),updated_by=?"
                    + " WHERE id=?",
                hash,
                u.getId(),
                id);
        unlocks.invalidate(id);
        event(u, hash == null ? "password_clear" : "password_set", id);
        Node updated = load(id);
        Scope refreshed = new Scope(u);
        return refreshed.can(updated, "view", false, false)
                ? refreshed.entry(updated, false)
                : receipt(updated);
    }

    @Transactional
    public Unlocked unlock(UUID id, Unlock request) {
        AuthUser u = user();
        Scope s = new Scope(u);
        Node n = s.node(id);
        s.require(n, "view", n.deleted, false);
        // Unlock ancestors first; a known child UUID cannot skip an ancestor password.
        for (Node ancestor : s.chain(n))
            if (!ancestor.id.equals(id)
                    && ancestor.passwordHash != null
                    && !unlocks.isUnlocked(ancestor.id, ancestor.passwordRevision, u))
                throw new ApiException(ErrorCode.FORBIDDEN, "请先解锁上层文件夹");
        Instant expiry =
                unlocks.unlock(id, n.passwordRevision, n.passwordHash, request.password(), u);
        event(u, "unlock", id);
        return new Unlocked(expiry);
    }

    public void lock(UUID id) {
        AuthUser u = user();
        Scope s = new Scope(u);
        Node n = s.node(id);
        s.require(n, "view", n.deleted, false);
        unlocks.lock(id, u);
    }

    public List<Principal> principals(String type, String search) {
        AuthUser u = user();
        // Any reader may resolve subjects: folder-level managers are appointed through
        // directory ACL grants, not through global administration codes (V958).
        requireGlobal(u, "view");
        if (!Set.of("USER", "DEPARTMENT").contains(type)) throw invalid("请选择人员或部门");
        String value = search == null ? "" : search.strip();
        if (value.length() > 60) throw invalid("搜索内容过长");
        String pattern =
                "%" + value.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_") + "%";
        if (type.equals("DEPARTMENT"))
            return jdbc.query(
                    "SELECT id,name,code detail FROM departments WHERE NOT is_deleted AND (name"
                            + " ILIKE ? OR code ILIKE ?) ORDER BY sort_order,name,id LIMIT 50",
                    (rs, row) ->
                            new Principal(
                                    rs.getObject("id", UUID.class),
                                    rs.getString("name"),
                                    rs.getString("detail"),
                                    type),
                    pattern,
                    pattern);
        return jdbc.query(
                """
                SELECT u.id,e.full_name||'('||e.code||')' AS name,d.name AS detail
                FROM users u JOIN employees e ON e.id=u.employee_id LEFT JOIN departments d ON d.id=e.department_id
                WHERE NOT u.is_deleted AND u.status='active' AND NOT e.is_deleted
                  AND (e.full_name ILIKE ? OR e.code ILIKE ?) ORDER BY e.full_name,e.code,u.id LIMIT 50
                """,
                (rs, row) ->
                        new Principal(
                                rs.getObject("id", UUID.class),
                                rs.getString("name"),
                                rs.getString("detail"),
                                type),
                pattern,
                pattern);
    }

    /**
     * These paths are also called by the generic attachment API, never only by the library
     * controller.
     */
    public void requireAttachmentView(UUID id, AuthUser u) {
        Scope s = new Scope(u);
        Node n = s.node(id);
        requireFile(n);
        s.require(n, "view", false, !(n.pending && n.createdBy.equals(u.getId())));
    }

    public void requireAttachmentDownload(UUID id, AuthUser u) {
        Scope s = new Scope(u);
        Node n = s.node(id);
        requireFile(n);
        s.require(n, "download", false, true);
        if (n.pending) throw conflict("文件还未完成发布");
    }

    public void requireAttachmentUpload(UUID id, AuthUser u, boolean forUpdate) {
        if (forUpdate) treeLock();
        Scope s = new Scope(u);
        Node n = s.node(id);
        requireFile(n);
        s.requirePendingUpload(n);
    }

    private final class Scope {
        final AuthUser user;
        final Map<UUID, Node> cache = new HashMap<>();
        final Map<UUID, List<Acl>> aclCache = new HashMap<>();
        final Set<UUID> departments;
        final Map<UUID, String> actorNames = new HashMap<>();

        Scope(AuthUser user) {
            this.user = user;
            requireGlobal(user, "view");
            // Metadata and ACL are fetched in bounded batches under READ_COMMITTED, including
            // when invoked by the generic attachment service's outer transaction. Hold the
            // tree's shared transaction lock so those batches cannot mix before/after policy
            // states. Every library write acquires the matching exclusive lock before a Scope.
            jdbc.queryForObject("SELECT pg_advisory_xact_lock_shared(925,1)", Object.class);
            departments =
                    user.getEmployeeId() == null
                            ? Set.of()
                            : new HashSet<>(
                                    jdbc.queryForList(
                                            """
                                            WITH RECURSIVE membership(id) AS (
                                                SELECT department_id FROM employees WHERE id=? AND NOT is_deleted
                                                UNION SELECT department_id FROM employee_secondary_departments WHERE employee_id=?
                                            ), ancestors(id,parent_id,path) AS (
                                                SELECT d.id,d.parent_id,ARRAY[d.id] FROM departments d JOIN membership m ON m.id=d.id WHERE NOT d.is_deleted
                                                UNION ALL SELECT d.id,d.parent_id,a.path||d.id FROM departments d JOIN ancestors a ON d.id=a.parent_id
                                                WHERE NOT d.is_deleted AND NOT d.id=ANY(a.path)
                                            ) SELECT DISTINCT id FROM ancestors
                                            """,
                                            UUID.class,
                                            user.getEmployeeId(),
                                            user.getEmployeeId()));
        }

        void prime(List<Node> nodes) {
            if (nodes.isEmpty()) return;
            List<UUID> ids = nodes.stream().map(n -> n.id).distinct().toList();
            String placeholders = placeholders(ids.size());
            List<Node> ancestors =
                    jdbc.query(
                            "WITH RECURSIVE ancestry AS (SELECT * FROM company_file_nodes WHERE id"
                                    + " IN ("
                                    + placeholders
                                    + ") UNION SELECT p.* FROM company_file_nodes p JOIN ancestry c"
                                    + " ON p.id=c.parent_id) SELECT * FROM ancestry",
                            NODE,
                            ids.toArray());
            for (Node n : ancestors) cache.put(n.id, n);
            List<UUID> missingAcls =
                    ancestors.stream()
                            .map(n -> n.id)
                            .filter(id -> !aclCache.containsKey(id))
                            .distinct()
                            .toList();
            if (!missingAcls.isEmpty()) {
                missingAcls.forEach(id -> aclCache.put(id, new ArrayList<>()));
                jdbc.query(
                        "SELECT node_id,subject_type,subject_id,effect,actions FROM"
                                + " company_file_acl WHERE node_id IN ("
                                + placeholders(missingAcls.size())
                                + ") ORDER BY subject_type,subject_id,effect",
                        (org.springframework.jdbc.core.RowCallbackHandler)
                                rs ->
                                        aclCache.get(rs.getObject(1, UUID.class))
                                                .add(
                                                        new Acl(
                                                                rs.getString(2),
                                                                rs.getObject(3, UUID.class),
                                                                rs.getString(4),
                                                                List.of(
                                                                        (String[])
                                                                                rs.getArray(5)
                                                                                        .getArray()))),
                        missingAcls.toArray());
            }
            Set<UUID> actors = new HashSet<>();
            for (Node n : ancestors) {
                if (!actorNames.containsKey(n.createdBy)) actors.add(n.createdBy);
                if (!actorNames.containsKey(n.updatedBy)) actors.add(n.updatedBy);
            }
            if (!actors.isEmpty()) {
                actors.forEach(id -> actorNames.put(id, "已停用账号"));
                jdbc.query(
                        "SELECT u.id,coalesce(e.full_name||'('||e.code||')','管理员') AS name FROM"
                            + " users u LEFT JOIN employees e ON e.id=u.employee_id WHERE u.id IN ("
                                + placeholders(actors.size())
                                + ")",
                        (org.springframework.jdbc.core.RowCallbackHandler)
                                rs -> actorNames.put(rs.getObject(1, UUID.class), rs.getString(2)),
                        actors.toArray());
            }
        }

        Node node(UUID id) {
            Node result = cache.get(id);
            if (result == null) {
                prime(List.of(load(id)));
                result = cache.get(id);
            }
            return result;
        }

        List<Node> chain(Node node) {
            List<Node> result = new ArrayList<>();
            Set<UUID> seen = new HashSet<>();
            Node current = node;
            while (current != null) {
                if (!seen.add(current.id) || result.size() >= MAX_DEPTH)
                    throw conflict("目录结构异常，请联系管理员");
                result.add(current);
                current = current.parentId == null ? null : node(current.parentId);
            }
            Collections.reverse(result);
            return result;
        }

        List<Acl> rules(UUID id) {
            return aclCache.getOrDefault(id, List.of());
        }

        private record Verdict(boolean allowed, boolean denied) {}

        /** Reading is open unless a non-inheriting cut or deny blocks it; writes start closed. */
        Verdict verdict(List<Node> chain, String action) {
            boolean allowed = DEFAULT_OPEN_ACTIONS.contains(action), denied = false;
            for (Node n : chain) {
                if (!n.inheritPermissions) allowed = false;
                for (Acl rule : rules(n.id)) {
                    boolean matches =
                            EVERYONE_SUBJECT_TYPE.equals(rule.subjectType)
                                    ? rule.subjectId.equals(EVERYONE_SUBJECT_ID)
                                    : rule.subjectType.equals("USER")
                                            ? rule.subjectId.equals(user.getId())
                                            : departments.contains(rule.subjectId);
                    if (matches && rule.actions.contains(action)) {
                        if (rule.effect.equals("DENY")) denied = true;
                        else allowed = true;
                    }
                }
            }
            return new Verdict(allowed, denied);
        }

        boolean decision(List<Node> chain, String action) {
            Verdict verdict = verdict(chain, action);
            return verdict.allowed() && !verdict.denied();
        }

        boolean can(Node n, String action, boolean trash, boolean requireUnlocked) {
            if (!cache.containsKey(n.id)) prime(List.of(n));
            // The single system switch: the library entrance. Every action needs it.
            if (!has(user, "view")) return false;
            List<Node> path = chain(n);
            boolean recovery = action.equals("manage_permissions") && user.isSuperAdmin();
            if (!trash && path.stream().anyMatch(v -> v.deleted)) return false;
            if (n.pending
                    && !n.createdBy.equals(user.getId())
                    && !recovery
                    && (!Set.of("view", "delete").contains(action) || !canAdministerPending(path)))
                return false;
            if (recovery)
                return true; // Audited ACL/password recovery only. Never grants view/download
            // bytes.
            // A protected folder's own label can be shown. Known UUIDs never reveal metadata below
            // it.
            if (path.subList(0, path.size() - 1).stream()
                    .anyMatch(
                            v ->
                                    v.passwordHash != null
                                            && !unlocks.isUnlocked(v.id, v.passwordRevision, user)))
                return false;
            for (int i = 0; i < path.size(); i++)
                if (!decision(path.subList(0, i + 1), "view")) return false;
            // Reads ride the entrance plus the folder scope; writes need an explicit folder
            // allow rule or a global library-administration code. A deny always wins.
            return authorized(path, action)
                    && (!requireUnlocked
                            || path.stream()
                                    .noneMatch(
                                            v ->
                                                    v.passwordHash != null
                                                            && !unlocks.isUnlocked(
                                                                    v.id,
                                                                    v.passwordRevision,
                                                                    user)));
        }

        /** Folder-ACL grant or (for writes) a global administration code; denies win. */
        boolean authorized(List<Node> path, String action) {
            Verdict verdict = verdict(path, action);
            return !verdict.denied()
                    && (verdict.allowed()
                            || (!DEFAULT_OPEN_ACTIONS.contains(action) && has(user, action)));
        }

        private boolean canAdministerPending(List<Node> path) {
            // Recover metadata left by a departed uploader. This never permits completion,
            // replacement or a content download, and does not depend on the grant's source.
            return has(user, "manage_permissions")
                    && has(user, "delete")
                    && authorized(path, "manage_permissions")
                    && authorized(path, "delete")
                    // As with any locked entry, eligible cleanup managers can see its own
                    // lock label and enter a known password. Ancestors must already be unlocked;
                    // actual deletion still requires every password through can(..., true).
                    && path.subList(0, path.size() - 1).stream()
                            .noneMatch(
                                    v ->
                                            v.passwordHash != null
                                                    && !unlocks.isUnlocked(
                                                            v.id, v.passwordRevision, user));
        }

        void require(Node n, String action, boolean trash, boolean requireUnlocked) {
            if (!can(n, action, trash, requireUnlocked)) {
                if (!can(n, "view", trash, false)) throw missing();
                if (requireUnlocked && locked(n))
                    throw new ApiException(ErrorCode.FORBIDDEN, "资料已锁定，请先输入访问密码");
                throw new ApiException(ErrorCode.FORBIDDEN, "没有这项操作的资料权限，请联系资料管理员");
            }
        }

        boolean canPendingUpload(Node n) {
            return n.kind.equals("FILE") && n.pending && n.createdBy.equals(user.getId())
                    && can(n, "upload", false, false);
        }

        void requirePendingUpload(Node n) {
            if (!n.kind.equals("FILE") || !n.pending || !n.createdBy.equals(user.getId()))
                throw new ApiException(ErrorCode.FORBIDDEN, "这个文件不能再上传或替换原件，请上传为新文件");
            // Only the initializing owner can finish this unpublished file. Parent locks and ACLs
            // are checked by can/require even when the file's own new password is not unlocked.
            require(n, "upload", false, false);
        }

        boolean locked(Node n) {
            return chain(n).stream()
                    .anyMatch(
                            v ->
                                    v.passwordHash != null
                                            && !unlocks.isUnlocked(v.id, v.passwordRevision, user));
        }

        List<String> actions(Node n, boolean trash) {
            List<String> result = new ArrayList<>();
            for (String action : ACTIONS) {
                if (action.equals("view")) {
                    if (can(n, action, trash, false)) result.add(action);
                    continue;
                }
                if (n.deleted && !action.equals("restore")) continue;
                if (!n.deleted && action.equals("restore")) continue;
                if (n.kind.equals("FILE") && action.equals("create")) continue;
                if (n.kind.equals("FOLDER") && action.equals("download")) continue;
                if (action.equals("upload")
                        && n.kind.equals("FILE")
                        && (!n.pending || !n.createdBy.equals(user.getId()))) continue;
                if (n.pending && action.equals("download")) continue;
                if ((action.equals("upload") && canPendingUpload(n))
                        || can(n, action, trash, true)) result.add(action);
            }
            if (n.pending
                    && !n.deleted
                    && n.createdBy.equals(user.getId())
                    && canPendingUpload(n)
                    && !result.contains("delete")) result.add("delete");
            return List.copyOf(result);
        }

        String actor(UUID id) {
            return actorNames.getOrDefault(id, "已停用账号");
        }

        Entry entry(Node n, boolean trash) {
            if (!cache.containsKey(n.id)) prime(List.of(n));
            return new Entry(
                    n.id,
                    n.parentId,
                    n.kind,
                    n.name,
                    n.description,
                    n.version,
                    n.position,
                    n.passwordHash != null,
                    locked(n),
                    n.deleted,
                    n.deletedAt,
                    n.createdAt,
                    n.updatedAt,
                    actor(n.createdBy),
                    actor(n.updatedBy),
                    n.attachmentId,
                    n.sizeBytes,
                    n.contentType,
                    n.pending,
                    actions(n, trash));
        }
    }

    private Map<String, Acl> validatedRules(List<Rule> rules, boolean readOnly) {
        if (rules == null || rules.size() > 100) throw invalid("资料访问规则无效");
        Set<String> allowed = readOnly ? Set.of("view", "download") : Set.copyOf(ACTIONS);
        Map<String, Acl> result = new LinkedHashMap<>();
        for (Rule rule : rules) {
            if (rule == null || rule.subjectId() == null
                    || rule.subjectType() == null || rule.effect() == null
                    || !Set.of("USER", "DEPARTMENT", EVERYONE_SUBJECT_TYPE).contains(rule.subjectType())
                    || !Set.of("ALLOW", "DENY").contains(rule.effect())
                    || rule.actions() == null || rule.actions().isEmpty()
                    || rule.actions().stream().anyMatch(Objects::isNull)
                    || !allowed.containsAll(rule.actions())
                    || new HashSet<>(rule.actions()).size() != rule.actions().size()) {
                throw invalid(readOnly ? "新资料只能设置查看和下载范围，不能授予系统操作权限" : "资料授权规则无效");
            }
            // The synthetic everyone subject is a fixed allow-view/read marker only.
            if (EVERYONE_SUBJECT_TYPE.equals(rule.subjectType())
                    && (!rule.subjectId().equals(EVERYONE_SUBJECT_ID)
                            || !"ALLOW".equals(rule.effect())
                            || !Set.of("view", "download").containsAll(rule.actions())))
                throw invalid("所有人规则仅支持允许查看和下载");
            Acl value = new Acl(rule.subjectType(), rule.subjectId(), rule.effect(), rule.actions().stream().sorted().toList());
            if (result.putIfAbsent(aclKey(value.subjectType, value.subjectId, value.effect), value) != null)
                throw invalid("同一对象的相同授权类型不能重复");
        }
        Map<String, Principal> principals =
                loadPrincipals(result.values().stream()
                        .filter(rule -> !EVERYONE_SUBJECT_TYPE.equals(rule.subjectType())).toList());
        if (result.values().stream().anyMatch(rule -> !EVERYONE_SUBJECT_TYPE.equals(rule.subjectType())
                && !principals.containsKey(principalKey(rule.subjectType, rule.subjectId))))
            throw invalid("授权对象已停用或不存在，请重新选择");
        return result;
    }

    private Rule ruleDto(Acl acl, Map<String, Principal> principals) {
        String name = EVERYONE_SUBJECT_TYPE.equals(acl.subjectType)
                ? "所有人"
                : principals.getOrDefault(principalKey(acl.subjectType, acl.subjectId),
                        new Principal(acl.subjectId, "已停用对象", "", acl.subjectType)).name();
        return new Rule(acl.subjectType, acl.subjectId, name, acl.effect, acl.actions);
    }

    /** Read and validate the same active subjects in at most one query per subject type. */
    private Map<String, Principal> loadPrincipals(Collection<Acl> rules) {
        Map<String, Principal> result = new HashMap<>();
        for (String type : List.of("USER", "DEPARTMENT")) {
            List<UUID> ids = rules.stream().filter(rule -> rule.subjectType.equals(type))
                    .map(Acl::subjectId).distinct().toList();
            if (ids.isEmpty()) continue;
            String query;
            if (type.equals("USER")) query =
                    "SELECT u.id,coalesce(e.full_name||'('||e.code||')','管理员') AS"
                        + " name,coalesce(d.name,'') AS detail FROM users u LEFT JOIN"
                        + " employees e ON e.id=u.employee_id LEFT JOIN departments d ON"
                        + " d.id=e.department_id WHERE u.id IN (" + placeholders(ids.size())
                        + ") AND NOT u.is_deleted AND u.status='active'";
            else query = "SELECT id,name,code detail FROM departments WHERE id IN ("
                    + placeholders(ids.size()) + ") AND NOT is_deleted";
            List<Principal> subjects =
                    jdbc.query(
                            query,
                            (rs, row) ->
                                    new Principal(
                                            rs.getObject("id", UUID.class),
                                            rs.getString("name"),
                                            rs.getString("detail"),
                                            type),
                            ids.toArray());
            subjects.forEach(subject -> result.put(principalKey(type, subject.id()), subject));
        }
        return result;
    }

    private static String principalKey(String type, UUID id) {
        return type + ":" + id;
    }

    private Node load(UUID id) {
        return jdbc.query("SELECT * FROM company_file_nodes WHERE id=?", NODE, id).stream()
                .findFirst()
                .orElseThrow(CompanyFileService::missing);
    }

    private List<Node> subtree(UUID id, Boolean deleted) {
        List<Node> result =
                jdbc.query(
                        """
                        WITH RECURSIVE tree AS (
                            SELECT n.*,0 AS depth,ARRAY[n.id] AS walk FROM company_file_nodes n WHERE id=?
                            UNION ALL SELECT n.*,t.depth+1,t.walk||n.id FROM company_file_nodes n JOIN tree t ON n.parent_id=t.id
                                    WHERE (?::boolean IS NULL OR n.deleted=?) AND NOT n.id=ANY(t.walk) AND t.depth<32
                        ) SELECT * FROM tree ORDER BY depth,id LIMIT 5001
                        """,
                        NODE,
                        id,
                        deleted,
                        deleted);
        if (result.size() > MAX_SUBTREE) throw conflict("目录内容较多，请分批处理");
        return result;
    }

    private void capacity(UUID parent) {
        Integer count =
                jdbc.queryForObject(
                        "SELECT count(*) FROM company_file_nodes WHERE parent_id IS NOT DISTINCT"
                                + " FROM ? AND NOT deleted",
                        Integer.class,
                        parent);
        if (count != null && count >= MAX_CHILDREN) throw invalid("每个目录最多容纳 500 项，请新建子文件夹后分类存放");
    }

    private void treeLock() {
        jdbc.queryForObject("SELECT pg_advisory_xact_lock(925,1)", Object.class);
    }

    private AuthUser user() {
        AuthUser u = currentUser.get().orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));
        if (u.isVisitor()) throw new ApiException(ErrorCode.FORBIDDEN);
        return u;
    }

    private static boolean has(AuthUser u, String action) {
        if (u == null
                || u.isVisitor()
                || !ACTIONS.contains(action)) return false;
        // V958: view is the single common-module entrance switch; download follows it.
        if (action.equals("view") || action.equals("download"))
            return u.getPermissions().contains(PERMISSIONS.get("view"));
        if (action.equals("upload"))
            return u.getEmployeeId() != null
                    && u.getPermissions()
                            .containsAll(Set.of("attachment:view", "attachment:upload"));
        // Write actions remain catalog codes held by global library administrators.
        return u.getPermissions().contains(PERMISSIONS.get(action));
    }

    private static void requireGlobal(AuthUser u, String action) {
        if (!has(u, action)) throw new ApiException(ErrorCode.FORBIDDEN);
    }

    private static void requireFolder(Node n) {
        if (!n.kind.equals("FOLDER")) throw invalid("请选择文件夹");
    }

    private static void requireFile(Node n) {
        if (!n.kind.equals("FILE")) throw missing();
    }

    private static void checkVersion(Node n, Long expected) {
        if (expected == null || n.version != expected) throw conflict("内容已被其他人修改，请刷新后重新操作");
    }

    static String validName(String raw) {
        String name =
                raw == null
                        ? ""
                        : java.text.Normalizer.normalize(
                                raw.strip(), java.text.Normalizer.Form.NFC);
        if (name.isBlank()
                || name.length() > 180
                || name.equals(".")
                || name.equals("..")
                || name.matches(".*[\\p{Cntrl}/\\\\:*?\"<>|].*")
                || name.endsWith(".")
                || name.endsWith(" ")) throw invalid("名称不能为空，最多 180 个字符，不能包含路径或 Windows 文件名特殊字符");
        String stem = name.split("\\.", 2)[0].toUpperCase(Locale.ROOT);
        if (stem.matches("CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9]")) throw invalid("这个名称为系统保留名称，请换一个");
        return name;
    }

    static void requireSameFileExtension(String original, String renamed) {
        String expected = extension(original);
        String actual = extension(renamed);
        if (expected.isEmpty() || actual.isEmpty() || !expected.equalsIgnoreCase(actual))
            throw invalid("文件扩展名必须与上传原件一致，重命名时请只修改文件名主体并保留格式后缀");
    }

    private static String extension(String name) {
        if (name == null) return "";
        int separator = name.lastIndexOf('.');
        return separator < 0 || separator == name.length() - 1 ? "" : name.substring(separator + 1);
    }

    private static String validDescription(String value) {
        if (value == null || value.isBlank()) return null;
        if (value.length() > 2000) throw invalid("说明最多 2000 个字符");
        return value.strip();
    }

    private static String arrayLiteral(List<String> values) {
        return "{" + String.join(",", values) + "}";
    }

    private static String aclKey(String type, UUID id, String effect) {
        return type + ":" + id + ":" + effect;
    }

    private static List<String> rootActions(AuthUser u) {
        return List.of("view", "create", "upload", "move").stream().filter(a -> has(u, a)).toList();
    }

    private static String placeholders(int size) {
        return String.join(",", Collections.nCopies(size, "?"));
    }

    private static String fingerprint(UUID parent, String kind, String name, String description) {
        try {
            return java.util.HexFormat.of()
                    .formatHex(
                            java.security.MessageDigest.getInstance("SHA-256")
                                    .digest(
                                            (String.valueOf(parent)
                                                            + "\u0000"
                                                            + kind
                                                            + "\u0000"
                                                            + name
                                                            + "\u0000"
                                                            + String.valueOf(description))
                                                    .getBytes(
                                                            java.nio.charset.StandardCharsets
                                                                    .UTF_8)));
        } catch (java.security.NoSuchAlgorithmException impossible) {
            throw new IllegalStateException(impossible);
        }
    }

    private String creationFingerprint(AuthUser user, Create request, String kind, String name,
            String description, Map<String, Acl> rules) {
        String legacy = fingerprint(request.parentId(), kind, name, description);
        if (request.access() == null) return legacy;
        if (creationFingerprints == null)
            throw new IllegalStateException("资料库初始访问设置缺少创建请求验证器");
        StringBuilder payload = new StringBuilder();
        appendCanonical(payload, legacy);
        appendCanonical(payload, String.valueOf(request.access().inheritPermissions()));
        rules.entrySet().stream().sorted(Map.Entry.comparingByKey()).forEach(row -> {
            appendCanonical(payload, row.getKey());
            appendCanonical(payload, String.join(",", row.getValue().actions));
        });
        // The password exists only in this transient keyed input. A plain digest would become
        // an offline password oracle in the node fingerprint and FULL audit snapshots.
        appendCanonical(payload, request.access().password());
        return creationFingerprints.sign(user.getId(), payload.toString());
    }

    private static void appendCanonical(StringBuilder target, String value) {
        if (value == null) target.append("-1:");
        else target.append(value.length()).append(':').append(value);
    }

    /** One fixed-expression ordering contract for ordinary directories and streamed trash roots. */
    private static String ordering(String sort, String direction) {
        String key = sort == null ? "manual" : sort;
        if (!Set.of("manual", "name", "updated", "size").contains(key)) throw invalid("排序方式无效");
        if (direction != null && !Set.of("asc", "desc").contains(direction))
            throw invalid("排序方向无效");
        String value =
                switch (key) {
                    case "name" -> "lower(n.name) COLLATE \"C\"";
                    case "updated" -> "n.updated_at";
                    case "size" -> "CASE WHEN n.kind='FILE' AND NOT n.pending AND n.attachment_id IS NOT NULL THEN n.size_bytes END";
                    default -> "n.position";
                };
        return "(n.kind<>'FOLDER')," + value
                + ("desc".equals(direction) ? " DESC" : " ASC") + " NULLS LAST,n.id";
    }

    private void event(AuthUser u, String action, UUID id) {
        audit.logCommitted(
                u.getId(),
                u.getLoginAccount(),
                "company_file_" + action,
                "company_file_nodes",
                id == null ? null : id.toString(),
                "success");
    }

    private static Entry receipt(Node n) {
        // Only identity/version acknowledge a successful access mutation. All other fields
        // are safe constants: knowing an ID and recovery authority do not grant file metadata.
        return new Entry(
                n.id,
                null,
                "",
                "",
                null,
                n.version,
                0,
                false,
                true,
                false,
                null,
                null,
                null,
                "",
                "",
                null,
                null,
                null,
                false,
                List.of());
    }

    private static ApiException missing() {
        return new ApiException(ErrorCode.NOT_FOUND, "文件或目录不存在，或当前账号无权查看");
    }

    private static ApiException conflict(String message) {
        return new ApiException(ErrorCode.CONFLICT, message);
    }

    private static ApiException invalid(String message) {
        return new ApiException(ErrorCode.VALIDATION_FAILED, message);
    }

    private static Instant instant(ResultSet rs, String column) throws SQLException {
        var value = rs.getTimestamp(column);
        return value == null ? null : value.toInstant();
    }

    private static final RowMapper<Node> NODE =
            (rs, row) ->
                    new Node(
                            rs.getObject("id", UUID.class),
                            rs.getObject("parent_id", UUID.class),
                            rs.getString("kind"),
                            rs.getString("name"),
                            rs.getString("description"),
                            rs.getLong("version"),
                            rs.getLong("position"),
                            rs.getBoolean("inherit_permissions"),
                            rs.getString("password_hash"),
                            rs.getLong("password_revision"),
                            rs.getObject("attachment_id", UUID.class),
                            (Long) rs.getObject("size_bytes"),
                            rs.getString("content_type"),
                            rs.getBoolean("pending"),
                            rs.getBoolean("deleted"),
                            instant(rs, "deleted_at"),
                            rs.getObject("deletion_batch", UUID.class),
                            instant(rs, "created_at"),
                            instant(rs, "updated_at"),
                            rs.getObject("created_by", UUID.class),
                            rs.getObject("updated_by", UUID.class));

    private record Acl(String subjectType, UUID subjectId, String effect, List<String> actions) {}

    private record Node(
            UUID id,
            UUID parentId,
            String kind,
            String name,
            String description,
            long version,
            long position,
            boolean inheritPermissions,
            String passwordHash,
            long passwordRevision,
            UUID attachmentId,
            Long sizeBytes,
            String contentType,
            boolean pending,
            boolean deleted,
            Instant deletedAt,
            UUID deletionBatch,
            Instant createdAt,
            Instant updatedAt,
            UUID createdBy,
            UUID updatedBy) {}
}
