"""生成《飞机大作战》所需的全部音频素材。

只依赖 Python 标准库（math / wave / random / pathlib），因此任何人都能重新
生成同一批文件，不存在第三方素材与授权问题。生成结果写入
outputs/PlaneBattle/assets/audio/，Godot 导入后即为 AudioStreamWAV。

为什么自己合成而不是外挂素材：本项目对外宣称“零外部素材依赖”，音频如果依赖
外部文件就破了这个前提，还要处理授权。这里合成的是很朴素的方波/噪声音效与
一段 8 秒循环的芯片音乐，听感接近 8-bit——够用、可复现，但不精美。要换成
正式素材，直接用同名 .wav 覆盖即可，游戏代码不需要改。

噪声使用固定随机种子，所以每次生成的文件逐字节一致。

运行：python tools/generate_audio.py
"""

from __future__ import annotations

import math
import random
import wave
from pathlib import Path

SAMPLE_RATE = 22050
TAU_PHASE = 2.0 * math.pi
OUT_DIR = Path(__file__).resolve().parent.parent / 'outputs' / 'PlaneBattle' / 'assets' / 'audio'

#: 生成结果概览：(文件名, 说明)
MANIFEST = (
    ('shoot.wav', '射击：短促方波下滑音'),
    ('explosion.wav', '击毁：低通噪声爆音'),
    ('hurt.wav', '受伤：低频锯齿下滑'),
    ('upgrade.wav', '升级：上行四音琶音'),
    ('gameover.wav', '结算：下行四音'),
    ('boss.wav', 'Boss 登场：低频抖颤锯齿下滑'),
    ('phase.wav', 'Boss 转阶段：上行抖颤锯齿，与登场那条正好相反'),
    ('bgm.wav', '背景音乐：8 秒循环，Am–F–C–G'),
)


def _clamp16(value: float) -> int:
    """把 -1..1 的浮点样本转成 16 位整数，并做削波保护。"""
    limited = max(-1.0, min(1.0, value))
    return int(limited * 32000.0)


def write_wav(name: str, samples: list[float]) -> int:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    path = OUT_DIR / name
    frames = bytearray()
    for sample in samples:
        frames += _clamp16(sample).to_bytes(2, 'little', signed=True)
    with wave.open(str(path), 'wb') as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(SAMPLE_RATE)
        handle.writeframes(bytes(frames))
    return len(samples)


def _oscillator(kind: str, phase: float, duty: float = 0.5) -> float:
    """phase 取 0..1 的一个周期。"""
    if kind == 'square':
        return 1.0 if phase < duty else -1.0
    if kind == 'saw':
        return 2.0 * phase - 1.0
    if kind == 'triangle':
        return 4.0 * abs(phase - 0.5) - 1.0
    return math.sin(TAU_PHASE * phase)


def sweep(duration: float, start_hz: float, end_hz: float, kind: str = 'square',
          duty: float = 0.5, decay: float = 0.0) -> list[float]:
    """一段频率随时间线性滑动的音。用相位累加而不是 sin(2πft)，扫频时不会产生相位跳变。"""
    count = max(1, int(SAMPLE_RATE * duration))
    output: list[float] = []
    phase = 0.0
    for index in range(count):
        progress = index / (count - 1) if count > 1 else 0.0
        frequency = start_hz + (end_hz - start_hz) * progress
        phase = (phase + frequency / SAMPLE_RATE) % 1.0
        amplitude = math.exp(-decay * progress) if decay > 0.0 else 1.0
        output.append(_oscillator(kind, phase, duty) * amplitude)
    return output


def arpeggio(notes: list[float], note_seconds: float, kind: str = 'square',
             duty: float = 0.5, decay: float = 6.0) -> list[float]:
    output: list[float] = []
    for note in notes:
        output += sweep(note_seconds, note, note, kind=kind, duty=duty, decay=decay)
    return output


def noise_burst(duration: float, decay: float, smoothing: float,
                rng: random.Random) -> list[float]:
    """低通噪声：一阶低通把白噪声里最刺耳的部分磨掉，听感更像“爆”而不是“嘶”。"""
    count = max(1, int(SAMPLE_RATE * duration))
    output: list[float] = []
    previous = 0.0
    for index in range(count):
        progress = index / count
        white = rng.uniform(-1.0, 1.0)
        previous += (white - previous) * smoothing
        output.append(previous * math.exp(-decay * progress))
    return output


def mix_at(target: list[float], source: list[float], start: int, gain: float) -> None:
    for index, value in enumerate(source):
        position = start + index
        if 0 <= position < len(target):
            target[position] += value * gain


def tremolo(samples: list[float], rate: float, depth: float) -> list[float]:
    """给一段音加振幅抖动。低频长音加抖颤会立刻显得“来者不善”，比单纯下滑更有压迫感。"""
    output: list[float] = []
    for index, value in enumerate(samples):
        phase = TAU_PHASE * rate * index / SAMPLE_RATE
        output.append(value * (1.0 - depth + depth * (0.5 + 0.5 * math.sin(phase))))
    return output


def build_bgm() -> list[float]:
    """Am–F–C–G 四小节、120 BPM、每小节 2 秒，共 8 秒，首尾同相以便无缝循环。"""
    beat = 0.5
    bar = beat * 4
    total = int(SAMPLE_RATE * bar * 4)
    track = [0.0] * total
    # (低音根音, 和弦音)
    progression = (
        (110.00, (220.00, 261.63, 329.63)),   # Am
        (87.31, (174.61, 220.00, 261.63)),    # F
        (130.81, (261.63, 329.63, 392.00)),   # C
        (98.00, (196.00, 246.94, 293.66)),    # G
    )
    rng = random.Random(20260918)
    for bar_index, (root, chord) in enumerate(progression):
        bar_start = int(SAMPLE_RATE * bar * bar_index)
        # 低音：八分音符，方波占空比 0.5，略带包络避免每音都“咔”一下
        for step in range(8):
            note_start = bar_start + int(SAMPLE_RATE * beat * 0.5 * step)
            mix_at(track, sweep(beat * 0.46, root, root, 'square', 0.5, 4.0),
                   note_start, 0.22)
        # 主旋律：十六分音符在和弦音之间来回，制造芯片音乐的琶音感
        pattern = (0, 1, 2, 1, 2, 1, 2, 0, 1, 2, 1, 2, 0, 1, 0, 1)
        for step, tone in enumerate(pattern):
            note_start = bar_start + int(SAMPLE_RATE * beat * 0.25 * step)
            mix_at(track, sweep(beat * 0.22, chord[tone], chord[tone], 'square', 0.25, 7.0),
                   note_start, 0.13)
        # 打击：每小节第 1、3 拍各一记噪声
        for beat_index in (0, 2):
            hit_start = bar_start + int(SAMPLE_RATE * beat * beat_index)
            mix_at(track, noise_burst(0.09, 12.0, 0.55, rng), hit_start, 0.16)
    # 整体压到 0.5，给 Music 总线的 -6 dB 留出余量，也避免叠加处削波
    return [value * 0.5 for value in track]


def main() -> int:
    rng = random.Random(20260918)
    clips: dict[str, list[float]] = {
        'shoot.wav': sweep(0.07, 900.0, 420.0, 'square', 0.5, 3.0),
        'explosion.wav': noise_burst(0.28, 5.5, 0.35, rng),
        'hurt.wav': sweep(0.30, 320.0, 110.0, 'saw', decay=2.5),
        'upgrade.wav': arpeggio([523.25, 659.25, 783.99, 1046.50], 0.09, 'square', 0.5, 5.0),
        'gameover.wav': arpeggio([523.25, 392.00, 329.63, 261.63], 0.22, 'triangle', 0.5, 2.0),
        'boss.wav': tremolo(sweep(1.0, 165.0, 82.0, 'saw', decay=0.6), 6.5, 0.55),
        # 转阶段：**上行**（120 → 520 Hz）+ 更快的抖颤（11 Hz）。上行是"越来越急"的
        # 通用语汇，与 boss.wav 的下行正好构成一对：一条是"它来了"，一条是"它变招了"。
        'phase.wav': tremolo(sweep(0.9, 120.0, 520.0, 'saw', decay=0.35), 11.0, 0.6),
        'bgm.wav': build_bgm(),
    }
    assert sorted(clips) == sorted(name for name, _ in MANIFEST)

    total_bytes = 0
    for name, description in MANIFEST:
        count = write_wav(name, clips[name])
        size = (OUT_DIR / name).stat().st_size
        total_bytes += size
        print(f'{name:<14} {count / SAMPLE_RATE:5.2f}s  {size / 1024:7.1f} KB  {description}')
    print(f'合计 {total_bytes / 1024:.1f} KB，输出目录 {OUT_DIR}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
