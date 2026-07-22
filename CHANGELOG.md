## Unreleased

* fix(apple-web): avoid Windows WebView2 startup deadlock
  - Windows now uses the plugin's default WebView2 environment instead of waiting on a custom environment before creating the page
  - Windows Apple login uses an Edge/Chromium user agent rather than pretending to be Safari

* fix(apple-web): 稳定 Apple WebView 登录兜底链路
  - WebView 登录 URL 会带上 `tenant_id`,避免 anylogin 回落默认租户导致 client_id mismatch
  - 同时识别 `https://auth.janyee.com/apple/callback` 与 legacy `https://api.janyee.com/user/apple/callback`
  - Windows WebView2 初始化完成前显示准备状态,并使用独立 user data 目录
  - macOS / iOS WebView fallback 使用 Safari UA,避免 Apple 登录页拒绝桌面 Chrome UA
  - 主动轮询当前 URL 作为导航回调兜底,确保拿到 `callbackUrl` 后交给 `/login/directLogin`

## 0.0.2

* fix(oauth): 适配 userLogin OIDC profile claims 字段重命名
  - `/oauth/userinfo` 响应里读 `picture`(OIDC 标准)优先,fallback `avatar`(老服务)
  - `UserInfo.fromJson` 同样兼容 picture / phone_number / sub
  - 现在升不升级 userLogin 服务端,easy_auth 都能正常拿到头像 + sub
* 不需要任何 app 端代码改动,字段映射在 SDK 内部处理

## 0.0.1

* Initial release.
