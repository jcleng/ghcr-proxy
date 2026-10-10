# AGENTS.md

本文件面向在本仓库工作的 AI 助手/自动化代理，记录项目的关键约定与**镜像构建发布流程**。

---

## 1. 项目是什么

`ghcr-proxy`：用 Caddy 反向代理 `ghcr.io` 的 Docker Registry v2 API，
让 Docker 能从自建地址拉取 GitHub Container Registry 镜像。

- 上游：`https://ghcr.io`
- 对外：`134.175.61.80:5999`（HTTPS）
- 证书：Caddy 内置 ACME 自动向 Let's Encrypt 申请，**不使用自签证书**
- 文件：
  - `Caddyfile` — Caddy 配置（snippet `ghcr_proxy` + 站点定义）
  - `Dockerfile` — 基于 `caddy:2.11-alpine`
  - `README.md` — 面向使用者的完整文档

---

## 2. 硬性约束（改动前必读）

1. **不要用自签证书。** 必须走 ACME 自动签发，客户端零配置。
2. **基础镜像必须 ≥ `caddy:2.11`。** ACME Profiles 是 2.11 才支持的能力；
   为「裸 IP」签发公网证书必须带 `profile shortlived`，降级镜像会直接失败。
3. **裸 IP 证书的两条限制**（Let's Encrypt 政策，无法绕过）：
   - 必须用 `shortlived` profile（有效期约 6 天，Caddy 自动续期）；
   - 只能用 `http-01` / `tls-alpn-01` 验证 → **80 或 443 必须对公网开放**，不能用 DNS 验证。
4. **`/data` 卷必须持久化**（ACME 账户密钥 + 证书）。否则容器重建会重复申请，
   极易触发 Let's Encrypt 速率限制。
5. **realm 重写必须用 `{http.request.hostport}`**，不能用 `{http.request.host}`。
   后者会丢端口，导致 token 请求打到 `:443` 而失败。
6. **必须设置 `default_sni`。** Docker 客户端用 Go `crypto/tls`，对「IP 字面量」
   **不发 SNI**（TLS 规范禁止 SNI 带 IP）。Caddy 收不到 SNI 时会用「连接的本地 IP」
   （容器内是 `172.x.x.x`）匹配证书，匹配不到则握手失败：
   `docker pull → remote error: tls: internal error`。
   **验证时不能只用 curl/openssl**（它们默认带 SNI，会掩盖问题），
   必须用 `openssl s_client -quiet -connect host:port`（不带 `-servername`）或直接 `docker pull`。
7. 本仓库**不需要**客户端改 `docker/daemon.json`，也不需要在拉取端安装 `ca.crt`。
   如果发现文档/配置里又出现这类要求，说明方案退化成了自签，需纠正。

---

## 3. 镜像构建与发布流程

**不要在本地构建镜像。** 统一通过 GitHub Actions 触发远端构建并推送到阿里云镜像仓库。

### 3.1 工作流

- 仓库：`jcleng/action-sync-images`
- 文件：`.github/workflows/build-repo.yml`
- 触发方式：`workflow_dispatch`
- 作用：克隆指定仓库 → `docker build` → 推送到阿里云 → 创建 Release

镜像会被推送到：

```
registry.cn-hangzhou.aliyuncs.com/jcleng/gitbuild-ghcr-proxy:latest
```

> 镜像名规则：`<arg_aliyunuser>/<arg_username>-<arg_name>`，
> 即 `jcleng/gitbuild-ghcr-proxy:latest`。

### 3.2 触发命令

```bash
gh workflow run build-repo.yml -R jcleng/action-sync-images \
  -f arg_repo_url=https://github.com/jcleng/ghcr-proxy.git \
  -f arg_branch_name=main \
  -f arg_username=gitbuild \
  -f arg_name=ghcr-proxy:latest
```

参数说明：

| 参数 | 值 | 说明 |
|---|---|---|
| `arg_repo_url` | `https://github.com/jcleng/ghcr-proxy.git` | 本仓库地址 |
| `arg_branch_name` | `main` | 构建分支 |
| `arg_username` | `gitbuild` | 镜像名前缀 |
| `arg_name` | `ghcr-proxy:latest` | 镜像名 + 标签 |
| `arg_aliyunurl` | `registry.cn-hangzhou.aliyuncs.com` | 默认值，无需传 |
| `arg_aliyunuser` | `jcleng` | 默认值，无需传 |

### 3.3 等待并校验结果

```bash
# 查看最新一次运行
gh run list -R jcleng/action-sync-images --workflow=build-repo.yml -L 1

# 跟踪到结束（--exit-status 失败时返回非 0）
gh run watch <RUN_ID> -R jcleng/action-sync-images --exit-status --interval 15

# 取镜像 digest 作为构建成功的证据
gh run view <RUN_ID> -R jcleng/action-sync-images --log 2>/dev/null \
  | grep -E "digest: sha256"
```

**验证标准**：运行状态为 `success`，且日志里出现 `latest: digest: sha256:...`。
在向用户汇报「构建成功」前，必须确认这两点。

### 3.4 网络异常时使用代理

访问 GitHub API 失败（如 `TLS handshake timeout`）时，为 `gh` 加代理：

```bash
export https_proxy=http://127.0.0.1:20171
export http_proxy=http://127.0.0.1:20171
```

`git push` 同理需要该代理。

### 3.5 完整发布流程

```bash
cd /home/jcleng/work/mywork/ghcr-proxy
export https_proxy=http://127.0.0.1:20171 http_proxy=http://127.0.0.1:20171

git add -A && git commit -m "<描述>"
git push origin main

gh workflow run build-repo.yml -R jcleng/action-sync-images \
  -f arg_repo_url=https://github.com/jcleng/ghcr-proxy.git \
  -f arg_branch_name=main \
  -f arg_username=gitbuild \
  -f arg_name=ghcr-proxy:latest

sleep 10
gh run list -R jcleng/action-sync-images --workflow=build-repo.yml -L 1
```

> 工作流克隆的是**远端 main 分支**，所以**必须先 push 再触发**，
> 否则构建的是旧代码。

---

## 4. 线上部署与验证（由使用者执行）

```bash
docker run -d --name ghcr-proxy --restart unless-stopped \
  -p 80:80 -p 443:443 -p 5999:5999 \
  -v ghcr-proxy-data:/data \
  registry.cn-hangzhou.aliyuncs.com/jcleng/gitbuild-ghcr-proxy:latest
```

验证证书确实来自公网 CA（而非 `Caddy Local Authority`）：

```bash
echo | openssl s_client -connect 134.175.61.80:5999 -servername 134.175.61.80 2>/dev/null \
  | openssl x509 -noout -issuer
```

**必须额外验证无 SNI 场景**（Docker 的真实行为，见第 2 节约束 6）：

```bash
printf 'GET /v2/ HTTP/1.1\r\nHost: 134.175.61.80:5999\r\nConnection: close\r\n\r\n' \
  | openssl s_client -quiet -connect 134.175.61.80:5999 2>/dev/null | head -1
# 期望 HTTP/1.1 401；若报 tlsv1 alert internal error，则 default_sni 未生效
```

验证协议链路：

```bash
curl -i https://134.175.61.80:5999/v2/          # 期望 401，realm 指向本代理
docker pull 134.175.61.80:5999/jcleng/opencode-free-provider:latest
```

调试期可先用 Let's Encrypt staging 避免生产速率限制
（`-e ACME_CA=https://acme-staging-v02.api.letsencrypt.org/directory`），
但 staging 证书**不被 Docker 信任**。

**切回生产环境时必须删除 `/data` 卷**（`docker volume rm ghcr-proxy-data`），
否则 Caddy 存储里已有 staging 证书，会直接复用而**不会**重新申请。

### 速率限制要点（不要删卷重建）

- 「New Certificates per Exact Set of Identifiers」= **5 次 / 7 天**，全局计算、不区分账户。
- **ARI 续期豁免所有速率限制**，Caddy 2.11 默认走 ARI，所以 6 天证书长期运行不会撞限。
- 因此正确做法是：**持久化 `/data` 卷，让 Caddy 自行续期**。
  反复删卷重建 = 每次都算全新订单，7 天内 5 次就满。

---

## 5. 提交约定

- 提交信息用中文描述性语句，说明**改了什么、为什么**。
- 涉及证书方案的改动，必须在提交信息中说明对「自签 / ACME」「80/443 端口」「Caddy 版本」的影响。
- 不要在仓库中提交任何私钥、token 或证书文件。
- `.dockerignore` 已排除 `*.md`，文档不会进入构建上下文。
