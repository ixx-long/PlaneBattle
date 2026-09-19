# 一键启动「飞机大作战」。由根目录的 play.bat 调用（那里刻意只写 ASCII）。
#
# 之所以拆成两个文件：cmd.exe 解析 .bat 时按当前 ANSI 代码页逐字节读取，中文会被
# 拆坏甚至把命令行断错，chcp 65001 也救不回来。PowerShell 脚本带 UTF-8 BOM 时
# 能稳定读出中文，所以中文提示全部放在这里。
#
# 额外参数会原样透传给引擎，例如：play.bat --headless --quit-after 90

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$engine = Join-Path $root 'tools\godot-4.7.2\Godot_v4.7.2-stable_win64.exe'
$project = Join-Path $root 'outputs\PlaneBattle'
# 引擎把 user:// 映射到以 config/name 命名的目录，名字里有“ · ”也要原样保留。
$userData = Join-Path $env:APPDATA 'Godot\app_userdata\飞机大作战 · Flight School'

if (-not (Test-Path -LiteralPath $engine)) {
    Write-Host '[x] 找不到 Godot 引擎：' -ForegroundColor Red
    Write-Host "    $engine"
    Write-Host '    请确认 tools\godot-4.7.2\ 下的引擎文件没有被移动或删除。'
    Read-Host '按回车退出'
    exit 1
}
if (-not (Test-Path -LiteralPath (Join-Path $project 'project.godot'))) {
    Write-Host '[x] 找不到工程文件：' -ForegroundColor Red
    Write-Host "    $(Join-Path $project 'project.godot')"
    Read-Host '按回车退出'
    exit 1
}

Write-Host '正在启动「飞机大作战」。' -ForegroundColor Cyan
Write-Host '操作：WASD / 方向键移动 · 空格持续射击 · 升级时按数字键 1-5 选能力 · R 重开'
Write-Host '关闭游戏窗口即结束本局，随后这里会显示对局记录的存放位置。'
Write-Host ''

& $engine --path $project @args

Write-Host ''
Write-Host '本次游玩的记录已经追加到：' -ForegroundColor Green
Write-Host "  $userData\runs.jsonl"
Write-Host '把该文件整个发给助手，就能按你的真实对局数据来调难度。'
