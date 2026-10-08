# Ollama 모델 해시 확인

## ollama.com 페이지에 보이는 해시의 정체
* 태그 옆 큰 해시 : **매니페스트 digest** = `ollama list`의 `ID` 컬럼 (앞 12자)
    - ex) gemma4:31b → `6316f0629137`
* 레이어 목록의 해시 : **model blob digest** (실제 가중치 파일)
    - ex) gemma4:31b → `280af6832eca`

## ~/.ollama 폴더 구조
```
~/.ollama/models/
├── manifests/registry.ollama.ai/library/{모델}/{태그}   # 매니페스트(JSON)
└── blobs/sha256-{전체해시}                                # 실제 데이터 조각(model/license/params)
```

## 로컬에서 확인하는 법
```bash
# 1. 설치된 모델 ID(=매니페스트 digest 앞 12자) 확인 → ollama.com 상단 해시와 일치해야 함
ollama list
ollama show {모델}:{태그}

# 2. 매니페스트 직접 열기 (레이어별 blob digest 확인)
cat ~/.ollama/models/manifests/registry.ollama.ai/library/{모델}/{태그} | python3 -m json.tool
#   → layers[].digest 의 model 레이어 = ollama.com 의 blob 해시

# 3. 매니페스트 파일 자체의 해시 = 모델 ID 검증
shasum -a 256 ~/.ollama/models/manifests/registry.ollama.ai/library/{모델}/{태그}
#   → ollama.com 상단 해시로 시작해야 함

# 4. blob 무결성 검증 (파일명 뒷부분이 곧 sha256)
shasum -a 256 ~/.ollama/models/blobs/sha256-{전체해시}
#   → 출력 해시 == 파일명 뒷부분 이면 손상 없음
```

## 주의
* 위 명령은 ollama 서버가 떠 있어야 동작 (`ollama serve` — Docker 컨테이너 이용 시 컨테이너 내부에서 실행)
* 다운로드 중단 시 `~/.ollama/models/blobs/*partial*` 잔여 파일이 남음 → `ollama pull` 재실행으로 이어받거나 수동 삭제


