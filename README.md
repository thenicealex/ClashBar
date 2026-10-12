<div align="center">

<img src="./docs/public/clashbar-logo.png" width="220" alt="ClashBar Logo" />

# ClashBar

原生 macOS 菜单栏代理客户端，基于 `SwiftUI + AppKit`，由 `mihomo` 驱动。  
轻量、稳定，在菜单栏完成配置、节点、规则、连接与系统代理管理。 ✨

<p>
  <img alt="Platform" src="https://img.shields.io/badge/macOS-13%2B-111111?style=flat-square&logo=apple" />
  <img alt="Swift" src="https://img.shields.io/badge/Swift-6.2-F05138?style=flat-square&logo=swift" />
  <img alt="Build" src="https://img.shields.io/badge/Build-SwiftPM-0A84FF?style=flat-square" />
  <img alt="i18n" src="https://img.shields.io/badge/i18n-zh--Hans%20%7C%20en-34C759?style=flat-square" />
  <a href="https://github.com/Sitoi/ClashBar/releases" target="_blank" rel="noopener noreferrer">
    <img alt="Version" src="https://img.shields.io/github/v/release/Sitoi/ClashBar?style=flat-square&logo=github" />
  </a>
  <a href="https://github.com/Sitoi/ClashBar/stargazers" target="_blank" rel="noopener noreferrer">
    <img alt="Stars" src="https://img.shields.io/github/stars/Sitoi/ClashBar?style=flat-square&logo=github" />
  </a>
  <a href="https://github.com/Sitoi/ClashBar/issues" target="_blank" rel="noopener noreferrer">
    <img alt="Issues" src="https://img.shields.io/github/issues/Sitoi/ClashBar?style=flat-square&logo=github" />
  </a>
  <a href="https://github.com/Sitoi/ClashBar/pulls" target="_blank" rel="noopener noreferrer">
    <img alt="PRs" src="https://img.shields.io/github/issues-pr/Sitoi/ClashBar?style=flat-square&logo=github" />
  </a>
  <a href="https://github.com/Sitoi/ClashBar/network/members" target="_blank" rel="noopener noreferrer">
    <img alt="Forks" src="https://img.shields.io/github/forks/Sitoi/ClashBar?style=flat-square&logo=github" />
  </a>
  <a href="https://github.com/Sitoi/ClashBar/releases" target="_blank" rel="noopener noreferrer">
    <img alt="Downloads" src="https://img.shields.io/github/downloads/Sitoi/ClashBar/total?style=flat-square&logo=github" />
  </a>
  <a href="https://github.com/Sitoi/ClashBar/commits" target="_blank" rel="noopener noreferrer">
    <img alt="Commit Activity" src="https://img.shields.io/github/commit-activity/m/Sitoi/ClashBar?style=flat-square&logo=github" />
  </a>
  <a href="https://github.com/Sitoi/ClashBar/commits" target="_blank" rel="noopener noreferrer">
    <img alt="Last Commit" src="https://img.shields.io/github/last-commit/Sitoi/ClashBar?style=flat-square&logo=github" />
  </a>
  <a href="https://github.com/Sitoi/ClashBar/blob/main/LICENSE" target="_blank" rel="noopener noreferrer">
    <img alt="License" src="https://img.shields.io/github/license/Sitoi/ClashBar?style=flat-square" />
  </a>
</p>

<p>
  🌐 <a href="https://clashbar.sitoi.workers.dev"><strong>文档站</strong></a>
  ·
  📦 <a href="https://github.com/Sitoi/ClashBar/releases"><strong>Releases</strong></a>
  ·
  💬 <a href="https://t.me/clashbars"><strong>Telegram</strong></a>
</p>

</div>

<p>
  <img src="./docs/public/clashbar-black.png" width="49%" alt="ClashBar Dark" />
  <img src="./docs/public/clashbar-light.png" width="49%" alt="ClashBar Light" />
</p>

## ✨ 特点

- 🪶 **轻量**：去掉 Core 约 3 MB 内
- 🧭 **菜单栏优先**：配置导入/更新、节点切换、延迟测试、规则与连接排障
- 🔐 **系统集成**：系统代理、开机启动
- 📊 **可观测**：实时流量、连接、内存、日志过滤
- 🌍 **中英双语**：简体中文 / English

### 📏 体积对比（macOS Finder 显示值，仅供参考）

| 客户端                 |     体积 |
| ---------------------- | -------: |
| ClashBar.app (No Core) |     3 MB |
| ClashMac.app           |  75.2 MB |
| Clash Verge.app        | 128.4 MB |
| Clash Party.app        | 496.7 MB |

## 📦 安装

**要求：** macOS 13+ 🍎

```sh
brew tap Sitoi/tap
brew install --cask clashbar
```

或从 [Releases](https://github.com/Sitoi/ClashBar/releases) 下载 `.dmg`，将 `ClashBar.app` 拖入 `/Applications`。

卸载：

```sh
brew uninstall --cask clashbar
# 同时清除数据
brew uninstall --zap --cask clashbar
```

> [!IMPORTANT]
>
> - ⚠️ 同一时间只让一个 mihomo / Clash 系客户端接管系统代理。
> - 📂 系统代理依赖打包后的 `.app`；请放到 `/Applications` 后再使用。
> - 🔑 第一次开启系统代理时输入管理员密码。helper 会装到系统目录，之后更新 app 不会让它失效。开机启动仍需在登录项中允许 ClashBar。
> - 🔄 系统代理开关异常时，在应用内重新打开一次；必要时 `Restart` 内核。若系统弹出后台项目提示，在登录项里允许该 helper。

## 🚀 快速上手

1. 🖱️ 点击菜单栏图标打开面板
2. 📥 在 Proxy 选择或导入配置
3. ▶️ `Start` / `Restart` 启动内核
4. 🎛️ 选择模式：`Rule` / `Global` / `Direct`
5. 📶 切换节点并测速，确认可用后再开系统代理

更多说明见文档站：📖 [快速开始](https://clashbar.sitoi.workers.dev/docs/quick-start) · [功能说明](https://clashbar.sitoi.workers.dev/docs/features) · [故障排查](https://clashbar.sitoi.workers.dev/docs/troubleshooting)

## 🗺️ 功能一览

| 页面           | 内容                                            |
| -------------- | ----------------------------------------------- |
| 🧭 Proxy       | 配置、模式、系统代理、节点切换、延迟与 Provider |
| 📚 Rules       | 规则统计、筛选、Provider 更新                   |
| 🌐 Connections | 连接过滤与关闭                                  |
| 🪵 Logs        | 级别过滤、关键词检索                            |
| ⚙️ System      | 语言、状态栏、端口、`allow-lan` / `ipv6` 等     |

📁 运行时数据目录：`~/Library/Application Support/clashbar`  
🧩 内置内核会复制到：`~/Library/Application Support/clashbar/core/mihomo`

### 链式代理

在 Proxy 页面打开「链式代理」，添加并选择独立保存的后置节点，规则模式的前置跟随主界面首个节点选择组，全局模式跟随全局节点选择；其他服务分组不会另行作为前置。默认关闭，选择后置节点后通过启用开关立即保存并应用；只有启用成功后开关才显示蓝色，失败时保留原状态并提示错误。
代理流量路径为 `本机 → 前置节点 → 落地节点 → 目标网站`，出口 IP 为落地节点。

- 启用状态及后置节点的完整参数独立保存在 `state/chain-proxy.json`，不绑定机场配置；不再独立保存前置节点。
- 节点库独立保存在 `state/chain-proxy-nodes.json`。支持添加、编辑、删除节点，不从机场配置或订阅缓存读取节点；启用期间锁定后置选择及正在使用后置节点的编辑和删除；关闭后可修改，再开启应用。
- 更新订阅、切换机场或重启应用后自动沿用保存的后置节点；机场选点及自动测速选点由原代理组处理；节点服务端失效或凭据变更时，关闭开关，在节点库中编辑后重新开启。
- 节点测速使用当前机场选中节点的配置快照，经机场连接后置节点；使用独立临时内核，不修改运行中的配置和选择。前置不可用时不会改为直连。
- 机场原文件保持不变。启动、重启及配置重载时自动生成内核运行配置，保存在 `runtime/`，不会出现在机场配置列表中。
- 规则模式下代理规则通过链路，直连、拒绝和规则匹配条件保留；全局模式沿用机场全局节点选择并串接后置，直连模式继续直连。
- 关闭启用开关会立即恢复机场原有策略，独立保存的节点仍保留供下次启用。
- 添加节点支持 SOCKS5 / HTTP 手动表单、单条 SOCKS5 / HTTP / HTTPS / Shadowsocks 分享链接，以及单节点 YAML。链接解析后确认再添加；暂不支持链接插件或查询参数，复杂协议请使用 YAML。
- 编辑表单只修改可见字段，嵌套及其他参数完整保留；复杂节点默认使用 YAML 编辑。不要在节点中设置 `dialer-proxy`，前置关系自动由机场代理组的当前选择决定。

链式代理启停、校验、应用、保存及回滚失败会记录到现有 Logs 页面与应用日志；连接失败沿用 Mihomo 日志源。节点凭据在写入日志和展示前脱敏。

回归测试：`swift test`。设置 `CLASHBAR_TEST_MIHOMO` 为 mihomo 可执行文件路径，可同时运行内核配置校验测试。

## 🛠️ 开发构建

```sh
# 依赖：Xcode / Swift 6.2+、macOS 13+
make build                 # 产出 dist/ClashBar.app（默认不含 Core）
make build WITH_CORE=1     # 打包内置 mihomo
make dist WITH_CORE=1      # app + dmg
```

## 🙌 社区

- 🌐 文档：<https://clashbar.sitoi.workers.dev>
- 💬 Telegram：<https://t.me/clashbars>
- 🐛 Issue / PR：欢迎反馈与贡献

## 👥 贡献者

[![Contributors](https://contrib.rocks/image?repo=Sitoi/ClashBar)](https://github.com/Sitoi/ClashBar/graphs/contributors)

## 🙏 致谢

感谢 [MetaCubeX/mihomo](https://github.com/MetaCubeX/mihomo) 提供内核能力。
感谢 [Linux DO](https://linux.do/) 社区的支持与帮助 🙏

## ⭐ Star 趋势

[![Star History Chart](https://star-history.dera.page/svg?repos=Sitoi/ClashBar&type=date&legend=top-left)](https://star-history.dera.page/#Sitoi/ClashBar&type=date&legend=top-left)
