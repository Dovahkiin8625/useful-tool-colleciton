# 快速恢复工作区

双击 **`快速恢复工作区.lnk`**（桌面也放了一份），一次性把工作要用到的终端和文件夹全部打开，
每一个都直接停在配置好的目录里。启动器隐藏运行，开完就退出，不留黑框。

## 配置文件：`workspace.json`

```json
{
  "defaultApp": "powershell",
  "mode": "window",
  "explorerMode": "tab",
  "maximized": false,
  "launch": [
    { "path": "E:/project-clip/comfy-prompt-factory", "title": "提示词工程", "app": "explorer" },
    { "path": "D:/Comfy-Desktop/ComfyUI-Shared/output", "title": "Comfy输出", "app": "explorer" },
    { "path": "E:/project/desk-pet", "title": "桌宠根目录", "app": "cmd" }
  ]
}
```

| 字段 | 说明 |
| --- | --- |
| `defaultApp` | 条目没写 `app` 时用这个。可选 `powershell`（默认）/ `cmd` / `wt` / `explorer` |
| `mode` | 终端：`window`＝每项一个独立窗口（默认）；`tab`＝合并到一个 Windows Terminal 窗口的多标签页里 |
| `explorerMode` | 资源管理器：`tab`＝所有文件夹开在同一个窗口的不同标签页（默认）；`window`＝每个文件夹一个独立窗口 |
| `maximized` | `true` / `false`，终端窗口是否最大化启动（对资源管理器不生效） |
| `launch` | 目标列表，写几项就开几个 |

`launch` 里每一项：

| 写法 | 说明 |
| --- | --- |
| `"C:/work"` | 只有路径，程序用 `defaultApp` |
| `{ "path": "...", "title": "..." }` | 自定义窗口标题 |
| `{ "path": "...", "app": "explorer" }` | 这一项单独指定程序，覆盖 `defaultApp` |

- `app` 取值：`powershell` / `cmd` / `wt`（Windows Terminal）/ `explorer`（资源管理器）。
- 路径正斜杠 `C:/Users/Felix` 或双反斜杠 `C:\\Users\\Felix` 都行（JSON 里单个 `\` 是转义符，会报错）。
- 支持 `~`、`%USERPROFILE%` 这类环境变量，以及相对本文件的路径。
- 目录不存在会自动跳过，不会打断其他项；`wt` 不可用时会自动退回 powershell。

### 资源管理器标签页是怎么做到的

`explorer.exe` 本身没有“开多标签页”的命令行参数。脚本的做法是：先用第一个文件夹开出一个窗口，
再通过 UI 自动化点该窗口上的「添加新标签页」，然后用 Shell COM（`Shell.Application.Windows()`）
让新建的那个标签页导航到目标目录。整个过程不抢焦点、不动剪贴板，只在后台操作那个窗口。

如果系统或界面语言导致找不带那个按钮，会自动退化成每个文件夹一个独立窗口，不会漏开。
`explorerMode` 设成 `window` 就恢复成老行为。

## 命令行调试

```powershell
# 只看会执行什么，不真的打开
powershell -NoProfile -ExecutionPolicy Bypass -File Restore-Workspace.ps1 -DryRun

# 用另一份配置
powershell -NoProfile -ExecutionPolicy Bypass -File Restore-Workspace.ps1 -ConfigPath 别的.json
```
