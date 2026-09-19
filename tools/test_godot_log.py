"""godot_log 判读逻辑的回归测试。

`godot_log` 现在是整条验证流水线的闸门：`validate_project.py` 用它决定构建是否
失败，`build_deliverables.py` 用它决定能否出交付物、以及在文档里写多少项断言。
闸门一旦被无声放宽，所有错误都会跟着放行，所以这里把“该放行的放行、该拦下的
拦下”都钉死。

运行：python tools/test_godot_log.py
"""

from __future__ import annotations

import sys

from godot_log import annotate_benign, classify, smoke_totals

BENIGN_BLOCK = (
    "Godot Engine v4.7.2.stable.official\n"
    "ERROR: Failed to read the root certificate store.\n"
    "   at: get_system_ca_certificates (platform/windows/os_windows.cpp:2582)\n"
    "PASS: initial READY state\n"
)

#: (用例名, 日志, 期望放行条数, 期望错误条数)
CLASSIFY_CASES: tuple[tuple[str, str, int, int], ...] = (
    ("已登记的环境诊断被放行且不计为错误", BENIGN_BLOCK, 1, 0),
    ("同一诊断连续出现两次都被识别", BENIGN_BLOCK + BENIGN_BLOCK, 2, 0),
    ("未知的资源加载错误必须拦下", "ERROR: Cannot open file res://scenes/Missing.tscn\n", 0, 1),
    (
        "push_error 形式的断言失败必须拦下",
        "USER ERROR: FAIL: duplicate hit does not duplicate score\n"
        "   at: check (res://tests/SmokeTest.gd:17)\n",
        0,
        1,
    ),
    (
        "消息吻合但引擎位置不符必须拦下",
        "ERROR: Failed to read the root certificate store.\n"
        "   at: something (platform/linux/os_linux.cpp:99)\n",
        0,
        1,
    ),
    (
        "脚本运行错误必须拦下",
        "SCRIPT ERROR: Invalid call. Nonexistent function 'foo' in base 'Node'.\n",
        0,
        1,
    ),
)

#: 注释替换的期望结果：只动环境诊断那一段，其余逐字保留。
ANNOTATED_EXPECTED = (
    "Godot Engine v4.7.2.stable.official\n"
    "<ENV NOTE>\n"
    "PASS: initial READY state"
)

#: (用例名, 日志) —— 这些都必须让 smoke_totals 抛错。
TOTALS_REJECT_CASES: tuple[tuple[str, str], ...] = (
    ("存在失败项时必须报错", "RESULT: 60/61 checks passed; failures=1\n"),
    ("通过数少于总数时必须报错", "RESULT: 60/61 checks passed; failures=0\n"),
    ("缺少汇总行时必须报错", "PASS: a\nPASS: b\n"),
)


def check(condition: bool, message: str) -> int:
    """返回 0 或 1，便于调用方累加失败数。"""
    print(("PASS: " if condition else "FAIL: ") + message)
    return 0 if condition else 1


def run_classify_cases() -> int:
    failures = 0
    for name, log, want_benign, want_errors in CLASSIFY_CASES:
        errors, benign = classify(log)
        failures += check(
            len(benign) == want_benign and len(errors) == want_errors,
            f"{name}（放行={len(benign)} 错误={len(errors)}，"
            f"期望 放行={want_benign} 错误={want_errors}）",
        )
    return failures


def run_annotate_case() -> int:
    annotated = annotate_benign(BENIGN_BLOCK, "<ENV NOTE>")
    return check(
        annotated == ANNOTATED_EXPECTED,
        f"注释替换后其余日志逐字保留（实际 {annotated!r}）",
    )


def run_totals_cases() -> int:
    """smoke_totals 是交付文档里数字的唯一来源，读错就会让文档说谎。"""
    failures = 0
    try:
        passed, total, failed = smoke_totals("PASS: a\nRESULT: 61/61 checks passed; failures=0\n")
    except AssertionError as error:
        failures += check(False, f"正常汇总行应被接受，却抛错：{error}")
    else:
        failures += check(
            (passed, total, failed) == (61, 61, 0),
            f"正常汇总行解析为 61/61, failures=0（实际 {(passed, total, failed)}）",
        )

    for name, log in TOTALS_REJECT_CASES:
        try:
            smoke_totals(log)
        except AssertionError:
            failures += check(True, name)
        else:
            failures += check(False, name)
    return failures


def main() -> int:
    failures = 0
    failures += run_classify_cases()
    failures += run_annotate_case()
    failures += run_totals_cases()

    total = len(CLASSIFY_CASES) + 1 + 1 + len(TOTALS_REJECT_CASES)
    print(f"RESULT: {total - failures}/{total} checks passed; failures={failures}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
