FROM kalilinux/kali-rolling:latest

ARG KATANA_VERSION=1.5.0
ARG NUCLEI_VERSION=3.7.1
ARG DALFOX_VERSION=2.12.0
ARG CLOUDFOX_VERSION=2.0.1

# 使用官方源
RUN rm -rf /var/lib/apt/lists/* && \
    apt-get clean

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y \
    kali-linux-headless sudo git curl wget unzip jq yq bsdextrautils npm python3-pip \
    file binutils p7zip-full jadx apktool tshark poppler-utils sqlite3 \
    iputils-ping sshpass ncat rlwrap dirsearch naabu nikto netexec adb bloodyad coercer \
    enum4linux-ng pwncat chisel-common-binaries krb5-user gitleaks \
    python3-pwntools \
    build-essential python3-dev libssl-dev libffi-dev \
    cmake ninja-build pkg-config \
    libcapstone-dev libglib2.0-dev && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Quota-aware extraction for project assets. Agents invoke it on demand.
COPY astra-unpack.py /usr/local/bin/astra-unpack
RUN chmod 0755 /usr/local/bin/astra-unpack

# 以 root 用户运行
USER root

# pip 使用官方源
RUN pip3 install --break-system-packages pycryptodome capstone && \
    pip3 install --break-system-packages pymongo tccli awscli && \
    npm config set registry https://registry.npmmirror.com && \
    npm install -g @playwright/cli@latest @openai/codex@0.118.0 \
      @anthropic-ai/claude-code@2.1.98 @mariozechner/pi-coding-agent@0.73.0 && \
    cd /tmp && playwright-cli install

RUN set -eux; cd /tmp; \
    curl -fL --retry 5 --retry-all-errors --connect-timeout 30 "https://github.com/projectdiscovery/katana/releases/download/v${KATANA_VERSION}/katana_${KATANA_VERSION}_linux_amd64.zip" -o katana.zip; \
    curl -fL --retry 5 --retry-all-errors --connect-timeout 30 "https://github.com/projectdiscovery/nuclei/releases/download/v${NUCLEI_VERSION}/nuclei_${NUCLEI_VERSION}_linux_amd64.zip" -o nuclei.zip; \
    curl -fL --retry 5 --retry-all-errors --connect-timeout 30 "https://github.com/hahwul/dalfox/releases/download/v${DALFOX_VERSION}/dalfox-linux-amd64.tar.gz" -o dalfox.tar.gz; \
    curl -fL --retry 5 --retry-all-errors --connect-timeout 30 "https://github.com/BishopFox/cloudfox/releases/download/v${CLOUDFOX_VERSION}/cloudfox-linux-amd64.zip" -o cloudfox.zip; \
    curl -fL --retry 5 --retry-all-errors --connect-timeout 30 "https://github.com/ropnop/kerbrute/releases/download/v1.0.3/kerbrute_linux_amd64" -o kerbrute; \
    unzip -q katana.zip katana; unzip -q nuclei.zip nuclei; tar -xzf dalfox.tar.gz; \
    unzip -q cloudfox.zip cloudfox/cloudfox; \
    install -m 0755 katana nuclei cloudfox/cloudfox kerbrute /usr/local/bin/; \
    install -m 0755 dalfox-linux-amd64 /usr/local/bin/dalfox; \
    rm -rf /tmp/*

RUN mkdir -p /root/.local /root/.config/nuclei && \
    git clone --depth=1 https://github.com/projectdiscovery/nuclei-templates.git /root/.local/nuclei-templates && \
    printf '%s\n' 'disable-update-check: true' \
      'update-template-dir: /root/.local/nuclei-templates' \
      >/root/.config/nuclei/config.yaml

RUN mkdir -p /root/knowledges && cd /root/knowledges && \
    git clone --depth=1 https://github.com/swisskyrepo/PayloadsAllTheThings.git && \
    git clone --depth=1 https://github.com/swisskyrepo/InternalAllTheThings.git && \
    git clone --depth=1 https://github.com/HackTricks-wiki/hacktricks.git && \
    git clone --depth=1 https://github.com/HackTricks-wiki/hacktricks-cloud.git

RUN mkdir -p /root/tools && cd /root/tools && \
    wget -q https://github.com/frohoff/ysoserial/releases/download/v0.0.6/ysoserial-all.jar -O ysoserial.jar && \
    git clone --depth=1 https://github.com/ticarpi/jwt_tool.git && \
    pip3 install --break-system-packages -r jwt_tool/requirements.txt && \
    git clone --depth=1 https://github.com/IOActive/jdwp-shellifier.git

RUN mkdir -p /root/pocs && cd /root/pocs && \
    git clone --depth=1 https://github.com/iSee857/CVE-PoC.git && \
    git clone --depth=1 https://github.com/zhzyker/exphub.git && \
    git clone --depth=1 https://github.com/passwa11/2023Hvv_.git && \
    git clone --depth=1 https://github.com/Threekiii/Awesome-POC.git && \
    git clone --depth=1 https://github.com/vulhub/vulhub.git

RUN cd /tmp && \
    wget -q https://github.com/BurntSushi/ripgrep/releases/download/15.1.0/ripgrep_15.1.0-1_amd64.deb -O ripgrep.deb && \
    wget -q https://github.com/sharkdp/fd/releases/download/v10.4.2/fd_10.4.2_amd64.deb -O fd.deb && \
    apt-get update && apt-get install -y ./ripgrep.deb ./fd.deb && \
    apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* && \
    bash -c "$(curl -fsSL https://aliyuncli.alicdn.com/install.sh)"

RUN rm -rf /usr/lib/llvm-*/build && \
    chmod o+rx /usr/lib/mysql/plugin/auth_pam_tool_dir /etc/ssl/private && \
    mkdir -p /root/workspace && cd /root/workspace && git init

COPY --chown=root:root .agents /root/workspace/.agents
COPY --chown=root:root .agents /root/workspace/.claude
COPY --chown=root:root AGENTS.md /root/workspace/AGENTS.md
COPY --chown=root:root AGENTS.md /root/workspace/CLAUDE.md

ENV TZ=Asia/Shanghai \
    PLAYWRIGHT_MCP_BROWSER=chromium \
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
    PYTHONUNBUFFERED=1

WORKDIR /root/workspace
CMD ["sleep", "infinity"]