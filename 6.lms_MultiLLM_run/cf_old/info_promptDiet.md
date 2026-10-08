# 프롬프트 다이어트 — 도구 스키마 제거로 20k → 3k 토큰 (-84%)

로컬 LLM 백엔드에서 Claude Code 가 매 요청에 보내는 프롬프트 **19,385 토큰 중 83%(16,136)가
도구 스키마**다(측정 당시 24개). `Workflow` 하나가 5,043 토큰(전체의 26%). 불필요한 도구를 제거하면
**3,041 토큰(-84%)**, 응답은 **qwen 6.8배 / gemma 3.7배** 빨라진다. 품질 저하는 관측되지 않았다.

> 실측: fg1 (NVIDIA 16GB) + LM Studio + Claude Code 2.1.212. 요청 body 를 프록시로 캡처하고
> llama-server `/tokenize` 로 계수(추정 아님). 상세: `DeviceManagement/fg1/lms/benchmark_lms_report.md`
>
> ⚠️ **반입본과의 차이**: 위 측정은 Claude Code **2.1.212**(도구 24개). 이 폴더에
> 반입되는 `claude.tar` 는 **2.1.195** 로 노출 도구가 **23개**(전체 21개 + 항상 차단되는
> WebSearch/WebFetch 2개)다. 절감 비율의 방향은 같으나 절대 개수는 한 버전 만큼 어긋난다.
> 실제 적용되는 deny 목록은 `entrypoint.sh` 가 SSOT(19개) — 아래 §4 예시는 참고용.

---

## 1. 프롬프트 구성 (실측)

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
무관하게 전송된다. 이미지의 `~/.claude` 는 비어 있다.

## 2. 다이어트의 실체

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
| `permissions.deny` 의 도구 이름들 | claude 가 기동 시 읽는 settings.json | 그 파일이 읽히는 한 |

## 3. 이 폴더(6.lms_MultiLLM_run)의 특수 사정

`entrypoint.sh` 가 **기동할 때마다 `$HOME/.claude/settings.json` 을 새로 생성**한다(11~21행):

```bash
mkdir -p "$HOME/.claude"
cat > "$HOME/.claude/settings.json" <<JSON
{ "model": "...", "env": { "ANTHROPIC_BASE_URL": "...", "ANTHROPIC_AUTH_TOKEN": "lms" } }
JSON
```

이 사실이 두 가지를 결정한다.

* `~/.claude/settings.json` 에 다이어트를 수동으로 넣어도 **컨테이너 재기동 때 지워진다.**
  (`start.sh` 는 `--restart unless-stopped` 로 띄운다.)
* 반대로 **`entrypoint.sh` 자체가 폴더에서 bind-mount** 되므로
  (`-v "$SCRIPT_DIR/entrypoint.sh:/usr/local/bin/entrypoint.sh:ro"`),
  **여기에 넣으면 폴더 복사만으로 다이어트가 따라간다.** ← 이 폴더의 정답

## 4. 적용 방법

### ① entrypoint.sh 패치 (권장 — 폴더 복사 대응 + 전역 적용)

`entrypoint.sh` 의 heredoc 에 `permissions.deny` 를 추가한다:

```bash
cat > "$HOME/.claude/settings.json" <<JSON
{
  "model": "${ANTHROPIC_MODEL:-${LMS_MODEL:-}}",
  "env": {
    "ANTHROPIC_BASE_URL": "http://${GW_HOST}:${GW_PORT}",
    "ANTHROPIC_AUTH_TOKEN": "lms"
  },
  "permissions": {
    "deny": ["Workflow","Agent","CronCreate","CronDelete","CronList","ScheduleWakeup",
             "EnterWorktree","ExitWorktree","TaskCreate","TaskUpdate","TaskGet","TaskList",
             "TaskOutput","TaskStop","SendMessage","NotebookEdit",
             "Skill","WebSearch","WebFetch"]
  }
}
JSON
```

`model`·`env`·`permissions` 3키 공존은 실측 검증됨 → 도구 4개(`Bash, Edit, Read, Write`), 3,153 토큰.
cwd 와 무관하게 모든 `cc` 호출에 적용되고, 재기동해도 entrypoint 가 매번 다시 써주므로 유지된다.

### ② 코드 폴더에 배치 (`MOUNT_CODE_DIR` 사용 시)

```bash
mkdir -p <코드폴더>/.claude
cp <매니페스트> <코드폴더>/.claude/settings.json
# .env 에 MOUNT_CODE_DIR=<코드폴더> → /home/ubuntu/code 로 마운트됨
docker exec -it claude bash
cd /home/ubuntu/code && cc "질문"      # ← cwd 가 그 폴더여야 읽힘
```

호스트 파일이라 entrypoint 가 건드리지 않는다. 단 **cwd 가 그 폴더일 때만** 적용된다.

### ③ 1회성

```bash
cc "질문" --tools Read Bash Edit Write      # 프롬프트를 반드시 먼저!
```

### 효과 비교 (실측)

| 방법 | 적용 범위 | 토큰 |
| :--- | :--- | ---: |
| ① entrypoint 패치 / `~/.claude/settings.json` | 전역 (모든 호출) | 3,153 |
| ② 코드 폴더 `.claude/settings.json` | 그 폴더에서 도는 호출 | 3,149 |
| ③ `--tools` | 그 호출 1회 | 3,041 |
| (대조군) 미적용 | — | 20,177 |

> 3,041 / 3,149 / 3,153 의 차이는 **토크나이저와 로드된 모델이 달라서**다. 같은 조건끼리만 비교할 것.

## 5. 함정

* **`--tools`·`--disallowedTools` 는 가변 인자(variadic)다.** `--tools Read Bash "질문"` 으로 쓰면
  질문까지 도구명으로 삼켜 **에러 메시지 없이 exit 1** 로 죽는다. **프롬프트를 먼저** 둘 것.
* **매니페스트를 `~/.claude/settings.json` 에 bind-mount 하지 말 것.** 실측 결과:
  * `:ro` → entrypoint 가 그 경로에 쓰려다 `Read-only file system` 으로 **죽는다.**
  * rw → entrypoint 가 **호스트의 원본 파일을 덮어쓴다.** 매니페스트가 파괴되고 다이어트도 적용 안 됨.
* **`deny` 는 블랙리스트다.** Claude Code 버전이 올라가 새 도구가 추가되면 자동으로 프롬프트에 들어온다.
  버전 업 후에는 실제 요청을 캡처해 재확인할 것(§7).
* **LMS JIT 로드 주의.** 모델 미로드 상태에서 요청이 오면 LM Studio 가 기본 `ctx 8192 / parallel 4`
  (슬롯당 2,048 토큰)로 올려 400 이 난다. 다이어트(3,041)로도 2,048 은 못 넘으므로 **모델 선로드는 필수**.

## 6. 왜 빨라지나 — prefill 병목

느렸던 원인은 모델도 컨테이너 오버헤드도 아니고 **도구 스키마 16k 토큰의 prefill** 이다.
프롬프트 84% 감소에 소요시간 85% 감소가 거의 1:1 대응했다.

**에이전트 루프는 도구를 한 번 호출할 때마다 늘어난 대화 전체를 다시 prefill** 하므로 왕복 N회면
프리필도 N배다. 실측에서 qwen 은 Write+Bash 로 스크립트를 만들어 실행(다중 왕복), gemma 는 도구 없이
바로 답(단일 왕복)했는데 **같은 19,385 토큰인데 qwen 242.2s / gemma 94.2s** 로 갈렸다.
다이어트 배율이 왕복 많은 qwen 에서 더 큰 것(6.8배 vs 3.7배)도 같은 이유다.

→ **경로 간·모델 간 절대시간 비교는 성립하지 않는다.** 같은 모델의 full vs diet 만 신뢰할 것.

## 7. 재계측법 (Claude Code 버전 업 후)

1. POST body 를 파일로 덤프하고 최소 응답을 돌려주는 HTTP 서버를 띄운다.
2. `ANTHROPIC_BASE_URL` 을 그 프록시로 돌려 `claude -p "hi"` 를 1회 실행한다.
3. 덤프된 body 의 `system` / `tools` / `messages` 를 llama-server `/tokenize` 로 각각 계수한다.

`--tools` 를 바꿔가며 2~3 을 반복하면 도구별 기여도가 그대로 나온다.

## 관련

* `README.md` — 이 폴더의 토폴로지·기동
* `info_jinja_and_lms.md` — LMS jinja 템플릿 이슈
* `DeviceManagement/fg1/lms/diet_settings.json` — 매니페스트 SSOT
* `DeviceManagement/fg1/lms/benchmark_lms_report.md` — 원본 실측 리포트
