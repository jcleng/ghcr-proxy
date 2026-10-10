# ghcr-proxy — 用 Caddy 反向代理加速 ghcr.io 镜像拉取

用 Caddy 把 `ghcr.io` 的 Docker Registry v2 API 反向代理到本机端口，
让 Docker 可以像拉取普通镜像一样从自己的地址拉取 GitHub Container Registry 的镜像。

- 上游：`https://ghcr.io`
- 默认监听：
  - **`134.175.61.80:5999`（HTTPS，推荐）** — Docker 默认走 HTTPS，无需改 `daemon.json`
  - `:5998`（HTTP，可选）— 仅供已配置 `insecure-registries` 的客户端
- 映射关系：

  | 原始地址 | 代理地址 |
  |---|---|
  | `ghcr.io/jcleng/opencode-free-provider:latest` | `134.175.61.80:5999/jcleng/opencode-free-provider:latest` |

> 注意：代理只是**转发**，不会缓存镜像层，也不改变镜像内容；
> 首次拉取仍会从 ghcr.io 下载。若需要缓存，请参考文末「可选：加缓存」。

---

## 目录结构

```
ghcr-proxy/
├── Caddyfile       # Caddy 配置
├── Dockerfile      # 基于 caddy:2-alpine 构建
├── .dockerignore
└── README.md
```

---

## 一、为什么必须用 HTTPS（重要）

Docker 客户端**默认只信任 HTTPS 仓库**。如果代理只提供 HTTP，`docker pull` 会直接报：

```
Error response from daemon: Get "https://134.175.61.80:5999/v2/":
http: server gave HTTP response to HTTPS client
```

绕开它有两条路：

| 方案 | 客户端需要做什么 | 说明 |
|---|---|---|
| **A. 代理上 TLS（本仓库默认）** | 安装 CA 证书（或换真实域名） | 不用改 `daemon.json` |
| B. 代理只走 HTTP | 改 `daemon.json` 加 `insecure-registries` | 需重启 Docker，见附录 |

本仓库默认走 **A**：`5999` 端口由 Caddy 用内置 CA 签发自签证书提供 HTTPS，
客户端只要把 CA 证书放到 `/etc/docker/certs.d/<host:port>/ca.crt` 即可。

如果你有真实域名（例如 `ghcr.example.com`），把 Caddyfile 里的 `tls internal` 删掉、
站点地址改成域名，Caddy 会自动申请 Let's Encrypt 证书，**客户端零配置**。

---

## 二、原理（重要）

Docker 拉取镜像的流程分两步：

1. **请求 manifest**：`GET /v2/<owner>/<repo>/manifests/<tag>`
   未认证时上游返回 `401`，并带上：

   ```
   WWW-Authenticate: Bearer realm="https://ghcr.io/token",service="ghcr.io",scope="repository:...:pull"
   ```

2. **拿 token 再重试**：客户端根据 `realm` 去请求 `https://ghcr.io/token?...` 拿到 Bearer Token，
   再带 `Authorization` 重新请求 manifest / blob。

所以如果只做透明反代，客户端拿到 `realm="https://ghcr.io/token"` 后会**绕过代理直接访问 ghcr.io**，
在无法直连的网络里就会失败。因此 Caddyfile 里做了两件关键事：

- 把响应头里的 realm 重写为本代理地址：
  `header_down WWW-Authenticate "https://ghcr.io/token" "{http.request.scheme}://{http.request.hostport}/token"`
- 增加 `/token*` 路由，把 token 请求也转发到 `https://ghcr.io`。
  ghcr.io 的 token 端点会忽略 `service` 参数，因此客户端传 `service=<本代理地址>` 也能正常签发 token。

> 必须用 **hostport**（会保留 `:5999`）。用 `{http.request.host}` 会丢掉端口，
> 导致 token 请求发到 `https://<ip>/token`（443 端口）而失败。
> 用 `{http.request.scheme}` 则让 HTTP/HTTPS 两个端口都能正确回写 realm。

---

## 三、构建与运行

### 方式 A：Docker（推荐）

```bash
cd ghcr-proxy
docker build -t ghcr-proxy:latest .

docker run -d --name ghcr-proxy \
  --restart unless-stopped \
  -p 5999:5999 \
  -p 5998:5998 \
  -v ghcr-proxy-data:/data \
  ghcr-proxy:latest
```

`-v ghcr-proxy-data:/data` 用来持久化 Caddy 的 CA 与证书
（CA 证书路径：容器内 `/data/caddy/pki/authorities/local/root.crt`）。

查看日志：

```bash
docker logs -f ghcr-proxy
```

### 方式 B：本机 caddy 二进制

```bash
caddy run --config ./Caddyfile --adapter caddyfile
```

后台运行（示例 systemd unit，按需调整路径）：

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

## 四、客户端配置（关键）

### 1. 导出 CA 证书

```bash
# 从容器里拷出来
docker cp ghcr-proxy:/data/caddy/pki/authorities/local/root.crt ./ghcr-proxy-ca.crt

# 若用 caddy 二进制，直接取文件
# cp $HOME/.local/share/caddy/pki/authorities/local/root.crt ./ghcr-proxy-ca.crt
```

### 2. 安装到拉取端 Docker

```bash
sudo mkdir -p /etc/docker/certs.d/134.175.61.80:5999
sudo cp ghcr-proxy-ca.crt /etc/docker/certs.d/134.175.61.80:5999/ca.crt
```

> 目录名必须和 `docker pull` 里写的 **host:port 完全一致**。
> 用 IP 拉取就写 IP，用域名拉取就写域名。**不需要重启 Docker**，Docker 每次拉取会重新读取该目录。

### 3. 拉取镜像

```bash
docker pull 134.175.61.80:5999/jcleng/opencode-free-provider:latest

# 重新打回原 tag
docker tag 134.175.61.80:5999/jcleng/opencode-free-provider:latest \
           ghcr.io/jcleng/opencode-free-provider:latest
```

### 4. 可选：让宿主机/客户端也信任（curl、containerd 等）

```bash
sudo cp ghcr-proxy-ca.crt /usr/local/share/ca-certificates/ghcr-proxy.crt
sudo update-ca-certificates        # Debian/Ubuntu
# sudo update-ca-trust             # RHEL/Fedora
```

---

## 五、验证

### 1. 服务是否起来

```bash
curl -i --cacert ghcr-proxy-ca.crt https://134.175.61.80:5999/v2/
```

预期 `401`，且 `WWW-Authenticate` 里的 realm 已指向本代理：

```
HTTP/2 401
www-authenticate: Bearer realm="https://134.175.61.80:5999/token",service="ghcr.io",scope="..."
```

### 2. 完整协议链路（token → manifest → blob）

```bash
REPO=jcleng/opencode-free-provider
BASE=https://134.175.61.80:5999
CA=./ghcr-proxy-ca.crt

# 拿 token
TOKEN=$(curl -s --cacert $CA "$BASE/token?scope=repository:$REPO:pull&service=ghcr.io" \
        | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')

# manifest
curl -sI --cacert $CA -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
  "$BASE/v2/$REPO/manifests/latest" | grep -iE 'HTTP/|docker-content-digest'

# blob（用 manifest 里的 digest）
curl -sI --cacert $CA -H "Authorization: Bearer $TOKEN" \
  "$BASE/v2/$REPO/blobs/sha256:e2de96513ba9eb53b431787ec8a65cdde380ac4772a3e4c4b714dcfde2a102b5" \
  | grep -iE 'HTTP/|content-length'
```

### 3. 真实拉取

```bash
docker pull 134.175.61.80:5999/jcleng/opencode-free-provider:latest
```

### 4. 网络异常时让代理容器走上游代理

若代理容器无法直连外网（日志里出现 `lookup ghcr.io: i/o timeout`、`502 Bad Gateway`），
给代理容器本身加代理环境变量：

```bash
docker run -d --name ghcr-proxy --restart unless-stopped -p 5999:5999 -p 5998:5998 \
  -v ghcr-proxy-data:/data \
  -e HTTP_PROXY=http://172.17.0.1:20171 \
  -e HTTPS_PROXY=http://172.17.0.1:20171 \
  ghcr-proxy:latest
```

> 容器里 `127.0.0.1` 指向容器自身，要访问宿主机上的代理需用宿主机在 docker 网桥上的地址
> （通常是 `172.17.0.1`，可用 `ip -4 addr show docker0` 确认），或用 `--network host`。

Caddy 的 `reverse_proxy` 默认不读 `HTTP_PROXY` 环境变量，
需要显式配置时才生效（本仓库默认不配置，因为多数场景下代理与 ghcr.io 直连正常）：

```caddyfile
reverse_proxy https://ghcr.io {
    header_up Host ghcr.io
    transport http {
        proxy http://172.17.0.1:20171
    }
}
```

---

## 六、常见问题

| 现象 | 原因 / 解决 |
|---|---|
| `http: server gave HTTP response to HTTPS client` | 拉取的是 HTTP 端口或代理没启用 TLS。用 `5999`（HTTPS）并按第四节装 CA 证书 |
| `x509: certificate signed by unknown authority` | 没装 CA 证书，或 `/etc/docker/certs.d/<host:port>` 目录名与拉取地址不一致 |
| `x509: certificate is valid for X, not Y` | 证书 SAN 不含你用的地址。用 Caddyfile 里 `SITE_ADDR` 配置的那个地址拉取 |
| `dial tcp 127.0.0.1:443: connection refused` | realm 丢端口。确认用 `{http.request.hostport}` 而不是 `{http.request.host}` |
| `502 Bad Gateway` + 日志 `lookup ghcr.io: i/o timeout` | 代理容器出网 DNS/网络不通，给容器加代理，见第五节 4 |
| `401` 且 realm 指向 `https://ghcr.io/token` | 没有做 `header_down` 重写，客户端绕过了代理 |
| `docker pull` 报 `manifest unknown` | 仓库/标签不存在，或私有仓库需要 `docker login ghcr.io` 后使用 |

私有镜像：先在拉取端 `docker login ghcr.io -u <user> -p <token>`，
再 `docker pull <proxy>/<owner>/<repo>:<tag>`；代理会转发 `Authorization` 头，无需在代理侧配置凭据。

---

## 附录 A：改 `daemon.json` 的 HTTP 方案（不推荐）

如果坚持用 HTTP（`5998` 端口）且不想装 CA 证书，必须在**拉取端**配置 `insecure-registries`：

```json
{
  "insecure-registries": ["134.175.61.80:5998"]
}
```

```bash
sudo systemctl restart docker
docker pull 134.175.61.80:5998/jcleng/opencode-free-provider:latest
```

> 不要把 `http://` 前缀写进 `insecure-registries`，只写 `host:port`。

---

## 附录 B：换真实域名（客户端零配置）

1. 域名 A 记录指向服务器；
2. Caddyfile 把站点地址改成域名并去掉 `tls internal`：

   ```caddyfile
   ghcr.example.com {
       import ghcr_proxy
   }
   ```

3. 放行 80/443（Caddy 自动申请 Let's Encrypt 证书）；
4. 客户端直接 `docker pull ghcr.example.com/jcleng/opencode-free-provider:latest`，
   无需任何证书或 `daemon.json` 配置。

---

## 附录 C：可选：加缓存

本配置是纯转发。若想减少重复下载，可在 Caddy 前加一层 registry 缓存
（如 `registry:2` 的 pull-through cache，或 `distribution/distribution`），
或把 Caddy 换成带缓存的镜像代理项目。Caddy 自身也可用 `cache-handler` 插件，
但需要自定义构建（`xcaddy build --with github.com/caddyserver/cache-handler`）。

---

## 附录 D：安全提示

- 该端口是**匿名可用的公网代理**，会暴露你的出口 IP 并消耗带宽，建议加访问控制
  （防火墙白名单 / Caddy `basic_auth` / 反向代理前置鉴权）。
- 仅监听内网时可把站点地址改为 `10.x.x.x:5999` 或配合防火墙。
- 自签 CA 的私钥在容器 `/data` 卷里，注意卷的访问权限；换真实域名后建议删除该 CA。
