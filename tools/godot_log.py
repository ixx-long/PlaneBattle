"""Godot 运行日志判读。

`validate_project.py` 负责产出日志，`build_deliverables.py` 负责校验日志并
生成交付物。两处原先各自复制了一份 `'ERROR:' not in log` 的宽泛子串判断，
它有两个毛病：会把环境级诊断误判成项目缺陷（无法通过），也说不清究竟哪一
行有问题（无法排错）。

本模块把判读集中到一处，遵循两条原则：

1. **不放宽真实错误的检出。** 只有同时命中 `BENIGN_DIAGNOSTICS` 中的消息片段
   与引擎源码位置片段的诊断才被放行；其余一律算错误。仅凭关键词就放过是不
   允许的。
2. **不静默吞掉诊断。** 被放行的诊断原样返回，由调用方打印成 NOTE 或写进交付
   文档，保证日志始终可追溯。
"""

from __future__ import annotations

import re

#: 引擎按“错误级别”输出的日志标记。`push_error()` 记作 `USER ERROR:`，
#: 同样命中 `ERROR:`；`FAIL:` 覆盖 SmokeTest 断言失败时打印的原始消息。
ERROR_MARKERS = ("ERROR:", "SCRIPT ERROR:", "Parse Error:", "FAIL:")

#: 已知的环境级诊断，元素为 (消息片段, 引擎源码位置片段)，必须成对匹配。
#:
#: `Failed to read the root certificate store.` 来自
#: `platform/windows/os_windows.cpp` 的 `get_system_ca_certificates()`：引擎在
#: 完整初始化（而非 `--version`）时读取 Windows 根证书库，受限进程下会失败。
#: 本项目是纯离线原型，不发起 TLS 连接，因此该诊断不影响任何验收项。
BENIGN_DIAGNOSTICS: tuple[tuple[str, str], ...] = (
    ("Failed to read the root certificate store.", "os_windows.cpp"),
)

#: 诊断块中紧随首行的 `at: ...` 续行。
_AT_LINE = re.compile(r"^\s*at: ")

#: SmokeTest 结尾的汇总行，例如 `RESULT: 48/48 checks passed; failures=0`。
_SMOKE_RESULT = re.compile(r"RESULT: (\d+)/(\d+) checks passed; failures=(\d+)")


def smoke_totals(log: str) -> tuple[int, int, int]:
    """解析 SmokeTest 汇总行，返回 (通过项, 总项, 失败项)。

    断言项数量会随测试增加而变化。交付文档若把它写死，改测试就会让文档说谎，
    因此统一从这里读取实际结果。
    """
    match = _SMOKE_RESULT.search(log)
    if match is None:
        raise AssertionError("SmokeTest 日志中找不到 RESULT 汇总行")
    passed, total, failures = (int(value) for value in match.groups())
    if failures != 0 or passed != total:
        raise AssertionError(f"SmokeTest 未全部通过：{passed}/{total}，failures={failures}")
    return passed, total, failures


def classify(log: str) -> tuple[list[str], list[str]]:
    """把日志分成 (真实错误, 已放行的环境诊断)。

    与错误同属一条诊断的 `at:` 续行会并入同一条目，不单独判定；返回的是合并
    后的完整文本，调用方可直接定位。
    """
    lines = log.splitlines()
    errors: list[str] = []
    benign: list[str] = []
    index = 0
    while index < len(lines):
        if _is_marked(lines[index]):
            block = _take_block(lines, index)
            target = benign if _is_benign(block) else errors
            target.append(_flatten(block))
            index += len(block)
            continue
        index += 1
    return errors, benign


def require_clean(log: str, label: str) -> list[str]:
    """日志中不存在真实错误时返回已放行的诊断，否则抛出 AssertionError。"""
    errors, benign = classify(log)
    if errors:
        detail = "\n".join(f"  {line}" for line in errors)
        raise AssertionError(f"{label} 日志中存在 {len(errors)} 条错误：\n{detail}")
    return benign


def annotate_benign(log: str, note: str) -> str:
    """把已放行的环境诊断替换为一行 `note`，其余日志逐字保留。

    供交付文档引用：读者既不会把环境噪音当成缺陷，也不会以为日志被悄悄裁剪。
    """
    lines = log.splitlines()
    output: list[str] = []
    index = 0
    while index < len(lines):
        if _is_marked(lines[index]):
            block = _take_block(lines, index)
            if _is_benign(block):
                output.append(note)
                index += len(block)
                continue
        output.append(lines[index])
        index += 1
    return "\n".join(output)


def _is_marked(line: str) -> bool:
    return any(marker in line for marker in ERROR_MARKERS)


def _take_block(lines: list[str], start: int) -> list[str]:
    block = [lines[start]]
    index = start + 1
    while index < len(lines) and _AT_LINE.match(lines[index]):
        block.append(lines[index])
        index += 1
    return block


def _is_benign(block: list[str]) -> bool:
    head = block[0]
    location = block[1] if len(block) > 1 else ""
    return any(
        message in head and source in location
        for message, source in BENIGN_DIAGNOSTICS
    )


def _flatten(block: list[str]) -> str:
    return " / ".join(part.strip() for part in block)
