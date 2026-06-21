#!/usr/bin/env python3
"""ベンチ用の現実的コーパスを生成する（圧縮可能なテキスト/コード様データ）。

ファイルサイズ分布を実物に寄せる: 小ファイル多数 + 中 + 大ファイル数本。
内容は辞書語をシャッフルした擬似テキスト（圧縮率 ~30% 相当）。決定論的（seed 固定）。
"""
import os, sys, random

OUT = sys.argv[1] if len(sys.argv) > 1 else "corpus"
random.seed(42)

# 辞書語を語彙として読む
words = []
for p in ("/usr/share/dict/words",):
    if os.path.exists(p):
        with open(p, encoding="utf-8", errors="ignore") as f:
            words = [w.strip() for w in f if w.strip()]
        break
if not words:
    words = ["lorem", "ipsum", "dolor", "sit", "amet", "consectetur"] * 1000

def make_text(nbytes: int) -> bytes:
    """擬似テキストを nbytes 程度生成（行＝語の連なり）。"""
    out = []
    total = 0
    while total < nbytes:
        n = random.randint(6, 16)
        line = " ".join(random.choice(words) for _ in range(n)) + "\n"
        out.append(line)
        total += len(line)
    return "".join(out).encode("utf-8")[:nbytes]

def write_file(path: str, nbytes: int):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(make_text(nbytes))

# 分布: (本数, サイズ下限, サイズ上限, サブディレクトリ)
plan = [
    (2000,   5 * 1024,   50 * 1024, "src"),     # 小: ~50MB
    (50,  1 * 1024 * 1024, 2 * 1024 * 1024, "docs"),  # 中: ~75MB
    (10, 25 * 1024 * 1024, 35 * 1024 * 1024, "data"), # 大: ~300MB
]

total_bytes = 0
total_files = 0
for count, lo, hi, sub in plan:
    for i in range(count):
        sz = random.randint(lo, hi)
        d = os.path.join(OUT, sub, f"d{i // 100:03d}")
        write_file(os.path.join(d, f"f{i:05d}.txt"), sz)
        total_bytes += sz
        total_files += 1

print(f"generated {total_files} files, {total_bytes/1024/1024:.1f} MB under {OUT}/")
