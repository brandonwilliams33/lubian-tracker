# 测试与验证

## 可复现的自动测试

```sh
zsh test.command
```

测试使用 Swift `assert`，测试脚本不启用优化，以保留断言。运行不依赖炉石客户端、网络或下载卡牌库；临时日志在测试中合成，结束后清理。

| 范围 | 已覆盖的回归场景 |
| --- | --- |
| 增量读取 | 小块读取、断行、会话轮换、文件截断 |
| 事件状态 | 抽牌、换牌、生成牌、重复源、延迟身份、变形后的历史出牌 |
| 套牌代码 | 导出文本、Base64 补齐、40 张主牌、备选牌、缺失卡牌、损坏/截断输入 |
| 收藏与匹配 | JSON 往返、重复导入、候选歧义、唯一匹配、生成牌排除、核心版本归一化 |
| 牌库顶 | 普通位置不推断、探底候选不立即置顶、揭示、抽走、洗牌、新局失效 |
| 窗口布局 | 不同分辨率、尺寸范围、负坐标显示器、越界恢复 |

测试入口：[Sources/Tests.swift](../Sources/Tests.swift)。测试是行为回归证据，尚无覆盖率统计，不能解释为全部机制覆盖。

## 本地真实日志回放

```sh
mkdir -p build/cache
xcrun swiftc -module-cache-path build/cache \
  Sources/Core.swift Sources/ReplayTests.swift -o build/replay
build/replay /path/to/Power.log
# 可选：再提供旧版 deck.json，用于报告收藏匹配与扣减
build/replay /path/to/Power.log /path/to/deck.json
```

回放只读取本地文件，不上传内容。输入必须包含有效对局、抽牌及出牌；缺少这些条件时断言失败，不代表所有失败都是解析错误。

0.6 开发阶段，一份本机历史日志回放报告 11 次牌库到手牌变化、最多 30 条已知出牌；结合本机保存构筑，得到 17 个原始卡牌证据、1 个候选构筑和 16 张原牌扣减。这是特定日志上的观测值，不是正确率、吞吐量或泛化评估。原日志和个人构筑不随仓库提供，外部只能使用自己的日志复现回放流程。

## 构建校验

```sh
zsh build.command
codesign --verify --deep --strict dist/炉边记牌器.app
lipo -archs dist/炉边记牌器.app/Contents/MacOS/Lubian
unzip -tq dist/炉边记牌器-Mac.zip
```

预期包含 arm64 和 x86_64。签名检查仅证明构建产物的本地签名完整，不代表 Developer ID 认证或 Apple 公证。

## 尚需人工验证

- 0.6 主题的实际窗口布局、卡图预览与小屏幕可用性。
- 炉石前台“复制即收录”的端到端表现。
- 客户端实际输出 Decks.log 时的内容格式与收录行为。
- 更多探底卡牌、间接施放、完整疲劳流程和其他复杂效果。
- 不同 macOS、全屏模式、多显示器、Intel 实机运行。

0.5 曾进行悬浮列表、预览和折叠交互检查；这不能替代 0.6 新界面的验收。CI 不启动游戏和 GUI，只测试逻辑与构建。
