# ghcr-proxy — 用 Caddy 反向代理加速 ghcr.io 镜像拉取

用 Caddy 把 `ghcr.io` 的 Docker Registry v2 API 反向代理到本机一个 HTTP 端口，
让 Docker 可以像拉取普通镜像一样从自己的地址拉取 GitHub Container Registry 的镜像。

- 上游：`https://ghcr.io`
- 本地监听：`0.0.0.0:5999`（HTTP）
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

## 一、原理（重要）

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
  `header_down WWW-Authenticate "https://ghcr.io/token" "http://{http.request.hostport}/token"`
- 增加 `/token*` 路由，把 token 请求也转发到 `https://ghcr.io`。
  ghcr.io 的 token 端点会忽略 `service` 参数，因此客户端传 `service=<本代理地址>` 也能正常签发 token。

> `{http.request.hostport}` 必须用 **hostport**（会保留 `:5999`）。
> 用 `{http.request.host}` 会丢掉端口，导致 token 请求发到 `http://<ip>/token`（80 端口）而失败。

---

## 二、构建与运行

### 方式 A：Docker（推荐）

```bash
cd ghcr-proxy
docker build -t ghcr-proxy:latest .

docker run -d --name ghcr-proxy \
  --restart unless-stopped \
  -p 5999:5999 \
  ghcr-proxy:latest
```

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

## 三、客户端配置（关键）

代理是 **HTTP（非 HTTPS）且带非标准端口**，Docker 默认拒绝，必须在**拉取端**配置
`insecure-registries`。

编辑 `/etc/docker/daemon.json`（不存在则新建）：

```json
{
  "insecure-registries": ["134.175.61.80:5999"]
}
```

重启 Docker：

```bash
sudo systemctl restart docker
```

> 如果只想让本机用，也可以用 `127.0.0.1:5999`。
> 不要把 `http://` 前缀写进 `insecure-registries`，只写 `host:port`。

拉取镜像：

```bash
docker pull 134.175.61.80:5999/jcleng/opencode-free-provider:latest

# 重新打回原 tag
docker tag 134.175.61.80:5999/jcleng/opencode-free-provider:latest \
           ghcr.io/jcleng/opencode-free-provider:latest
```

### 不想改 daemon.json 的临时方案

只能走 TLS 才能免配置，所以临时方案是**本机加 hosts + 反代到 443**，成本更高；
最省事的还是上面的 `insecure-registries`。

---

## 四、验证

### 1. 服务是否起来

```bash
curl -i http://127.0.0.1:5999/v2/
```

预期 `401`，且 `WWW-Authenticate` 里的 realm 已指向本代理：

```
HTTP/1.1 401 Unauthorized
Www-Authenticate: Bearer realm="http://127.0.0.1:5999/token",service="ghcr.io",scope="..."
```

### 2. 完整协议链路（token → manifest → blob）

```bash
REPO=jcleng/opencode-free-provider
BASE=http://127.0.0.1:5999

# 拿 token
TOKEN=$(curl -s "$BASE/token?scope=repository:$REPO:pull&service=ghcr.io" \
        | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')

# manifest
curl -sI -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
  "$BASE/v2/$REPO/manifests/latest" | grep -iE 'HTTP/|docker-content-digest'

# blob（用 manifest 里的 digest）
curl -sI -H "Authorization: Bearer $TOKEN" \
  "$BASE/v2/$REPO/blobs/sha256:e2de96513ba9eb53b431787ec8a65cdde380ac4772a3e4c4b714dcfde2a102b5" \
  | grep -iE 'HTTP/|content-length'
```

### 3. 真实拉取

```bash
docker pull 134.175.61.80:5999/jcleng/opencode-free-provider:latest
```

### 4. 网络异常时用代理验证

若本机/容器无法直连外网，通过 HTTP 代理验证（例如 `127.0.0.1:20171`）：

```bash
# curl 走代理
export https_proxy=http://127.0.0.1:20171
export http_proxy=http://127.0.0.1:20171
curl -I https://ghcr.io/v2/
```

给 Docker 守护进程配置代理（拉取时生效）：

```bash
sudo mkdir -p /etc/systemd/system/docker.service.d
sudo tee /etc/systemd/system/docker.service.d/proxy.conf >/dev/null <<'EOF'
[Service]
Environment="HTTP_PROXY=http://127.0.0.1:20171"
Environment="HTTPS_PROXY=http://127.0.0.1:20171"
Environment="NO_PROXY=localhost,127.0.0.1,134.175.61.80"
EOF
sudo systemctl daemon-reload && sudo systemctl restart docker
```

给代理容器本身配置代理（Caddy 容器出网走代理）：

```bash
docker run -d --name ghcr-proxy --restart unless-stopped -p 5999:5999 \
  -e HTTP_PROXY=http://172.17.0.1:20171 \
  -e HTTPS_PROXY=http://172.17.0.1:20171 \
  ghcr-proxy:latest
```

> 容器里 `127.0.0.1` 指向容器自身，要访问宿主机上的代理需用宿主机在 docker 网桥上的地址
> （通常是 `172.17.0.1`，可用 `ip -4 addr show docker0` 确认），或用 `--network host`。

---

## 五、常见问题

| 现象 | 原因 / 解决 |
|---|---|
| `http: server gave HTTP response to HTTPS client` | 客户端没配 `insecure-registries`，见第三节 |
| `dial tcp 127.0.0.1:80: connection refused` | realm 丢端口。确认用 `{http.request.hostport}` 而不是 `{http.request.host}` |
| `502 Bad Gateway` + 日志 `lookup ghcr.io: i/o timeout` | 代理容器出网 DNS/网络不通，给容器或 Docker 配代理，见第四节 4 |
| `401` 且 realm 指向 `https://ghcr.io/token` | 没有做 `header_down` 重写，客户端绕过了代理 |
| `docker pull` 报 `manifest unknown` | 仓库/标签不存在，或私有仓库需要 `docker login ghcr.io` 后使用 |

私有镜像：先在拉取端 `docker login ghcr.io -u <user> -p <token>`，
再 `docker pull <proxy>/<owner>/<repo>:<tag>`；代理会转发 `Authorization` 头，无需在代理侧配置凭据。

---

## 六、可选：加缓存

本配置是纯转发。若想减少重复下载，可在 Caddy 前加一层 registry 缓存
（如 `registry:2` 的 pull-through cache，或 `distribution/distribution`），
或把 Caddy 换成带缓存的镜像代理项目。Caddy 自身也可用 `cache-handler` 插件，
但需要自定义构建（`xcaddy build --with github.com/caddyserver/cache-handler`）。

---

## 七、安全提示

- 该端口是**匿名可用的公网代理**，会暴露你的出口 IP 并消耗带宽，建议加访问控制
  （防火墙白名单 / Caddy `basic_auth` / 反向代理前置鉴权）。
- 仅监听内网时可把 `:5999` 改为 `10.x.x.x:5999` 或配合防火墙。
