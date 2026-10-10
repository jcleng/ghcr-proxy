# ghcr-proxy — 用 Caddy 反向代理加速 ghcr.io 镜像拉取

用 Caddy 把 `ghcr.io` 的 Docker Registry v2 API 反向代理到本机端口，
让 Docker 可以像拉取普通镜像一样从自己的地址拉取 GitHub Container Registry 的镜像。

- 上游：`https://ghcr.io`
- 对外端口：`134.175.61.80:5999`（HTTPS）
- **证书：由 Caddy 自动向 Let's Encrypt 申请，无需自签、无需客户端装 CA**
- 映射关系：

  | 原始地址 | 代理地址 |
  |---|---|
  | `ghcr.io/jcleng/opencode-free-provider:latest` | `134.175.61.80:5999/jcleng/opencode-free-provider:latest` |

> 代理只是**转发**，不缓存镜像层。首次拉取仍会从 ghcr.io 下载。

---

## 目录结构

```
ghcr-proxy/
├── Caddyfile       # Caddy 配置（含 ACME 自动签发）
├── Dockerfile      # 基于 caddy:2.11-alpine 构建
├── .dockerignore
└── README.md
```

---

## 一、证书方案：自动申请，不自签

`docker pull` 默认只信任 HTTPS 仓库，所以代理必须提供 TLS。本项目**不使用自签证书**，
而是让 Caddy 内置的 ACME 客户端自动向 **Let's Encrypt** 申请证书，Docker 客户端开箱即信。

Caddy 的自动 HTTPS 是内置能力，不需要装任何插件：只要站点地址是域名或 IP，
Caddy 就会自动完成「申请 → 安装 → 到期前自动续期」全流程。

### 关于「裸 IP」证书的限制（重要）

为**裸 IP**（而不是域名）签发证书是 Let's Encrypt 2025 年才 GA 的新能力，有两条硬性要求：

1. **必须使用 `shortlived` profile** —— 证书有效期只有约 6 天（Caddy 会自动续期，无需人工干预）。
   本仓库 Caddyfile 已配置：
   ```caddyfile
   tls {
       issuer acme {
           profile shortlived
       }
   }
   ```
2. **只能用 `http-01` 或 `tls-alpn-01` 验证** —— 即服务器的 **80 或 443 端口必须对公网开放**
   （无法用 DNS 验证来证明你拥有一个 IP）。

因此容器需要同时映射 **80** 与 **443**（供 ACME 验证），以及 **5999**（镜像拉取）：

```bash
docker run -d --name ghcr-proxy --restart unless-stopped \
  -p 80:80 -p 443:443 -p 5999:5999 \
  -v ghcr-proxy-data:/data \
  ghcr-proxy:latest
```

> `-v ghcr-proxy-data:/data` 用来持久化 ACME 账户密钥与已签发证书。
> **必须持久化**，否则容器每次重建都要重新申请证书，容易触发 Let's Encrypt 速率限制。

### 有域名的话更简单（推荐）

如果你有域名（例如 `ghcr.example.com`）指向本机，就完全没有上面这些限制，
拿到的是标准 90 天证书，且不需要开放 80/443：

1. 域名 A 记录指向服务器；
2. Caddyfile 把站点地址换成域名，并删掉整个 `tls { ... }` 块：

   ```caddyfile
   ghcr.example.com {
       import ghcr_proxy
   }
   ```

3. 客户端直接 `docker pull ghcr.example.com/jcleng/opencode-free-provider:latest`。

---

## 二、原理（重要）

Docker 拉取镜像分两步：

1. **请求 manifest**：`GET /v2/<owner>/<repo>/manifests/<tag>`
   未认证时上游返回 `401`，并带上：

   ```
   WWW-Authenticate: Bearer realm="https://ghcr.io/token",service="ghcr.io",scope="repository:...:pull"
   ```

2. **拿 token 再重试**：客户端根据 `realm` 请求 `https://ghcr.io/token?...` 拿到 Bearer Token，
   再带 `Authorization` 重新请求 manifest / blob。

如果只做透明反代，客户端会**绕过代理直接访问 ghcr.io**，在无法直连的网络里就会失败。
因此 Caddyfile 做了两件事：

- 把响应头里的 realm 重写为本代理地址：
  `header_down WWW-Authenticate "https://ghcr.io/token" "{http.request.scheme}://{http.request.hostport}/token"`
- 增加 `/token*` 路由，把 token 请求也转发到 `https://ghcr.io`。
  ghcr.io 的 token 端点会忽略 `service` 参数，因此客户端传 `service=<本代理地址>` 也能正常签发 token。

> 必须用 **hostport**（保留 `:5999`）。用 `{http.request.host}` 会丢端口，
> 导致 token 请求发到 `https://<ip>/token`（443 端口）而失败。

---

## 三、构建与运行

### 方式 A：Docker（推荐）

```bash
cd ghcr-proxy
docker build -t ghcr-proxy:latest .

docker run -d --name ghcr-proxy \
  --restart unless-stopped \
  -p 80:80 -p 443:443 -p 5999:5999 \
  -v ghcr-proxy-data:/data \
  ghcr-proxy:latest
```

查看日志（首次启动会看到 ACME 申请过程）：

```bash
docker logs -f ghcr-proxy
```

正常会看到类似：

```
"msg":"obtaining certificate","identifier":"134.175.61.80"
"msg":"certificate obtained successfully","identifier":"134.175.61.80"
```

### 方式 B：本机 caddy 二进制

需要 **Caddy ≥ 2.11**（支持 ACME profile）：

```bash
caddy run --config ./Caddyfile --adapter caddyfile
```

后台运行（示例 systemd unit）：

```ini
# /etc/systemd/system/ghcr-proxy.service
[Unit]
Description=Caddy ghcr.io pull-through proxy
After=network-online.target

[Service]
ExecStart=/usr/local/bin/caddy run --config /opt/ghcr-proxy/Caddyfile --adapter caddyfile
Restart=always

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now ghcr-proxy
```

---

## 四、客户端配置

**无需任何配置**。证书由公网 CA 签发，Docker 原生信任：

```bash
docker pull 134.175.61.80:5999/jcleng/opencode-free-provider:latest

# 重新打回原 tag
docker tag 134.175.61.80:5999/jcleng/opencode-free-provider:latest \
           ghcr.io/jcleng/opencode-free-provider:latest
```

不需要 `ca.crt`，不需要改 `daemon.json`。

---

## 五、可配置的环境变量

| 变量 | 默认值 | 说明 |
|---|---|---|
| `SITE_ADDR` | `134.175.61.80:5999` | 站点地址。改成域名即切换为域名证书 |
| `ACME_EMAIL` | `j.c.leng@foxmail.com` | ACME 账户邮箱，用于到期提醒/找回 |
| `ACME_CA` | Let's Encrypt 生产 | 改成 `https://acme-staging-v02.api.letsencrypt.org/directory` 可先用测试环境调试 |
| `ACME_PROFILE` | `shortlived` | 裸 IP 必须用 `shortlived`；用域名时应删除 tls 块而非改此项 |

示例（先用 staging 试，避免生产速率限制）：

```bash
docker run -d --name ghcr-proxy --restart unless-stopped \
  -p 80:80 -p 443:443 -p 5999:5999 \
  -v ghcr-proxy-data:/data \
  -e ACME_CA=https://acme-staging-v02.api.letsencrypt.org/directory \
  registry.cn-hangzhou.aliyuncs.com/jcleng/gitbuild-ghcr-proxy:latest
```

> 注意：staging 签发的证书**不被 Docker 信任**（浏览器/客户端会报 unknown authority）。
> 只在调试时用。**切换到生产环境时必须删掉 `/data` 卷**，否则 Caddy 会认为证书已存在
> 而继续复用 staging 证书，不会重新申请（详见第七节「切换到生产环境」）。

### 关于速率限制（`shortlived` 特别重要）

裸 IP 证书有效期只有约 6 天，续期频繁，因此必须理解 Let's Encrypt 的限制：

| 限制 | 额度 | 说明 |
|---|---|---|
| New Certificates per Exact Set of Identifiers | 5 次 / 7 天 | **同一组标识符**（如 `[134.175.61.80]`）签发的证书数，全局计算、不区分账户 |
| New Orders per Account | 300 次 / 3 小时 | 账户级 |

好消息是**续期不计入限制**：

- **ARI 续期（Caddy 默认走这条）**：Caddy 2.11 支持 ACME Renewal Info，会按 CA 给出的最优时间窗续期。
  **ARI 续期豁免所有速率限制**，因此 6 天证书长期运行不会撞限。
- 所以只要**保持 `/data` 卷持久化、让 Caddy 自己按 ARI 续期**，就不用担心速率限制。

真正会撞限的是「反复删除 `/data` 卷重新申请」——每次都是全新订单而非续期，7 天内 5 次就打满。
这也正是上面强调 staging 调试后要删卷、而生产环境不要随意删卷的原因。

---

## 六、从 staging 切换到生产环境（重要，容易踩坑）

先用 staging 验证流程是推荐做法。但**切换到生产环境时必须删掉 `/data` 卷**：

```bash
# 1) 停掉并删除容器
docker rm -f ghcr-proxy

# 2) 删除持久化卷（丢弃 staging 账户与证书）
docker volume rm ghcr-proxy-data

# 3) 不加 ACME_CA，重新启动 → 会向生产环境申请
#    注意：Caddy 的存储里若已有 staging 证书，它会直接复用、不会重新申请，
#    所以第 2 步不能省。
docker run -d --name ghcr-proxy --restart unless-stopped \
  -p 80:80 -p 443:443 -p 5999:5999 \
  -v ghcr-proxy-data:/data \
  registry.cn-hangzhou.aliyuncs.com/jcleng/gitbuild-ghcr-proxy:latest

# 4) 确认 issuer 已是生产 CA
docker logs -f ghcr-proxy | grep -iE "obtaining certificate|certificate obtained|acme-v02|staging"
```

预期日志中的 URL 由 `acme-staging-v02.api.letsencrypt.org` 变为 `acme-v02.api.letsencrypt.org`：

```
"msg":"certificate obtained successfully","identifier":"134.175.61.80",
"issuer":"acme-v02.api.letsencrypt.org-directory"
```

> `issuer` 后缀是 `-directory` 是正常现象（Caddy 用目录 URL 的主机名标识 issuer），
> 只要主机名是 `acme-v02.api.letsencrypt.org` 就说明拿到的是生产证书。

> 删卷会消耗一次「5 次 / 7 天」额度。若已多次删卷重建，可先查额度用量：
> <https://crt.sh/?q=134.175.61.80>

---

## 七、验证

### 1. 证书是否已由公网 CA 签发

```bash
echo | openssl s_client -connect 134.175.61.80:5999 -servername 134.175.61.80 2>/dev/null \
  | openssl x509 -noout -issuer -ext subjectAltName
```

预期 issuer 是 Let's Encrypt（而不是 `Caddy Local Authority`）：

```
issuer=C = US, O = Let's Encrypt, CN = R1x
X509v3 Subject Alternative Name:
    IP Address:134.175.61.80
```

### 2. 服务是否起来

```bash
curl -i https://134.175.61.80:5999/v2/
```

预期 `401`，且 `WWW-Authenticate` 的 realm 指向本代理：

```
HTTP/2 401
www-authenticate: Bearer realm="https://134.175.61.80:5999/token",service="ghcr.io",scope="..."
```

### 3. 完整协议链路（token → manifest → blob）

```bash
REPO=jcleng/opencode-free-provider
BASE=https://134.175.61.80:5999

TOKEN=$(curl -s "$BASE/token?scope=repository:$REPO:pull&service=ghcr.io" \
        | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')

curl -sI -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
  "$BASE/v2/$REPO/manifests/latest" | grep -iE 'HTTP/|docker-content-digest'
```

### 4. 真实拉取

```bash
docker pull 134.175.61.80/jcleng/opencode-free-provider:latest
```

---

## 八、常见问题

| 现象 | 原因 / 解决 |
|---|---|
| 日志 `subject '...' does not qualify for a public certificate` | 该地址是内网/保留 IP，公网 CA 无法签发。只能用域名或公网 IP |
| 日志 `cannot have public IP certificate` | Caddy 版本 < 2.11，或 profile 未设为 `shortlived` |
| 日志 `unable to get ACME profile ... not advertised` | ACME 服务器不支持 profiles。确认用的是 Let's Encrypt，或升级 Caddy |
| ACME 一直失败 / 超时 | 80、443 端口没对公网放行（安全组/防火墙）。裸 IP 证书只能用 http-01/tls-alpn-01 验证 |
| `too many certificates already issued` | 触发 LE 速率限制（5 次 / 7 天 / 同一组标识符）。改用 staging 调试；**务必持久化 `/data` 卷**，让 Caddy 走 ARI 续期（豁免限流）。注意删卷重建=全新订单，会消耗额度 |
| `x509: certificate signed by unknown authority` | 证书是自签或 staging 签发的。确认 issuer 是 Let's Encrypt 生产 CA |
| `http: server gave HTTP response to HTTPS client` | 客户端访问的是 HTTP 端口，改用 `https://` + 5999 |
| `dial tcp 127.0.0.1:443: connection refused` | realm 丢端口。确认用 `{http.request.hostport}` |
| `502 Bad Gateway` + `lookup ghcr.io: i/o timeout` | 代理容器出网不通，见第八节 |
| `docker pull` 报 `manifest unknown` | 仓库/标签不存在，或私有仓库需 `docker login ghcr.io` |

私有镜像：先在拉取端 `docker login ghcr.io -u <user> -p <token>`，再拉取；
代理会转发 `Authorization` 头，无需在代理侧配置凭据。

---

## 九、网络异常时让代理走上游代理

若代理容器无法直连外网（日志出现 `lookup ghcr.io: i/o timeout`、`502`），
Caddy 的 `reverse_proxy` 默认不读 `HTTP_PROXY` 环境变量，需要显式配置：

```caddyfile
reverse_proxy https://ghcr.io {
    header_up Host ghcr.io
    transport http {
        proxy http://172.17.0.1:20171
    }
}
```

> 容器里 `127.0.0.1` 指向容器自身，访问宿主机代理需用 docker0 网桥地址
> （通常 `172.17.0.1`，用 `ip -4 addr show docker0` 确认）。

---

## 附录 A：可选：加缓存

本配置是纯转发。若想减少重复下载，可在 Caddy 前加一层 registry 缓存
（如 `registry:2` 的 pull-through cache），或使用带缓存的镜像代理项目。
Caddy 自身也可用 `cache-handler` 插件，但需要自定义构建。

---

## 附录 B：安全提示

- 该端口是**匿名可用的公网代理**，会暴露出口 IP 并消耗带宽，建议加访问控制
  （防火墙白名单 / Caddy `basic_auth` / 前置鉴权）。
- 仅监听内网时可把站点地址改为内网地址（但内网 IP 无法申请公网证书）。
- ACME 账户私钥与证书存放在 `/data` 卷，注意卷的访问权限。
