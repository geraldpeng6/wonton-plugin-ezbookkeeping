# 家庭记账（ezBookkeeping）

把 [ezBookkeeping](https://github.com/mayswind/ezbookkeeping)（MIT）包成云吞插件：记花销和收入的个人账本，
能导入支付宝、微信的账单，手机上好用。账目存在自己家里。

## 登录

打开插件网页即用云吞账号登录（`sso: oidc`，回调 `/oauth2/callback`）。应用自己的密码登录在清单里关掉了
（`EBK_AUTH_ENABLE_INTERNAL_AUTH=false`），登录页只剩"使用云吞登录"。首次登录自动建号
（上游 `oauth2_auto_register`，需要 `EBK_USER_ENABLE_REGISTER=true`，保持打开）：

- 每个家人用云吞账号登录都会建自己的账本，数据互相独立；给好友开放插件后同理。
- 自动建号的用户默认货币是上游写死的美元（OIDC 建号带不了货币声明），装好后在
  「我的 → 个人资料」里改成人民币（清单 `setup` 也提示了这一步）。
- 自助注册接口因此保持打开，但密码登录已关：直接访问注册页只能建出无法登录的账号，只占用户名。

## 助手（MCP）

上游自带 MCP（Streamable HTTP，`/mcp`），插件把它接进云吞的工具总线，共 8 个工具（记账、删账、查账、查类别/标签/账户/汇率）。
上游的工具都没有标 `readOnlyHint`，所以助手每次调用都会发确认卡片。

令牌的取得是上游的设计：MCP 令牌只认应用自己签发的用户令牌，生成时要过账号密码确认。首次流程（清单 `about` 和
设置项描述里也写了）：

1. 在应用「设置 → 个人资料」设一个密码（OIDC 建的号没有密码，设密码不要求旧密码；设了密码也不影响用云吞账号登录）。
2. 在「设置 → 安全」生成 MCP 令牌（默认不过期）。
3. 把令牌填到云吞里这个插件的设置（`secrets` 的 `mcp_token`），总线经 `Authorization: Bearer` 带给应用。

没填令牌时，总线会如实报"插件的 MCP 服务拒绝了核心的凭据"，应用本身不受影响。

## 数据

都在 `${WONTON_APP_DATA}` 下：`data/`（SQLite 库）、`storage/`（头像、小票图片）。日志只走 stdout。
卸载 `--purge` 删干净。

## 出网与模型

- `network.egress`：汇率数据源（默认欧洲央行）在应用里拉取；地图瓦片由浏览器直接取。
- `models`：AI 记账（文字/小票识别）走云吞的模型网关（OpenAI 兼容接口）。网关没接上时这些配置为空，
  应用里的 AI 功能如实不可用；已连接时用网关的默认模型。

## 已知限制

- 上游是按"每人一个账本"设计的，没有家庭共用一本账的功能；家人各自登录各自记。
- MCP 令牌需要上面那一步手动生成，装完不能立刻被助手调用（上游要求密码确认，见上）。
- OIDC 自动建号的账号语言跟随浏览器，货币默认美元（见上）。

## 图标

图标用上游官方标志（垫白底），来源、许可和商标说明见 [NOTICE](NOTICE)；`tabs/` 下的页面图标为本仓库原创。

通用开发流程见[开发指南](https://github.com/wontonapp/wonton-docs/blob/main/develop.md)，
规范见[插件规范](https://github.com/wontonapp/wonton-docs/blob/main/plugin-spec.md)。
