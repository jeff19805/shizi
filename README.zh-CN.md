# 拾字（shizi）

[English](README.md) | 简体中文

拾字是 Mac 上的本机文字识别：把图片、截图、扫描件和 PDF 里的字认出来，认过的照片按字就能搜到。
用的是 macOS 自带的文字识别，全在本机、不联网、不收费。
有带界面的 App，也有给 AI 助手用的 MCP 服务 `shizi-mcp`：Claude Code 这类支持 MCP 的助手接上它，就能读图片和 PDF 里的字。

0.0.35 及以前叫 mac-ocr-mcp，升级要改什么见 [CHANGELOG.md](CHANGELOG.md) 的 0.0.36。

## 能做什么

- **各种图**：照片、截图、扫描件都能认。任意角度（倒着的也行），拍歪的纸先拉正，大图里的小字切块细认，二维码、条码一起找。
- **表格和版面**：表格出成 Markdown，多栏按阅读顺序排，竖排从右往左；扫描的表格、表单按纸上画的线一格一格读。表格、多栏、竖排要 macOS 26。
- **PDF**：Word、浏览器导出的 PDF 直接用它自带的字，一字不差，也快得多，里面的插图另外认；扫描件一页页认图。
- **语言**：30 种，默认自动判断。汉字夹在字母、数字、算式里的，选「中文优先」认得准。
- **照片**：给照片图库里的照片认字，以后按字就能搜到；接上判定服务还能按内容给照片分类，分好存成相簿。
- **给 AI 助手用**：MCP 服务能认图片和 PDF、把整份文件认完写成文本、在认过的照片里按字找。
- **判定插件（可选）**：接一个判定服务，让它认之前先看图定怎么认、认完复核可疑的行、给照片分类。不装也照常工作。

## 安装

运行要 macOS 14 或更新（表格、多栏、竖排要 macOS 26）。

### 下载

到 [Releases 页](https://github.com/jeff19805/shizi/releases/latest) 下载最新的 `.dmg`，打开后把拾字拖进「应用程序」。
App 用 Developer ID 签名、经苹果公证，支持 Apple 芯片的 Mac；Intel 的 Mac 请从源码编。App 里带着 MCP 服务
（`/Applications/Shizi.app/Contents/MacOS/shizi-mcp`）和判定插件。以后升级，照片权限不用重新给。

### 从源码编

要 Xcode 26 或同版本的命令行工具。编 App：

```bash
./scripts/build-app.sh   # 编出 .build/app/Shizi.app，本机自签，拖进「应用程序」就能用
```

本机自签的 App 每重编一次，系统都当成新程序，照片权限要重新给。

只要 MCP 服务和命令行：

```bash
swift build -c release   # 得到 .build/release/shizi-mcp，判定插件是 .build/release/ocr-plugin-systemone
```

## 用法

### App

图片、PDF 拖进来、打开，或者 ⌘V 粘贴截图，就开始认。

- 左边是原图，叠着每一行的框；右边是认出的字。「整页」是一整段，表格画成真的表；「逐行」一行一项，可能认错的标出来。⌘1、⌘2 切换。
- 在图上拖一个框，只认那一块。能复制全文，能导出 Markdown、纯文字、JSON（带每行的位置）。
- 多页的 PDF 一页页认，随时能停；原图上下接成一长条，滚到哪页，页码和右边的字就跟到哪页。
- **照片**：左栏「照片」里给权限、选相簿，点「识别」认还没认过的照片。搜索框按字找认过的照片，选几张能加进相簿。
  原图只在 iCloud 上的照片先下载再认，设置里能关。
- **分类**：相簿页头的「分类」，按类别分照片，或者按一句条件找；可以看认出的字，也可以看画面。要先在设置里给判定插件打开「分类照片」。
- **界面语言**：中文、英文。默认跟着系统：系统语言是中文就用中文，别的都用英文；设置里也能单独指定，重开拾字后生效。
- **设置**（⌘,）：识别的默认做法、识别语言、界面语言、判定插件；「接入」里复制给 Claude Code 的命令、给别的助手的配置，
  也能一键接入灵犀（作者自己用的 AI 助手）。

### 接进 AI 助手（MCP）

不带参数运行 `shizi-mcp`，就是 MCP 服务（走标准输入输出）。Claude Code：

```bash
claude mcp add shizi -- /绝对路径/shizi-mcp
```

别的助手照这样配：

```json
{ "mcpServers": { "shizi": { "command": "/绝对路径/shizi-mcp" } } }
```

装了 App 的，路径在设置的「接入」里能直接复制。

工具说明、回复、结果里的说明文字跟 App 用同一种语言：App 里带的服务跟着拾字的界面语言，自己编的服务跟着系统语言。
自己编的服务到仓库的 `scripts/app` 里找英文对照表；把编好的程序拷到别处单独跑，就只有中文。

工具：

- `ocr_image`：认图片或 PDF，回认出的字：正文按阅读顺序，表格是 Markdown，末尾列出二维码和可能认错的行。
- `ocr_to_file`：整份认完写成 Markdown 文件，回复只给路径和摘要；页数多、要全文时用。参数跟 `ocr_image` 一样，另有 `outputPath`；
  不给就写到 `~/Library/Caches/shizi/results/`（7 天后自动清掉）。一次最多 100 页。
- `photos_search`：在拾字认过的照片里按字找，参数 `query`（几个词用空格隔开）、`limit`。只读拾字存的字，不碰照片图库。
- `ocr_status`：这台 Mac 能认什么、配了哪些插件、连不连得上。

`ocr_image`、`ocr_to_file` 的参数：

| 参数 | 说明 |
|---|---|
| `path` | 必填，图片或 PDF 的路径（可以用 ~） |
| `pages` | PDF 页码，如 `"1-3,5"`；默认从头起最多 20 页 |
| `mode` | `auto`（默认）/ `lines` 逐行 / `document` 认文档 |
| `languages` | 不给就照设置里的识别语言；`["chinese-first"]` 中文优先，`["auto"]` 自动判断，`["zh-Hans", "en-US"]` 这样是指定语言（只用第一个语言的模型，中日韩的排到最前） |
| `region` | 只认一块：`[左, 上, 宽, 高]`，0–1，左上为原点；结果的坐标仍相对整张图 |
| `rectify` | 拉正拍歪的纸：`auto` / `on` / `off` |
| `tiles` | 大图小字切块细认：`auto` / `on` / `off` |
| `barcodes` | 找不找二维码、条码，默认找 |
| `detail` | `text`（默认）只给字；`full` 另附一块 JSON：每行的位置、可信度、表格格子等 |
| `plugins` | 这次调不调判定插件，默认调 |
| `textLayer` | PDF 里有字时直接用，默认 `true`；`false` 全部认图 |

一次回复最多约 45 KB。多页 PDF 放不下时在整页处停，末尾写明接着用什么 `pages` 再调。
`detail: "full"` 的 JSON 里，坐标都是 0–1、左上为原点。

### 命令行

```bash
shizi-mcp ocr 图片.png                   # 认出的字
shizi-mcp ocr 文件.pdf --pages 2 --json  # 完整的结构化结果
shizi-mcp status                         # 能认什么、插件通不通
```

选项跟工具参数一一对应，`shizi-mcp --help` 看全部。

## 设置

配置文件是 `~/.config/shizi/config.json`（也可以用环境变量 `SHIZI_CONFIG` 指定别的）。拾字的设置页改的就是它；
MCP 服务每次调用前看一眼它改没改过，改了不用重启。

- **识别语言**：`"recognition": {"languages": "chinese-first"}` 是中文优先，不写是自动判断。自动判断是系统一行一行挑语言，
  汉字夹在字母、数字里的行容易认成乱码；中文优先先按中文认，整页是西文、或者有中文认不了的字（韩文、日文）时改回自动判断。
- **判定插件**：写在 `plugins` 里，每个插件一项；密钥放钥匙串，不写进配置文件。插件会把要判断的东西发给你配的服务：
  看图、按画面分类时发缩小的图，复核时发可疑的那几行字，按字分类时发认出的字。不配插件就什么都不发。
  怎么配、插件约定，见 [docs/plugins.zh-CN.md](docs/plugins.zh-CN.md)。

## 认不了或认不准的

表情符号、公式里的上下标、太小的字（字高不到约 8 像素）、印章那种沿弧线排的字、I 和 l 这类字体本身就分不清的、
合并的表格格子（会拆成空格）。表格线只认黑线，红底、浅灰线的表还是一行行出。签名认不出，手写的字没专门调过。

## 原理

自动模式怎么决定认法、PDF 什么时候用它自带的字、中文优先什么时候改回自动判断，见 [docs/how-it-works.zh-CN.md](docs/how-it-works.zh-CN.md)。

## 开发

开发规矩见 [AGENTS.md](AGENTS.md)，改动记录见 [CHANGELOG.md](CHANGELOG.md)，界面规范见 [docs/design-spec.md](docs/design-spec.md)。

```bash
./scripts/setup-hooks.sh   # 克隆后跑一次：启用提交钩子（检查 CHANGELOG、版本号 +1）
./scripts/test.sh          # 单元测试
./scripts/test-hooks.sh    # 测提交钩子
```

`./scripts/build-app.sh --sign`、`--release` 用你自己的 Developer ID 签名、公证，怎么设见脚本开头。
`./scripts/publish-release.sh` 把 `--release` 打好的包发到 GitHub 的 Releases 页。
验收脚本 `bench/bench.mjs` 要用作者本机的一组测试图，测试图不在这个仓库里。

## 许可证

[MIT](LICENSE)。
