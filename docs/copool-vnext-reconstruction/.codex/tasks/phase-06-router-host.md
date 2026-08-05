# Phase 06 — 独立 RouterHost

目标：将数据面移出 SwiftUI 进程，同时保持行为等价和回滚。

- 独立 executable target。
- UDS/local control API 与 service lifecycle。
- target-specific listener/capability/state。
- InProcess 与 Host engine fixture 等价。
- feature flag 切换和旧路径回退。

验收：崩溃不拖垮 UI；升级/停止/恢复明确；等价 suite 通过。
