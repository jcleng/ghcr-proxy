# ghcr.io 反向代理 —— 基于官方 Caddy 镜像，内置 Caddyfile
#
# 使用 caddy:2.11+ ：2.11 起 Caddy 支持 ACME Profiles，
# 才能为「裸 IP」向 Let's Encrypt 申请公网可信证书（需 shortlived profile）。
FROM caddy:2.11-alpine

# 覆盖默认 Caddyfile（官方镜像默认监听 :80）
COPY Caddyfile /etc/caddy/Caddyfile

# 5999 = Docker Registry 对外端口（HTTPS，证书由 Let's Encrypt 自动签发）
# 80   = ACME http-01 验证（申请裸 IP 证书必须放行，Caddy 自动使用）
# 443  = 备用：ACME tls-alpn-01 验证 / 自动 HTTP->HTTPS 跳转
EXPOSE 5999 80 443

# 官方镜像自带 ENTRYPOINT ["caddy"]，这里显式声明便于阅读
ENTRYPOINT ["caddy"]
CMD ["run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
