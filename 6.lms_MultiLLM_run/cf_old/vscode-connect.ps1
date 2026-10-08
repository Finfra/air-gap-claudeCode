<#
.SYNOPSIS
  Windows VSCode 의 Claude Code 확장을 로컬 LMS(또는 게이트웨이)에 연결/해제.
  vscode-connect.sh(호스트 Linux/Mac 용) 의 Windows PowerShell 대응물.

.DESCRIPTION
  확장은 CLI 와 동일하게 %USERPROFILE%\.claude\settings.json 을 읽는다.
  이 스크립트는 그 파일에 아래를 "병합"(기존 키 보존)한다:
    env.ANTHROPIC_BASE_URL, env.ANTHROPIC_AUTH_TOKEN, env.API_TIMEOUT_MS,
    env.CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC, model

.PARAMETER Action   on | off | status  (기본 on)
.PARAMETER BaseUrl  백엔드 주소. 로컬 LM Studio=http://localhost:1234,
                    원격 게이트웨이=http://<서버IP>:8080
.PARAMETER Model    모델 키 (예: qwen/qwen3-8b, google/gemma-4-e2b)
.PARAMETER TimeoutMs  API_TIMEOUT_MS (기본 600000 = 10분, 느린 로컬 추론 대비)
.PARAMETER Settings   대상 settings.json (기본 %USERPROFILE%\.claude\settings.json)

.EXAMPLE
  .\vscode-connect.ps1 -Action on -BaseUrl http://localhost:1234 -Model qwen/qwen3-8b
.EXAMPLE
  .\vscode-connect.ps1 -Action on -BaseUrl http://192.168.0.4:8080 -Model google/gemma-4-e2b
.EXAMPLE
  .\vscode-connect.ps1 -Action status
.EXAMPLE
  .\vscode-connect.ps1 -Action off

.NOTES
  실행정책에 막히면: powershell -ExecutionPolicy Bypass -File .\vscode-connect.ps1 ...
  적용 후 VSCode: 명령팔레트(Ctrl+Shift+P) → "Developer: Reload Window"
  ⚠️ 전역 설정을 바꾼다. off 또는 .bak 복원으로 실제 Anthropic 복귀.
#>
[CmdletBinding()]
param(
  [ValidateSet('on','off','status')]
  [string]$Action = 'on',
  [string]$BaseUrl,
  [string]$Model,
  [string]$TimeoutMs = '600000',
  [string]$Settings = "$env:USERPROFILE\.claude\settings.json"
)

$ErrorActionPreference = 'Stop'

# --- settings.json 로드 (없으면 빈 객체) ---
$dir = Split-Path -Parent $Settings
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
if (Test-Path $Settings) {
  $raw = Get-Content -Raw -Path $Settings
  if ([string]::IsNullOrWhiteSpace($raw)) { $raw = '{}' }
  $cfg = $raw | ConvertFrom-Json
} else {
  $cfg = [pscustomobject]@{}
}

function Set-Prop($obj, $name, $value) {
  if ($obj.PSObject.Properties[$name]) { $obj.$name = $value }
  else { $obj | Add-Member -NotePropertyName $name -NotePropertyValue $value }
}
function Remove-Prop($obj, $name) {
  if ($obj -and $obj.PSObject.Properties[$name]) { $obj.PSObject.Properties.Remove($name) }
}
function Save-Json($obj, $path) {
  # BOM 없는 UTF-8 로 저장 — Windows PowerShell 5.1 의 Set-Content -Encoding UTF8 은
  # BOM 을 붙여 settings.json 의 JSON 파싱을 깨뜨릴 수 있음.
  $json = $obj | ConvertTo-Json -Depth 20
  [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

switch ($Action) {
  'on' {
    if (-not $BaseUrl) { Write-Error "-BaseUrl 필요 (예: http://localhost:1234 또는 http://<서버IP>:8080)"; exit 1 }
    if (-not $Model)   { Write-Error "-Model 필요 (예: qwen/qwen3-8b)"; exit 1 }

    # 백엔드 응답 확인 (경고만)
    try {
      Invoke-RestMethod -Uri "$BaseUrl/v1/models" -TimeoutSec 5 | Out-Null
      Write-Host "[+] 백엔드 응답 OK: $BaseUrl/v1/models"
    } catch {
      Write-Host "[!] 백엔드 무응답($BaseUrl). 로컬이면 LM Studio 서버, 원격이면 서버 start.sh/방화벽 확인. (계속)"
    }

    # 최초 1회 백업
    $bak = "$Settings.bak"
    if ((Test-Path $Settings) -and -not (Test-Path $bak)) {
      Copy-Item $Settings $bak; Write-Host "[+] 백업: $bak"
    }

    if (-not $cfg.env) { Set-Prop $cfg 'env' ([pscustomobject]@{}) }
    Set-Prop $cfg.env 'ANTHROPIC_BASE_URL' $BaseUrl
    Set-Prop $cfg.env 'ANTHROPIC_AUTH_TOKEN' 'lms'
    Set-Prop $cfg.env 'API_TIMEOUT_MS' $TimeoutMs
    Set-Prop $cfg.env 'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC' '1'
    Set-Prop $cfg 'model' $Model

    Save-Json $cfg $Settings
    Write-Host "[+] 연결 설정 완료 -> $Settings"
    Write-Host "      ANTHROPIC_BASE_URL = $BaseUrl"
    Write-Host "      model              = $Model"
    Write-Host "      API_TIMEOUT_MS     = $TimeoutMs (느린 로컬 추론 대비)"
    Write-Host ""
    Write-Host "  다음: VSCode 명령팔레트 -> 'Developer: Reload Window'"
  }

  'off' {
    if ($cfg.env) {
      'ANTHROPIC_BASE_URL','ANTHROPIC_AUTH_TOKEN','API_TIMEOUT_MS','CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC' |
        ForEach-Object { Remove-Prop $cfg.env $_ }
      if ($cfg.env.PSObject.Properties.Count -eq 0) { Remove-Prop $cfg 'env' }
    }
    # model 은 '우리가 넣은 값일 때만' 제거 — sh 판(jq: if .model == $model)과 동일 동작.
    #   무조건 제거하면 on 실행 전부터 있던 사용자 설정(예: "model": "opus")을 말없이 날린다.
    #   -Model 은 off 에서 필수가 아니므로, 미지정이면 판별 불가 → 건드리지 않고 알린다.
    if ($Model) {
      if ($cfg.model -eq $Model) { Remove-Prop $cfg 'model' }
      else { Write-Host "[i] model='$($cfg.model)' 은 우리가 넣은 값이 아니라 보존함" }
    } elseif ($cfg.model) {
      Write-Host "[i] model='$($cfg.model)' 보존 — 제거하려면 '-Model $($cfg.model)' 로 다시 실행"
    }
    Save-Json $cfg $Settings
    Write-Host "[+] 연결 해제(우리가 넣은 키 제거) -> $Settings"
    Write-Host "      (전체 복원: Copy-Item '$Settings.bak' '$Settings')"
    Write-Host "  다음: VSCode 'Developer: Reload Window'"
  }

  'status' {
    Write-Host "대상: $Settings"
    if ($cfg.model -or $cfg.env) {
      [pscustomobject]@{
        model             = $cfg.model
        ANTHROPIC_BASE_URL = $cfg.env.ANTHROPIC_BASE_URL
        API_TIMEOUT_MS     = $cfg.env.API_TIMEOUT_MS
      } | Format-List
      if ($cfg.env.ANTHROPIC_BASE_URL) {
        Write-Host "백엔드 모델 목록:"
        try {
          (Invoke-RestMethod -Uri "$($cfg.env.ANTHROPIC_BASE_URL)/v1/models" -TimeoutSec 5).data |
            ForEach-Object { Write-Host "  - $($_.id)" }
        } catch { Write-Host "  (무응답)" }
      }
    } else {
      Write-Host "(연결 설정 없음 — Anthropic 기본)"
    }
  }
}
