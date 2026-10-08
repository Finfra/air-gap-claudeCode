#!/usr/bin/env python3
"""KV cache dtype 비교 클라이언트 — 표준 라이브러리만 사용 (호스트 python3 로 실행)

  run     : 기동된 단일 vLLM 에 3종 부하 → JSON
            1) 단일 스트림   TTFT · decode tok/s
            2) 동시 부하     고유 프롬프트 N개 동시 → 처리량·지연 + /metrics 폴링(동시 실행 수·대기·KV 사용률·선점)
            3) 품질          needle-in-haystack 5위치 + greedy 출력(기준 dtype 과 일치도 비교용)
  report  : 결과 폴더의 JSON·기동 로그를 모아 markdown 표 출력
"""
import argparse
import glob
import json
import os
import random
import re
import threading
import time
import urllib.request

WORDS = ("river mountain quiet engine paper window garden signal market winter "
         "copper lantern orbit valley harbor meadow circuit canvas thunder marble "
         "pocket ladder violet bridge candle forest silver rocket shadow anchor "
         "planet castle meadow travel number corner method season basket island").split()


def filler(n_words, seed):
    rnd = random.Random(seed)
    out = []
    for i in range(0, n_words, 12):
        out.append(" ".join(rnd.choice(WORDS) for _ in range(12)).capitalize() + ".")
    return " ".join(out)


def post(base, body, timeout=900):
    req = urllib.request.Request(base + "/v1/chat/completions", json.dumps(body).encode(),
                                 {"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)


def stream(base, body, timeout=900):
    """SSE 스트림 → (ttft, 마지막 토큰 시각, completion_tokens, 시작 시각)"""
    body = dict(body, stream=True, stream_options={"include_usage": True})
    req = urllib.request.Request(base + "/v1/chat/completions", json.dumps(body).encode(),
                                 {"Content-Type": "application/json"})
    t0 = time.time()
    first = last = None
    usage = None
    with urllib.request.urlopen(req, timeout=timeout) as r:
        for raw in r:
            line = raw.decode().strip()
            if not line.startswith("data:") or line == "data: [DONE]":
                continue
            d = json.loads(line[5:])
            if d.get("usage"):
                usage = d["usage"]
            if d.get("choices") and d["choices"][0].get("delta", {}).get("content"):
                last = time.time()
                first = first or last
    return first - t0, last, usage["completion_tokens"], t0, usage["prompt_tokens"]


def metrics(base):
    txt = urllib.request.urlopen(base + "/metrics", timeout=5).read().decode()
    m = {}
    for key in ("num_requests_running", "num_requests_waiting", "kv_cache_usage_perc", "num_preemptions_total"):
        v = re.findall(r"^vllm:%s(?:\{[^}]*\})? ([0-9.e+-]+)$" % key, txt, re.M)
        m[key] = sum(float(x) for x in v) if v else 0.0
    return m


def run(a):
    base, model, res = a.base, a.model, {"dtype": a.dtype}

    # 1) 단일 스트림 — 짧은 프롬프트, 256 토큰 강제 생성 (2회 중 두 번째 = 워밍업 제외)
    body = {"model": model, "max_tokens": 256, "temperature": 0, "ignore_eos": True,
            "messages": [{"role": "user", "content": "Write a long story about a lighthouse keeper."}]}
    for _ in range(2):
        ttft, last, n, t0, _p = stream(base, body)
    res["single"] = {"ttft_s": round(ttft, 3), "decode_tok_s": round((n - 1) / (last - t0 - ttft), 1)}
    print("single", res["single"], flush=True)

    # 2) 동시 부하 — 요청마다 앞부분이 다른 프롬프트(prefix cache 로 KV 를 아끼지 못하게)
    words = int(a.prompt_tokens / 1.35)
    lat, outs, errs = [], [], []
    peak = {"running": 0, "waiting": 0, "kv": 0.0}
    stop = threading.Event()
    pre0 = metrics(base)["num_preemptions_total"]

    def poll():
        while not stop.is_set():
            try:
                m = metrics(base)
                peak["running"] = max(peak["running"], m["num_requests_running"])
                peak["waiting"] = max(peak["waiting"], m["num_requests_waiting"])
                peak["kv"] = max(peak["kv"], m["kv_cache_usage_perc"])
            except Exception:
                pass
            time.sleep(0.25)

    def one(i):
        b = {"model": model, "max_tokens": a.gen_tokens, "temperature": 0, "ignore_eos": True,
             "messages": [{"role": "user", "content": "Request %d. Summarize the text below.\n\n%s" % (i, filler(words, 1000 + i))}]}
        t = time.time()
        try:
            r = post(base, b)
            lat.append(time.time() - t)
            outs.append((r["usage"]["prompt_tokens"], r["usage"]["completion_tokens"]))
        except Exception as e:
            errs.append(str(e)[:200])

    pt = threading.Thread(target=poll)
    pt.start()
    t0 = time.time()
    th = [threading.Thread(target=one, args=(i,)) for i in range(a.concurrency)]
    for t in th:
        t.start()
    for t in th:
        t.join()
    wall = time.time() - t0
    stop.set()
    pt.join()
    gen = sum(o[1] for o in outs)
    res["concurrent"] = {
        "requests": a.concurrency, "ok": len(outs), "errors": errs[:3],
        "prompt_tokens_each": outs[0][0] if outs else None,
        "wall_s": round(wall, 1), "gen_tok_s": round(gen / wall, 1),
        "lat_mean_s": round(sum(lat) / len(lat), 1) if lat else None,
        "lat_max_s": round(max(lat), 1) if lat else None,
        "peak_running": int(peak["running"]), "peak_waiting": int(peak["waiting"]),
        "peak_kv_usage": round(peak["kv"], 3),
        "preemptions": int(metrics(base)["num_preemptions_total"] - pre0),
    }
    print("concurrent", res["concurrent"], flush=True)

    # 3-a) needle-in-haystack — 긴 문맥 5위치에 비밀 코드를 심고 각각 질문
    hay_words = int(a.needle_tokens / 1.35)
    parts = filler(hay_words, 7).split(". ")
    needles = {"Lisbon": "4817", "Osaka": "2093", "Quito": "7741", "Tromso": "5308", "Hanoi": "6625"}
    for k, (city, code) in enumerate(needles.items()):
        pos = int(len(parts) * (0.1 + 0.2 * k))
        parts.insert(pos, "The secret code for %s is %s" % (city, code))
    hay = ". ".join(parts)
    hits, detail = 0, []
    for city, code in needles.items():
        r = post(base, {"model": model, "max_tokens": 16, "temperature": 0, "messages": [
            {"role": "user", "content": hay + "\n\nWhat is the secret code for %s? Answer with the number only." % city}]})
        ans = r["choices"][0]["message"]["content"].strip()
        hits += code in ans
        detail.append("%s=%s" % (city, ans[:12]))
    res["needle"] = {"context_tokens": r["usage"]["prompt_tokens"], "hits": hits, "of": len(needles), "answers": detail}
    print("needle", res["needle"], flush=True)

    # 3-b) greedy 출력 — 기준 dtype(auto) 대비 일치도 계산용
    qs = ["Explain how a hash map handles collisions.", "List the planets of the solar system in order.",
          "Write a Python function that checks whether a string is a palindrome.",
          "What causes the seasons on Earth?"]
    res["greedy"] = [post(base, {"model": model, "max_tokens": 160, "temperature": 0,
                                 "messages": [{"role": "user", "content": q}]})["choices"][0]["message"]["content"] for q in qs]
    json.dump(res, open(a.out, "w"), ensure_ascii=False, indent=1)


def common_prefix_ratio(x, y):
    n = 0
    for c1, c2 in zip(x, y):
        if c1 != c2:
            break
        n += 1
    return n / max(len(x), len(y), 1)


def report(a):
    rows, base_greedy = [], None
    res = {}
    for f in sorted(glob.glob(os.path.join(a.dir, "*.json"))):
        r = json.load(open(f))
        res[r["dtype"]] = r
    base_greedy = res.get("auto", {}).get("greedy")
    order = [d for d in a.order.split(",") if d in res or os.path.exists(os.path.join(a.dir, d + ".log"))]
    print("| KV dtype | KV 메모리 | KV 토큰 | 32k 기준 최대 동시 | 단일 decode | 동시 %s 처리량 | 피크 동시 실행 | 피크 대기 | 선점 | 평균/최대 지연 | needle | greedy 일치(auto 대비) |" % a.concurrency)
    print("| :-- | --: | --: | --: | --: | --: | --: | --: | --: | --: | :-: | --: |")
    for d in order:
        log = open(os.path.join(a.dir, d + ".log"), errors="ignore").read() if os.path.exists(os.path.join(a.dir, d + ".log")) else ""
        kvmem = re.findall(r"Available KV cache memory: ([0-9.]+ GiB)", log)
        kvtok = re.findall(r"GPU KV cache size: ([0-9,]+) tokens", log)
        conc = re.findall(r"Maximum concurrency for [0-9,]+ tokens per request: ([0-9.]+)x", log)
        kvt = int(kvtok[-1].replace(",", "")) if kvtok else 0
        if d not in res:
            err = re.findall(r"(ValueError: .{0,140}|RuntimeError: .{0,140})", log)
            print("| `%s` | %s | %s | — | 기동 실패: %s | | | | | | | |" % (d, kvmem[-1] if kvmem else "—", kvtok[-1] if kvtok else "—", err[-1] if err else "로그 확인"))
            continue
        r = res[d]
        c = r["concurrent"]
        g = "—"
        if base_greedy and d != "auto":
            g = "%.0f%%" % (100 * sum(common_prefix_ratio(x, y) for x, y in zip(base_greedy, r["greedy"])) / len(base_greedy))
        elif d == "auto":
            g = "기준"
        print("| `%s` | %s | %s | %.2fx | %s tok/s | %s tok/s | %d | %d | %d | %s / %s s | %d/%d | %s |" % (
            d, kvmem[-1] if kvmem else "—", kvtok[-1] if kvtok else "—", kvt / 32768,
            r["single"]["decode_tok_s"], c["gen_tok_s"], c["peak_running"], c["peak_waiting"], c["preemptions"],
            c["lat_mean_s"], c["lat_max_s"], r["needle"]["hits"], r["needle"]["of"], g))


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("--base", default="http://localhost:18000")
    r.add_argument("--model", required=True)
    r.add_argument("--dtype", required=True)
    r.add_argument("--out", required=True)
    r.add_argument("--concurrency", type=int, default=16)
    r.add_argument("--prompt-tokens", type=int, default=3000)
    r.add_argument("--gen-tokens", type=int, default=256)
    r.add_argument("--needle-tokens", type=int, default=6000)
    s = sub.add_parser("report")
    s.add_argument("dir")
    s.add_argument("--order", default="auto,fp8,turboquant_k8v4,turboquant_4bit_nc,turboquant_3bit_nc")
    s.add_argument("--concurrency", default="16")
    a = p.parse_args()
    run(a) if a.cmd == "run" else report(a)
