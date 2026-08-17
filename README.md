# naivereal-linux-deploy

Linux 服务端一键部署脚本，用于部署 [naivereal](https://github.com/lipeiying032/naive-reality) 服务端组件：

- 官方 naive 内核（作为本地后端）
- REALITY 前端（H2 REALITY 模式）
- H3 frontend（QUIC/HTTP3 CONNECT 模式）

## 使用方法

```bash
sudo bash install.sh \
  --domain your.domain.com \
  --reality-target www.microsoft.com \
  --reality-sni www.microsoft.com
```

参数说明：

| 参数 | 默认值 | 说明 |
|---|---|---|
| `--version` | 最新 Release | 指定 naivereal Release 版本，例如 `1.1.0` |
| `--domain` | 空 | 用于 h3frontend 的 TLS 证书域名 |
| `--reality-target` | 空 | REALITY 回落目标域名/IP |
| `--reality-sni` | 空 | REALITY SNI，一般与 target 相同 |
| `--user` | `user` | naive 后端认证用户名 |
| `--pass` | 随机生成 | naive 后端认证密码 |
| `--h3-port` | `8443` | h3frontend UDP 监听端口 |
| `--frontend-port` | `443` | REALITY 前端监听端口 |

## 生成内容

- `/opt/naivereal/bin/naive`
- `/opt/naivereal/bin/naivereal-frontend`
- `/opt/naivereal/bin/h3frontend`
- systemd 服务：
  - `naivereal-server.service`
  - `naivereal-frontend.service`
  - `naivereal-h3frontend.service`

## 安全提示

- 脚本默认从 GitHub Release 下载公开构建产物。
- 请确保域名已解析到本机后再使用 `--domain` 申请 Let's Encrypt 证书。
- 默认只监听本地回环的 naive 后端，不直接暴露 18080 端口。
