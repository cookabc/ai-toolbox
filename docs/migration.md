# 历史版本迁移

本页仅供曾使用旧版 ZCode UI Enhancer 注入方案的用户参考。当前应用是独立的 macOS 菜单栏用量监视器，无需安装旧版组件。

旧的 `app.asar` 注入代码、安装器和 JavaScript 演示已从仓库移除。如果曾安装自动注入 hook，请检查 `~/.zcode/cli/config.json`，移除调用旧 `install.py --auto` 的 `SessionStart` hook。

删除仓库中的旧代码不会自动清理外部 hook，也不会恢复已修改的 ZCode 安装包。

原项目的版权声明保留在 [LICENSE](../LICENSE) 中。
