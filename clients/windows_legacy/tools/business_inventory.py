#!/usr/bin/env python3
"""Read-only business-source inventory; --write explicitly saves the JSON artifact.

This is a lexical inventory, not a Dart/Java compiler, permission verifier, API
test, workflow count, or migration-completion report. It makes no network calls.
"""
from __future__ import annotations

import argparse
from collections import Counter, defaultdict
from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[3]
OUTPUT = ROOT / "clients/windows_legacy/progress/business-inventory.json"
ROUTER = "lib/core/router/app_router.dart"
ROUTE_NAMES = "lib/core/router/route_names.dart"
ENDPOINTS = "lib/core/network/api_endpoints.dart"
PERMISSIONS = "lib/shared/auth/permissions.dart"
FEATURE_LABELS = {
    "admin": "系统管理", "auth": "登录与认证", "basic_data": "基础资料", "client_update": "客户端下载与更新",
    "company_files": "公司资料库", "dashboard": "工作台", "department": "组织部门", "disaster_recovery": "灾难恢复入口",
    "employee": "员工生命周期", "expense": "报销", "finance": "财务", "hr_profile": "人事资料变更", "hr_task": "人事任务",
    "notice": "通知", "operations_workbench": "运营任务工作台", "payroll": "薪资", "procurement_iqc_rejection": "采购来料不合格处置",
    "production": "生产", "profile": "个人资料", "purchase": "采购单据", "quality": "品质", "rd_task": "工程研发任务",
    "sales": "销售", "security": "安保", "settings": "个人与系统设置", "shell": "应用壳层", "stock": "库存查询与分析",
    "subcontract": "委外", "suggestion": "建议", "visitor": "已下线访客门户保留源码", "visitor_approval": "员工访客审批与预约",
    "warehouse": "仓库业务", "webinquiry": "网站询盘衔接", "website_management": "网站管理衔接",
}
ACTION_WORDS = {"save", "submit", "approve", "reject", "confirm", "cancel", "delete", "remove", "create", "update", "edit",
    "import", "export", "print", "audit", "post", "reverse", "withdraw", "recall", "undo", "restore", "reconcile", "receive",
    "ship", "dispatch", "issue", "assign", "transfer", "close", "finish", "complete", "start", "stop", "upload", "download",
    "login", "logout", "send", "pay", "settle", "copy", "paste", "unapprove", "unaudit"}


def _string_end(text: str, start: int) -> tuple[int, int, int]:
    raw = text[start] in "rR" and start + 1 < len(text) and text[start + 1] in "'\""
    quote_at = start + 1 if raw else start
    quote = text[quote_at]
    width = 3 if text.startswith(quote * 3, quote_at) else 1
    i = quote_at + width
    while i < len(text):
        if text.startswith(quote * width, i):
            return i + width, quote_at + width, i
        if not raw and text[i] == "\\":
            i += 2
            continue
        if not raw and text.startswith("${", i):
            depth, i = 1, i + 2
            while i < len(text) and depth:
                if text[i] in "'\"" or text[i] in "rR" and i + 1 < len(text) and text[i + 1] in "'\"":
                    i = _string_end(text, i)[0]
                    continue
                if text[i] == "{": depth += 1
                elif text[i] == "}": depth -= 1
                i += 1
            continue
        i += 1
    return len(text), quote_at + width, len(text)


def _lex(text: str) -> tuple[str, str, list[tuple[int, int, str]]]:
    code, mask, strings = list(text), list(text), []
    i = 0
    def blank(start, end, target):
        for offset in range(start, end):
            if text[offset] not in "\r\n": target[offset] = " "
    while i < len(text):
        if text.startswith("//", i):
            end = text.find("\n", i)
            if end < 0: end = len(text)
            blank(i, end, code); blank(i, end, mask); i = end
        elif text.startswith("/*", i):
            end, depth = i + 2, 1
            while end < len(text) and depth:
                if text.startswith("/*", end): depth += 1; end += 2
                elif text.startswith("*/", end): depth -= 1; end += 2
                else: end += 1
            blank(i, end, code); blank(i, end, mask); i = end
        elif text[i] in "'\"" or (text[i] in "rR" and i + 1 < len(text) and text[i + 1] in "'\""
                and (i == 0 or not (text[i - 1].isalnum() or text[i - 1] == "_"))):
            end, first, last = _string_end(text, i)
            strings.append((i, end, text[first:last]))
            blank(i, end, mask); i = end
        else:
            i += 1
    return "".join(code), "".join(mask), strings


@dataclass
class Unit:
    source: str
    text: str
    code: str
    mask: str
    strings: list
    sha256: str

    def line(self, offset: int) -> int:
        return self.text.count("\n", 0, offset) + 1

    def summary(self) -> dict:
        return {"source": self.source, "sha256": self.sha256, "lineCount": len(self.text.splitlines())}


class Sources:
    def __init__(self):
        self.units = {}

    def get(self, source: str) -> Unit | None:
        if source in self.units: return self.units[source]
        path = ROOT / source
        if not path.is_file(): return None
        data = path.read_bytes()
        text = data.decode("utf-8-sig")
        code, mask, strings = _lex(text)
        result = Unit(source, text, code, mask, strings, hashlib.sha256(data).hexdigest())
        self.units[source] = result
        return result


def _balanced(mask: str, start: int, opening="(", closing=")") -> int:
    depth = 0
    for i in range(start, len(mask)):
        if mask[i] == opening: depth += 1
        elif mask[i] == closing:
            depth -= 1
            if depth == 0: return i
    return len(mask) - 1


def _classes(unit: Unit) -> list[dict]:
    result = []
    for match in re.finditer(r"\bclass\s+([A-Za-z_]\w*)", unit.mask):
        end = unit.mask.find("{", match.end())
        header = unit.code[match.end():end if end >= 0 else match.end() + 150]
        extends = re.search(r"\bextends\s+([A-Za-z_]\w*(?:\s*<[^{}]+>)?)", header)
        name = match.group(1)
        result.append({"name": name, "line": unit.line(match.start()),
                       "role": "state-class" if name.endswith("State") else "page-class" if name.endswith("Page") else "supporting-class",
                       "extends": extends.group(1).strip() if extends else None})
    return result


def _resolve_import(owner: str, uri: str) -> str | None:
    if uri.startswith("package:uten_imp/"):
        return "lib/" + uri[len("package:uten_imp/"):]
    if ":" in uri: return None
    path = ((ROOT / owner).parent / uri).resolve()
    try: return path.relative_to(ROOT).as_posix()
    except ValueError: return None


def _imports(unit: Unit, sources: Sources) -> list[dict]:
    result = []
    for match in re.finditer(r"\b(import|export|part)\s+(['\"])([^'\"]+)\2\s*([^;]*);", unit.code):
        uri, tail = match.group(3), match.group(4)
        source = _resolve_import(unit.source, uri)
        target = sources.get(source) if source else None
        alias = re.search(r"\bas\s+(\w+)", tail)
        show = re.search(r"\bshow\s+([^;]+?)(?=\bhide\b|$)", tail)
        hide = re.search(r"\bhide\s+([^;]+?)(?=\bshow\b|$)", tail)
        if source and ("/repositories/" in source or source.endswith("_repository.dart")): role = "repositories"
        elif source and "/models/" in source: role = "models"
        elif source and (source.startswith("lib/shared/") or source.startswith("lib/components/")): role = "sharedComponents"
        elif source and "/widgets/" in source: role = "featureWidgets"
        elif source and "/providers/" in source: role = "providers"
        elif source and source.startswith("lib/core/"): role = "core"
        else: role = "other"
        result.append({"directive": match.group(1), "uri": uri, "source": source, "line": unit.line(match.start()),
                       "role": role, "importAlias": alias.group(1) if alias else None,
                       "showSymbols": re.findall(r"[A-Za-z_]\w*", show.group(1)) if show else [],
                       "hideSymbols": re.findall(r"[A-Za-z_]\w*", hide.group(1)) if hide else [],
                       "existsInRepository": target is not None, "targetSha256": target.sha256 if target else None})
    return result


def _expand(value: str, constants: dict[str, str]) -> str:
    def substitute(match):
        name = match.group(1) or match.group(2)
        return constants.get(name, "{" + name + "}")
    return re.sub(r"\$\{([^}]+)\}|\$(\w+)", substitute, value)


def _definitions(unit: Unit, *, constants_only: bool = False) -> tuple[dict, dict]:
    declarations = {}
    const = r"const\s+" if constants_only else r"(?:const\s+)?"
    pattern = r"\bstatic\s+" + const + r"(?:String\s+)?([A-Za-z_]\w*)\s*(\([^;{}]*?\))?\s*(?:=>|=)\s*(.*?);"
    for match in re.finditer(pattern, unit.code, re.S):
        expression = match.group(3).strip()
        literals = [token[2] for token in _lex(expression)[2]]
        declarations[match.group(1)] = {"line": unit.line(match.start()), "expression": expression,
            "parameters": match.group(2), "literalTemplates": literals}
    constants = {}
    for _ in range(len(declarations) + 1):
        changed = False
        for name, declaration in declarations.items():
            literals = declaration["literalTemplates"]
            if len(literals) == 1:
                value = _expand(literals[0], constants)
            elif declaration["expression"] in constants:
                value = constants[declaration["expression"]]
            else: continue
            if constants.get(name) != value:
                constants[name] = value; changed = True
        if not changed: break
    return declarations, constants


def _permission_refs(unit: Unit, definitions: dict) -> list[dict]:
    result = []
    for match in re.finditer(r"\bPerm\.([A-Za-z_]\w*)", unit.mask):
        definition = definitions.get(match.group(1))
        result.append({"symbol": "Perm." + match.group(1), "literal": definition["literalTemplates"][0]
                       if definition and len(definition["literalTemplates"]) == 1 else None,
                       "line": unit.line(match.start()), "definitionSource": PERMISSIONS,
                       "definitionLine": definition["line"] if definition else None})
    for start, _, value in unit.strings:
        if re.fullmatch(r"[a-z_][a-z0-9_.-]*(?::[a-z_][a-z0-9_.-]*){1,5}", value):
            nearby = unit.code[max(0, start - 150):start]
            if re.search(r"permission|authority|contains|hasAny|canAccess|requireAny", nearby, re.I):
                result.append({"symbol": None, "literal": value, "line": unit.line(start), "definitionSource": unit.source,
                               "definitionLine": unit.line(start)})
    return result


def _endpoint_refs(unit: Unit, declarations: dict, values: dict) -> list[dict]:
    result = []
    for match in re.finditer(r"\bApiEndpoints\.([A-Za-z_]\w*)", unit.mask):
        name = match.group(1); declaration = declarations.get(name)
        result.append({"symbol": "ApiEndpoints." + name, "line": unit.line(match.start()), "source": unit.source,
                       "template": values.get(name), "definitionSource": ENDPOINTS,
                       "definitionLine": declaration["line"] if declaration else None,
                       "definitionExpression": declaration["expression"] if declaration else None})
    return result


def _actions(unit: Unit) -> list[dict]:
    result = []
    for match in re.finditer(r"\b((?:[A-Za-z_]\w*\.)*)(_?[A-Za-z]\w*)\s*\(", unit.mask):
        receiver, name = match.group(1).rstrip("."), match.group(2)
        if name.lower().startswith(("_build", "build", "_render", "render")): continue
        if name in {"createState", "createElement", "didUpdateWidget", "updateShouldNotify", "initState", "didChangeDependencies",
                    "didChangeAppLifecycleState", "dispose", "deactivate", "activate", "debugFillProperties", "debugPrint", "debugPrintStack"}:
            continue
        if name == "print" and not receiver: continue
        words = re.sub(r"([a-z0-9])([A-Z])", r"\1_\2", name).strip("_").lower().split("_")
        categories = sorted(set(words) & ACTION_WORDS)
        if not categories: continue
        opening = unit.mask.find("(", match.start(), match.end())
        closing = _balanced(unit.mask, opening)
        tail = unit.mask[closing + 1:closing + 45]
        declaration = not receiver and bool(re.match(r"\s*(?:async\*?|sync\*)?\s*(?:=>|\{)", tail))
        line_start = unit.text.rfind("\n", 0, match.start()) + 1
        line_end = unit.text.find("\n", match.start())
        if line_end < 0: line_end = len(unit.text)
        prefix = unit.mask[line_start:match.start()]
        kind = "action-ui-factory" if declaration and re.search(r"\bWidget\s*$", prefix) else "method-declaration-candidate" if declaration else "action-like-invocation"
        result.append({"symbol": name, "receiver": receiver or None, "line": unit.line(match.start()), "kind": kind,
                       "actionNameHints": categories, "evidenceLine": unit.text[line_start:line_end].strip()[:280]})
    for match in re.finditer(r"\b(on[A-Z]\w*)\s*:\s*(_?[A-Za-z]\w*)\b", unit.mask):
        name = match.group(2)
        words = re.sub(r"([a-z0-9])([A-Z])", r"\1_\2", name).strip("_").lower().split("_")
        categories = sorted(set(words) & ACTION_WORDS)
        if categories:
            result.append({"symbol": name, "line": unit.line(match.start()), "kind": "callback-reference",
                           "callback": match.group(1), "actionNameHints": categories})
    return result


def _named_arguments(unit: Unit, opening: int, closing: int) -> dict:
    positions, depth, i, expect_label = [], [], opening + 1, True
    while i < closing:
        char = unit.mask[i]
        if not depth and expect_label and not char.isspace():
            match = re.match(r"([A-Za-z_]\w*)\s*:", unit.mask[i:closing])
            expect_label = False
            if match:
                positions.append((match.group(1), i, i + match.end())); i += match.end(); continue
        if char in "([{": depth.append(char)
        elif char in ")]}":
            if depth: depth.pop()
        elif not depth and char == ",": expect_label = True
        i += 1
    result = {}
    for index, (name, position, start) in enumerate(positions):
        end = positions[index + 1][1] if index + 1 < len(positions) else closing
        value = unit.code[start:end].strip().rstrip(",").strip()
        result[name] = {"expression": value, "line": unit.line(position)}
    return result


def _routes(router: Unit, constants: dict, sources: Sources) -> list[dict]:
    imports = _imports(router, sources)
    class_sources = defaultdict(list)
    for entry in imports:
        imported = sources.get(entry["source"]) if entry["source"] else None
        if not imported: continue
        for item in _classes(imported):
            if (item["name"].startswith("_") or item["name"] in entry["hideSymbols"]
                    or entry["showSymbols"] and item["name"] not in entry["showSymbols"]):
                continue
            name = (entry["importAlias"] + "." if entry["importAlias"] else "") + item["name"]
            class_sources[name].append(imported.source)
    routes = []
    for match in re.finditer(r"\b(GoRoute|DraftAwareGoRoute|ShellRoute)\s*\(", router.mask):
        opening = router.mask.find("(", match.start(), match.end())
        closing = _balanced(router.mask, opening)
        args = _named_arguments(router, opening, closing)
        builder = args.get("builder", args.get("pageBuilder", {})).get("expression")
        constructed = []
        if builder:
            for name in sorted(set(re.findall(r"\b([A-Za-z_]\w*(?:\.[A-Za-z_]\w*)?)\s*\(", _lex(builder)[1]))):
                if name in class_sources:
                    constructed.append({"class": name, "sources": sorted(set(class_sources[name]))})
        expression = args.get("path", {}).get("expression")
        path = None
        if expression:
            if re.fullmatch(r"RouteName\.\w+", expression): path = constants.get(expression.split(".", 1)[1])
            else:
                literals = _lex(expression)[2]
                if len(literals) == 1: path = _expand(literals[0][2], {"RouteName." + key: value for key, value in constants.items()})
        routes.append({"id": "router:" + str(router.line(match.start())), "source": ROUTER,
                       "line": router.line(match.start()), "constructor": match.group(1), "path": path,
                       "pathExpression": expression, "builderExpression": builder, "constructedClasses": constructed,
                       "redirectExpression": args.get("redirect", {}).get("expression"),
                       "status": "static-constructor-evidence; effective reachability requires review"})
    return routes


def _controllers(sources: Sources) -> list[dict]:
    result = []
    base = ROOT / "server/src/main/java"
    for path in sorted(base.rglob("*Controller.java")):
        unit = sources.get(path.relative_to(ROOT).as_posix())
        class_match = re.search(r"\bclass\s+(\w+)", unit.mask)
        paths = []
        for match in re.finditer(r"@RequestMapping\b", unit.mask[:class_match.start() if class_match else len(unit.mask)]):
            opening = unit.mask.find("(", match.end())
            if opening < 0: continue
            closing = _balanced(unit.mask, opening)
            paths.extend(value for _, _, value in _lex(unit.code[opening + 1:closing])[2] if value.startswith("/"))
        methods = []
        method_start = class_match.end() if class_match else 0
        for match in re.finditer(r"@(Get|Post|Put|Patch|Delete|Request)Mapping\b", unit.mask[method_start:]):
            offset = method_start + match.start()
            tail = method_start + match.end()
            while tail < len(unit.mask) and unit.mask[tail].isspace(): tail += 1
            literals = []
            if tail < len(unit.mask) and unit.mask[tail] == "(":
                closing = _balanced(unit.mask, tail)
                literals = [value for _, _, value in _lex(unit.code[tail + 1:closing])[2] if value.startswith("/")]
            methods.append({"httpMethod": match.group(1).upper(), "line": unit.line(offset), "declaredPathLiterals": literals,
                            "fullPathCandidates": [base.rstrip("/") + path for base in paths for path in (literals or [""])]})
        result.append({**unit.summary(), "class": class_match.group(1) if class_match else path.stem,
                       "declaredBasePaths": paths,
                       "methodMappingAnnotationCount": len(methods), "declaredMethodMappings": methods,
                       "bindingStatus": "需人工核实"})
    return result


def _controller_candidates(endpoints: list[dict], controllers: list[dict]) -> list[dict]:
    matches = {}
    for endpoint in endpoints:
        template = endpoint.get("template")
        if not template or not template.startswith("/"): continue
        target = re.sub(r"^/api(?=/)", "", template.split("?", 1)[0]).strip("/").split("/")
        for controller in controllers:
            for base in controller["declaredBasePaths"]:
                prefix = re.sub(r"^/api(?=/)", "", base).strip("/").split("/")
                if len(prefix) <= len(target) and all(a == b or "{" in a or "{" in b or "$" in a or "$" in b for a, b in zip(prefix, target)):
                    item = matches.setdefault(controller["source"], {"source": controller["source"], "status": "需人工核实",
                        "matchBasis": "declared controller-prefix vs direct page/repository endpoint evidence", "endpointEvidence": []})
                    evidence = {"source": endpoint["source"], "line": endpoint["line"], "template": template, "controllerBase": base}
                    if evidence not in item["endpointEvidence"]: item["endpointEvidence"].append(evidence)
    return sorted(matches.values(), key=lambda item: item["source"])


def collect() -> dict:
    sources = Sources()
    router, names = sources.get(ROUTER), sources.get(ROUTE_NAMES)
    permission_definitions, _ = _definitions(sources.get(PERMISSIONS))
    endpoint_definitions, endpoint_values = _definitions(sources.get(ENDPOINTS))
    # RouteName constants and RoutePaths helpers can share a member name. Only
    # constant declarations describe registered path values; helpers add query.
    _, route_values = _definitions(names, constants_only=True)
    routes = _routes(router, route_values, sources)
    global_redirect = None
    global_router = re.search(r"\bGoRouter\s*\(", router.mask)
    if global_router:
        opening = router.mask.find("(", global_router.start(), global_router.end())
        args = _named_arguments(router, opening, _balanced(router.mask, opening))
        if "redirect" in args:
            global_redirect = {"source": ROUTER, **args["redirect"], "status": "source policy; manually verify reachability"}
    controllers = _controllers(sources)
    pages = []
    for path in sorted((ROOT / "lib/features").rglob("*_page.dart")):
        unit = sources.get(path.relative_to(ROOT).as_posix())
        feature = path.relative_to(ROOT / "lib/features").parts[0]
        imports = _imports(unit, sources)
        endpoints = _endpoint_refs(unit, endpoint_definitions, endpoint_values)
        repository_evidence, parts = [], []
        for entry in imports:
            target = sources.get(entry["source"]) if entry["source"] else None
            if not target: continue
            if entry["directive"] == "part":
                parts.append({**target.summary(), "classes": _classes(target), "actionHandlers": _actions(target),
                              "permissionReferences": _permission_refs(target, permission_definitions),
                              "apiEndpointReferences": _endpoint_refs(target, endpoint_definitions, endpoint_values)})
            if entry["role"] == "repositories":
                refs = _endpoint_refs(target, endpoint_definitions, endpoint_values)
                _, local_values = _definitions(target)
                for start, _, value in target.strings:
                    if value.startswith("/") and not value.startswith("//"):
                        refs.append({"source": target.source, "line": target.line(start), "template": _expand(value, local_values),
                                     "symbol": None, "basis": "repository path literal; verify actual request call"})
                repository_evidence.append({**target.summary(), "apiEndpointReferences": refs})
        direct_routes = []
        for route in routes:
            classes = [item["class"] for item in route["constructedClasses"] if unit.source in item["sources"]]
            if classes:
                direct_routes.append({"routeId": route["id"], "routerLine": route["line"], "path": route["path"],
                    "pathExpression": route["pathExpression"], "builderClasses": classes,
                    "builderExpression": route["builderExpression"], "redirectExpression": route["redirectExpression"]})
        direct_paths = {route["path"] for route in direct_routes if route["path"]}
        redirects = []
        for route in routes:
            if not route["redirectExpression"]: continue
            refs = re.findall(r"\bRouteName\.(\w+)", _lex(route["redirectExpression"])[1])
            possible = [name for name in refs if route_values.get(name) in direct_paths]
            if possible:
                redirects.append({"routeId": route["id"], "routerLine": route["line"], "path": route["path"],
                    "targetConstants": possible, "redirectExpression": route["redirectExpression"], "status": "possible alias; 需人工核实"})
        all_endpoints = endpoints + [item for repository in repository_evidence for item in repository["apiEndpointReferences"]]
        all_endpoints += [item for part in parts for item in part["apiEndpointReferences"]]
        review_flags = []
        if feature == "visitor": review_flags.append("访客门户前端已被全局redirect下线；保留源码不等于本次需要恢复该门户，需确认范围。")
        if not direct_routes: review_flags.append("未找到直接路由builder构造；可能由动态factory、共享页面或内部导航进入，需核实。")
        if len(direct_routes) > 1: review_flags.append("同页存在多个路由/参数实例；不能据此认定业务、权限或生命周期等价。")
        if any(entry["role"] in {"featureWidgets", "providers", "sharedComponents"} for entry in imports):
            review_flags.append("存在委托组件/provider；页面内操作和权限引用不是完整链路清单，需沿导入继续审查。")
        if parts: review_flags.append("已附直接part文件证据；part及共享依赖不能作为新增独立workflow计数。")
        pages.append({"id": "page:" + unit.source[len("lib/features/"):], "feature": feature, **unit.summary(),
            "classes": _classes(unit), "directImports": imports, "partUnits": parts,
            "permissionReferences": _permission_refs(unit, permission_definitions), "apiEndpointReferences": endpoints,
            "directRepositoryEvidence": repository_evidence, "actionHandlers": _actions(unit),
            "routerBindings": direct_routes, "possibleRedirectAliases": redirects,
            "candidateBackendControllers": _controller_candidates(all_endpoints, controllers), "reviewFlags": review_flags})
    counts = Counter(page["feature"] for page in pages)
    evidence = []
    for source in (ROUTE_NAMES, ROUTER):
        unit = sources.get(source)
        for line, text in enumerate(unit.text.splitlines(), 1):
            if re.search(r"退役|访客门户前端|前端下线|/visitor\*", text):
                evidence.append({"source": source, "line": line, "text": text.strip()})
    access_policy = sources.get("lib/core/router/route_access_policy.dart")
    retired_guard = re.search(r"bool\s+isVisitorPortalLocation\([^)]*\)\s*=>.*?;", access_policy.code, re.S) if access_policy else None
    guard_evidence = {"source": access_policy.source, "line": access_policy.line(retired_guard.start()),
                      "expression": retired_guard.group(0), "sha256": access_policy.sha256} if retired_guard else None
    unresolved_endpoints = sorted({item["symbol"] for page in pages for item in page["apiEndpointReferences"] if item["template"] is None})
    return {"schemaVersion": 1, "status": "source-inventory-only", "fullWorkflowCount": None,
        "summary": {"pageFiles": len(pages), "featureGroups": len(counts), "controllerFiles": len(controllers),
            "routeConstructorCandidates": len(routes), "pagesWithDirectRouterBinding": sum(bool(page["routerBindings"]) for page in pages),
            "pagesWithPossibleAliases": sum(bool(page["possibleRedirectAliases"]) or len(page["routerBindings"]) > 1 for page in pages),
            "directPartUnits": sum(len(page["partUnits"]) for page in pages),
            "methodDeclarationActionCandidates": sum(item["kind"] == "method-declaration-candidate" for page in pages for item in page["actionHandlers"]),
            "actionUiFactoryCandidates": sum(item["kind"] == "action-ui-factory" for page in pages for item in page["actionHandlers"]),
            "retiredPortalPagesNeedingScopeConfirmation": counts.get("visitor", 0)},
        "interpretation": {"pageFilesAreNotWorkflows": True, "controllerCandidatesRequireManualVerification": True,
            "actionsAreNameBasedCandidatesNotCommandsProvenToWrite": True, "noBusinessApiOrNetworkExecuted": True},
        "parsingBoundaries": ["Lexical Dart/Java extraction, not compiler AST or runtime navigation execution.",
            "Router constructor calls and class construction references may include dynamic factories and globally redirected routes.",
            "Only direct page/part/repository imports and references are expanded; shared/provider transitive business logic remains manual work.",
            "Direct permission occurrences do not replace central permission_by_path guards or server authorization/object scope checks.",
            "Controller-prefix matches are candidates, not confirmed method/HTTP/payload/transaction relationships.",
            "Action names can include UI cancellation or collection operations; declarations, callback references and invocations are distinguished.",
            "An absent handler/API/route match is an extraction gap, not evidence that the page has no business behavior."],
        "featureGroups": [{"feature": feature, "label": FEATURE_LABELS.get(feature, feature), "pageCount": count,
                            "pageIds": [page["id"] for page in pages if page["feature"] == feature]} for feature, count in sorted(counts.items())],
        "scopeConfirmation": {"retiredEntry": {"path": "/entry", "status": "retired redirect retained; confirm compatibility-only scope"},
            "retiredVisitorPortal": {"feature": "visitor", "pageCount": counts.get("visitor", 0), "status": "frontend disabled; confirm whether to keep retired"},
            "employeeVisitorApproval": {"feature": "visitor_approval", "pageCount": counts.get("visitor_approval", 0), "status": "separate employee workflow; do not retire with portal"},
            "sourceEvidence": evidence, "visitorPortalGuard": guard_evidence},
        "globalRouterRedirectPolicy": global_redirect,
        "unresolvedDirectApiEndpointSymbols": unresolved_endpoints, "pages": pages, "routerInventory": routes,
        "controllerInventory": controllers, "sourceFiles": [unit.summary() for _, unit in sorted(sources.units.items())]}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true", help="compare saved inventory without writing")
    mode.add_argument("--write", action="store_true", help="explicitly update the source inventory JSON")
    args = parser.parse_args()
    inventory = collect()
    rendered = json.dumps(inventory, ensure_ascii=False, indent=2) + "\n"
    if args.check:
        if not OUTPUT.is_file() or OUTPUT.read_text(encoding="utf-8") != rendered:
            raise SystemExit("Business inventory is stale or absent; run business_inventory.py --write.")
        print(json.dumps(inventory["summary"], ensure_ascii=False))
    elif args.write:
        OUTPUT.parent.mkdir(parents=True, exist_ok=True)
        OUTPUT.write_text(rendered, encoding="utf-8")
        print(json.dumps(inventory["summary"], ensure_ascii=False))
    else:
        print(rendered, end="")


if __name__ == "__main__":
    main()
