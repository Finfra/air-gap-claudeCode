---
name: info_promptDiet
description: step5 기초 참고 — 도구 스키마 제거로 프롬프트 20k→3k. Windows(step5)에서는 settings.json.sample 의 permissions.deny 로 적용
date: 2026-07-21
---

# 개요

로컬 LLM 백엔드에서 Claude Code 가 매 요청에 보내는 프롬프트 **19,385 토큰 중 83%(16,136)가
도구 스키마**다(측정 당시 24개). `Workflow` 하나가 5,043 토큰(전체의 26%). 불필요한 도구를 제거하면
**3,041 토큰(-84%)**, 응답은 **최대 6.8배** 빨라진다. 품질 저하는 관측되지 않았다.

> **step5 관점**: Windows 클라이언트는 이 다이어트를 **`%USERPROFILE%\.claude\settings.json` 의
> `permissions.deny`** 로 적용한다. 원본은 [step5.win_gw_lms2/settings.json.sample](step5.win_gw_lms2/settings.json.sample).
> 컨테이너 cc(step4)는 [step4.cc_gw_lms2/entrypoint.cc.sh](step4.cc_gw_lms2/entrypoint.cc.sh) 가
> 같은 deny 목록을 자동 주입한다 — **양쪽 deny 목록은 같아야 한다**(§4가 SSOT).

> 실측: fg1 (NVIDIA 16GB) + LM Studio + Claude Code 2.1.212. 요청 body 를 프록시로 캡처하고
> llama-server `/tokenize` 로 계수(추정 아님).
>
> ⚠️ **버전 차이**: 위 측정은 Claude Code **2.1.212**(도구 24개). 반입 `claude.tar` 는 버전이
> 다를 수 있어 노출 도구 개수가 어긋난다. 절감 비율의 방향은 같으나 절대 개수는 버전마다 다르다.
> **실제 적용 deny 목록은 [step4.cc_gw_lms2/entrypoint.cc.sh](step4.cc_gw_lms2/entrypoint.cc.sh)
> 가 SSOT** — 아래 §4 예시는 참고용.

# 1. 프롬프트 구성 (실측)

| 구성 | 토큰 | 비중 |
| :--- | ---: | ---: |
| **도구 정의(측정 당시 24개)** | **16,136** | **83%** |
| 메시지 (agent 타입 목록 1,739 + 실제 질문 116) | 1,845 | 10% |
| 시스템 프롬프트 3블록 | 1,404 | 7% |
| 합계 | 19,385 | 100% |

| 도구 | 토큰 | | 도구 | 토큰 |
| :--- | ---: | :-- | :--- | ---: |
| **Workflow** | **5,043** | | Bash | 678 |
| CronCreate | 1,122 | | Read | 466 |
| ScheduleWakeup | 1,015 | | Edit | 246 |
| EnterWorktree | 952 | | Write | 167 |
| TaskUpdate | 915 | | | |

`Agent` 를 빼면 **"Available agent types" 메시지(1,739 토큰)도 함께 사라진다** (msg 1,845 → 118).

`~/.claude` 나 CLAUDE.md 때문이 **아니다.** 도구 스키마는 바이너리에 내장되어 프로젝트 설정과
무관하게 전송된다.

# 2. 다이어트의 실체

**파일이 아니라 요청 body 의 `tools` 배열이다.**

```
POST /v1/messages
{ model, messages, system, tools: [...24개, 16,136 토큰...], ... }   # 측정 당시(2.1.212) 기준
                                   ↓ 다이어트
                            tools: ["Bash","Edit","Read","Write"]   (1,607 토큰)
```

claude 는 기동할 때마다 이 배열을 새로 조립해 보내고 프로세스가 죽으면 사라진다.
디스크에 남는 "다이어트된 무언가" 는 없다. 스위치는 두 개뿐이다.

| 스위치 | 실체 | 지속성 |
| :--- | :--- | :--- |
| `--tools Read Bash Edit Write` | CLI 인자 | 그 호출 1회 |
| `permissions.deny` 의 도구 이름들 | claude 가 기동 시 읽는 `settings.json` | 그 파일이 읽히는 한 |

**step5(Windows)·step4(컨테이너)는 둘 다 후자(`permissions.deny`) 방식**을 쓴다. 위치만 다르다.

# 3. 적용 위치 — step 별로 어디에 넣나

| 대상 | `settings.json` 위치 | 누가 씀 | 재기동 내성 |
| :--- | :--- | :--- | :--- |
| **Windows 클라이언트 (step5)** | `%USERPROFILE%\.claude\settings.json` | **사람이 수동** ([sample](step5.win_gw_lms2/settings.json.sample) 복사) | 파일이 남아 있는 한 유지 |
| **컨테이너 cc (step4)** | 컨테이너 `$HOME/.claude/settings.json` | `entrypoint.cc.sh` 가 **기동 시마다 생성** | 재기동해도 매번 다시 씀 |

## Windows (step5) — 수동, 그러나 영속

Windows 는 컨테이너가 아니므로 누가 덮어쓰지 않는다. [settings.json.sample](step5.win_gw_lms2/settings.json.sample)
을 `%USERPROFILE%\.claude\settings.json` 으로 저장하면 그 파일이 지워지기 전까지 다이어트가 유지된다.

> **저장 인코딩 주의**: 메모장 → 다른 이름으로 저장 → 인코딩 **`UTF-8`**(BOM 아님). `UTF-8(BOM)`
> 은 Claude Code 가 못 읽는다 — 이전 반입 실패의 직접 원인. (→ [step5.win_gw_lms2/README.md](step5.win_gw_lms2/README.md) 2-4)

## 컨테이너 cc (step4) — entrypoint 가 매번 생성

[step4.cc_gw_lms2/entrypoint.cc.sh](step4.cc_gw_lms2/entrypoint.cc.sh) 는 **기동할 때마다
`$HOME/.claude/settings.json` 을 새로 생성**한다(약 34~49행). `CLAUDE_DIET=1`(기본)이면 deny 목록을
넣는다. `entrypoint.cc.sh` 가 폴더에서 bind-mount 되므로 **폴더 복사만으로 다이어트가 따라간다.**

* 컨테이너 `~/.claude/settings.json` 에 수동으로 넣어도 재기동 때 덮어써진다 → **entrypoint 를 고쳐야** 영속.
* `CLAUDE_DIET=0` 이면 다이어트 도구는 열리되 `WebSearch`/`WebFetch` 는 **여전히 deny**(폐쇄망 분리).

# 4. deny 목록 (SSOT: entrypoint.cc.sh)

[step4.cc_gw_lms2/entrypoint.cc.sh](step4.cc_gw_lms2/entrypoint.cc.sh) 의 실제 목록 (약 22~32행):

```jsonc
// 폐쇄망 상시 deny (CLAUDE_DIET 무관)
"WebSearch", "WebFetch",
// 다이어트 deny (CLAUDE_DIET=1 일 때 추가)
"Workflow", "Agent",
"CronCreate", "CronDelete", "CronList",
"ScheduleWakeup", "EnterWorktree", "ExitWorktree",
"TaskCreate", "TaskUpdate", "TaskGet", "TaskList", "TaskOutput", "TaskStop",
"SendMessage", "NotebookEdit", "Skill"
```

Windows [settings.json.sample](step5.win_gw_lms2/settings.json.sample) 의 `permissions.deny` 도
**이 목록과 동일**하다. 도구 4개(`Bash, Edit, Read, Write`)만 남아 ~3k 토큰이 된다.

> ⚠️ **폐쇄망에서는 `WebSearch`/`WebFetch` 를 반드시 deny.** 외부망 도구를 켜두면 모델이
> 호출→실패→재시도 루프에 빠진다. air-gap 에는 인터넷이 없으므로 이 두 도구는 어차피 무용하다.
> `CLAUDE_DIET=0` 으로도 열리지 않도록 entrypoint 가 분리해 둔다.

# 5. 함정

* **`deny` 는 블랙리스트다.** Claude Code 버전이 올라가 새 도구가 추가되면 자동으로 프롬프트에
  들어온다. 버전 업 후에는 실제 요청을 캡처해 재확인할 것(§6). Windows·컨테이너 **양쪽 deny 목록을 함께 갱신**.
* **LMS JIT 로드 주의.** 모델 미로드 상태에서 요청이 오면 LM Studio 가 기본 `ctx 8192 / parallel 4`
  (슬롯당 2,048 토큰)로 올려 400 이 난다. 다이어트(3,041)로도 2,048 은 못 넘으므로 **서버에서 모델 선로드 필수**.
* **Windows 저장 인코딩**: `UTF-8(BOM)` 로 저장하면 파싱 실패(§3).
* **기존 Windows 설정 병합**: `%USERPROFILE%\.claude\settings.json` 이 이미 있으면 덮어쓰지 말고
  `model`·`env`·`permissions` 를 하나의 JSON 으로 합칠 것(최상위 키 중복 금지). (→ [step5.win_gw_lms2/README.md](step5.win_gw_lms2/README.md) 2-4)

# 6. 왜 빨라지나 — prefill 병목

느렸던 원인은 모델도 컨테이너 오버헤드도 아니고 **도구 스키마 16k 토큰의 prefill** 이다.
프롬프트 84% 감소에 소요시간 85% 감소가 거의 1:1 대응했다.

**에이전트 루프는 도구를 한 번 호출할 때마다 늘어난 대화 전체를 다시 prefill** 하므로 왕복 N회면
프리필도 N배다. → **경로 간·모델 간 절대시간 비교는 성립하지 않는다.** 같은 모델의 full vs diet 만 신뢰할 것.

# 7. 재계측법 (Claude Code 버전 업 후)

1. POST body 를 파일로 덤프하고 최소 응답을 돌려주는 HTTP 서버를 띄운다.
2. `ANTHROPIC_BASE_URL` 을 그 프록시로 돌려 `claude -p "hi"` 를 1회 실행한다.
3. 덤프된 body 의 `system` / `tools` / `messages` 를 llama-server `/tokenize` 로 각각 계수한다.

`--tools` 를 바꿔가며 2~3 을 반복하면 도구별 기여도가 그대로 나온다.

# 관련

* [info_modelTuning.md](info_modelTuning.md) — 서버 튜닝(VRAM·속도·컨텍스트)
* [info_jinja_and_lms.md](info_jinja_and_lms.md) — LMS jinja 템플릿 이슈 / GPU offload
* [step4.cc_gw_lms2/entrypoint.cc.sh](step4.cc_gw_lms2/entrypoint.cc.sh) — deny 목록 SSOT
* [step5.win_gw_lms2/settings.json.sample](step5.win_gw_lms2/settings.json.sample) — Windows deny 원본
* [step5.win_gw_lms2/README.md](step5.win_gw_lms2/README.md) — Windows 연결 매뉴얼
