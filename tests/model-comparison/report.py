#!/usr/bin/env python3
"""
Generates results/summary.md from raw transcripts.
Levenshtein distance at word level for divergence metric.
"""
import os, json, math

DIR = os.path.dirname(os.path.abspath(__file__))
RAW = os.path.join(DIR, "results", "raw")
OUT = os.path.join(DIR, "results", "summary.md")

SESSIONS_META = {
    "20260831_162820_g16": {"dur": 0.3,  "label": "тишина/случайное нажатие — q5_0 галлюцинирует 'you'"},
    "20260831_175508_g23": {"dur": 4.2,  "label": "эталон recent.json = '.' — краевой случай"},
    "20260830_033027_g62": {"dur": 2.6,  "label": "английский: 'All right.'"},
    "20260829_030347_g4":  {"dur": 2.4,  "label": "короткая русская фраза"},
    "20260831_180501_g25": {"dur": 11.8, "label": "эталон recent.json, чистый русский"},
    "20260830_022709_g38": {"dur": 8.8,  "label": "чистое короткое техническое предложение"},
    "20260831_171450_g7":  {"dur": 19.4, "label": "разговорный/просторечный русский"},
    "20260830_031623_g54": {"dur": 32.0, "label": "клиппинг (пик=32768) + эмоциональная речь"},
    "20260830_223738_g82": {"dur": 31.7, "label": "громкая чистая речь про микрофон"},
    "20260831_175406_g22": {"dur": 29.6, "label": "эталон recent.json, техническое (WSL/sandbox)"},
    "20260829_161020_g7":  {"dur": 78.3, "label": "code-switching ru+en жаргон ('Cloud MD'=CLAUDE.md)"},
    "20260830_022647_g37": {"dur": 62.6, "label": "тихая, затихающая к концу речь"},
    "20260831_175627_g24": {"dur": 37.4, "label": "эталон recent.json, тема — ru/uk язык"},
    "20260830_042249_g73": {"dur": 120.3,"label": "плотная техническая про bash-скрипт"},
    "20260829_155540_g3":  {"dur": 143.0,"label": "самая длинная, финансовый контент (Payoneer/PayPal)"},
}

MODEL_Q5 = "large-v3-turbo-q5_0"
MODEL_LV3 = "large-v3"

RECENT_JSON = os.path.expanduser("~/.local-whisper/recent.json")
RECENT_TIMESTAMPS = {
    # session -> unix timestamp (seconds) — filled from recent.json by matching
}


def load_recent():
    try:
        with open(RECENT_JSON) as f:
            data = json.load(f)
        return {item["time"]: item["text"] for item in data if "time" in item and "text" in item}
    except Exception:
        return {}


def session_unix_time(session):
    # session name like 20260831_175406_g22 -> parse YYYYMMDD_HHMMSS in local time
    import datetime
    parts = session.split("_")
    if len(parts) < 2:
        return None
    try:
        dt = datetime.datetime.strptime(parts[0] + parts[1], "%Y%m%d%H%M%S")
        return dt.timestamp()
    except ValueError:
        return None


def match_recent(session, recent_by_time, tolerance=90):
    t = session_unix_time(session)
    if t is None:
        return None
    best = None
    best_diff = tolerance
    for ts, text in recent_by_time.items():
        diff = abs(ts - t)
        if diff < best_diff:
            best_diff = diff
            best = text
    return best


def word_levenshtein(a, b):
    wa = a.lower().split()
    wb = b.lower().split()
    if not wa and not wb:
        return 0
    if not wa:
        return len(wb)
    if not wb:
        return len(wa)
    dp = list(range(len(wb) + 1))
    for i, ca in enumerate(wa):
        ndp = [i + 1] + [0] * len(wb)
        for j, cb in enumerate(wb):
            cost = 0 if ca == cb else 1
            ndp[j + 1] = min(dp[j + 1] + 1, ndp[j] + 1, dp[j] + cost)
        dp = ndp
    return dp[-1]


def word_error_rate(hyp, ref):
    if not ref.split():
        return None
    ed = word_levenshtein(hyp, ref)
    return ed / len(ref.split())


def read_raw(session, model):
    path = os.path.join(RAW, f"{session}__{model}.txt")
    if not os.path.exists(path):
        return None
    with open(path) as f:
        return f.read().strip()


def read_time_ms(session, model):
    path = os.path.join(RAW, f"{session}__{model}.time")
    if not os.path.exists(path):
        return None
    try:
        return int(open(path).read().strip())
    except Exception:
        return None


def fmt_time(ms):
    if ms is None:
        return "—"
    if ms < 1000:
        return f"{ms}ms"
    return f"{ms/1000:.1f}s"


def main():
    recent = load_recent()
    sessions = list(SESSIONS_META.keys())

    total_q5_ms = 0
    total_lv3_ms = 0
    n_timed = 0

    lines = []
    lines.append("# Сравнение large-v3-turbo-q5_0 vs large-v3\n")
    lines.append(f"Дата прогона: 2026-08-31  \n")
    lines.append("Архив: `~/.local-whisper/voice-archive/` | 15 сессий | ~85 мин  \n")
    lines.append("**Украинских фрагментов в выборке нет** — только русский + английский жаргон.\n\n")
    lines.append("---\n\n")

    for i, session in enumerate(sessions, 1):
        meta = SESSIONS_META[session]
        dur = meta["dur"]
        label = meta["label"]
        ground_truth = match_recent(session, recent, tolerance=90)

        q5_text = read_raw(session, MODEL_Q5)
        lv3_text = read_raw(session, MODEL_LV3)
        q5_ms = read_time_ms(session, MODEL_Q5)
        lv3_ms = read_time_ms(session, MODEL_LV3)

        if q5_ms is not None:
            total_q5_ms += q5_ms
        if lv3_ms is not None:
            total_lv3_ms += lv3_ms
        if q5_ms is not None and lv3_ms is not None:
            n_timed += 1

        # divergence between models
        divergence = None
        if q5_text is not None and lv3_text is not None:
            divergence = word_levenshtein(q5_text, lv3_text)

        # WER vs ground truth
        wer_q5 = word_error_rate(q5_text or "", ground_truth) if ground_truth else None
        wer_lv3 = word_error_rate(lv3_text or "", ground_truth) if ground_truth else None

        # speed ratio
        speed_ratio = None
        if q5_ms and lv3_ms and q5_ms > 0:
            speed_ratio = lv3_ms / q5_ms

        lines.append(f"## #{i}. {session}\n\n")
        lines.append(f"**Длит.:** {dur}с  \n")
        lines.append(f"**Категория:** {label}  \n")
        if ground_truth:
            lines.append(f"**Эталон (recent.json):** {ground_truth!r}  \n")
        lines.append(f"**Время q5_0:** {fmt_time(q5_ms)}  \n")
        lines.append(f"**Время large-v3:** {fmt_time(lv3_ms)}  \n")
        if speed_ratio is not None:
            lines.append(f"**large-v3 медленнее в:** {speed_ratio:.1f}×  \n")
        if divergence is not None:
            lines.append(f"**Расхождение (word-Levenshtein):** {divergence} слов  \n")
        if wer_q5 is not None:
            lines.append(f"**WER q5_0 vs эталон:** {wer_q5:.0%}  \n")
        if wer_lv3 is not None:
            lines.append(f"**WER large-v3 vs эталон:** {wer_lv3:.0%}  \n")
        lines.append("\n")

        lines.append(f"**large-v3-turbo-q5_0:**\n")
        lines.append(f"> {q5_text if q5_text is not None else '_(нет данных)_'}\n\n")
        lines.append(f"**large-v3:**\n")
        lines.append(f"> {lv3_text if lv3_text is not None else '_(нет данных)_'}\n\n")
        lines.append("---\n\n")

    # Summary table
    lines.append("## Сводная таблица\n\n")
    lines.append("| # | Сессия | Длит | Расхожд. | q5_0 time | lv3 time | lv3/q5 | WER q5 | WER lv3 |\n")
    lines.append("|---|--------|------|----------|-----------|----------|--------|--------|--------|\n")
    for i, session in enumerate(sessions, 1):
        meta = SESSIONS_META[session]
        dur = meta["dur"]
        gt = match_recent(session, recent, tolerance=90)
        q5_text = read_raw(session, MODEL_Q5)
        lv3_text = read_raw(session, MODEL_LV3)
        q5_ms = read_time_ms(session, MODEL_Q5)
        lv3_ms = read_time_ms(session, MODEL_LV3)
        div = word_levenshtein(q5_text or "", lv3_text or "") if (q5_text and lv3_text) else "—"
        wq5 = f"{word_error_rate(q5_text or '', gt):.0%}" if gt else "—"
        wlv3 = f"{word_error_rate(lv3_text or '', gt):.0%}" if gt else "—"
        ratio = f"{lv3_ms/q5_ms:.1f}×" if (q5_ms and lv3_ms and q5_ms > 0) else "—"
        lines.append(f"| {i} | `{session}` | {dur}s | {div} | {fmt_time(q5_ms)} | {fmt_time(lv3_ms)} | {ratio} | {wq5} | {wlv3} |\n")

    lines.append("\n")
    if total_q5_ms > 0 and total_lv3_ms > 0:
        overall_ratio = total_lv3_ms / total_q5_ms
        lines.append(f"**Суммарное время q5_0:** {fmt_time(total_q5_ms)}  \n")
        lines.append(f"**Суммарное время large-v3:** {fmt_time(total_lv3_ms)}  \n")
        lines.append(f"**large-v3 медленнее суммарно в:** {overall_ratio:.1f}×  \n\n")
        lines.append(
            f"> **Вывод по скорости:** large-v3 требует в {overall_ratio:.1f}× больше времени на те же записи. "
            f"Для live-режима (цель — минимизировать ожидание после диктовки) это критично — "
            f"решение о переключении зависит от того, перевешивает ли выигрыш в качестве этот штраф.\n\n"
        )

    lines.append("**Замечание:** украинских фрагментов в выборке нет. "
                 "Если uk-качество важно — потребуются отдельные тестовые клипы.\n")

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w") as f:
        f.writelines(lines)
    print(f"Report written to {OUT}")


if __name__ == "__main__":
    main()
