---
name: info_jinja_manual_setup
description: Claude Code ↔ LM Studio jinja chat template 수동 설정 매뉴얼. 검증 모델로도 jinja 오류가 남을 때의 최후 수동 우회(GUI 편집 / 헤드리스 config 주입 / 붙여넣을 gemma+tools 템플릿)
date: 2026-07-21
---

# 이 문서의 목적

LM Studio(llmster)에 모델을 **설치·로드하는 것만으로는 Claude Code 가 붙지 않는다.** Claude Code 는
매 요청에 `tools`(도구 스키마)와 `system`(시스템 프롬프트)을 실어 보내는데, 모델에 내장된
**Jinja chat template** 이 이 페이로드를 렌더하지 못하면 추론 이전 단계에서 `500` 으로 실패한다.
이 jinja 정합이 이번 반입에서 **가장 오래 잡고 있던 부분**이라, 자동 우회가 실패했을 때 손으로
복구하는 절차를 여기 박제한다.

* 증상·원인 분석·GPU offload 와의 구분은 [info_jinja_and_lms.md](info_jinja_and_lms.md) 가 SSOT.
  본 문서는 그 §2("문제 A — Jinja 템플릿 오류")의 **수동 복구 실행편**이다.
* 진단·검증 모델 로드 자동화는 [lms-jinja-fix.sh](lms-jinja-fix.sh) 가 담당. 본 문서는 그 스크립트가
  **해결하지 못하는 경우**(검증 모델조차 tools 요청에서 jinja 오류)의 마지막 수단이다.

> ⚠️ 전제: 먼저 **GPU offload 미동작(CPU 추론)** 을 배제하라. 응답이 "느린" 것은 jinja 가 아니라
> GPU 문제다([info_jinja_and_lms.md](info_jinja_and_lms.md) §3). jinja 오류는 **느림이 아니라 즉시
> `500` + `Cannot perform operation ~ on undefined values`** 로 나타난다. 이 문자열이 없으면 본
> 문서 대상이 아니다.

# 0. 언제 이 문서를 여는가 (판별 1줄)

```bash
# 게이트웨이(:8080) 경유, tools 포함 요청으로 jinja 오류를 강제 재현
./lms-jinja-fix.sh probe <모델키>
```

* `[✗] JINJA 오류 발생` + 응답에 `jinja` / `Cannot perform operation ~ on undefined values`
  → **본 문서 진행**.
* `[✓] 정상 응답` → jinja 문제 아님. 종료.
* `[~] 타임아웃/지연` → GPU offload 문제. [info_jinja_and_lms.md](info_jinja_and_lms.md) §3 으로.

# 1. 복구 경로 3가지 (우선순위)

| 순위 | 방법 | 적용 환경 | 재빌드 | 절차 |
| :--: | :--- | :-------- | :----- | :--- |
| C(우선) | **검증 모델로 교체** | 어디서나 | 불필요 | `./lms-jinja-fix.sh use <검증모델>` — §2 |
| A | **GUI 로 chat template 편집** | LM Studio **GUI 있는 머신**(반입 전 사전작업) | 이미지 재반입 | §3 |
| B | **헤드리스 config 파일 주입** | 폐쇄망 컨테이너(GUI 없음) | 불필요(재로드) | §4 |

> 원칙: **모델을 바꿔서 피할 수 있으면 템플릿을 고치지 마라(C).** 보안망 제약상 Google/gemma
> 계열만 쓰므로 후보가 좁지만, 그 안에서 tools 정상 모델이 있으면 그걸로 끝낸다. 템플릿 편집(A/B)은
> "그 모델을 반드시 써야 하는데 jinja 만 걸리는" 경우의 수단이다.

# 2. 방법 C — 검증 모델로 교체 (가장 먼저 시도)

```bash
./lms-jinja-fix.sh verified          # jinja 오류 없는 검증 모델 목록
./lms-jinja-fix.sh use gemma-4-e2b-it   # 전 백엔드에서 언로드 후 로드 (16GB 검증 호스트 기준)
./lms-jinja-fix.sh probe gemma-4-e2b-it # 재검증
```

* 교체 후 **클라이언트의 모델 키도 반드시 일치**시킨다:
    - 컨테이너 cc: [step4.cc_gw_lms2/.env](step4.cc_gw_lms2/.env) 의 `LMS_MODEL` 수정 → `run.sh` 재기동.
    - Windows 확장: `%USERPROFILE%\.claude\settings.json` 의 `"model"` 수정 → 새 터미널/Reload
      ([step5.win_gw_lms2/README.md](step5.win_gw_lms2/README.md)).
* 보안 정책: 중국계(Qwen·GLM/zai-org) 금지, **Google 계열만**([airgap-model-policy] 메모리 규칙).

여기서 통과하면 §3·§4 는 불필요. 통과 못 하는(반드시 특정 모델을 써야 하는) 경우만 아래로.

# 3. 방법 A — GUI 로 chat template 편집 (반입 전 사전 굽기)

폐쇄망 안에는 GUI 가 없다. 따라서 **반입 전에**, LM Studio GUI 가 있는 머신에서 문제 모델의
템플릿을 고쳐 두고, 그 **모델 폴더(고쳐진 config 포함)를 통째로 반입**한다. 이것이 이번에 실제로
효과를 본 경로다(헤드리스엔 템플릿 override CLI 플래그가 없음).

## 절차

1. GUI 머신에서 LM Studio 실행 → **My Models** → 문제 모델 선택.
2. 모델의 **⚙ 설정(또는 "Prompt" 탭)** → **Prompt Template** 항목을 연다.
3. 템플릿 유형을 **Jinja** 로 두고, 내장 템플릿을 §5 의 "검증 gemma+tools 템플릿"으로 **교체**한다.
   (핵심 원인은 내장 템플릿이 undefined 값에 `~`(문자열 결합)·`| string` 필터를 수행하는 것 —
   교체 템플릿은 모든 값에 `or ''` 가드를 걸어 이를 회피한다.)
4. **Chat** 탭에서 도구를 요구하는 간단 질문으로 1회 검증(응답이 나오면 OK).
5. 저장. LM Studio 는 이 override 를 모델별 config 로 로컬에 기록한다(§4 의 파일).
6. **모델 폴더 + config 를 함께 반입.** 반입 후 헤드리스에서 `lms load` 하면 저장된 템플릿이 적용된다.

> GUI 가 확실한 이유: 헤드리스 `lms load` 에는 `--prompt-template` 류 플래그가 **없다.** 템플릿은
> 오직 모델별 config 파일로만 주입된다(§4). GUI 는 그 파일을 안전하게 써 주는 프론트일 뿐이다.

# 4. 방법 B — 헤드리스 컨테이너에서 config 파일 주입 (GUI 없이)

GUI 머신을 못 쓰는 상황(이미 폐쇄망 안, 재반입 불가)에서 컨테이너 내부 config 파일을 직접 고쳐
템플릿을 주입한다. **`lms load` 플래그로는 불가**하므로 파일을 쓰고 **모델을 재로드**해야 반영된다.

## 4.1 config 파일 위치 확인 (버전마다 경로가 달라 반드시 실측)

```bash
# 컨테이너 안에서 chat template / 모델 config 후보 파일 탐색
docker exec lms-1 bash -lc '
  export PATH=$HOME/.lmstudio/bin:$PATH
  find $HOME/.lmstudio -maxdepth 4 -iname "*.json" 2>/dev/null \
    | grep -iE "config|template|concrete|preset" ; echo "---" ;
  grep -rIl "chat_template\|promptTemplate\|jinja" $HOME/.lmstudio 2>/dev/null | head'
```

* 유력 후보(llmster 버전에 따라 다름 — 위 탐색 결과를 우선):
    - `~/.lmstudio/.internal/user-concrete-model-default-config/<model>.json` — 모델별 로드 기본 config
    - 모델 폴더 내 `*.json`(gguf 옆) 의 `promptTemplate` / `chat_template` 필드
* 못 찾으면 방법 B 는 포기하고 **방법 C(모델 교체)로 회귀**한다. 조용히 성공한 척하지 말 것(fail-loud).

## 4.2 템플릿 주입 + 재로드

```bash
# ① 대상 config 백업 (되돌리기 대비)
docker exec lms-1 bash -lc 'cp <config.json> <config.json>.bak'

# ② §5 템플릿을 컨테이너로 복사 (호스트에 template.jinja 로 저장해 두고)
docker cp ./template.jinja lms-1:/tmp/template.jinja

# ③ config 의 promptTemplate / chat_template 필드를 /tmp/template.jinja 내용으로 치환
#    (이미지에 jq/python3 이 없으므로, 필드 구조가 단순하면 config 를 통째 재작성하는 편이 안전.
#     GUI(방법 A)가 어려운 진짜 이유가 이 편집의 취약성이다 — 가능하면 A 로 사전에 구워라.)

# ④ 재로드해야 반영됨 (파일만 고치고 재로드 안 하면 메모리의 옛 템플릿 그대로)
docker exec lms-1 bash -lc 'export PATH=$HOME/.lmstudio/bin:$PATH;
  lms unload --all; lms load "<모델키>" --yes --gpu "${LMS_GPU:-max}" \
    --parallel 1 --context-length 32768'

# ⑤ 검증
./lms-jinja-fix.sh probe <모델키>
```

> B 는 취약하다(config 스키마가 llmster 버전마다 다르고, jq 없이 JSON 편집이 위험). **가급적 A 로
> 반입 전에 처리**하고, B 는 현장 응급 처치로만 쓴다.

# 5. 붙여넣을 검증 템플릿 (gemma + tools + system)

gemma 계열용. **원 오류(`~ on undefined`)를 모든 값에 `or ''` 가드로 회피**한다. gemma 는 `system`
역할이 없으므로 시스템 메시지를 첫 user 턴에 병합하고, `tools` 는 텍스트로 주입한다.

```jinja
{{ bos_token }}
{%- if messages and messages[0]['role'] == 'system' -%}
    {%- set system_message = (messages[0]['content'] or '') | trim -%}
    {%- set loop_messages = messages[1:] -%}
{%- else -%}
    {%- set system_message = '' -%}
    {%- set loop_messages = messages -%}
{%- endif -%}
{%- if tools is defined and tools -%}
    {%- set system_message = system_message ~ '\n\n# Available tools\nWhen a tool is needed, reply with a JSON object: {"name": <tool>, "arguments": <args>}.\n' -%}
    {%- for tool in tools -%}
        {%- set system_message = system_message ~ '\n' ~ (tool | tojson) -%}
    {%- endfor -%}
{%- endif -%}
{%- for message in loop_messages -%}
    {%- set role = 'model' if message['role'] == 'assistant' else 'user' -%}
    {{ '<start_of_turn>' ~ role ~ '\n' -}}
    {%- if loop.first and system_message -%}
        {{ system_message ~ '\n\n' -}}
    {%- endif -%}
    {{ (message['content'] or '') | trim -}}
    {{ '<end_of_turn>\n' -}}
{%- endfor -%}
{%- if add_generation_prompt -%}
    {{ '<start_of_turn>model\n' -}}
{%- endif -%}
```

> ⚠️ **이 템플릿은 반드시 적용 직후 `probe` 로 검증**하라(본 세션에서 실측 검증되지 않음). 가드 포인트:
> `(x or '')` 로 undefined 결합을 차단, `| string` 필터 미사용, `system`/`tools` 부재 시에도 안전.
> 통과 못 하면 미련 없이 §2(방법 C, 모델 교체)로 회귀한다.

# 6. 최후 우회 (템플릿을 못 고칠 때)

* **요청 다이어트** — Claude Code 가 보내는 도구 스키마 자체를 줄여 렌더 실패 표면을 축소.
  [info_promptDiet.md](info_promptDiet.md) 참조.
* **fallback 게이트웨이(ollama)** — jinja 를 llmster 가 아니라 다른 백엔드로 우회.
  [fallback.gw_ollama/](fallback.gw_ollama/) 참조.

# 검증 체크리스트 (완료 기준)

- [ ] `./lms-jinja-fix.sh probe <모델키>` → `[✓] 정상 응답`(jinja 오류 없음)
- [ ] Claude Code 에서 도구 사용이 필요한 실제 대화 1회 성공(500 없음)
- [ ] 사용한 방법(C/A/B)과 최종 모델 키를 [step4.cc_gw_lms2/.env](step4.cc_gw_lms2/.env) `LMS_MODEL` 및
      클라이언트 설정에 반영
- [ ] (A/B 로 템플릿을 고쳤다면) 고친 config/모델 폴더를 반입 산출물에 포함

# 관련

* [info_jinja_and_lms.md](info_jinja_and_lms.md) — 증상·원인 SSOT(§2 Jinja / §3 GPU offload 구분)
* [lms-jinja-fix.sh](lms-jinja-fix.sh) — `probe`·`verified`·`use`·`status`
* [info_promptDiet.md](info_promptDiet.md) — 요청 축소(도구 스키마 제거)
* [info_modelTuning.md](info_modelTuning.md) — 로드 파라미터(VRAM·컨텍스트·parallel)
* [step4.cc_gw_lms2/README.md](step4.cc_gw_lms2/README.md) — 서버 스택 / `.env` SSOT
* [step5.win_gw_lms2/README.md](step5.win_gw_lms2/README.md) — Windows 클라이언트 연결
