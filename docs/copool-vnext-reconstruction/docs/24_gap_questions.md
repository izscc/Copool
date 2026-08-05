# 24. 待确认问题与缺口

这些问题不阻塞 P0 侦察和模块化，但在相应阶段前必须回答：

1. Copool vNext 是否继续正式支持 iOS，还是仅保留 Accounts/Proxy 的当前有限能力？
2. Cursor/opencode 是 macOS 首发还是 P1 Beta？
3. Windows 需要完整 UI、CLI，还是只需要 router daemon？
4. Remote Node 是否允许承载第三方 provider keys，还是只接收短期下发凭据？
5. 登录无关 Codex 模式是否作为普通用户入口，还是 Expert Mode？
6. 是否允许自动跨供应商 failover，默认建议关闭。
7. 路由成本数据是否需要内置价格，还是仅用户手工填写？
8. Session Center 是否允许编辑/继续外部会话，还是只读导入？
9. Voice 首发支持哪些 STT/TTS/Realtime provider？
10. P1/P2 的许可状态需项目所有者确认；在此之前保持 clean-room。
11. App Store/TestFlight 分发是否允许后台 helper、下载 provider registry、Node/Swift remote binaries？需签名和沙箱评估。
12. 当前仓库中 `proxyd-src/prebuilt` 的发布、架构和远程 Linux 兼容矩阵需要实测。
