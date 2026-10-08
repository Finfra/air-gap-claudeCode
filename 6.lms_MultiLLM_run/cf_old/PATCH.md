# 패치 사용법 — VSCode 연결 & Jinja 오류 우회

`6.lms_MultiLLM_run` 스택(`./start.sh` 로 기동)에 붙는 **호스트 측 패치 2종**의 사용법.

| 패치 | 역할 |
| :--- | :--- |
| [`vscode-connect.sh`](vscode-connect.sh) | 호스트 **VSCode Claude Code 확장**을 이 스택 게이트웨이(`localhost:8080`)에 연결/해제 |
| [`lms-jinja-fix.sh`](lms-jinja-fix.sh) | LLM 호출 시 **Jinja 템플릿 오류** 진단·우회 (검증 모델로 전환) |

> 전제: `./start.sh` 로 스택이 떠 있고(gateway 가 호스트 `:${GATEWAY_PORT}` 노출), 호스트에
> `jq`·`curl`·`docker` 가 있어야 함. 파라미터는 같은 폴더 `.env` 에서 자동 로드.

---

## 1. `vscode-connect.sh` — VSCode 확장 연결

VSCode 의 Claude Code 확장은 CLI 와 동일하게 `~/.claude/settings.json` 을 읽는다. 이 스크립트가
거기에 아래를 **병합**(기존 키 보존)한다 — 컨테이너 `cc` 의 환경과 동일하게 맞춘 것:

| 키 | 값 | 이유 |
| :--- | :--- | :--- |
| `env.ANTHROPIC_BASE_URL` | `http://<HOST>:<GATEWAY_PORT>` | 게이트웨이로 라우팅 |
| `env.ANTHROPIC_AUTH_TOKEN` | `lms` | LMS 더미 토큰 |
| `env.API_TIMEOUT_MS` | `600000` (`.env` 값) | **로컬 추론이 느려 첫 응답 지연 → 타임아웃 방지** |
| `env.CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` | `1` | 비-Anthropic 엔드포인트에 불필요 트래픽 차단 |
| `model` | `<LMS_MODEL>` | 사용 모델 키 |

> **jinja/GPU 문제는 서버(LMS) 쪽**이라 VSCode 에서 고칠 것이 없다. VSCode 측 패치의 핵심은
> **느린 로컬 추론에 대비한 `API_TIMEOUT_MS`** 와 **불필요 트래픽 차단**뿐 — 나머지는 서버에서
> 해결한다([`info_jinja_and_lms.md`](info_jinja_and_lms.md)).

```bash
./vscode-connect.sh on        # 연결 (최초 실행 시 settings.json.bak 백업)
./vscode-connect.sh status    # 현재 설정 + 게이트웨이 모델 목록
./vscode-connect.sh off       # 우리가 넣은 키만 제거 → Anthropic 복귀
```

적용 후 **VSCode 명령팔레트 → `Developer: Reload Window`** (또는 확장 재시작).

**옵션**

| 상황 | 명령 |
| :--- | :--- |
| 다른 머신에서 접속 | `LMS_HOST=<GPU호스트IP> ./vscode-connect.sh on` |
| 워크스페이스에만 적용(전역 오염 회피) | `CLAUDE_SETTINGS=.claude/settings.local.json ./vscode-connect.sh on` |

> ⚠️ 기본 대상이 **전역** `~/.claude/settings.json` 이라, `on` 은 호스트의 모든 Claude Code
> (CLI·확장)를 로컬 LMS 로 향하게 한다. 되돌리려면 `off` 또는
> `cp ~/.claude/settings.json.bak ~/.claude/settings.json`.

---

## 2. `lms-jinja-fix.sh` — Jinja 템플릿 오류 우회

### 증상

일부 모델에서 Claude Code 호출 시 아래 오류가 난다 (컨테이너 `cc` 든 VSCode 확장이든 동일):

```
500 {"error":{"message":"Error rendering prompt with jinja template:
     \"Cannot perform operation ~ on undefined values\" ..."}}
```

모델의 embedded **Jinja chat template** 이 Claude Code 의 `tools`/`system` 페이로드를
렌더하지 못해 발생한다. (참고: `LM_Studio_Ubuntu_Headless.md` Troubleshooting)

### 진단·우회 (헤드리스 권장 = 검증 모델)

```bash
./lms-jinja-fix.sh verified          # 검증된 모델 목록 (jinja 오류 없음)
./lms-jinja-fix.sh probe             # 현재 로드 모델 진단 (tools 포함 요청 → 오류 여부)
./lms-jinja-fix.sh probe <model>     # 특정 모델 진단
./lms-jinja-fix.sh use <model>       # 전 LMS 백엔드에서 언로드 후 검증 모델 로드
./lms-jinja-fix.sh status            # 로드 상태
```

**검증(문서 기준) 모델** — ⚠️ **보안 정책상 중국계(Qwen/GLM) 제외, Google 계열만 사용**:

* `google/gemma-4-31b-qat` — 본 스택 필수 모델
* `google/gemma-4-26b-a4b` — 참고 문서 권장(더 작음, 이 번들엔 미포함)

> ⚠️ **`google/gemma-4-31b-qat` 이 느렸던 건 jinja 가 아니라 GPU offload 미동작(CPU 추론)**
> 이었다. 초기 504 타임아웃의 실제 원인은 CUDA 런타임 미선택 + VRAM 부족. 자세한 진단·해결은
> [`info_jinja_and_lms.md`](info_jinja_and_lms.md) 참조. 요지: `entrypoint.lms.sh` 가 CUDA
> 런타임을 자동 선택하도록 패치됨(다음 `./start.sh` 부터 반영), A6000 48GB 면 전량 offload 로
> 정상 속도. **모델 전환(use)은 보안상 불가** — gemma-4-31b-qat 을 GPU 로 제대로 돌리는 것이 답.

예) 문제 모델을 쓰다 오류가 나면 검증 모델로 전환:

```bash
./lms-jinja-fix.sh probe                          # [✗] JINJA 오류 확인
./lms-jinja-fix.sh use google/gemma-4-31b-qat     # 전 백엔드 검증 모델로 교체
# 클라이언트 모델 키도 맞춤:
#   .env 의 LMS_MODEL=google/gemma-4-31b-qat 확인 → ./vscode-connect.sh on (확장) / start.sh 재기동(cc)
```

> ⚠️ 기반입 `lms:latest` 이미지에는 **gemma-4-31b-qat 하나만 내장** — `use` 로 전환할 다른 모델이 없다.
> 다른 검증 모델을 쓰려면 GGUF 를 별도 매체로 반입해 `LMS_MODEL_MOUNT` bind mount 로 추가할 것.

### 고급: prompt template 직접 편집 (문제 모델을 꼭 써야 할 때)

헤드리스 CLI(`lms load`)에는 템플릿 override 플래그가 없다. 템플릿 편집은 **LM Studio GUI** 가
가장 확실하다:

* My Models → 해당 모델 → ⚙️ → **Prompt Template** 탭
* `| string` 필터가 있는 라인에서 필터 제거: `{{ tool | string }}` → `{{ tool }}`
* 렌더 실패가 계속되면 모델 계열에 맞는 템플릿으로 통째 교체 (예: Nemotron 계열 템플릿은
  참고 문서 `LM_Studio_Ubuntu_Headless.md` 에 수록).

> GUI 가 없는 순수 headless 환경에서는 **검증 모델 전환(위 `use`)** 이 유일하게 안정적인
> 방법이다. 번들이 검증 모델(gemma-4-31b-qat)을 내장하는 이유.

---

## 3. 권장 순서 (요약)

```bash
cd 6.lms_MultiLLM_run

# 1) 스택 기동
./start.sh

# 2) jinja 오류 없는지 진단, 필요 시 검증 모델로 재로드
./lms-jinja-fix.sh probe
# (오류 시) ./lms-jinja-fix.sh use google/gemma-4-31b-qat

# 3) VSCode 확장을 게이트웨이에 연결
./vscode-connect.sh on
#    → VSCode: Developer: Reload Window

# 4) 확인
./vscode-connect.sh status
```

---

## 참고

* 원 문서: `jm4:/Users/nowage/_doc/3.Resource/_LLM/Tools/LM_Studio_Ubuntu_Headless.md`
  (LM Studio Ubuntu headless 설치 + Jinja 오류 해결)
* 스택 구조·기동: 같은 폴더 [`README.md`](README.md)
