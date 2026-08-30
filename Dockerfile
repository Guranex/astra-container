FROM kalilinux/kali-rolling:latest

ARG KATANA_VERSION=1.5.0
ARG NUCLEI_VERSION=3.7.1
ARG DALFOX_VERSION=2.12.0
ARG CLOUDFOX_VERSION=2.0.1

# 彻底清理并更换为阿里云源
RUN rm -rf /var/lib/apt/lists/* && \
    echo "deb http://mirrors.aliyun.com/kali kali-rolling main non-free contrib" > /etc/apt/sources.list && \
    echo "deb-src http://mirrors.aliyun.com/kali kali-rolling main non-free contrib" >> /etc/apt/sources.list && \
    apt-get clean

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y \
    kali-linux-headless sudo git curl wget unzip jq yq bsdextrautils npm python3-pip \
    file binutils p7zip-full jadx apktool tshark poppler-utils sqlite3 \
    iputils-ping sshpass ncat rlwrap dirsearch naabu nikto netexec adb bloodyad coercer \
    enum4linux-ng pwncat chisel-common-binaries krb5-user gitleaks && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Quota-aware extraction for project assets. Agents invoke it on demand.
COPY astra-unpack.py /usr/local/bin/astra-unpack
RUN chmod 0755 /usr/local/bin/astra-unpack

RUN useradd --create-home --shell /bin/bash kali && \
    printf '%s\n' 'kali ALL=(ALL) NOPASSWD:ALL' >/etc/sudoers.d/kali

USER kali

# pip 换源
RUN pip3 config set global.index-url https://pypi.tuna.tsinghua.edu.cn/simple && \
    pip3 install --break-system-packages pwntools pymongo tccli awscli && \
    sudo npm config set registry https://registry.npmmirror.com && \
    sudo npm install -g @playwright/cli@latest @openai/codex@0.118.0 \
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
    sudo install -m 0755 katana nuclei cloudfox/cloudfox kerbrute /usr/local/bin/; \
    sudo install -m 0755 dalfox-linux-amd64 /usr/local/bin/dalfox; \
    sudo rm -rf /tmp/*

RUN mkdir -p /home/kali/.local /home/kali/.config/nuclei && \
    git clone --depth=1 https://github.com/projectdiscovery/nuclei-templates.git /home/kali/.local/nuclei-templates && \
    printf '%s\n' 'disable-update-check: true' \
      'update-template-dir: /home/kali/.local/nuclei-templates' \
      >/home/kali/.config/nuclei/config.yaml

RUN mkdir -p /home/kali/knowledges && cd /home/kali/knowledges && \
    git clone --depth=1 https://github.com/swisskyrepo/PayloadsAllTheThings.git && \
    git clone --depth=1 https://github.com/swisskyrepo/InternalAllTheThings.git && \
    git clone --depth=1 https://github.com/HackTricks-wiki/hacktricks.git && \
    git clone --depth=1 https://github.com/HackTricks-wiki/hacktricks-cloud.git

RUN mkdir -p /home/kali/tools && cd /home/kali/tools && \
    wget -q https://github.com/frohoff/ysoserial/releases/download/v0.0.6/ysoserial-all.jar -O ysoserial.jar && \
    git clone --depth=1 https://github.com/ticarpi/jwt_tool.git && \
    pip3 install --break-system-packages -r jwt_tool/requirements.txt && \
    git clone --depth=1 https://github.com/IOActive/jdwp-shellifier.git

RUN mkdir -p /home/kali/pocs && cd /home/kali/pocs && \
    git clone --depth=1 https://github.com/iSee857/CVE-PoC.git && \
    git clone --depth=1 https://github.com/zhzyker/exphub.git && \
    git clone --depth=1 https://github.com/passwa11/2023Hvv_.git && \
    git clone --depth=1 https://github.com/Threekiii/Awesome-POC.git && \
    git clone --depth=1 https://github.com/vulhub/vulhub.git

RUN cd /tmp && \
    wget -q https://github.com/BurntSushi/ripgrep/releases/download/15.1.0/ripgrep_15.1.0-1_amd64.deb -O ripgrep.deb && \
    wget -q https://github.com/sharkdp/fd/releases/download/v10.4.2/fd_10.4.2_amd64.deb -O fd.deb && \
    sudo apt-get update && sudo apt-get install -y ./ripgrep.deb ./fd.deb && \
    sudo apt-get clean && sudo rm -rf /var/lib/apt/lists/* /tmp/* && \
    sudo bash -c "$(curl -fsSL https://aliyuncli.alicdn.com/install.sh)"

RUN sudo rm -rf /usr/lib/llvm-*/build && \
    sudo chmod o+rx /usr/lib/mysql/plugin/auth_pam_tool_dir /etc/ssl/private && \
    mkdir -p /home/kali/workspace && cd /home/kali/workspace && git init

COPY --chown=kali:kali .agents /home/kali/workspace/.agents
COPY --chown=kali:kali .agents /home/kali/workspace/.claude
COPY --chown=kali:kali AGENTS.md /home/kali/workspace/AGENTS.md
COPY --chown=kali:kali AGENTS.md /home/kali/workspace/CLAUDE.md

ENV TZ=Asia/Shanghai \
    PLAYWRIGHT_MCP_BROWSER=chromium \
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
    PYTHONUNBUFFERED=1

WORKDIR /home/kali/workspace
CMD ["sleep", "infinity"]
