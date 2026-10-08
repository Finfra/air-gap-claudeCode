FROM debian:bookworm-slim

ARG USER_UID=1000
ARG USER_GID=1000
# 반입본은 버전을 고정할 것 — 'latest' 는 빌드 시점마다 결과가 달라져 재현이 안 된다.
#   ex) docker build --build-arg CLAUDE_VERSION=2.1.195 ...
ARG CLAUDE_VERSION=latest

ENV LC_ALL=C.UTF-8
ENV DEBIAN_FRONTEND=noninteractive
ENV CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1

# ⚠️ 백엔드 주소(ANTHROPIC_BASE_URL)를 이미지에 굽지 않는다.
#   step1~4 는 GW_HOST/GW_PORT(또는 LMS_HOST/LMS_PORT), step5 는 CC_BASE_URL 로 런타임에 주입한다.
#   이미지에 구우면 단계마다 이미지를 새로 빌드해야 하고, 실제 접속처와 다른 값이 남아 오진을 부른다.

# Node.js 22 + curl(헬스 확인) + git + tzdata(TZ 적용용 zoneinfo)
RUN apt-get update && \
    apt-get install -y curl git ca-certificates tzdata && \
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && \
    apt-get install -y nodejs && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Claude Code 설치 + 실제 설치된 버전을 이미지에 박제(폐쇄망 반입 후 추적용)
RUN if [ "$CLAUDE_VERSION" = "latest" ]; then \
      npm install -g @anthropic-ai/claude-code; \
    else \
      npm install -g "@anthropic-ai/claude-code@${CLAUDE_VERSION}"; \
    fi && \
    npm cache clean --force && \
    claude --version > /etc/claude-code-version && \
    cat /etc/claude-code-version

# ubuntu 유저 (UID/GID 가변, 기본 1000 — 호스트 사용자와 일치 권장)
RUN groupadd -g ${USER_GID} ubuntu && \
    useradd -m -u ${USER_UID} -g ${USER_GID} -s /bin/bash ubuntu && \
    mkdir -p /home/ubuntu/.claude /home/ubuntu/.local/bin && \
    chown -R ubuntu:ubuntu /home/ubuntu

# alias 는 시스템 전체(bash.bashrc)에 둔다 — /home/ubuntu 가 named volume 으로 덮여도 남는다.
RUN echo "alias cc='claude --dangerously-skip-permissions'" >> /etc/bash.bashrc

# ~/.local/bin 선순위 — entrypoint 가 만드는 claude shim(X-Session affinity)이
#   'docker exec <cc> claude' 처럼 셸 미경유 진입에서도 잡히게 한다.
ENV PATH=/home/ubuntu/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

USER ubuntu
WORKDIR /home/ubuntu

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["sleep", "infinity"]
