# Hysteria2 管理脚本

`hy2-manager.sh` 是一个交互式 Bash 管理脚本，用于部署和维护官方 Hysteria2 服务端，并支持 ACME HTTP-01 证书管理和 mihomo 客户端 YAML 导出。

## 主要设计

- 服务端使用官方 Hysteria2 安装脚本：`https://get.hy2.sh/`。
- ACME 邮箱自动随机生成。
- 认证密码可以直接回车随机生成，也可以手动输入。
- 服务端刻意不配置 `bandwidth`。客户端 `up` 和 `down` 只在导出 mihomo YAML 时询问。
- 端口跳跃默认使用 `20000-50000`，第一个端口作为主端口。
- 伪装站点默认使用 `https://www.bing.com`，菜单提供 Apple、iCloud、Yahoo、Microsoft、Epic Games、Steam、Nvidia 或自定义 URL。
- 脚本状态保存到 `/etc/hysteria/hy2-manager.env`。
- 服务端配置写入 `/etc/hysteria/config.yaml`。
- mihomo YAML 写入 `/etc/hysteria/hy2-mihomo.yaml`。

## 使用方式

在目标 Linux 服务器上用 root 运行：

```bash
bash hy2-manager.sh
```

建议在云厂商安全组和本机防火墙放行：

- TCP `80`：用于 ACME HTTP-01 证书签发。
- UDP `20000-50000`：使用默认端口跳跃时需要放行。
- 如果使用单端口模式，则放行你选择的 UDP 单端口。

## 维护菜单

脚本支持：

- 全新安装/重装。
- 查看当前配置。
- 修改域名与 ACME 配置。
- 修改单端口或端口跳跃范围。
- 修改认证密码。
- 修改伪装站点。
- 开启/关闭 Salamander 混淆。
- 修改拥塞控制。
- 多次导出 mihomo YAML，并为不同客户端填写不同 `up` / `down`。
- 查看状态/日志、重启、更新、备份/恢复、卸载。
