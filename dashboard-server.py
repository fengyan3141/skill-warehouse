#!/usr/bin/env python3
"""Serve the skill-library dashboard with a guarded one-click action API.

Starts on 127.0.0.1 + a random port + a random per-session token. Every GET /
regenerates the dashboard fresh (via `skillctl dashboard build --apply`) so
the page always reflects live state, then injects a small live-config script
block the dashboard's own JS looks for (window.__DASHBOARD_LIVE__). Without
that block (i.e. the static file opened directly), the dashboard falls back
to its normal "copy command to clipboard" behaviour untouched.

Usage:
    dashboard-server.py

SAFETY MODEL — read before changing:
- Allowlist: every `id` in a request must exist as a directory under
  $SKILL_LIBRARY_ROOT/skills (i.e. actually be a real, existing skill in the
  repo). This is re-checked on every request, not just at startup, and is the
  core guard against being used to run skillctl against arbitrary strings.
- Bound to 127.0.0.1 only; every POST requires the per-session token; Host
  header must be 127.0.0.1/localhost (blocks DNS-rebinding from a malicious
  page open in another tab).
- Only three actions are exposed: "activate", "deactivate", and "delete" —
  all three just shell out to `skillctl <action> <id> --apply`, already
  idempotent/safe by skillctl's own design. `skillctl delete` itself
  deactivates, moves the skill's real folder to the system Trash (reversible,
  not `rm -rf`), rebuilds catalog.tsv, and removes the id's row from
  config/aliases.tsv — this used to be reimplemented here in Python (missing
  the aliases.tsv cleanup, which then lingered forever); now there's one
  implementation both this server and the static-mode copy-paste command
  share.
- /github-import (preview/confirm) shells out to `skillctl import-github`,
  which is the one place a raw external URL reaches this server. This code
  does NOT re-implement that command's URL/path validation — it stays the
  single source of truth in skillctl (bash), reached here only through
  subprocess.run(list) (never shell=True, never string-interpolated), so a
  hostile url/path/ref value can at worst be an argv token skillctl itself
  rejects, never something the shell reinterprets. The one check duplicated
  here (url must start with https://github.com/) is a cheap fail-fast, not
  the real gate.
- /upload-import (preview/confirm) accepts a dragged-in folder (JSON list of
  {path, content_b64}) or a dragged-in .zip (one base64 blob), writes it into
  a fresh temp staging dir, then hands that staging dir to `skillctl import`
  — same reuse principle as /github-import. Every relative path (folder
  entries, zip entries) is checked with safe_join() before anything is
  written, rejecting `..`, absolute paths, and any resolved path that lands
  outside the staging dir (the zip case is the classic "zip slip" attack —
  extraction is done entry-by-entry with this check, never a bare
  ZipFile.extractall()). Total size and file count are capped (see
  MAX_UPLOAD_BYTES/MAX_UPLOAD_FILES) as a sanity net against dropping the
  wrong folder, not a security boundary by itself.
- /check-updates just shells out to `skillctl check-updates` (no id — checks
  everything with a tracked source) and reparses its tab-separated stdout
  into {id, message} pairs for the dashboard to annotate rows with. No new
  write surface: check-updates itself never mutates anything, it only reads
  and, for stale-but-untouched skills, clones upstream to compare.
- /backup shells out to `skillctl backup sync --apply` (no arguments reach it
  from the request beyond the fixed literal "sync" action check — no id, no
  url, no path, nothing string-interpolated into the subprocess argv). A
  non-zero exit (e.g. a same-skill-directory merge conflict between local and
  remote) is reported back as ok:false with skillctl's own printed guidance;
  this endpoint never attempts to resolve a conflict itself, only surfaces
  it. `skillctl backup init` (creating the private GitHub repo in the first
  place) is deliberately NOT exposed here — it requires an authenticated
  `gh` and is a one-time setup step, left to the terminal.
- /add-custom-tool shells out to `skillctl tools add <name> <path> --apply`,
  which appends one row to config/adapters/tools.tsv. Validation (id-slug
  legality, id collisions, path must start with ~ or /) lives entirely in
  that command, not duplicated here. New rows are written with a literal
  "unverified" verification field, which skillctl tools connect already
  gates behind --allow-unverified — a user-registered platform is never
  auto-trusted for actual symlink writes just because it was registered.
"""
import base64
import io
import json
import os
import secrets
import shutil
import subprocess
import sys
import tempfile
import webbrowser
import zipfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SKILL_LIBRARY_ROOT = os.environ.get("SKILL_LIBRARY_ROOT") or os.path.expanduser("~/.skill-library")
SKILLCTL = os.path.join(SKILL_LIBRARY_ROOT, "bin", "skillctl")
DASHBOARD_HTML = os.path.join(SKILL_LIBRARY_ROOT, "dashboard", "index.html")
SKILLS_DIR = os.path.join(SKILL_LIBRARY_ROOT, "skills")
# 拖拽上传的这两个上限不是安全边界（本来就只挂在 127.0.0.1、要 token），
# 只是防误操作——skill 包本来就应该是几十 KB 到几 MB 的文本/小脚本，超过
# 这个量级基本可以确定是拖错了目录（比如整个项目、整个 Downloads）。
MAX_UPLOAD_BYTES = 25 * 1024 * 1024
MAX_UPLOAD_FILES = 500
TOKEN = secrets.token_urlsafe(24)
ACTIONS = ("activate", "deactivate", "delete")


def valid_skill_id(sid):
    # 跟 skillctl 自己的 valid_skill_name 对齐：只认字母数字和连字符，防止
    # 路径穿越（../、绝对路径、内嵌斜杠等）混进 id 里。
    if not sid or not isinstance(sid, str):
        return False
    if sid in (".", ".."):
        return False
    return all(c.isalnum() or c == "-" for c in sid)


def skill_exists(sid):
    if not valid_skill_id(sid):
        return False
    path = os.path.realpath(os.path.join(SKILLS_DIR, sid))
    if not (path == SKILLS_DIR.rstrip("/") or path.startswith(SKILLS_DIR.rstrip("/") + os.sep)):
        return False  # realpath 逃出了仓库范围（比如软链跳出去了），拒绝
    return os.path.isdir(path)


def run_skillctl(*args, timeout=30):
    r = subprocess.run([SKILLCTL, *args], capture_output=True, text=True, timeout=timeout)
    return r.returncode, r.stdout, r.stderr


def safe_join(base, relative):
    # 拼路径并确认结果没跳出 base——relative 是前端/zip 条目传来的字符串，
    # 不可信。跟 skillctl 自己 bash 版本的 path_is_ancestor 是同一个检查
    # 思路，这里是 Python 版本。
    base_real = os.path.realpath(base)
    target = os.path.realpath(os.path.join(base, relative))
    if target != base_real and not target.startswith(base_real + os.sep):
        raise ValueError("路径越界：%r" % (relative,))
    return target


def _reject_bad_relative_path(rel):
    if not isinstance(rel, str) or not rel:
        raise ValueError("非法路径：%r" % (rel,))
    if rel.startswith("/") or rel.startswith("\\"):
        raise ValueError("非法路径（不能是绝对路径）：%r" % (rel,))
    parts = rel.replace("\\", "/").split("/")
    if ".." in parts or "" in parts[1:]:
        raise ValueError("非法路径：%r" % (rel,))


def stage_folder_upload(staging_dir, files):
    if not isinstance(files, list) or not files:
        raise ValueError("没有收到文件")
    if len(files) > MAX_UPLOAD_FILES:
        raise ValueError("文件数量过多（%d 个，上限 %d），像是拖错了目录" % (len(files), MAX_UPLOAD_FILES))
    total = 0
    for f in files:
        if not isinstance(f, dict):
            raise ValueError("文件条目格式错误")
        rel = f.get("path")
        _reject_bad_relative_path(rel)
        try:
            data = base64.b64decode(f.get("content_b64") or "", validate=True)
        except Exception:
            raise ValueError("文件内容不是合法 base64：%r" % (rel,))
        total += len(data)
        if total > MAX_UPLOAD_BYTES:
            raise ValueError("上传内容超过 %dMB 上限，像是拖错了目录" % (MAX_UPLOAD_BYTES // (1024 * 1024),))
        dest = safe_join(staging_dir, rel)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        with open(dest, "wb") as fh:
            fh.write(data)


def stage_zip_upload(staging_dir, zip_b64):
    if not isinstance(zip_b64, str) or not zip_b64:
        raise ValueError("没有收到 zip 内容")
    try:
        raw = base64.b64decode(zip_b64, validate=True)
    except Exception:
        raise ValueError("zip 内容不是合法 base64")
    if len(raw) > MAX_UPLOAD_BYTES:
        raise ValueError("zip 超过 %dMB 上限" % (MAX_UPLOAD_BYTES // (1024 * 1024),))
    try:
        zf = zipfile.ZipFile(io.BytesIO(raw))
    except Exception:
        raise ValueError("不是合法的 zip 文件")
    infos = [i for i in zf.infolist() if not i.is_dir()]
    if len(infos) > MAX_UPLOAD_FILES:
        raise ValueError("zip 内文件数量过多（%d 个，上限 %d）" % (len(infos), MAX_UPLOAD_FILES))
    total = 0
    # 逐条目手动解压、每条目先过 safe_join 校验，不用 ZipFile.extractall()——
    # 那个函数对名字里带 ../ 的恶意条目（"zip slip"）没有防护，会真的写到
    # 解压目录外面去。
    for info in infos:
        _reject_bad_relative_path(info.filename)
        total += info.file_size
        if total > MAX_UPLOAD_BYTES:
            raise ValueError("解压后内容超过 %dMB 上限" % (MAX_UPLOAD_BYTES // (1024 * 1024),))
        dest = safe_join(staging_dir, info.filename)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        with zf.open(info) as src, open(dest, "wb") as out:
            shutil.copyfileobj(src, out)


def find_skill_root(staging_dir):
    # 前端拖文件夹进来时，webkitGetAsEntry 通常会带着文件夹名这一层
    # （比如 my-skill/SKILL.md 而不是直接 SKILL.md），zip 打包时也常见
    # 同样的结构——SKILL.md 不在根目录就再往下找一层，找不到才算失败。
    if os.path.isfile(os.path.join(staging_dir, "SKILL.md")):
        return staging_dir
    try:
        entries = [e for e in os.listdir(staging_dir) if not e.startswith(".")]
    except OSError:
        return None
    dirs = [e for e in entries if os.path.isdir(os.path.join(staging_dir, e))]
    if len(dirs) == 1 and os.path.isfile(os.path.join(staging_dir, dirs[0], "SKILL.md")):
        return os.path.join(staging_dir, dirs[0])
    return None


def build_dashboard():
    r = subprocess.run([SKILLCTL, "dashboard", "build", "--apply"], capture_output=True, text=True, timeout=30)
    if r.returncode != 0:
        raise RuntimeError((r.stderr or r.stdout or "dashboard build 失败").strip())


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, body, ctype="application/json"):
        b = body.encode("utf-8") if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(b)))
        # 页面上明明白白写着"每次刷新页面自动重新生成"——但之前没告诉浏览器
        # 不许缓存，一次普通刷新（非强制刷新）完全可能直接吃浏览器磁盘缓存，
        # 连请求都不发到这个进程，那句承诺就是空的：修了 build-dashboard.sh
        # 里的逻辑、用户刷新页面却还在看几分钟前的旧版本，会被当成"修了没
        # 生效"。加上禁止缓存，保证每次真的会打到这个进程重新生成。
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate")
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        if self.path not in ("/", "/index.html"):
            self._send(404, "not found", "text/plain")
            return
        try:
            build_dashboard()
            html = open(DASHBOARD_HTML, encoding="utf-8").read()
        except Exception as e:
            self._send(500, ("生成面板失败：%s" % e), "text/plain; charset=utf-8")
            return
        cfg = json.dumps({"token": TOKEN, "endpoint": "/action"}, ensure_ascii=False)
        inject = "<script>window.__DASHBOARD_LIVE__ = %s;</script>\n<script>" % cfg
        html = html.replace("<script>", inject, 1)
        self._send(200, html, "text/html; charset=utf-8")

    def do_POST(self):
        if self.path == "/action":
            self._handle_action()
        elif self.path == "/github-import":
            self._handle_github_import()
        elif self.path == "/upload-import":
            self._handle_upload_import()
        elif self.path == "/check-updates":
            self._handle_check_updates()
        elif self.path == "/add-custom-tool":
            self._handle_add_custom_tool()
        elif self.path == "/backup":
            self._handle_backup()
        else:
            self._send(404, json.dumps({"ok": False, "error": "not found"}))

    def _read_json_body(self):
        n = int(self.headers.get("Content-Length", 0))
        return json.loads(self.rfile.read(n) or b"{}")

    def _check_host_and_token(self, req):
        host = (self.headers.get("Host") or "").split(":")[0]
        if host not in ("127.0.0.1", "localhost"):
            self._send(403, json.dumps({"ok": False, "error": "host 不被允许"}))
            return False
        if req.get("token") != TOKEN:
            self._send(403, json.dumps({"ok": False, "error": "token 校验失败"}))
            return False
        return True

    def _handle_action(self):
        try:
            req = self._read_json_body()
        except Exception:
            self._send(400, json.dumps({"ok": False, "error": "请求格式错误"}))
            return
        if not self._check_host_and_token(req):
            return
        action = req.get("action")
        sid = req.get("id")
        if action not in ACTIONS:
            self._send(400, json.dumps({"ok": False, "error": "未知操作：%s" % action}))
            return
        if not skill_exists(sid):
            self._send(403, json.dumps({"ok": False, "error": "id 不在仓库白名单：%s" % sid}))
            return
        try:
            # 三个 action 现在都是单条 skillctl 命令，好处不只是省代码：删除
            # 以前在这里单独实现（Trash 移动 + catalog 重建），漏了清理
            # config/aliases.tsv 里那一行——skillctl delete 把这四步收进一
            # 个命令后，这里跟静态模式复制的命令（build-dashboard.sh 里的
            # commandForSelectedId）就是同一处实现，不会再各漏一遍。
            rc, out, err = run_skillctl(action, sid, "--apply")
            if rc != 0:
                self._send(500, json.dumps({"ok": False, "error": (err or out).strip()}))
                return
        except Exception as e:
            self._send(500, json.dumps({"ok": False, "error": str(e)}))
            return
        self._send(200, json.dumps({"ok": True}))

    def _handle_github_import(self):
        try:
            req = self._read_json_body()
        except Exception:
            self._send(400, json.dumps({"ok": False, "error": "请求格式错误"}))
            return
        if not self._check_host_and_token(req):
            return

        step = req.get("step")
        if step not in ("preview", "confirm"):
            self._send(400, json.dumps({"ok": False, "error": "未知 step：%s" % step}))
            return

        url = req.get("url")
        # 真正的校验在 skillctl import-github 自己的正则里（唯一真源），这
        # 里只是个快速失败——不重复实现那套规则，只挡明显不对的输入。
        if not isinstance(url, str) or not url.startswith("https://github.com/"):
            self._send(400, json.dumps({"ok": False, "error": "url 必须是 https://github.com/ 开头"}))
            return
        path = req.get("path") or ""
        ref = req.get("ref") or ""
        if not isinstance(path, str) or not isinstance(ref, str):
            self._send(400, json.dumps({"ok": False, "error": "path/ref 必须是字符串"}))
            return

        args = ["import-github", url]
        if path:
            args += ["--path", path]
        if ref:
            args += ["--ref", ref]
        if step == "confirm":
            if req.get("replace"):
                args += ["--replace"]
            if req.get("activate"):
                args += ["--activate"]
            args += ["--apply"]

        try:
            rc, out, err = run_skillctl(*args, timeout=90)
        except subprocess.TimeoutExpired:
            self._send(504, json.dumps({"ok": False, "error": "执行超时（网络慢或仓库较大），可以重试"}))
            return
        except Exception as e:
            self._send(500, json.dumps({"ok": False, "error": str(e)}))
            return

        output = (out or "") + (("\n" + err) if err else "")
        self._send(200, json.dumps({"ok": rc == 0, "output": output.strip()}, ensure_ascii=False))

    def _handle_upload_import(self):
        # base64 + JSON 包装大概有 1.35 倍膨胀，这里按粗略上限提前拒绝，
        # 不把整个超大请求体读进内存再说——精确的 MAX_UPLOAD_BYTES 检查
        # 在 stage_folder_upload/stage_zip_upload 里对解码后的真实内容再
        # 查一遍。
        content_length = int(self.headers.get("Content-Length", 0))
        if content_length > MAX_UPLOAD_BYTES * 2:
            self._send(413, json.dumps({"ok": False, "error": "请求体过大，像是拖错了目录"}))
            return
        try:
            req = self._read_json_body()
        except Exception:
            self._send(400, json.dumps({"ok": False, "error": "请求格式错误"}))
            return
        if not self._check_host_and_token(req):
            return

        step = req.get("step")
        if step not in ("preview", "confirm"):
            self._send(400, json.dumps({"ok": False, "error": "未知 step：%s" % step}))
            return
        kind = req.get("kind")
        if kind not in ("folder", "zip"):
            self._send(400, json.dumps({"ok": False, "error": "未知 kind：%s" % kind}))
            return

        staging_dir = tempfile.mkdtemp(prefix="skillctl-upload-")
        try:
            try:
                if kind == "folder":
                    stage_folder_upload(staging_dir, req.get("files"))
                else:
                    stage_zip_upload(staging_dir, req.get("zip_b64"))
            except ValueError as e:
                self._send(400, json.dumps({"ok": False, "error": str(e)}, ensure_ascii=False))
                return
            except Exception as e:
                self._send(400, json.dumps({"ok": False, "error": "解析上传内容失败：%s" % e}, ensure_ascii=False))
                return

            skill_root = find_skill_root(staging_dir)
            if not skill_root:
                self._send(400, json.dumps({"ok": False, "error": "没找到 SKILL.md（根目录下，或唯一一层子目录下都没有）"}, ensure_ascii=False))
                return

            args = ["import", skill_root]
            if step == "confirm":
                if req.get("replace"):
                    args += ["--replace"]
                if req.get("activate"):
                    args += ["--activate"]
                args += ["--apply"]

            try:
                rc, out, err = run_skillctl(*args, timeout=30)
            except Exception as e:
                self._send(500, json.dumps({"ok": False, "error": str(e)}))
                return

            output = (out or "") + (("\n" + err) if err else "")
            self._send(200, json.dumps({"ok": rc == 0, "output": output.strip()}, ensure_ascii=False))
        finally:
            shutil.rmtree(staging_dir, ignore_errors=True)

    def _handle_check_updates(self):
        try:
            req = self._read_json_body()
        except Exception:
            self._send(400, json.dumps({"ok": False, "error": "请求格式错误"}))
            return
        if not self._check_host_and_token(req):
            return
        # 每个登记过来源的 skill 都要 clone 一次比对，数量一多会比较慢——
        # 给足超时，前端那边按钮会一直显示"检查中"到这个请求真的返回。
        try:
            rc, out, err = run_skillctl("check-updates", timeout=180)
        except subprocess.TimeoutExpired:
            self._send(504, json.dumps({"ok": False, "error": "检查超时（登记的 skill 比较多，或网络慢），可以重试"}))
            return
        except Exception as e:
            self._send(500, json.dumps({"ok": False, "error": str(e)}))
            return
        if rc != 0:
            self._send(500, json.dumps({"ok": False, "error": (err or out or "check-updates 执行失败").strip()}, ensure_ascii=False))
            return
        results = []
        for line in (out or "").splitlines():
            parts = line.split("\t", 1)
            if len(parts) == 2 and parts[0]:
                results.append({"id": parts[0], "message": parts[1]})
        self._send(200, json.dumps({"ok": True, "results": results}, ensure_ascii=False))

    def _handle_add_custom_tool(self):
        try:
            req = self._read_json_body()
        except Exception:
            self._send(400, json.dumps({"ok": False, "error": "请求格式错误"}))
            return
        if not self._check_host_and_token(req):
            return
        name = req.get("name")
        path = req.get("path")
        # 名字/路径真正的校验（slug 合法性、路径必须 ~ 或绝对路径开头、
        # id 不能跟已有平台冲突）全在 skillctl tools add 自己那层做，这里
        # 只挡类型不对的输入，不重复实现一遍规则。
        if not isinstance(name, str) or not name.strip():
            self._send(400, json.dumps({"ok": False, "error": "平台名称不能为空"}))
            return
        if not isinstance(path, str) or not path.strip():
            self._send(400, json.dumps({"ok": False, "error": "技能目录路径不能为空"}))
            return
        try:
            rc, out, err = run_skillctl("tools", "add", name, path, "--apply", timeout=30)
        except Exception as e:
            self._send(500, json.dumps({"ok": False, "error": str(e)}))
            return
        output = (out or "") + (("\n" + err) if err else "")
        self._send(200, json.dumps({"ok": rc == 0, "output": output.strip()}, ensure_ascii=False))

    def _handle_backup(self):
        try:
            req = self._read_json_body()
        except Exception:
            self._send(400, json.dumps({"ok": False, "error": "请求格式错误"}))
            return
        if not self._check_host_and_token(req):
            return
        if req.get("action") != "sync":
            self._send(400, json.dumps({"ok": False, "error": "未知操作：%s" % req.get("action")}))
            return
        # 跟 check-updates 一样给足超时——git fetch/push 走网络，比本地文件
        # 操作慢；rc != 0 最常见的原因是同一个 skill 目录本地和远端都改过，
        # skillctl backup sync 自己已经把按目录分组的冲突说明和处理命令都
        # 打印好了，这里原样透传给前端，不重新解释一遍。
        # 每次请求都往 stdout 打一行结果——log_message 整个类都被静音了
        # （见类顶注释），之前排查一次"点了同步、卡片却没变"的报告时发现
        # 完全没有留痕可查，只能靠猜；这行不受那个静音影响（直接 print，
        # 不走 log_message），跑 dashboard serve 的那个终端窗口就能看见。
        try:
            rc, out, err = run_skillctl("backup", "sync", "--apply", timeout=90)
        except subprocess.TimeoutExpired:
            print("[backup] 同步超时")
            self._send(504, json.dumps({"ok": False, "error": "同步超时（可能是网络慢），可以重试"}))
            return
        except Exception as e:
            print("[backup] 同步异常：%s" % e)
            self._send(500, json.dumps({"ok": False, "error": str(e)}))
            return
        if rc != 0:
            msg = (out or err or "同步失败").strip()
            print("[backup] 同步失败（rc=%d）：%s" % (rc, msg.splitlines()[0] if msg else ""))
            self._send(200, json.dumps({"ok": False, "error": msg}, ensure_ascii=False))
            return
        print("[backup] 同步成功")
        self._send(200, json.dumps({"ok": True}))


def main():
    srv = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    port = srv.server_address[1]
    url = "http://127.0.0.1:%d/" % port
    print("Skill 中央仓库服务已启动：" + url)
    print("每次刷新页面都会重新生成，删除/激活/停用按钮点击即生效")
    print("用完按 Ctrl+C 停止服务（服务关掉后按钮即失效，双击桌面图标仍能看静态快照）")
    webbrowser.open(url)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\n已停止服务。")


if __name__ == "__main__":
    main()
