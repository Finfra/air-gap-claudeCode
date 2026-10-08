

# GPU Server
* 생성 서버 : fg1
* Docker Info : dockerInfo.txt
* Docker Container
  * volume1(general) : ~/localLLM/df:/df
  * volume2(weight) : ~/localLLM/ollama_docker:/root/.ollama
  * port : 11436 (호스트), 11434 (컨테이너 내부)
* 기존 [Ollama]([Info_ollama.md):
  * 11434: systemd 서비스 (ollama 유저)
  * 11435: nowage 유저 인스턴스

## Container info
* [docker info](dockerInfo.txt)

# DevPc
* Vscode 1.119.1 node.js 22.22.1
## 반입 vscode Extention (toDo)
Mermaid diagram
Project mgr