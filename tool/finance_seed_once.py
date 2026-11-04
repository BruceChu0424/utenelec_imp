#!/usr/bin/env python3
"""Manually stage the specifically supplied finance sources once. Python stdlib only.

No startup/update hook, SQL writes, GL submission, approval, stock, or cash mutation.
Private plan/archive/journal belong outside the application's version directory.
"""
from __future__ import annotations

import argparse
import calendar
from contextlib import contextmanager
from decimal import Decimal
import getpass
import hashlib
import http.client
import ipaddress
import json
import os
from pathlib import Path, PurePosixPath
import re
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import uuid
import zipfile

VERSION = "uten-finance-seed-once-v1"
MAX_FILE = 15 * 1024 * 1024
MAX_ASSET = 64 * 1024 * 1024  # Matches DocumentIntakeProfile.FINANCIAL_ASSET.
REPORT_DIR = "september/2026年9月份报表/"
REPORT_NAMES = (
    "2026年9月固定资产明细表.xlsx", "2026年9月优腾公司经营指标基本信息表.xls",
    "2026年9月份销售出库成本核算表.xls", "2026年9月份费用明细表.xlsx",
    "2026年9月份财务报表.xlsx", "2026年9月份科目余额表.xls",
    "2026年9月份应收账款明细表.xls", "2026年9月份应付账款明细表.xls",
    "2026年9月份公司经营损益表.xlsx",
)
SOURCE_PATHS = (
    "2026年9月份科目余额表代码.xls", "ERP财务部门需求汇总.xlsx",
    "5380e0e9591d6269a0c67dfcc5ef7e38.png", "e4bebb7591a44ee7406fa583727bdefa.png",
    "40a4302aba9c0bbf3944864af49b56d2.png", "3493d7fb03a3a1a2e3dc638d915a481d.png",
    "codex-clipboard-b9371d07-a9af-47c0-8424-f6437c29aabc.png",
    "codex-clipboard-91335811-82b0-4e1c-89df-bff07421b4e9.png",
    "september/codex-clipboard-84ac21e0-6539-4ebd-bba6-9358ad11ae41.png",
    "september/2026年9月份报表.zip", "september/2026年9月份会计分录凭证.xls",
) + tuple(REPORT_DIR + name for name in REPORT_NAMES)
ASSETS = ("depreciation", "amortization", "depreciationCompleted")
COSTS = ("copperFee", "copperDetail", "plasticUsage", "plasticIssue", "plasticReturn",
         "plasticFinished", "salesCostSummary", "otherReceivableStatement")
STATEMENTS = ("subcontractStatement", "supplierStatement", "clientStatement")
REQUIRED_PERMISSIONS = {"finance_report:view", "finance:view:all", "payment_style:edit",
                        "finance_post:execute", "finance_asset:view", "finance_asset:edit"}


class SeedError(Exception):
    """Safe to display: messages must never include credentials/response payloads."""


class HttpFailure(SeedError):
    def __init__(self, status: int, code: str = "HTTP_ERROR"):
        self.status, self.code = status, code
        super().__init__(f"HTTP {status} ({code}); 保留原计划和原请求，在业务页面核对")


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def encode(value) -> bytes:
    # Plans contain no binary floats. Decimal responses are inspected, never serialized wholesale.
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"),
                      allow_nan=False).encode("utf-8")


def read_json(path: Path):
    try:
        return json.loads(path.read_text(encoding="utf-8"), parse_float=Decimal,
                          parse_constant=lambda _: (_ for _ in ()).throw(SeedError("无效JSON数字")))
    except (ValueError, OSError) as exc:
        raise SeedError("无法读取私有计划或日志；保留原文件") from exc


def atomic_bytes(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, name = tempfile.mkstemp(prefix=".seed-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
        if os.name != "nt":
            directory = os.open(path.parent, os.O_RDONLY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def atomic_json(path: Path, value) -> None:
    atomic_bytes(path, encode(value))


@contextmanager
def state_lock(state: Path):
    state.mkdir(parents=True, exist_ok=True, mode=0o700)
    lock = open(state / ".finance-seed.lock", "a+b")
    try:
        lock.seek(0, os.SEEK_END)
        if lock.tell() == 0:
            lock.write(b"0")
            lock.flush()
        lock.seek(0)
        try:
            if os.name == "nt":
                import msvcrt
                msvcrt.locking(lock.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as exc:
            raise SeedError("另一进程持有本次导入锁；不能并发运行") from exc
        yield
    finally:
        lock.close()  # OS releases the lock even after interruption/process death.


def server_url(value: str, allow_http_loopback=False) -> str:
    parsed = urllib.parse.urlsplit(value)
    if parsed.username or parsed.password or parsed.query or parsed.fragment or not parsed.hostname:
        raise SeedError("目标地址不能包含凭据、查询或片段")
    allowed_http = False
    if allow_http_loopback:
        try:
            allowed_http = ipaddress.ip_address(parsed.hostname).is_loopback
        except ValueError:
            allowed_http = parsed.hostname == "localhost"
    if parsed.scheme != "https" and not (parsed.scheme == "http" and allowed_http):
        raise SeedError("目标须使用HTTPS；匿名本机验证可显式允许loopback HTTP")
    if parsed.path.rstrip("/") not in ("", "/api"):
        raise SeedError("目标地址路径只允许空或/api")
    return urllib.parse.urlunsplit((parsed.scheme, parsed.netloc.lower(), "/api", "", ""))


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        fp.close()
        raise SeedError("服务器重定向已拒绝；认证信息未转发，请核对原目标地址")


class Api:
    def __init__(self, server: str, token: str):
        if not token or "\r" in token or "\n" in token:
            raise SeedError("请通过环境变量或安全交互提供当前令牌")
        self.server, self.token = server, token
        self.opener = urllib.request.build_opener(NoRedirect())

    def request(self, method, path, *, query=None, body=None, headers=None, raw=False):
        if not path.startswith("/") or path.startswith("//") or "?" in path or "#" in path:
            raise SeedError("请求必须使用固定相对API路径")
        url = self.server + path
        if query:
            url += "?" + urllib.parse.urlencode(sorted(query.items()))
        actual_headers = {"Authorization": "Bearer " + self.token, "Accept": "application/json"}
        actual_headers.update(headers or {})
        request = urllib.request.Request(url, data=body, headers=actual_headers, method=method)
        try:
            with self.opener.open(request, timeout=60) as response:
                data = response.read(64 * 1024 * 1024 + 1)
                if len(data) > 64 * 1024 * 1024:
                    raise SeedError("响应超限，保留原请求等待核对")
                if raw:
                    return data
                try:
                    return json.loads(data, parse_float=Decimal,
                                      parse_constant=lambda _: (_ for _ in ()).throw(ValueError()))
                except ValueError as exc:
                    raise SeedError("服务器响应无法核验；原请求保持未知") from exc
        except urllib.error.HTTPError as exc:
            code = "HTTP_ERROR"
            try:
                error = json.loads(exc.read(65536), parse_float=Decimal)
                candidate = error.get("code", "")
                if re.fullmatch(r"[A-Z_]{1,80}", candidate):
                    code = candidate
            except (ValueError, AttributeError, TypeError):
                pass
            finally:
                exc.close()
            raise HttpFailure(exc.code, code) from None
        except (urllib.error.URLError, http.client.HTTPException, TimeoutError, ConnectionError, OSError):
            raise SeedError("网络中断或响应丢失；原请求保持未知，继续时使用同一计划") from None


def checked_file(root: Path, relative: str) -> Path:
    path = root.joinpath(*PurePosixPath(relative).parts)
    if path.is_symlink() or not path.resolve().is_relative_to(root.resolve()):
        raise SeedError("来源或归档路径越界/为符号链接")
    limit = MAX_ASSET if relative.endswith(("2026年9月固定资产明细表.xlsx", "2026年9月份报表.zip")) else MAX_FILE
    if not path.is_file() or path.stat().st_size > limit or path.stat().st_size == 0:
        raise SeedError("指定来源缺失、为空或超限；不使用替代文件")
    return path


def zip_members(path: Path) -> dict[str, bytes]:
    """Inspect every entry before extracting any; reject traversal, duplicates and bombs."""
    result, seen, total = {}, set(), 0
    try:
        with zipfile.ZipFile(path) as archive:
            infos = archive.infolist()
            if len(infos) > 256:
                raise SeedError("ZIP条目超限")
            for info in infos:
                name = info.filename.replace("\\", "/")
                posix = PurePosixPath(name)
                normalized = str(posix).casefold().rstrip("/")
                if (not name or name.startswith("/") or ":" in name or ".." in posix.parts
                        or normalized in seen or info.flag_bits & 1
                        or (info.external_attr >> 16) & 0o170000 == 0o120000):
                    raise SeedError("ZIP存在越界、重名、加密或链接条目")
                seen.add(normalized)
                total += info.file_size
                limit = MAX_ASSET if posix.name == "2026年9月固定资产明细表.xlsx" else MAX_FILE
                if (info.file_size > limit or total > 128 * 1024 * 1024
                        or info.file_size > max(info.compress_size, 1) * 1000):
                    raise SeedError("ZIP大小或压缩比例超限")
            for info in infos:
                if not info.is_dir():
                    data = archive.read(info)
                    if len(data) != info.file_size:
                        raise SeedError("ZIP原件长度不一致")
                    basename = PurePosixPath(info.filename.replace("\\", "/")).name
                    if basename in REPORT_NAMES:
                        if basename in result:
                            raise SeedError("ZIP存在重复原文件名")
                        result[basename] = data
    except (zipfile.BadZipFile, RuntimeError, OSError) as exc:
        raise SeedError("ZIP无法安全读取") from exc
    return result


def precision_headers(path: Path | None) -> dict[str, str]:
    if path is None:
        return {}
    value = read_json(path)
    if not isinstance(value, dict) or set(value) - {"X-Uten-Precision-Choices"}:
        raise SeedError("仅接受本次已明确选择的X-Uten-Precision-Choices业务头，不保存凭据")
    for item in value.values():
        if not isinstance(item, str) or "\r" in item or "\n" in item:
            raise SeedError("业务头格式无效")
    return value


def create_plan(state: Path, source: Path, server: str, actor: str, source_system: str,
                currency: str, period: str, contract: Path, headers=None):
    actor, currency = str(uuid.UUID(actor)), str(uuid.UUID(currency))
    if not re.fullmatch(r"\d{4}-\d{2}", period):
        raise SeedError("期间须为YYYY-MM")
    year, month = map(int, period.split("-"))
    try:
        last = calendar.monthrange(year, month)[1]
    except ValueError as exc:
        raise SeedError("会计期间无效") from exc
    if period != "2026-09":
        raise SeedError("本次白名单为2026年9月原件，不能改成另一期间冒用")
    if not source_system or source_system != source_system.strip() or len(source_system) > 80:
        raise SeedError("须显式填写原账套标识，不能按公司名称猜配")
    if (state / "plan.json").exists() or (state / "journal.json").exists():
        raise SeedError("该目录已有计划；使用apply/verify继续，不能覆盖或换请求号")
    templates = read_json(contract)["templates"]
    archive = state / "source-archive"
    archive.mkdir(parents=True, exist_ok=True, mode=0o700)
    extracted = zip_members(checked_file(source, "september/2026年9月份报表.zip"))
    files = []
    for relative in SOURCE_PATHS:
        path = source.joinpath(*PurePosixPath(relative).parts)
        if path.exists():
            data = checked_file(source, relative).read_bytes()
            if relative.startswith(REPORT_DIR) and Path(relative).name in extracted:
                if sha(data) != sha(extracted[Path(relative).name]):
                    raise SeedError("解包文件与所给ZIP原件不一致")
        elif relative.startswith(REPORT_DIR) and Path(relative).name in extracted:
            data = extracted[Path(relative).name]
        else:
            raise SeedError("提供资料不完整，缺少白名单原件；不遍历其他私有目录")
        target = archive.joinpath(*PurePosixPath(relative).parts)
        target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        if target.exists() and sha(target.read_bytes()) != sha(data):
            raise SeedError("已有归档与原件不同，停止而不覆盖")
        if not target.exists():
            atomic_bytes(target, data)
        files.append({"path": relative, "sha256": sha(data), "bytes": len(data),
                      "purpose": "REFERENCE_ONLY_NO_LEDGER", "period": period,
                      "sourceSystem": source_system})
    by_path = {item["path"]: item for item in files}
    steps = []

    def add(kind, file=None, **kw):
        request_id = str(uuid.uuid4())
        step = {"id": f"{len(steps)+1:02d}-{kind}", "kind": kind, "requestId": request_id,
                "headers": dict(headers or {}), **kw}
        if file:
            step.update(file=file, sha256=by_path[file]["sha256"], filename=Path(file).name,
                        contentType="application/vnd.ms-excel" if file.endswith(".xls") else
                        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
            by_path[file]["purpose"] = ("REQUIREMENT_TEMPLATE_AND_SAMPLE_ONLY" if
                                         file == "ERP财务部门需求汇总.xlsx" else "ACTUAL_ORIGINAL_SOURCE_EVIDENCE")
        steps.append(step)
        return step["id"]

    chart = add("chart-preview", "2026年9月份科目余额表代码.xls", expectedRows=177)
    add("chart-directory", dependsOn=chart)
    vouchers = add("accounting-preview", "september/2026年9月份会计分录凭证.xls",
                   query={"kind": "VOUCHERS", "sourceSystem": source_system})
    balances = add("accounting-preview", REPORT_DIR + "2026年9月份科目余额表.xls",
                   query={"kind": "BALANCE", "sourceSystem": source_system})
    add("accounting-compare", dependsOn=vouchers, balanceStep=balances)
    for side, name in (("receivable", "2026年9月份应收账款明细表.xls"),
                       ("payable", "2026年9月份应付账款明细表.xls")):
        step_id = add("auxiliary-preview", REPORT_DIR + name,
                      query={"side": side, "sourceSystem": source_system, "currencyId": currency,
                             "dateFrom": period + "-01", "dateTo": period + f"-{last:02d}"})
        add("auxiliary-directory", dependsOn=step_id)
    for template in ASSETS + COSTS + STATEMENTS:
        desc = templates[template]
        actual = template in ASSETS
        file = REPORT_DIR + desc["sourceFile"] if actual else "ERP财务部门需求汇总.xlsx"
        sheet = desc.get("sourceSheet") if actual else desc["headerSource"].split("!", 1)[0]
        add("template-preview", file, query={"template": template, "period": period,
            "filename": Path(file).name, "sourceSheet": sheet},
            endpoint="assets" if actual else "costs",
            evidenceRole="ACTUAL_SOURCE" if actual else "REQUIREMENT_SAMPLE_NOT_ACTUAL_LEDGER")
    add("template-preview", REPORT_DIR + "2026年9月份销售出库成本核算表.xls",
        query={"template": "salesCostSummary", "period": period,
               "filename": "2026年9月份销售出库成本核算表.xls", "sourceSheet": "销售汇总表"},
        endpoint="costs", evidenceRole="ACTUAL_SOURCE")
    plan = {"version": VERSION, "server": server, "actor": actor, "period": period,
            "sourceSystem": source_system, "currencyId": currency, "files": files, "steps": steps,
            "contractSha256": sha(contract.read_bytes()),
            "scope": "SOURCE_AND_DIRECTORY_ONLY_REVIEW_CONTINUES_IN_ORIGINAL_WORKFLOW"}
    plan["planHash"] = sha(encode(plan))
    atomic_json(state / "plan.json", plan)
    return plan


def load_plan(state):
    plan = read_json(state / "plan.json")
    original = dict(plan)
    digest = original.pop("planHash", None)
    if plan.get("version") != VERSION or sha(encode(original)) != digest:
        raise SeedError("计划版本或SHA已变化，不能沿用旧完成标记")
    for step in plan["steps"]:
        if set(step.get("headers", {})) - {"X-Uten-Precision-Choices"}:
            raise SeedError("计划不得包含认证信息或额外传输头")
    for item in plan["files"]:
        if item["path"] not in SOURCE_PATHS:
            raise SeedError("计划来源超出所给资料白名单")
        path = checked_file(state / "source-archive", item["path"])
        if path.stat().st_size != item["bytes"] or sha(path.read_bytes()) != item["sha256"]:
            raise SeedError("归档原件被修改；保留原计划和未知请求，停止执行")
    return plan


def multipart(step, data):
    boundary = "uten-seed-" + step["requestId"]
    name = step["filename"]
    if any(x in name for x in ('"', "\r", "\n")):
        raise SeedError("原文件名不能安全传输")
    prefix = (f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="{name}"\r\n'
              f'Content-Type: {step["contentType"]}\r\n\r\n').encode("utf8")
    return prefix + data + f"\r\n--{boundary}--\r\n".encode(), "multipart/form-data; boundary=" + boundary


def immutable_receipt(step, data):
    if not isinstance(data, dict):
        raise SeedError("来源回执结构错误，保留原请求")
    try:
        identity = str(uuid.UUID(data["importId"]))
    except (KeyError, ValueError, TypeError) as exc:
        raise SeedError("来源回执缺少真实批次UUID") from exc
    if data.get("sha256") != step["sha256"]:
        raise SeedError("来源回执SHA与原文件不一致")
    query = step.get("query", {})
    fields = {}
    if step["kind"] == "accounting-preview":
        fields = {"kind": query["kind"], "sourceSystem": query["sourceSystem"]}
    elif step["kind"] == "auxiliary-preview":
        fields = {"receivable": query["side"] == "receivable", **{k: query[k] for k in
                  ("sourceSystem", "currencyId", "dateFrom", "dateTo")}}
    elif step["kind"] == "template-preview":
        fields = {k: query[k] for k in ("template", "period", "sourceSheet")}
    if any(data.get(key) != expected for key, expected in fields.items()):
        raise SeedError("来源回执的原账套、类别、期间或工作表不一致")
    if step["kind"] == "chart-preview" and len(data.get("rows", [])) != step["expectedRows"]:
        raise SeedError("原科目目录行数与明确计划不一致；不截断或凑数")
    return {"importId": identity, "sha256": data["sha256"], **fields}


def resource_path(step, receipt):
    family = step["kind"].split("-")[0]
    prefix = {"chart": "/finance/chart/imports/", "accounting": "/finance/accounting-imports/",
              "auxiliary": "/finance/auxiliary-imports/", "template": "/finance/template-imports/"}[family]
    return prefix + receipt["importId"]


class Runner:
    def __init__(self, state: Path, api: Api, plan):
        self.state, self.api, self.plan = state, api, plan
        if api.server != plan["server"]:
            raise SeedError("目标主机与计划不一致")
        me = api.request("GET", "/auth/me")
        if not isinstance(me, dict) or me.get("id") != plan["actor"]:
            raise SeedError("当前账号与计划不一致；不能冒用旧完成标记")
        if not me.get("businessDatasetId") or not isinstance(me.get("businessResetGeneration"), int):
            raise SeedError("目标没有数据集身份，不能安全绑定一次性导入")
        self.binding = {"planHash": plan["planHash"], "server": plan["server"], "actor": plan["actor"],
                        "datasetId": me["businessDatasetId"], "generation": me["businessResetGeneration"]}
        self.permissions = set(me.get("permissions") or [])
        journal_path = state / "journal.json"
        self.journal = read_json(journal_path) if journal_path.exists() else {"binding": self.binding, "steps": {}}
        if self.journal.get("binding") != self.binding:
            raise SeedError("目标、数据集、账号或计划变化；不能沿用旧日志")
        self.steps = {step["id"]: step for step in plan["steps"]}

    def save(self):
        atomic_json(self.state / "journal.json", self.journal)

    def dependency(self, step):
        entry = self.journal["steps"].get(step["dependsOn"], {})
        if entry.get("state") != "done":
            raise SeedError("前置原件尚未核实，不能继续目录写入")
        return entry["receipt"]

    def get_preview(self, step, receipt):
        result = self.api.request("GET", resource_path(step, receipt))
        if immutable_receipt(step, result) != receipt:
            raise SeedError("已完成资源与原回执不同；不重建来源")
        return result

    def verify_step(self, step, entry):
        kind = step["kind"]
        if kind.endswith("-preview"):
            data = self.get_preview(step, entry["receipt"])
            if kind == "auxiliary-preview":
                raw = self.api.request("GET", resource_path(step, entry["receipt"]) + "/file", raw=True)
                if sha(raw) != step["sha256"]:
                    raise SeedError("服务器原附件字节SHA不一致")
        elif kind.endswith("-directory"):
            receipt = self.dependency(step)
            source = self.steps[step["dependsOn"]]
            data = self.get_preview(source, receipt)
            flag = "applied" if kind == "chart-directory" else "directoryApplied"
            if data.get(flag) is not True:
                raise SeedError("目录回执尚未确认，不把旧done当成功")
        elif kind == "accounting-compare":
            source = self.dependency(step)
            balance = self.journal["steps"][step["balanceStep"]]["receipt"]
            self.api.request("GET", "/finance/accounting-imports/" + source["importId"] + "/compare",
                             query={"balanceImportId": balance["importId"]})
        else:
            raise SeedError("未支持的计划步骤")

    def preview(self, step, entry):
        kind = step["kind"]
        # With a durable ID, GET only. For a lost auxiliary response use the fixed operation receipt.
        if entry.get("receipt"):
            return self.get_preview(step, entry["receipt"])
        if kind == "auxiliary-preview" and entry.get("state") == "unknown":
            try:
                result = self.api.request("GET", "/finance/auxiliary-imports/operations/" + step["requestId"])
                if result.get("requestId") != step["requestId"]:
                    raise SeedError("原操作回执请求号不一致")
                return result["preview"]
            except HttpFailure as exc:
                if exc.status != 404:
                    raise
                # 404 is not evidence the original POST never executes. The SAME nonce/input is safe.
        data = checked_file(self.state / "source-archive", step["file"]).read_bytes()
        if sha(data) != step["sha256"]:
            raise SeedError("发送前原件SHA变化，停止而不替换原请求")
        query, headers = dict(step.get("query", {})), dict(step["headers"])
        if kind == "template-preview":
            path = f'/finance/template-imports/{step["endpoint"]}/preview'
            body = data
            headers["Content-Type"] = "application/octet-stream"
        else:
            body, content_type = multipart(step, data)
            headers["Content-Type"] = content_type
            path = {"chart-preview": "/finance/chart/import-preview",
                    "accounting-preview": "/finance/accounting-imports/preview",
                    "auxiliary-preview": "/finance/auxiliary-imports/preview"}[kind]
            if kind == "auxiliary-preview":
                query["requestId"] = step["requestId"]
        exact_request = {"path": path, "query": query, "headers": headers, "bodySha256": sha(body),
                         "fileSha256": step["sha256"], "requestId": step["requestId"]}
        request_digest = sha(encode(exact_request))
        if entry.get("requestHash") not in (None, request_digest):
            raise SeedError("未知提交的原请求输入变化，拒绝重放")
        entry.update(state="unknown", requestHash=request_digest, request=exact_request)
        self.save()  # fsync BEFORE network write; crashing here keeps the fixed original identity.
        return self.api.request("POST", path, query=query, body=body, headers=headers)

    def execute(self, step, entry):
        kind = step["kind"]
        if kind.endswith("-preview"):
            result = self.preview(step, entry)
            entry["receipt"] = immutable_receipt(step, result)
            # Store no response payload or business figures. Issues stay in the authorized original UI.
            entry["hasIssues"] = bool(result.get("issues") or
                (isinstance(result.get("source"), dict) and result["source"].get("issues")))
            entry["state"] = "done"
            self.save()
        elif kind.endswith("-directory"):
            receipt = self.dependency(step)
            source = self.steps[step["dependsOn"]]
            data = self.get_preview(source, receipt)
            flag = "applied" if kind == "chart-directory" else "directoryApplied"
            if data.get(flag) is not True:
                if data.get("issues"):
                    entry["state"] = "blocked-source-issues"
                    self.save()
                    return
                body = encode({"importId": receipt["importId"]})
                path = "/finance/chart/import-apply" if kind == "chart-directory" else "/finance/auxiliary-imports/directory-apply"
                exact_request = {"path": path, "body": {"importId": receipt["importId"]},
                                 "headers": step["headers"], "requestId": step["requestId"]}
                digest = sha(encode(exact_request))
                if entry.get("requestHash") not in (None, digest):
                    raise SeedError("原目录请求改变")
                entry.update(state="unknown", requestHash=digest, request=exact_request)
                self.save()
                self.api.request("POST", path, body=body,
                                 headers={**step["headers"], "Content-Type": "application/json"})
            entry.update(state="done", receipt=receipt)
            self.verify_step(step, entry)
            self.save()
        elif kind == "accounting-compare":
            source = self.dependency(step)
            balance = self.journal["steps"][step["balanceStep"]]["receipt"]
            result = self.api.request("GET", "/finance/accounting-imports/" + source["importId"] + "/compare",
                                      query={"balanceImportId": balance["importId"]})
            entry.update(state="done", hasIssues=bool(result.get("issues")), receipt=source)
            self.save()
        else:
            raise SeedError("未支持的计划步骤")

    def run(self, verify_only=False):
        if not verify_only and not REQUIRED_PERMISSIONS.issubset(self.permissions):
            raise SeedError("当前真实账号缺少本计划来源/目录权限；不伪造账号、scope或审核")
        if not verify_only:
            self.save()
        for step in self.plan["steps"]:
            entry = self.journal["steps"].setdefault(step["id"], {"state": "pending"})
            if entry["state"] == "done":
                self.verify_step(step, entry)
            elif verify_only:
                continue
            else:
                self.execute(step, entry)
        states = [item["state"] for item in self.journal["steps"].values()]
        return {"completed": states.count("done"), "blocked": states.count("blocked-source-issues"),
                "remaining": len(self.plan["steps"]) - states.count("done"), "writesToLedgerCashStock": 0}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    plan = sub.add_parser("plan", help="离线归档白名单原件并冻结原计划，不访问服务器")
    plan.add_argument("--state-dir", type=Path, required=True)
    plan.add_argument("--source-dir", type=Path, required=True)
    plan.add_argument("--server", required=True)
    plan.add_argument("--actor", required=True)
    plan.add_argument("--source-system", required=True)
    plan.add_argument("--currency-id", required=True)
    plan.add_argument("--period", required=True)
    plan.add_argument("--contract", type=Path, default=Path(__file__).resolve().parents[1] /
                      "server/src/main/resources/finance/template-contract-v1.json")
    plan.add_argument("--business-headers", type=Path)
    plan.add_argument("--allow-http-loopback", action="store_true")
    for name in ("apply", "verify"):
        command = sub.add_parser(name)
        command.add_argument("--state-dir", type=Path, required=True)
        command.add_argument("--server", required=True)
        command.add_argument("--actor", required=True)
        command.add_argument("--token-env", default="UTEN_FINANCE_SEED_TOKEN")
        command.add_argument("--allow-http-loopback", action="store_true")
    args = parser.parse_args(argv)
    try:
        state = args.state_dir.resolve()
        repo = Path(__file__).resolve().parents[1]
        if state.is_relative_to(repo):
            raise SeedError("持久state须放在应用/源码版本目录外的授权私有目录")
        server = server_url(args.server, args.allow_http_loopback)
        with state_lock(state):
            if args.command == "plan":
                result = create_plan(state, args.source_dir.resolve(), server, args.actor,
                                     args.source_system, args.currency_id, args.period, args.contract,
                                     precision_headers(args.business_headers))
                print("计划已冻结；原件、原工作表、落点、请求号见私有plan.json。尚未调用服务器。")
            else:
                result = load_plan(state)
                if result["server"] != server or result["actor"] != str(uuid.UUID(args.actor)):
                    raise SeedError("指定目标或账号与原计划不一致")
                token = os.environ.get(args.token_env) or getpass.getpass("当前账号访问令牌（不显示、不落盘）: ")
                summary = Runner(state, Api(server, token), result).run(args.command == "verify")
                print("已核验步骤: {completed}；待人工核对目录: {blocked}；未完成: {remaining}。".format(**summary))
                print("来源/目录阶段；未提交或批准凭证，未写总账、现金、库存或应收应付账。")
                if summary["remaining"]:
                    return 3
        return 0
    except (SeedError, ValueError, KeyError, KeyboardInterrupt):
        # Do not print traceback, payloads, filenames containing private content, tokens or business values.
        exc = sys.exc_info()[1]
        print(str(exc) if isinstance(exc, SeedError) else "已停止；保留私有计划和原请求后继续核对", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
