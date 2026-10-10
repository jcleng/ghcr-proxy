# ghcr.io 反向代理 —— 基于官方 Caddy 镜像，内置 Caddyfile
FROM caddy:2-alpine

# 覆盖默认 Caddyfile（官方镜像默认监听 :80）
COPY Caddyfile /etc/caddy/Caddyfile

# Docker Registry 端口：5999 = HTTPS（推荐），5998 = HTTP（可选）
EXPOSE 5999 5998

# 官方镜像自带 ENTRYPOINT ["caddy"]，这里显式声明便于阅读
ENTRYPOINT ["caddy"]
CMD ["run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
