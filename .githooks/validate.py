#!/usr/bin/env python3
"""Repository commit-message, staging hygiene, and CI validation script."""

from __future__ import annotations

import argparse
import glob
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

try:
    import yaml  # type: ignore
except ImportError:  # pragma: no cover
    yaml = None

ALLOWED_TYPES = (
    "feat",
    "fix",
    "docs",
    "style",
    "refactor",
    "perf",
    "test",
    "build",
    "ci",
    "chore",
)

SUBJECT_RE = re.compile(
    r"^(feat|fix|docs|style|refactor|perf|test|build|ci|chore)"
    r"(\([a-z0-9_/-]+\))?!?: (.+)$"
)
CJK_RE = re.compile(r"[\u4e00-\u9fff]")
SCISSORS_RE = re.compile(r"^# -+ >8 -+$")
TRAILER_RE = re.compile(r"^[A-Za-z][A-Za-z0-9-]*:\s+\S")

FORBIDDEN_PATH_PATTERNS: list[tuple[re.Pattern[str], str]] = [
    (
        re.compile(r"(?i)(^|/)[^/]*_summary\.md$"),
        "禁止提交临时总结报告文件 (*_SUMMARY.md)",
    ),
    (
        re.compile(r"(?i)(^|/)summary\.md$"),
        "禁止提交临时总结报告文件 (SUMMARY.md)",
    ),
    (
        re.compile(r"(?i)\.(jks|keystore|p12|pfx|pem|key)$"),
        "禁止提交密钥或证书文件",
    ),
    (
        re.compile(r"(?i)(^|/)key\.properties$"),
        "禁止提交 Android 签名配置文件 (key.properties)",
    ),
    (
        re.compile(r"(?i)(^|/)local\.properties$"),
        "禁止提交本地构建配置文件 (local.properties)",
    ),
    (
        re.compile(r"(?i)(^|/)google-services\.json$"),
        "禁止提交 Firebase 凭据文件 (google-services.json)",
    ),
    (
        re.compile(r"(?i)(^|/)GoogleService-Info\.plist$"),
        "禁止提交 Firebase 凭据文件 (GoogleService-Info.plist)",
    ),
    (
        re.compile(r"(?i)(^|/)[^/]*(credentials|secret)[^/]*\.json$"),
        "禁止提交凭据 JSON 文件 (*credentials*.json / *secret*.json)",
    ),
    (
        re.compile(
            r"^(build|\.dart_tool|coverage|\.pub|\.pub-cache|"
            r"android/\.gradle|android/app/debug|android/app/profile|"
            r"android/app/release|release|macos|docs)/"
        ),
        "禁止提交构建产物、缓存、已退役桌面目录 (macos/) 或内部文档 (docs/)",
    ),
    (
        re.compile(r"^\.github/workflows/build-desktop\.yml$"),
        "桌面端工作流已从本仓库退役，禁止提交 .github/workflows/build-desktop.yml",
    ),
    (
        re.compile(r"(?i)\.(apk|aab|ipa|dmg|exe|swp|swo)$"),
        "禁止提交二进制安装包、可执行文件或编辑器交换文件",
    ),
    (
        re.compile(r"(^|/)\.DS_Store$"),
        "禁止提交系统元文件 (.DS_Store)",
    ),
]

ENV_PATH_RE = re.compile(r"(?i)(^|/)\.env(\..+)?$")
ENV_ALLOW_RE = re.compile(r"(?i)(^|/)\.env\.(example|sample|template)$")

PRIVATE_KEY_RE = re.compile(
    r"-----BEGIN (?:RSA |EC |DSA |OPENSSH |PGP )?PRIVATE KEY-----"
)


def run_git(
    args: list[str],
    *,
    check: bool = True,
    text: bool = True,
) -> subprocess.CompletedProcess[str] | subprocess.CompletedProcess[bytes]:
    return subprocess.run(
        ["git", *args],
        check=check,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=text,
    )


def git_root() -> Path:
    res = run_git(["rev-parse", "--show-toplevel"])
    return Path(res.stdout.strip())


def split_nul_paths(raw: bytes) -> list[str]:
    if not raw:
        return []
    return [p.decode("utf-8", errors="replace") for p in raw.split(b"\0") if p]


def check_forbidden_paths(paths: list[str]) -> list[str]:
    errors: list[str] = []
    for path in paths:
        if ENV_PATH_RE.search(path) and not ENV_ALLOW_RE.search(path):
            errors.append(f"禁止提交本地环境变量文件: {path}")
            continue
        for pattern, reason in FORBIDDEN_PATH_PATTERNS:
            if pattern.search(path):
                errors.append(f"{reason}: {path}")
                break
    return errors


def check_private_keys_in_diff(diff_text: str) -> list[str]:
    errors: list[str] = []
    current_file = "<unknown>"
    for line in diff_text.splitlines():
        if line.startswith("+++ b/"):
            current_file = line[6:]
            continue
        if line.startswith("+") and not line.startswith("+++"):
            if PRIVATE_KEY_RE.search(line[1:]):
                errors.append(f"检测到疑似私钥内容被添加到 {current_file}")
    return errors


def strip_git_commit_comments(raw: str) -> list[str]:
    lines: list[str] = []
    for line in raw.splitlines():
        if SCISSORS_RE.match(line):
            break
        if line.startswith("#"):
            continue
        lines.append(line.rstrip())
    while lines and not lines[0].strip():
        lines.pop(0)
    while lines and not lines[-1].strip():
        lines.pop()
    return lines


def validate_commit_message(raw: str) -> list[str]:
    lines = strip_git_commit_comments(raw)
    if not lines:
        return ["提交信息不能为空。"]

    subject = lines[0].strip()
    if subject.startswith("Merge ") or subject.startswith("Revert "):
        return []

    errors: list[str] = []
    m = SUBJECT_RE.match(subject)
    if not m:
        errors.append(
            f"提交标题不符合规范: {subject!r}\n"
            f"  要求格式: <type>(<scope>): <中文简述>（scope 可选，破坏性变更在 : 前加 !）\n"
            f"  允许的 type: {', '.join(ALLOWED_TYPES)}\n"
            f"  scope 仅允许小写字母、数字、下划线、连字符和斜杠 ([a-z0-9_/-]+)\n"
            f"  示例: feat(auth): 新增 OAuth2 登录回调与令牌刷新"
        )
    else:
        desc = m.group(3)
        if not desc.strip():
            errors.append(f"提交标题缺少描述内容: {subject!r}")
        elif not CJK_RE.search(desc):
            errors.append(
                f"提交标题简述必须使用中文（至少包含一个汉字）: {subject!r}"
            )

    body_lines = [
        ln
        for ln in lines[1:]
        if ln.strip() and not TRAILER_RE.match(ln.strip())
    ]
    if body_lines and not CJK_RE.search("\n".join(body_lines)):
        errors.append("提交正文必须使用中文（至少包含一个汉字）。")

    return errors


def validate_workflow_yaml(path: str, content: str) -> list[str]:
    errors: list[str] = []
    if yaml is not None:
        try:
            parsed = yaml.safe_load(content)
        except yaml.YAMLError as exc:
            return [f"工作流 YAML 解析失败 ({path}): {exc}"]
        if not isinstance(parsed, dict):
            return [f"工作流 YAML 根节点必须为映射对象 ({path})"]
        triggers = parsed.get("on")
        if triggers is None and True in parsed:
            triggers = parsed.get(True)
        has_push = False
        if triggers == "push":
            has_push = True
        elif isinstance(triggers, list) and "push" in triggers:
            has_push = True
        elif isinstance(triggers, dict) and "push" in triggers:
            has_push = True
        if has_push and (
            "gh release create" in content
            or "softprops/action-gh-release" in content
        ):
            errors.append(
                f"工作流 {path} 不得将 push 触发与创建 GitHub Release 组合"
            )
    return errors


def is_python_hook_or_script(path: str, content: str) -> bool:
    if path.endswith(".py"):
        return True
    if path.startswith(".githooks/"):
        first_line = content.splitlines()[0] if content else ""
        return "python" in first_line
    return False


def validate_python_syntax(path: str, content: str) -> list[str]:
    try:
        compile(content, path, "exec")
    except SyntaxError as exc:
        return [f"Python 语法错误 ({path}:{exc.lineno}): {exc.msg}"]
    return []


def read_blob(rev_spec: str) -> str:
    res = run_git(["show", rev_spec], text=False)
    return res.stdout.decode("utf-8", errors="replace")


def is_generated_dart(path: str) -> bool:
    name = Path(path).name
    if name.startswith("app_localizations") and name.endswith(".dart"):
        return True
    return name.endswith(".g.dart") or name.endswith(".freezed.dart")


def find_dart_binary() -> str | None:
    which_dart = shutil.which("dart")
    if which_dart:
        return which_dart
    pattern = str(
        Path.home() / ".cache" / "flutter-sdk-*" / "flutter" / "bin" / "dart"
    )
    candidates = sorted(glob.glob(pattern), reverse=True)
    for cand in candidates:
        if os.access(cand, os.X_OK):
            return cand
    return None


def cmd_commit_msg(args: argparse.Namespace) -> int:
    msg_path = Path(args.msg_file)
    if not msg_path.is_file():
        print(f"[commit-msg] 找不到提交信息文件: {msg_path}", file=sys.stderr)
        return 1
    raw = msg_path.read_text(encoding="utf-8", errors="replace")
    errors = validate_commit_message(raw)
    if errors:
        print("[commit-msg] 提交信息校验未通过：", file=sys.stderr)
        for err in errors:
            print(f"  - {err}", file=sys.stderr)
        return 1
    return 0


def cmd_pre_commit(_: argparse.Namespace) -> int:
    root = git_root()
    os.chdir(root)

    staged_res = run_git(
        ["diff", "--cached", "--name-only", "--diff-filter=ACMR", "-z"],
        text=False,
    )
    staged_paths = split_nul_paths(staged_res.stdout)

    errors: list[str] = []
    errors.extend(check_forbidden_paths(staged_paths))

    diff_res = run_git(
        ["diff", "--cached", "-U0", "--no-color", "--", ".", ":!.githooks/validate.py"],
        text=False,
    )
    errors.extend(
        check_private_keys_in_diff(
            diff_res.stdout.decode("utf-8", errors="replace")
        )
    )

    ws_res = run_git(["diff", "--cached", "--check"], check=False, text=True)
    if ws_res.returncode != 0:
        detail = (ws_res.stdout or ws_res.stderr or "").strip()
        errors.append(f"检测到空白符错误或冲突标记 (git diff --cached --check):\n{detail}")

    for path in staged_paths:
        if path.startswith(".github/workflows/") and path.endswith((".yml", ".yaml")):
            content = read_blob(f":{path}")
            errors.extend(validate_workflow_yaml(path, content))
        elif path.endswith(".py") or path.startswith(".githooks/"):
            content = read_blob(f":{path}")
            if is_python_hook_or_script(path, content):
                errors.extend(validate_python_syntax(path, content))

    staged_dart = [
        p
        for p in staged_paths
        if p.endswith(".dart") and not is_generated_dart(p)
    ]
    if staged_dart:
        dart_bin = find_dart_binary()
        if not dart_bin:
            errors.append(
                "检测到暂存的 Dart 文件，但未找到 `dart` 可执行文件；"
                "请将 Flutter/Dart SDK 加入 PATH 后重试。"
            )
        else:
            merge_head = resolve_commit("MERGE_HEAD")

            def is_unchanged_from_merge_head(path: str) -> bool:
                """Skip dart format on files kept byte-identical to MERGE_HEAD."""
                if not merge_head:
                    return False
                idx_res = run_git(
                    ["rev-parse", "--verify", "--quiet", f":{path}"],
                    check=False,
                    text=True,
                )
                if idx_res.returncode != 0:
                    return False
                mh_res = run_git(
                    [
                        "rev-parse",
                        "--verify",
                        "--quiet",
                        f"{merge_head}:{path}",
                    ],
                    check=False,
                    text=True,
                )
                return (
                    mh_res.returncode == 0
                    and idx_res.stdout.strip() == mh_res.stdout.strip()
                )

            format_dart = [
                p for p in staged_dart if not is_unchanged_from_merge_head(p)
            ]
            unformatted: list[str] = []
            for path in format_dart:
                blob = run_git(["show", f":{path}"], text=False).stdout
                fmt = subprocess.run(
                    [
                        dart_bin,
                        "format",
                        "--output=none",
                        "--set-exit-if-changed",
                        "--stdin-name",
                        path,
                    ],
                    input=blob,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    check=False,
                )
                if fmt.returncode != 0:
                    unformatted.append(path)
            if unformatted:
                joined = " ".join(unformatted)
                errors.append(
                    "以下暂存的 Dart 文件格式不符合 `dart format` 规范，"
                    f"请先格式化并重新暂存:\n    dart format {joined}"
                )

            pkg_cfg = root / ".dart_tool" / "package_config.json"
            if not pkg_cfg.is_file():
                errors.append(
                    "缺少 .dart_tool/package_config.json，无法运行 `dart analyze`；"
                    "请先执行 `flutter pub get`。"
                )
            else:
                unstaged_res = run_git(
                    ["diff", "--name-only", "--", *staged_dart], text=True
                )
                unstaged = [
                    ln for ln in unstaged_res.stdout.splitlines() if ln.strip()
                ]
                if unstaged:
                    print(
                        "[pre-commit] 注意：以下暂存 Dart 文件存在未暂存的工作区修改，"
                        "`dart analyze` 按工作区内容检查: "
                        + ", ".join(unstaged),
                        file=sys.stderr,
                    )
                an_res = subprocess.run(
                    [dart_bin, "analyze", *staged_dart],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    text=True,
                    check=False,
                )
                if an_res.returncode != 0:
                    errors.append(
                        "`dart analyze` 检查暂存 Dart 文件失败:\n"
                        + an_res.stdout.strip()
                    )

    if errors:
        print("[pre-commit] 暂存区校验未通过：", file=sys.stderr)
        for err in errors:
            print(f"  - {err}", file=sys.stderr)
        return 1
    return 0


def resolve_commit(ref: str) -> str | None:
    res = run_git(["rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}"], check=False)
    if res.returncode != 0:
        return None
    sha = res.stdout.strip()
    return sha or None


def cmd_ci_check(args: argparse.Namespace) -> int:
    os.chdir(git_root())

    rev_args: list[str] = []
    base = (args.base or "").strip()
    if base and not re.fullmatch(r"0+", base):
        base_sha = resolve_commit(base)
        if base_sha:
            rev_args.append(f"{base_sha}..{args.head}")
        else:
            rev_args.append(args.head)
    else:
        rev_args.append(args.head)

    for ref in args.exempt_ref:
        sha = resolve_commit(ref)
        if sha:
            rev_args.append(f"^{sha}")

    rev_res = run_git(["rev-list", *rev_args], text=True)
    commits = [c.strip() for c in rev_res.stdout.splitlines() if c.strip()]
    if not commits:
        print("[ci-check] 无需校验的新增提交（所有提交均在豁免基线内）。")
        return 0

    all_errors: list[str] = []
    for sha in reversed(commits):
        commit_errors: list[str] = []
        msg = run_git(["log", "-1", "--format=%B", sha], text=True).stdout
        commit_errors.extend(validate_commit_message(msg))

        parents_line = run_git(["rev-list", "--parents", "-n", "1", sha], text=True).stdout
        parents = parents_line.strip().split()[1:]

        if len(parents) <= 1:
            files_res = run_git(
                [
                    "diff-tree",
                    "--no-commit-id",
                    "--name-only",
                    "-r",
                    "--root",
                    "--diff-filter=ACMR",
                    "-z",
                    sha,
                ],
                text=False,
            )
            changed_files = split_nul_paths(files_res.stdout)
            commit_errors.extend(check_forbidden_paths(changed_files))

            diff_res = run_git(
                [
                    "show",
                    "--format=",
                    "-U0",
                    "--no-color",
                    sha,
                    "--",
                    ".",
                    ":!.githooks/validate.py",
                ],
                text=False,
            )
            commit_errors.extend(
                check_private_keys_in_diff(
                    diff_res.stdout.decode("utf-8", errors="replace")
                )
            )

            if len(parents) == 1:
                ws_res = run_git(
                    ["diff", "--check", f"{parents[0]}..{sha}"],
                    check=False,
                    text=True,
                )
                if ws_res.returncode != 0:
                    detail = (ws_res.stdout or ws_res.stderr or "").strip()
                    commit_errors.append(f"空白符或冲突标记异常:\n{detail}")

            for path in changed_files:
                if path.startswith(".github/workflows/") and path.endswith(
                    (".yml", ".yaml")
                ):
                    commit_errors.extend(
                        validate_workflow_yaml(path, read_blob(f"{sha}:{path}"))
                    )
                elif path.endswith(".py") or path.startswith(".githooks/"):
                    content = read_blob(f"{sha}:{path}")
                    if is_python_hook_or_script(path, content):
                        commit_errors.extend(validate_python_syntax(path, content))
        else:
            p1, p2 = parents[0], parents[1]
            files_res = run_git(
                ["diff", "--name-only", "--diff-filter=ACMR", "-z", p1, sha],
                text=False,
            )
            fork_introduced: list[str] = []
            for path in split_nul_paths(files_res.stdout):
                in_p2 = run_git(
                    ["cat-file", "-e", f"{p2}:{path}"], check=False
                )
                if in_p2.returncode != 0:
                    fork_introduced.append(path)
            commit_errors.extend(check_forbidden_paths(fork_introduced))
            for path in fork_introduced:
                if path.startswith(".github/workflows/") and path.endswith(
                    (".yml", ".yaml")
                ):
                    commit_errors.extend(
                        validate_workflow_yaml(path, read_blob(f"{sha}:{path}"))
                    )
                elif path.endswith(".py") or path.startswith(".githooks/"):
                    content = read_blob(f"{sha}:{path}")
                    if is_python_hook_or_script(path, content):
                        commit_errors.extend(validate_python_syntax(path, content))

        if commit_errors:
            short_sha = sha[:8]
            subject = msg.splitlines()[0] if msg.splitlines() else ""
            all_errors.append(f"提交 {short_sha} ({subject}):")
            for err in commit_errors:
                all_errors.append(f"  - {err}")

    if all_errors:
        print("[ci-check] 校验失败：", file=sys.stderr)
        for line in all_errors:
            print(line, file=sys.stderr)
        return 1

    print(f"[ci-check] 已通过 {len(commits)} 个提交的规范与卫生校验。")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Plana-App Git 校验工具")
    sub = parser.add_subparsers(dest="command", required=True)

    p_msg = sub.add_parser("commit-msg", help="校验提交信息")
    p_msg.add_argument("msg_file", help="Git 提交信息文件路径")
    p_msg.set_defaults(func=cmd_commit_msg)

    p_pre = sub.add_parser("pre-commit", help="校验暂存区改动")
    p_pre.set_defaults(func=cmd_pre_commit)

    p_ci = sub.add_parser("ci-check", help="校验 CI 提交范围")
    p_ci.add_argument("--base", default="", help="基线提交 SHA")
    p_ci.add_argument("--head", required=True, help="目标提交 SHA")
    p_ci.add_argument(
        "--exempt-ref",
        action="append",
        default=[],
        help="豁免的基线引用或提交 SHA（可多次传入）",
    )
    p_ci.set_defaults(func=cmd_ci_check)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
