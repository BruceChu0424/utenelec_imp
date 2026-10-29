#!/usr/bin/env python3
"""Stable, source-backed Win7 migration work packages and handover documents.

init/sync preserve task identity; render derives Markdown from the registry.
No test result is inferred from the existence of code. A done transition requires
existing evidence, reviewed acceptance, and completed dependencies.
"""
from __future__ import annotations

import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[3]
STATE = ROOT / "clients/windows_legacy/progress"
DOCS = ROOT / "docs/99-项目治理/Win7兼容版"
REGISTRY = STATE / "work-items.json"
STATUSES = {"todo": "未开始", "in_progress": "进行中", "implemented": "源码已实现/待整合验证",
            "verified_local": "本机验证/待本项最终验收", "done": "本项DoD完成",
            "blocked": "有明确阻碍", "not_applicable": "经核实不适用"}
STATUS_ORDER = tuple(STATUSES)


def read_json(path: Path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


def write_json(path: Path, value) -> None:
    rendered = json.dumps(value, ensure_ascii=False, indent=2) + "\n"
    path.parent.mkdir(parents=True, exist_ok=True)
    handle, name = tempfile.mkstemp(prefix=".work-registry-", dir=path.parent)
    try:
        with os.fdopen(handle, "w", encoding="utf-8", newline="\n") as stream:
            stream.write(rendered)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name): os.unlink(name)


def relative_file(value: str) -> Path:
    name = value.split("#", 1)[0]
    path = (ROOT / name).resolve()
    if Path(name).is_absolute() or not path.is_relative_to(ROOT.resolve()):
        raise ValueError("Evidence must be a repository-relative file")
    return path


def page_task(page: dict, identifier: str, labels: dict) -> dict:
    source = page["source"]
    feature = page["feature"]
    actions = sorted({hint for item in page.get("actionHandlers", []) for hint in item.get("actionNameHints", [])})
    title = source.rsplit("/", 1)[-1].replace("_page.dart", "").replace("_", " ")
    partial = source in {"lib/features/basic_data/pages/product_category_page.dart", "lib/features/basic_data/pages/goods_detail_page.dart"}
    criteria = [
        "核实本页有效入口、路由/别名/内嵌/退役分类，以及静态发现之外的所有实际动作。",
        "逐一对照 owning Flutter UI/公共组件及后端DTO/权限/动作合同；缺失接口单独登记必要增量，不能猜测。",
        "原生WPF实现全部适用读取、筛选/排序/分页、详情/导航与业务动作，不能只做菜单或只读代替写流程。",
        "若源有新增/编辑/审核/批量/附件/导入导出/打印/历史，逐项迁移，保留币种/单位/来源/归属及精度/未知语义。",
        "权限/数据集/读范围、草稿、版本/幂等、未知提交、取消/断网/重启/升级行为有合同及恢复证据。",
        "复用同源Uten圆角/控件/字体/间距，完成键盘/IME/缩放/状态/焦点与现版本实际对照。",
        "当前源码x86与x64合同及调用方检查通过；在Win7 SP1两架构验证完整适用流程，并确认Win10相关回归。",
        "更新该页、相关FLOW链和证据记录；只有全部适用条件满足或有证据的N/A才可完成。",
    ]
    if actions:
        criteria.insert(3, "源码发现的动作线索须逐项核实：" + "、".join(actions) + "（仅静态线索，不等于完整动作清单）。")
    return {"id": identifier, "title": labels.get(feature, feature) + " / " + title,
            "group": "BIZ", "groupLabel": "全部业务页面迁移", "phase": "D", "feature": feature,
            "businessSource": source, "sourceSha256": page["sha256"],
            "sourceProofSha256": hashlib.sha256(json.dumps(page, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")).hexdigest(),
            "status": "in_progress" if partial else "todo", "impactArea": "frontend+shared-contract",
            "owner": "待认领", "sources": [source], "nativeTargets": [
                "clients/windows_legacy/Uten.Legacy.Desktop/Features/Goods/GoodsWorkspaceView.cs"] if partial else [],
            "dependencies": ["W7-GOV-005", "W7-GOV-006", "W7-CORE-011", "W7-CORE-012", "W7-CORE-013", "W7-CORE-014", "W7-UI-001"],
            "definitionOfDone": criteria, "evidence": [],
            "notes": "仅分类/分页/选中详情读取部分已有源；其余业务与目标机验收未完成。" if partial else "尚未迁移；先做动作/合同审计。",
            "lastUpdated": "2026-10-28"}


def inventory() -> dict:
    value = read_json(STATE / "business-inventory.json")
    if not isinstance(value.get("pages"), list) or not value["pages"]:
        raise ValueError("Source business inventory must be generated first")
    return value


def build_registry(previous=None) -> dict:
    source = inventory()
    catalog = read_json(STATE / "infrastructure-catalog.json")
    labels = {item["feature"]: item.get("label", item["feature"]) for item in source.get("featureGroups", [])}
    tasks = json.loads(json.dumps(catalog["tasks"]))
    old = {item["id"]: item for item in (previous or {}).get("tasks", [])}
    old_pages = {item["businessSource"]: item for item in old.values() if item.get("businessSource")}
    issued = [int(item["id"].rsplit("-", 1)[-1]) for item in old_pages.values()]
    next_page = max(issued, default=0) + 1
    current_sources = set()
    for page in sorted(source["pages"], key=lambda item: item["source"]):
        prior = old_pages.get(page["source"])
        identifier = prior["id"] if prior else "W7-BIZ-" + str(next_page).zfill(3)
        if prior is None:
            next_page += 1
        task = page_task(page, identifier, labels)
        if prior:
            for field in ("title", "status", "owner", "evidence", "notes", "nativeTargets", "definitionOfDone", "lastUpdated"):
                task[field] = prior[field]
            source_changed = (prior.get("sourceProofSha256") != task["sourceProofSha256"] if prior.get("sourceProofSha256")
                              else prior.get("sourceSha256") != page["sha256"])
            if source_changed and prior["status"] == "done":
                task["status"] = "in_progress"
                task["notes"] += "\n源代码指纹变化，旧完成状态已退回复核；原证据保留。"
        tasks.append(task)
        current_sources.add(page["source"])
    for task in tasks:
        if task["group"] != "BIZ" and task["id"] in old:
            for field in ("title", "status", "owner", "evidence", "notes", "nativeTargets", "definitionOfDone", "lastUpdated"):
                task[field] = old[task["id"]][field]
    for prior in old_pages.values():
        if prior["businessSource"] not in current_sources:
            retained = dict(prior)
            if retained["status"] != "not_applicable":
                retained["status"] = "in_progress"
                retained["notes"] += "\n源清单已不再发现该页，须人工分类退役/改名；不得自动删除历史任务。"
            tasks.append(retained)
    registry = {"schemaVersion": 1, "project": "UTEN Win7 native WPF complete migration",
            "branch": "uimp/win7-wpf-client-20261028", "baselineDate": "2026-10-28",
            "taskUnit": "稳定工作包；不等于页面、动作、工时或等权风险",
            "constraints": {"mergeMainAllowed": False, "productionDeploymentAllowed": False},
            "inventorySha256": hashlib.sha256((STATE / "business-inventory.json").read_bytes()).hexdigest(),
            "baselineCounts": {"businessPagePackages": len(source["pages"]),
                               "commonAndFlowPackages": len(catalog["tasks"]), "workPackages": len(tasks)},
            "groups": catalog["groups"] + [{"id": "BIZ", "title": "全部业务页面迁移", "phase": "D"}],
            "tasks": tasks}
    reopen_dependents(registry)
    return registry


def reopen_dependents(registry: dict) -> None:
    """A reopened prerequisite must not leave its dependents falsely checked."""
    changed = True
    while changed:
        changed = False
        states = {item["id"]: item["status"] for item in registry["tasks"]}
        for item in registry["tasks"]:
            pending = [identifier for identifier in item["dependencies"] if states.get(identifier) not in {"done", "not_applicable"}]
            if item["status"] == "done" and pending:
                item["status"] = "in_progress"
                item["notes"] += "\n前置工作重新打开，需复核：" + ", ".join(pending)
                item["lastUpdated"] = datetime.now(timezone.utc).isoformat()
                changed = True


def validate(registry: dict) -> None:
    tasks = registry["tasks"]
    ids = [item["id"] for item in tasks]
    if len(ids) != len(set(ids)):
        raise ValueError("Duplicate work package ID")
    known = set(ids)
    for item in tasks:
        if item["status"] not in STATUSES or not item["definitionOfDone"]:
            raise ValueError("Invalid status or empty acceptance criteria: " + item["id"])
        if set(item["dependencies"]) - known:
            raise ValueError("Unknown dependency: " + item["id"])
        if item["id"] in item["dependencies"]:
            raise ValueError("Self dependency")
        if item["status"] == "done" and not item["evidence"]:
            raise ValueError("A done package requires evidence: " + item["id"])
        if item["status"] in {"blocked", "not_applicable"} and not item["notes"].strip():
            raise ValueError("Blocked/N/A requires a specific explanation")
        if item["status"] == "not_applicable" and not item["evidence"]:
            raise ValueError("N/A requires owning source evidence, not just an explanation")
        for proof in item["evidence"]:
            if not relative_file(proof).is_file():
                raise ValueError("Evidence file does not exist: " + proof)
    visiting, visited = set(), set()
    by_id = {item["id"]: item for item in tasks}
    def walk(identifier):
        if identifier in visiting:
            raise ValueError("Cyclic task dependencies")
        if identifier in visited:
            return
        visiting.add(identifier)
        for dependency in by_id[identifier]["dependencies"]:
            walk(dependency)
        visiting.remove(identifier)
        visited.add(identifier)
    for identifier in ids:
        walk(identifier)


def summary(registry: dict) -> dict:
    counts = Counter(item["status"] for item in registry["tasks"])
    closed = {item["id"] for item in registry["tasks"] if item["status"] in {"done", "not_applicable"}}
    business = [item for item in registry["tasks"] if item.get("group") in {"BIZ", "FLOW"}]
    business_complete = bool(business) and all(item["id"] in closed for item in business) and any(item["status"] == "done" for item in business)
    win7_complete = {"W7-ARCH-003", "W7-ARCH-004", "W7-INS-008", "W7-UPD-010"}.issubset(closed)
    return {"totalWorkPackages": len(registry["tasks"]), "done": counts["done"],
            "remainingIncludingUnverified": sum(count for state, count in counts.items() if state not in {"done", "not_applicable"}),
            "notApplicable": counts["not_applicable"], "states": {state: counts[state] for state in STATUS_ORDER},
            "fullErpEquivalent": business_complete, "win7Accepted": win7_complete, "mergeMainAllowed": False}


def md(value) -> str:
    return str(value).replace("|", "\\|").replace("\n", "<br>")


def _task_details(item: dict) -> list[str]:
    lines = ["## " + item["id"], "", f"- [{'x' if item['status']=='done' else ' '}] **{item['title']}** — {STATUSES[item['status']]}", "",
             f"影响：`{item['impactArea']}`；负责人：{item['owner']}；依赖：{', '.join(item['dependencies']) or '无'}。", "",
             "源入口：" + "；".join(f"`{source}`" for source in item["sources"]) + "。", "",
             "完成条件：", ""]
    lines += [str(index) + ". " + text for index, text in enumerate(item["definitionOfDone"], 1)]
    lines += ["", "证据：" + ("；".join(f"`{value}`" for value in item["evidence"]) or "尚未登记，不得推定通过") + "。", "",
              "接续/限制：" + (item["notes"].replace("\n", "；") or "按依赖与DoD继续，完成后登记证据") + "。", ""]
    return lines


def _source_hint(kind, item):
    if not isinstance(item, dict):
        return md(item)
    if kind == "classes":
        return md(f"{item.get('name')} @{item.get('line')} ({item.get('role')})")
    if kind == "permissionReferences":
        return md(f"{item.get('literal') or item.get('symbol')} @{item.get('line')}；定义 {item.get('definitionSource')}:{item.get('definitionLine')}")
    if kind == "apiEndpointReferences":
        return md(f"{item.get('symbol')} @{item.get('line')} → {item.get('template') or item.get('definitionExpression')}")
    if kind == "directRepositoryEvidence":
        endpoints = sorted({str(value.get('template') or value.get('symbol')) for value in item.get('apiEndpointReferences', [])})
        return md(str(item.get("source")) + "；接口：" + "、".join(endpoints))
    if kind == "candidateBackendControllers":
        return md(str(item.get("source")) + "；" + str(item.get("status")) + "；依据 " + str(item.get("matchBasis")))
    if kind == "actionHandlers":
        text = str(item.get("evidenceLine") or item.get("callback") or "")
        if len(text) > 300:
            text = text[:300] + "…（完整内容按源码行号核查）"
        return md(f"{item.get('symbol')} @{item.get('line')} [{item.get('kind')}] 提示 {item.get('actionNameHints', [])}；{text}")
    if kind == "routerBindings":
        return md(f"{item.get('path') or item.get('pathExpression')}；router @{item.get('routerLine')}；builder {item.get('builderClasses')}；redirect {item.get('redirectExpression')}")
    return md(json.dumps(item, ensure_ascii=False, separators=(",", ":")))


def render(registry: dict) -> dict[Path, str]:
    stats = summary(registry)
    tasks = registry["tasks"]
    lines = ["# Win7 兼容版逐项进度清单", "", "由 `progress/work-items.json` 生成；请通过进度工具更新，不手改复选框。",
             "", f"基线：**{stats['totalWorkPackages']} 个工作包**；完成 **{stats['done']}**；尚待实施或验证 **{stats['remainingIncludingUnverified']}**；已核实不适用 **{stats['notApplicable']}**。",
             "", "工作包完成率不是工时/风险进度。源码存在、局部检查、本机双架构、Win7真机及正式交付分别记录；全ERP验收=" + str(stats["fullErpEquivalent"]) + "，Win7目标机验收=" + str(stats["win7Accepted"]) + "；合并和分支清理以当前明确授权及14最新记录为准，不等于完整验收或允许正式发布。", "",
             "| 状态 | 数量 |", "|---|---:|"]
    lines += [f"| {STATUSES[state]} | {stats['states'][state]} |" for state in STATUS_ORDER]
    lines += ["", "## 阶段/分组汇总", "", "| 组 | 阶段 | 总数 | DoD完成 | 尚未完成/适用性待审 |", "|---|---|---:|---:|---:|"]
    for group in registry["groups"]:
        selected = [item for item in tasks if item["group"] == group["id"]]
        done = sum(item["status"] == "done" for item in selected)
        na = sum(item["status"] == "not_applicable" for item in selected)
        lines.append(f"| {group['id']} {group['title']} | {group['phase']} | {len(selected)} | {done} | {len(selected)-done-na} |")
    outputs = {}
    lines += ["", "## 完整工作包索引", "", "每项链接进入详细DoD、依赖、证据及接续说明；业务按模块拆分，避免一个超大文件无法审查。", ""]
    for group in registry["groups"]:
        lines += [f"### {group['id']} · {group['title']}", ""]
        for item in [task for task in tasks if task["group"] == group["id"]]:
            detail_name = group["id"] + ("-" + item["feature"] if item.get("feature") else "") + ".md"
            detail = DOCS / "tasks" / detail_name
            if detail not in outputs:
                outputs[detail] = "# " + group["title"] + (" / " + item["feature"] if item.get("feature") else "") + "\n\n由唯一进度登记表生成。\n\n"
            outputs[detail] += "\n".join(_task_details(item)) + "\n"
            lines.append(f"- [{'x' if item['status']=='done' else ' '}] [{item['id']} · {item['title']}](tasks/{detail_name}#{item['id'].lower()}) — {STATUSES[item['status']]}")
        lines.append("")
    source = inventory()
    page_lines = ["# 业务页面 owning 来源逐项清单", "", "静态盘点是审计起点，不是已迁移证明；候选控制器/动作必须按02矩阵人工核对。", "",
                  f"本基线共 {len(source['pages'])} 页。完整数据见 `clients/windows_legacy/progress/business-inventory.json`。", ""]
    ids = {item["businessSource"]: item["id"] for item in tasks if item.get("businessSource")}
    page_lines += ["| 模块 | 页面数 | 逐页来源 |", "|---|---:|---|"]
    page_documents = {}
    for page in source["pages"]:
        feature = page["feature"]
        if feature not in page_documents:
            page_documents[feature] = ["# " + feature + "：业务页面来源", "", "候选/静态线索必须人工核对；完整JSON证据保留在business-inventory.json。", ""]
        detail_lines = page_documents[feature]
        detail_lines += [f"## {ids[page['source']]} · {page['source']}", "",
                       f"模块 `{page['feature']}`；{page['lineCount']} 行；SHA256 `{page['sha256']}`。", "",
                       "| 审计项 | 静态来源/线索 |", "|---|---|"]
        for key, label in [("classes", "页面/状态类"), ("routerBindings", "真实路由绑定"), ("possibleRedirectAliases", "重定向/别名候选"),
                           ("permissionReferences", "权限"), ("apiEndpointReferences", "接口常量"), ("directRepositoryEvidence", "仓库调用"),
                           ("actionHandlers", "动作处理"), ("candidateBackendControllers", "控制器候选（人工核实）"), ("reviewFlags", "审计限制")]:
            values = page.get(key, [])
            content = "<br>".join(_source_hint(key, value) for value in values) if values else "未静态确认；不能当作不存在"
            detail_lines.append(f"| {label} | {content} |")
        imports = [value for value in page.get("directImports", []) if value.get("existsInRepository")]
        detail_lines += ["", "直接源依赖：" + ("；".join(f"`{value.get('source',value.get('uri'))}` ({value.get('role','')})" for value in imports) or "未发现") + "。", ""]
    for feature, detail_lines in sorted(page_documents.items()):
        count = sum(page["feature"] == feature for page in source["pages"])
        page_lines.append(f"| {feature} | {count} | [逐页源码/动作/接口/权限](pages/{feature}.md) |")
        outputs[DOCS / "pages" / (feature + ".md")] = "\n".join(detail_lines) + "\n"
    outputs.update({DOCS / "01-逐项进度清单.md": "\n".join(lines) + "\n",
                    DOCS / "06-业务页面来源清单.md": "\n".join(page_lines) + "\n"})
    return {path: text.rstrip() + "\n" for path, text in outputs.items()}


def write_rendered(registry: dict, check=False) -> None:
    for path, text in render(registry).items():
        if check:
            if not path.is_file() or path.read_text(encoding="utf-8") != text:
                raise ValueError("Generated progress document drifted: " + str(path.relative_to(ROOT)))
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8")
    stats = summary(registry)
    main = DOCS / "00-总实施计划与交接入口.md"
    text = main.read_text(encoding="utf-8")
    message = (f"已登记 **{stats['totalWorkPackages']} 个稳定工作包**：{registry['baselineCounts']['commonAndFlowPackages']} 个公共/治理/业务闭环/交付验收工作包 + "
               f"{registry['baselineCounts']['businessPagePackages']} 个页面迁移工作包。DoD完成 **{stats['done']}**；尚待实施或验证 **{stats['remainingIncludingUnverified']}**；"
               f"已核实不适用 **{stats['notApplicable']}**。源码已实现但待验证的项目不算已完成。\n")
    updated = re.sub(r"(?s)(<!-- PROGRESS_SUMMARY:START -->\n).*?(<!-- PROGRESS_SUMMARY:END -->)",
                     lambda match: match.group(1) + message + match.group(2), text)
    if check and updated != text:
        raise ValueError("Main plan summary drifted")
    if not check:
        main.write_text(updated, encoding="utf-8")
    history = STATE / "history.jsonl"
    history_lines = ["# 工作包变更与完成记录", "", "由history.jsonl生成，记录时间为UTC。任务状态唯一入口仍为work-items.json。", "",
                     "| 时间UTC | 任务 | 原状态 → 新状态 | 操作者 | 说明 | 证据 |", "|---|---|---|---|---|---|"]
    if history.is_file():
        for line in history.read_text(encoding="utf-8").splitlines():
            event = json.loads(line)
            history_lines.append("| " + " | ".join(md(value) for value in [event.get("atUtc", ""), event.get("id", "baseline"),
                str(event.get("from", "")) + " → " + str(event.get("to", "")), event.get("owner", ""), event.get("note", ""), "；".join(event.get("evidence", []))]) + " |")
    history_text = "\n".join(history_lines) + "\n"
    history_doc = DOCS / "07-变更与完成记录.md"
    if check and (not history_doc.is_file() or history_doc.read_text(encoding="utf-8") != history_text):
        raise ValueError("Generated task history drifted")
    if not check:
        history_doc.write_text(history_text, encoding="utf-8")


def validate_document_links() -> None:
    from urllib.parse import unquote
    for source in DOCS.rglob("*.md"):
        for match in re.finditer(r"\[[^\]]*\]\(([^)]+)\)", source.read_text(encoding="utf-8")):
            target = match.group(1).strip("<>")
            if re.match(r"[A-Za-z]+://", target) or target.startswith("#"):
                continue
            path, _, fragment = target.partition("#")
            resolved = (source.parent / unquote(path)).resolve()
            if not resolved.exists():
                raise ValueError("Broken handover link in " + source.name + ": " + target)
            if fragment.startswith("w7-") and resolved.suffix == ".md":
                headings = {value.lower() for value in re.findall(r"^##\s+(W7-[A-Z]+-\d+)\s*$", resolved.read_text(encoding="utf-8"), re.M)}
                if fragment not in headings:
                    raise ValueError("Broken work package anchor: " + target)


def change_status(registry, identifier, state, owner, note, evidence, acceptance_reviewed=False):
    item = next((value for value in registry["tasks"] if value["id"] == identifier), None)
    if item is None or state not in STATUSES:
        raise ValueError("Unknown task or status")
    proofs = list(dict.fromkeys(item["evidence"] + evidence))
    for proof in proofs:
        if not relative_file(proof).is_file():
            raise ValueError("Evidence file does not exist: " + proof)
    if state == "done":
        if not acceptance_reviewed or not proofs:
            raise ValueError("done requires --acceptance-reviewed and existing evidence")
        states = {task["id"]: task["status"] for task in registry["tasks"]}
        if any(states[dependency] not in {"done", "not_applicable"} for dependency in item["dependencies"]):
            raise ValueError("Do not complete a task whose prerequisites are still open")
    if state in {"blocked", "not_applicable"} and not note.strip():
        raise ValueError("Provide the specific blocking condition or N/A source explanation")
    if state == "not_applicable" and not proofs:
        raise ValueError("N/A requires existing owning source evidence")
    prior = item["status"]
    item.update(status=state, owner=owner or item["owner"], notes=note or item["notes"], evidence=proofs,
                lastUpdated=datetime.now(timezone.utc).isoformat())
    return {"atUtc": item["lastUpdated"], "id": identifier, "from": prior, "to": state,
            "owner": item["owner"], "note": note, "evidence": proofs, "acceptanceReviewed": acceptance_reviewed}


def main():
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    for command in ("init", "sync", "render", "check", "status"):
        sub.add_parser(command)
    show = sub.add_parser("show"); show.add_argument("id")
    listing = sub.add_parser("list"); listing.add_argument("--group"); listing.add_argument("--feature"); listing.add_argument("--status", choices=STATUS_ORDER)
    sub.add_parser("next")
    edit = sub.add_parser("set")
    edit.add_argument("id"); edit.add_argument("--status", choices=STATUS_ORDER, required=True)
    edit.add_argument("--owner", default=""); edit.add_argument("--note", default="")
    edit.add_argument("--evidence", action="append", default=[])
    edit.add_argument("--acceptance-reviewed", action="store_true")
    args = parser.parse_args()
    try:
        previous = None
        if args.command == "init":
            if REGISTRY.exists(): raise ValueError("Registry exists; use sync to preserve task identity")
            registry = build_registry()
        elif args.command == "sync":
            previous = read_json(REGISTRY) if REGISTRY.exists() else None
            registry = build_registry(previous)
        else:
            registry = read_json(REGISTRY)
        event = None
        if args.command == "set":
            event = change_status(registry, args.id, args.status, args.owner, args.note, args.evidence, args.acceptance_reviewed)
            before_reopen = {item["id"]: dict(item) for item in registry["tasks"]}
            reopen_dependents(registry)
            if previous is None:
                previous = {"tasks": list(before_reopen.values())}
        validate(registry)
        if args.command == "show":
            item = next((item for item in registry["tasks"] if item["id"] == args.id), None)
            if item is None: raise ValueError("Unknown work package")
            print(json.dumps(item, ensure_ascii=False, indent=2)); return
        if args.command in {"list", "next"}:
            selected = registry["tasks"]
            if args.command == "list":
                selected = [item for item in selected if (not args.group or item["group"] == args.group)
                            and (not args.feature or item.get("feature") == args.feature)
                            and (not args.status or item["status"] == args.status)]
            else:
                states = {item["id"]: item["status"] for item in selected}
                selected = [item for item in selected if item["status"] not in {"done", "not_applicable", "blocked"}
                            and all(states[dependency] in {"done", "not_applicable"} for dependency in item["dependencies"])]
            print(json.dumps([{key: item.get(key) for key in ("id", "title", "status", "owner", "impactArea", "dependencies", "businessSource")}
                              for item in selected], ensure_ascii=False, indent=2)); return
        if args.command in {"init", "sync", "set"}:
            write_json(REGISTRY, registry)
        events = [event] if event else []
        if previous:
            prior_tasks = {item["id"]: item for item in previous["tasks"]}
            for item in registry["tasks"]:
                prior = prior_tasks.get(item["id"])
                if prior is None or prior["status"] != item["status"]:
                    events.append({"atUtc": datetime.now(timezone.utc).isoformat(), "id": item["id"],
                                   "from": prior["status"] if prior else "unregistered", "to": item["status"],
                                   "owner": item["owner"], "note": "Source inventory sync; stable task identity preserved.",
                                   "evidence": item["evidence"], "acceptanceReviewed": False})
        if events:
            with (STATE / "history.jsonl").open("a", encoding="utf-8") as stream:
                for recorded in events:
                    stream.write(json.dumps(recorded, ensure_ascii=False) + "\n")
        if args.command in {"init", "sync", "set", "render", "check"}:
            if args.command == "check":
                # Some bundled Python launchers report a directory as
                # sys.executable. Reuse the owning pure reader in-process.
                from business_inventory import collect
                current = json.dumps(collect(), ensure_ascii=False, indent=2) + "\n"
                if (STATE / "business-inventory.json").read_text(encoding="utf-8") != current:
                    raise ValueError("Business source inventory drifted; regenerate it explicitly")
            expected = hashlib.sha256((STATE / "business-inventory.json").read_bytes()).hexdigest()
            if registry["inventorySha256"] != expected:
                raise ValueError("Business source inventory changed; sync the work registry without resetting its history")
            write_rendered(registry, check=args.command == "check")
            if args.command == "check": validate_document_links()
        print(json.dumps(summary(registry), ensure_ascii=False))
    except (OSError, ValueError, KeyError, TypeError) as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()
