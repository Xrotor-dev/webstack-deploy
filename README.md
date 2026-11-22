# WebStack Deploy

适用于 Debian 12 / 13 的服务器初始化与网站部署脚本。

首次运行时安装 Nginx 和 Let's Encrypt 证书工具，并按需配置 SSH 端口、Fail2ban 和 Swap；之后用 `deploy` 命令添加和管理网站，支持静态网站、PHP 网站和反向代理。

本脚本不会安装任何数据库服务（MySQL、MariaDB 等）。

## 目录

- [功能](#功能)
- [系统要求](#系统要求)
- [快速开始](#快速开始)
- [首次初始化](#首次初始化)
- [添加网站](#添加网站)
- [管理命令](#管理命令)
- [SSH 端口](#ssh-端口)
- [安全设置](#安全设置)
- [Swap 策略](#swap-策略)
- [PHP 说明](#php-说明)
- [非交互使用](#非交互使用)
- [目录与文件](#目录与文件)
- [常见问题](#常见问题)
- [卸载](#卸载)
- [许可证](#许可证)

## 功能

- Nginx + Let's Encrypt 证书，到期前自动续签
- 三种网站类型：静态网站、PHP 网站（PHP 8.x）、反向代理（Node.js、Docker 等本机服务）
- 可同时配置 `www`，并自动跳转到主域名
- 申请证书前检查 DNS 解析（A 和 AAAA 记录）
- 修改 SSH 端口：自动放行防火墙、检查配置，新端口启动失败时自动恢复
- Fail2ban：SSH 防暴力破解（自动识别 SSH 端口）和 Nginx 扫描防护
- Swap：根据内存和磁盘给出建议值
- 管理命令：列出、删除网站，查看服务状态，在线更新
- 安全默认值：拒绝直接用 IP 或未添加的域名访问，禁止访问隐藏文件，添加常用安全响应头

## 系统要求

- Debian 12 或 Debian 13（Debian 11 已于 2026-08-31 结束官方安全支持，不再默认支持）
- 使用 root 用户运行
- 服务器的 80 和 443 端口可以从公网访问（请同时检查云服务商的安全组或防火墙）
- 添加网站前，域名已经解析到服务器

## 快速开始

```bash
wget -O deploy.sh https://raw.githubusercontent.com/Xrotor-dev/webstack-deploy/main/deploy.sh
bash deploy.sh
```

系统中没有 `wget` 时，可以使用 `curl`：

```bash
curl -fsSL -o deploy.sh https://raw.githubusercontent.com/Xrotor-dev/webstack-deploy/main/deploy.sh
bash deploy.sh
```

需要固定版本时，把地址中的 `main` 换成对应的版本标签，例如 `v1.0.0`。

> **下载时提示证书错误？** 说明系统的 CA 证书过旧，请先执行 `apt-get update && apt-get install -y ca-certificates` 再下载。请不要使用 `--no-check-certificate`：本脚本以 root 身份运行，跳过证书校验意味着下载的内容可能被篡改。

## 首次初始化

运行 `bash deploy.sh` 后，脚本会先询问全部设置，显示汇总并确认后才开始执行。确认之前不会对系统做任何修改。

需要回答的问题：

1. Swap 大小：显示内存、磁盘可用空间和建议值，直接回车使用建议值（系统已有 Swap 时跳过）
2. SSH 端口：直接回车保持不变（见 [SSH 端口](#ssh-端口)）
3. 是否启用 Fail2ban（默认启用）
4. Let's Encrypt 邮箱（可选，直接回车跳过）
5. 初始化完成后是否立即添加第一个网站；选择是，会接着询问网站设置（见[添加网站](#添加网站)）

确认界面示例：

```text
=== 即将执行 ===
  系统更新      apt-get update && apt-get upgrade
  安装组件      Nginx、Certbot、Fail2ban
  Swap          创建 1024 MB（/swapfile，swappiness 10）
  SSH 端口      22 → 22222
  Fail2ban      启用
  证书邮箱      不填写
[警告] SSH 端口将从 22 改为 22222。如果服务商启用了安全组或云防火墙（例如阿里云安全组、netcup 云防火墙），必须先在控制台放行 TCP 22222，否则当前连接断开后将无法登录。

是否已放行 TCP 22222（服务商没有启用这类防火墙时也可以继续）？ [y/N] y

确认开始？ [Y/n]
```

确认后脚本依次执行：

1. 更新软件包索引并升级已安装的软件包
2. 创建 Swap（如果选择了创建）
3. 安装 Nginx、Certbot，以及 Fail2ban（如果启用）
4. 写入 Nginx 公共配置和默认站点
5. 如果 UFW 防火墙已启用，放行 SSH（包括新端口）、80 和 443 端口
6. 修改 SSH 端口（如果设置了新端口）
7. 配置 Fail2ban 和证书自动续签
8. 安装 `deploy` 命令

> Let's Encrypt 自 2025 年 6 月起已停止发送证书到期提醒邮件，所以邮箱可以留空。证书由 `certbot.timer` 自动续签。

## 添加网站

初始化完成后，运行：

```bash
deploy
```

也可以直接带上域名：

```bash
deploy example.com
```

交互示例：

```text
=== 网站设置 ===
请输入域名（例如 example.com）：example.com
是否同时配置 www.example.com（自动跳转到 example.com）？ [Y/n]

网站类型：
  1) 静态网站（HTML、CSS、JS）
  2) PHP 网站
  3) 反向代理（转发到本机端口，例如 Node.js 或 Docker 应用）
请选择网站类型 [1]：2
[信息] 检查域名解析...
[信息] example.com 解析正常。
[信息] www.example.com 解析正常。

=== 即将添加网站 ===
  域名          example.com
  www           www.example.com → 跳转到 example.com
  网站类型      PHP（自动选择最新的 8.x）
  网站目录      /var/www/example.com（新建）

确认添加？ [Y/n]
```

输入域名时可以直接粘贴网址，脚本会自动去掉 `https://`、路径和末尾的点，并转成小写。中文域名请填写 Punycode 格式（以 `xn--` 开头）。

`www` 选项的默认值：主域名（如 `example.com`）默认配置，子域名（如 `blog.example.com`）默认不配置。

### 网站类型

| 类型 | 说明 |
| --- | --- |
| 静态网站 | 直接提供 HTML、CSS、JS、图片等文件 |
| PHP 网站 | 由 PHP-FPM 处理 `.php` 文件；不存在的路径交给 `index.php`，可直接用于 WordPress、Laravel 等程序的伪静态 |
| 反向代理 | 把请求转发到本机端口（例如 `3000`），支持 WebSocket，不创建网站目录 |

### DNS 检查

- 对比域名的 A 记录与本机公网 IPv4；本机有公网 IPv6 时，同时对比 AAAA 记录。
- 本机没有公网 IPv6、但域名有 AAAA 记录时会给出提示：Let's Encrypt 会优先通过 IPv6 验证，这种情况下证书申请通常会失败。
- 检查不通过时会询问是否继续。使用 CDN 代理（例如 Cloudflare 的橙色云朵）时 IP 不一致是正常的，可以继续。
- `www` 没有解析记录时，会建议只配置主域名。
- 获取本机公网 IP 时会访问 `api.ipify.org`（备用 `ifconfig.me`）。

### 网站目录与权限

- 网站目录默认是 `/var/www/域名`，也就是 Nginx 的网站根目录，直接把网站文件上传到这里即可。
- 新建的目录属于 `www-data` 用户。目录已经存在时，脚本不会改动其中的文件和权限。
- 上传网站文件之前，访问网站会显示 403，这是正常的。
- 用 WinSCP 等工具以 root 身份上传的文件属于 root。PHP 程序需要写入文件（上传附件、生成缓存、运行安装向导）时，请执行：

  ```bash
  chown -R www-data:www-data /var/www/example.com
  ```

- 为了方便 WinSCP 进入网站目录，初始化时会创建快捷入口 `/root/www → /var/www`。`/root/www` 已经存在时不会覆盖；设置 `WWW_SHORTCUT=0` 可以不创建。

### 重新添加同一个域名

脚本会先提示确认，再覆盖原有的 Nginx 配置；旧配置自动备份到 `/var/lib/webstack-deploy/backup/`。网站类型、`www` 等设置默认沿用上一次的选择。已有证书时继续使用，只有快到期时才会续签。

## 管理命令

| 命令 | 说明 |
| --- | --- |
| `deploy` | 添加网站 |
| `deploy example.com` | 添加指定的域名 |
| `deploy list` | 列出已添加的网站、启用状态和证书到期时间 |
| `deploy remove example.com` | 删除网站的 Nginx 配置和证书（网站文件保留） |
| `deploy status` | 查看 Nginx、PHP-FPM、Fail2ban、证书续签和 Swap 的状态 |
| `deploy ssh-port 22222` | 修改 SSH 端口（不带端口号时交互输入） |
| `deploy update` | 从 GitHub 更新到最新版本 |
| `deploy init` | 重新初始化，用于修改 Swap、SSH 端口、Fail2ban、邮箱等设置；已添加的网站不受影响 |
| `deploy help` | 显示帮助 |
| `deploy version` | 显示版本号 |

如果系统中已有其他程序占用了 `deploy` 这个命令名，脚本会改为安装 `webstack-deploy` 命令，用法相同。

## SSH 端口

把 SSH 从默认的 22 改为其他端口，可以大幅减少自动扫描和暴力破解。这一步是可选的：初始化时直接回车即保持不变，以后也可以随时用 `deploy ssh-port` 修改。

```text
=== SSH 端口 ===
  当前端口      22
  把 SSH 改为非 22 端口，可以大幅减少自动扫描和暴力破解（可选）。
  建议使用 10000–65000 之间的端口；修改后用 ssh -p 端口 root@服务器IP 登录。
请输入 SSH 端口（直接回车保持不变） [22]：22222
```

**修改前请先在服务商控制台放行新端口。** 很多服务商提供安全组或云防火墙（例如阿里云安全组、netcup 云防火墙），它们在服务器外部过滤流量，脚本无法替你修改。没有放行新端口时，当前连接断开后将无法再登录。所以脚本在修改前会单独确认一次。

脚本修改 SSH 端口的过程：

1. 检查端口：必须是 1–65535 之间的数字，不能是网站使用的 80 和 443，也不能是其他程序正在使用的端口。
2. 如果 UFW 已启用，先放行新端口（旧端口的规则保留，方便出问题时登录）。
3. 把新端口写入 `/etc/ssh/sshd_config.d/00-webstack-port.conf`，并注释掉 `/etc/ssh/sshd_config` 中原有的 `Port` 行（原文件备份在 `/var/lib/webstack-deploy/backup/`）。
4. 用 `sshd -t` 检查配置，重启 SSH 服务，并确认 SSH 已经在新端口上监听。
5. 任何一步失败，都会自动恢复原来的配置，SSH 继续使用原端口。
6. 成功后，Fail2ban 改为保护新端口。

重启 SSH 服务不会断开当前已经登录的窗口。修改完成后请**保持当前窗口不要关闭**，先打开一个新窗口测试：

```bash
ssh -p 22222 root@服务器IP
```

确认新端口可以登录后，再关闭当前窗口。如果使用 UFW，可以删除旧端口的规则：`ufw delete allow 22/tcp`。

以下情况脚本不会自动修改，需要手动处理：

- sshd 配置的 `ListenAddress` 中直接写了端口（例如 `ListenAddress 0.0.0.0:22`）
- `/etc/ssh/sshd_config.d/` 中的其他配置文件也设置了 `Port`（脚本会检测到并恢复原配置）

## 安全设置

- **默认站点**：直接用服务器 IP 或未添加的域名访问时，HTTP 直接断开连接（返回 444），HTTPS 拒绝握手，避免暴露已有网站和证书。Nginx 自带的欢迎页会被停用，原文件仍保留在 `/etc/nginx/sites-available/default`。
- **隐藏文件**：禁止访问以 `.` 开头的文件和目录（如 `.git`、`.env`），`/.well-known/` 除外。
- **HTTPS**：只启用 TLS 1.2 和 TLS 1.3，并添加 `X-Content-Type-Options`、`X-Frame-Options`、`Referrer-Policy` 响应头。默认不启用 HSTS，需要时见[常见问题](#如何启用-hsts)。
- **证书验证目录**：所有网站共用 `/var/lib/webstack-deploy/acme`，与网站目录分开，整体替换网站文件不会影响续签。
- **Fail2ban**：启用 `sshd` 和 `nginx-botsearch` 两个规则，保护的 SSH 端口从 sshd 配置中自动读取，修改 SSH 端口后会同步更新；同一 IP 在 10 分钟内失败 5 次（扫描规则为 10 次）后封禁 1 小时。
- **数据库**：不安装任何数据库服务。

## Swap 策略

| 情况 | 建议值 |
| --- | --- |
| 系统已有 Swap | 不修改 |
| 磁盘可用空间小于 3 GB | 0（不创建） |
| 内存不超过 4 GB | 1024 MB |
| 内存超过 4 GB | 0（不创建） |

- 可以输入 MB 数值，也可以带单位，例如 `512`、`2G`；输入 `0` 表示不创建。
- 最小 128 MB，最大为磁盘可用空间的一半。
- `/swapfile` 已存在但没有启用，或者文件系统是 btrfs 时，脚本会跳过创建。
- 创建后写入 `/etc/fstab`（重启后自动启用），并设置 `vm.swappiness = 10`。

## PHP 说明

- PHP 来自 [packages.sury.org](https://packages.sury.org/php/)，首次添加 PHP 网站时会添加这个软件源。
- 第一次安装时使用软件源中最新的 PHP 8.x，并把版本记录到配置文件。以后添加 PHP 网站会继续使用这个版本，不会因为软件源发布了新版本就再安装一套。需要指定版本时，设置 `PHP_VERSION`，例如 `PHP_VERSION=8.3`。
- 默认安装的组件：`cli`、`common`、`fpm`、`curl`、`mbstring`、`opcache`、`xml`、`zip`、`intl`、`gd`。软件源中不存在的组件会跳过，例如 PHP 8.5 起 OPcache 已内置，不再有单独的软件包。
- 默认不安装数据库相关扩展。需要连接外部数据库时，可以用 `PHP_EXTENSIONS` 安装客户端扩展，例如 `PHP_EXTENSIONS="mysql"`（只安装 PHP 扩展，不会安装数据库服务）。
- 上传大小上限 64 MB，执行时间上限 120 秒，Nginx 与 PHP 的设置保持一致。
- 所有 PHP 网站共用一个 PHP-FPM 进程池，以 `www-data` 用户运行。进程数按内存自动设置：

| 内存 | 最大进程数 | OPcache 内存 |
| --- | --- | --- |
| 不超过 1.5 GB | 3 | 64 MB |
| 不超过 3 GB | 6 | 128 MB |
| 不超过 6 GB | 10 | 128 MB |
| 超过 6 GB | 16 | 192 MB |

## 非交互使用

设置 `ASSUME_YES=1` 后，脚本不再提问：所有选项使用默认值或环境变量的值，确认步骤自动通过（包括覆盖已存在的网站配置和删除网站）。

在 cron、cloud-init 等没有终端的环境中运行时，即使不设置 `ASSUME_YES`，也会使用默认值；但修改 SSH 端口、覆盖网站配置、删除网站这类操作必须设置 `ASSUME_YES=1` 才会执行。

```bash
# 初始化，并添加一个静态网站
ASSUME_YES=1 DOMAIN=example.com bash deploy.sh

# 初始化，并添加一个 PHP 网站，Swap 设为 2 GB
ASSUME_YES=1 DOMAIN=example.com SITE_TYPE=php SWAP_SIZE=2G bash deploy.sh

# 只初始化，不添加网站，不启用 Fail2ban
ASSUME_YES=1 ADD_FIRST_SITE=0 ENABLE_FAIL2BAN=0 bash deploy.sh

# 初始化，并把 SSH 端口改为 22222（请先在服务商控制台放行该端口）
ASSUME_YES=1 SSH_PORT=22222 bash deploy.sh

# 初始化完成后，添加一个反向代理网站（转发到本机 3000 端口）
ASSUME_YES=1 SITE_TYPE=proxy PROXY_TARGET=3000 deploy app.example.com

# 删除网站
ASSUME_YES=1 deploy remove app.example.com
```

### 环境变量

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `ASSUME_YES` | `0` | `1`：不提问，使用默认值并自动确认 |
| `DOMAIN` | 无 | 网站域名 |
| `SITE_TYPE` | `static` | 网站类型：`static`、`php` 或 `proxy` |
| `WITH_WWW` | 主域名 `1`，子域名 `0` | 是否同时配置 `www` 并跳转到主域名 |
| `PROXY_TARGET` | 无 | 反向代理的后端地址：端口号或 `IP:端口`，例如 `3000`、`127.0.0.1:8080` |
| `WEBROOT` | `/var/www/域名` | 网站目录（静态网站和 PHP 网站） |
| `PHP_VERSION` | 已安装的版本，否则为最新的 8.x | 指定 PHP 版本，例如 `8.3` |
| `PHP_EXTENSIONS` | 无 | 额外安装的 PHP 扩展，用空格或逗号分隔，例如 `mysql sqlite3 redis` |
| `LE_EMAIL` | 空 | Let's Encrypt 邮箱，可以留空 |
| `LE_STAGING` | `0` | `1`：使用 Let's Encrypt 测试证书，调试时不消耗正式证书的申请次数 |
| `REQUIRE_DNS_MATCH` | `0` | `1`：DNS 检查不通过时直接退出 |
| `RUN_RENEW_DRY_RUN` | `0` | `1`：添加网站后测试一次证书续签 |
| `SWAP_SIZE` | 自动建议 | Swap 大小：`0` 表示不创建，数字表示 MB，也可以写 `2G` |
| `SWAPFILE` | `/swapfile` | Swap 文件路径 |
| `SWAPPINESS` | `10` | `vm.swappiness` 的值（0 到 100） |
| `SSH_PORT` | 当前端口 | 新的 SSH 端口；不设置或与当前端口相同时不修改 |
| `ENABLE_FAIL2BAN` | `1` | 是否启用 Fail2ban |
| `FAIL2BAN_IGNOREIP` | 无 | Fail2ban 白名单，用逗号分隔，例如 `203.0.113.10,198.51.100.0/24` |
| `ADD_FIRST_SITE` | `auto` | 初始化后是否添加网站：`auto` 表示设置了 `DOMAIN` 时添加、交互模式下询问；也可设为 `1` 或 `0` |
| `WWW_SHORTCUT` | `1` | 是否创建 `/root/www` 快捷入口 |
| `ALLOW_UNSUPPORTED` | `0` | `1`：允许在 Debian 12 / 13 以外的系统上运行（不保证可用） |
| `UPDATE_URL` | GitHub `main` 分支 | `deploy update` 使用的下载地址 |
| `NO_COLOR` | 无 | 设置为任意值时关闭彩色输出 |

## 目录与文件

| 用途 | 路径 |
| --- | --- |
| 网站目录 | `/var/www/域名` |
| WinSCP 快捷入口 | `/root/www` → `/var/www` |
| 网站的 Nginx 配置 | `/etc/nginx/sites-available/域名`（启用链接位于 `sites-enabled/`） |
| Nginx 公共配置 | `/etc/nginx/snippets/webstack-*.conf`、`/etc/nginx/conf.d/webstack.conf` |
| Nginx 默认站点 | `/etc/nginx/sites-available/webstack-default` |
| 证书 | `/etc/letsencrypt/live/域名/` |
| 证书验证目录 | `/var/lib/webstack-deploy/acme` |
| SSH 端口设置 | `/etc/ssh/sshd_config.d/00-webstack-port.conf` |
| 配置备份（Nginx 站点、sshd_config） | `/var/lib/webstack-deploy/backup` |
| 脚本配置 | `/etc/webstack-deploy/config` |
| 运行日志 | `/var/log/webstack-deploy.log` |
| 管理命令 | `/usr/local/bin/deploy`（脚本本体位于 `/usr/local/lib/webstack-deploy/deploy.sh`） |

脚本还会修改以下系统设置：

- 升级全部已安装的软件包（`apt-get upgrade`）
- `/etc/fstab` 和 `/etc/sysctl.d/99-webstack-swap.conf`（创建 Swap 时）
- `/etc/apt/sources.list.d/php-sury.list`（首次添加 PHP 网站时）
- `/etc/php/版本/fpm/pool.d/www.conf` 中的进程设置，以及 `/etc/php/版本/fpm/conf.d/99-webstack.ini`
- `/etc/ssh/sshd_config.d/00-webstack-port.conf`，并注释掉 `/etc/ssh/sshd_config` 中原有的 `Port` 行（修改 SSH 端口时）
- `/etc/fail2ban/jail.d/99-webstack.local`
- `/etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh`（证书续签后重新加载 Nginx）
- UFW 防火墙规则（仅当 UFW 已启用时）
- 停用 Nginx 自带的 `default` 站点

## 常见问题

### 证书申请失败

脚本会自动撤销本次的 Nginx 配置改动。请按顺序检查：

1. 域名是否已经解析到本服务器。新添加的解析可能需要几分钟到几小时才能生效。
2. 云服务商的安全组或防火墙是否放行了 80 端口。Let's Encrypt 通过 80 端口验证域名。
3. 域名是否开启了 CDN 代理并强制跳转 HTTPS。可以先暂时关闭代理（Cloudflare 改为灰色云朵），申请成功后再打开。
4. 查看详细日志：`/var/log/letsencrypt/letsencrypt.log`。

Let's Encrypt 对验证失败的次数有限制。排查期间可以加上 `LE_STAGING=1` 使用测试证书；确认没有问题后，不带这个变量重新添加一次，脚本会自动换成正式证书。

### 访问网站显示 403

网站目录是空的，或者没有 `index.html` / `index.php`。上传网站文件即可。

### 访问网站显示 502

- 反向代理网站：后端服务没有运行，或者端口填错了。
- PHP 网站：PHP-FPM 没有运行，用 `deploy status` 查看。

### PHP 程序提示没有写入权限

```bash
chown -R www-data:www-data /var/www/example.com
```

### Laravel 等程序的网站根目录是 public/

添加网站时指定网站目录：

```bash
WEBROOT=/var/www/example.com/public deploy example.com
```

### 如何启用 HSTS

在 `/etc/nginx/sites-available/域名` 中“HTTPS：网站”这一段的 `server { ... }` 里加入下面一行，然后执行 `nginx -t && systemctl reload nginx`：

```nginx
add_header Strict-Transport-Security "max-age=31536000" always;
```

注意：用 `deploy` 重新添加同一个域名时会覆盖这个文件（旧文件会备份），需要重新加入。

### 修改 SSH 端口后无法登录

1. 确认登录命令带上了新端口：`ssh -p 新端口 root@服务器IP`。
2. 确认服务商的安全组或云防火墙已经放行新端口。
3. 仍然无法登录时，通过服务商控制台的 VNC（网页终端）登录服务器，执行下面的命令恢复为默认端口 22：

   ```bash
   rm -f /etc/ssh/sshd_config.d/00-webstack-port.conf
   systemctl restart ssh
   ```

   修改前的 `sshd_config` 备份在 `/var/lib/webstack-deploy/backup/`。

### 自己的 IP 被 Fail2ban 封禁了

换一个网络（例如手机热点）登录服务器，然后执行：

```bash
fail2ban-client set sshd unbanip 你的IP
```

如果有固定 IP，可以加入白名单：`FAIL2BAN_IGNOREIP=你的IP deploy init`。

## 卸载

脚本没有提供自动卸载，需要时按以下步骤手动操作：

```bash
# 1. 删除所有由本脚本添加的网站（会同时删除证书，网站文件保留）
deploy list
deploy remove example.com

# 2. 删除脚本的命令、配置和 Nginx 公共配置
rm -f /usr/local/bin/deploy
rm -rf /usr/local/lib/webstack-deploy /etc/webstack-deploy /var/lib/webstack-deploy
rm -f /etc/nginx/sites-enabled/webstack-default /etc/nginx/sites-available/webstack-default
rm -f /etc/nginx/snippets/webstack-*.conf /etc/nginx/conf.d/webstack.conf
rm -f /etc/fail2ban/jail.d/99-webstack.local

# 3. 恢复 Nginx 自带的欢迎页，并重新加载服务
ln -s /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx
systemctl restart fail2ban    # 启用了 Fail2ban 时执行
```

SSH 端口设置不会随卸载改变。如需恢复为默认端口 22，请先确认防火墙已放行 22 端口，再执行 `rm -f /etc/ssh/sshd_config.d/00-webstack-port.conf && systemctl restart ssh`。

Nginx、Certbot、Fail2ban、PHP 等软件包不会被卸载，如不再需要可以用 `apt-get remove` 自行卸载。

## 许可证

[MIT](LICENSE)
