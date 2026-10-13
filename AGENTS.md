# 开发规矩

给参与这个项目的人和 AI 看。用法见 README.zh-CN.md（英文版是 README.md），自动模式怎么认见 docs/how-it-works.zh-CN.md，插件约定见 docs/plugins.zh-CN.md（英文版去掉 .zh-CN）。

## 项目是什么

拾字（shizi，0.0.35 及以前叫 mac-ocr-mcp）：把 macOS 自带的文字识别做成 App 和 MCP 服务（`shizi-mcp`）。核心只用系统框架、不联网；判定插件（接 Clef、Jev 这类判定服务）是可选的独立小程序，不装也照常工作。

| 目录 | 内容 |
|---|---|
| `Sources/OCRCore` | 识别核心：读图和 PDF、PDF 文字层、逐行识别、认文档与合并、切块与接缝拼接、拉正、阅读顺序、插件调用、结果排版；照片库（拾字认过的照片里的字，SQLite） |
| `Sources/OCRServer` | MCP 服务（标准输入输出上的 JSON-RPC）和命令行 |
| `Sources/shizi-mcp` | MCP 服务和命令行的程序入口（启动时把改名前的配置复制到新位置） |
| `Sources/ocr-plugin-systemone` | System One 判定插件（Clef、Jev 等都走它，名字和地址写在配置里）；不依赖核心，只按插件约定说话 |
| `Sources/ShiziKit` | 拾字 App 的界面和数据（SwiftUI）；认字只在 `Recognizer` 的串行队列上做；照片图库在 `PhotoLibrary` 接口后面（真的用 PhotoKit，测试用假的） |
| `Sources/Shizi` | 拾字 App 的壳（`@main`），只把 ShiziKit 挂进窗口和菜单 |
| `Sources/shizi-snapshots` | 开发用：把拾字的界面画成图片（浅色、深色各一张），评审界面用，不进 App |
| `Tests/OCRTests` | 单元测试和端到端测试；测试图都在测试里现画，不存图片文件 |
| `bench/bench.mjs` | 用研究目录里的测试图验收 |
| `scripts/` | `test.sh` 跑测试、`setup-hooks.sh` 装提交钩子、`test-hooks.sh` 测提交钩子、`build-app.sh` 编拾字 App（默认本机自签；`--sign` Developer ID 签名；`--release` 再公证、打包，会把 App 传给苹果，跑之前先问用户；签名身份写在本机的 `app/signing.env`，不进仓库；`app/` 里是 Info.plist 和画图标的脚本）、`publish-release.sh` 把 `--release` 打好的包发到 GitHub 的 Releases 页（发出去谁都能下载，跑之前先问用户；`--draft` 只存草稿，`--notes` 只看说明） |
| `.githooks/pre-commit` | 提交钩子：检查 CHANGELOG、版本号 +1 |
| `docs/design-spec.md` | 拾字的界面规范：改界面先看它 |
| `docs/how-it-works.md`、`docs/plugins.md` | 自动模式怎么认、判定插件的约定（英文；中文版是同名的 .zh-CN.md）：改了识别流程、插件约定要跟着改 |
| `docs/plans/` | 方案：一件事一份，文件名「日期-主题.md」（如 `2026-10-09-app.md`），做完一批在里面记一笔。别往根目录放。只在本机、不进仓库（在 .gitignore 里），评审记录 `docs/reviews/` 也一样：里面有实测数字和真文件的细节 |

## 写代码

- 只用系统框架，不加 SwiftPM 依赖。Swift 5 语言模式。
- 发布版编译不许有警告：`swift build -c release`。
- 改了代码要跑 `./scripts/test.sh`，全过才提交；加功能、修坑要配测试。
- 改了拾字的界面要出图看一眼：`swift run shizi-snapshots <输出文件夹> <测试图文件夹>`（测试图文件夹里放研究目录的
  receipt.png、table.png，和 short.pdf、long.pdf 两个多页 PDF：README.zh-CN.md 和一份 30 来页的中文文档（比如本机 docs/plans 里的方案）用 Chrome 打印成 A4，几页和 30 多页），
  浅色、深色都看，对着 `docs/design-spec.md` 查。界面有中文、英文两种，后面加 `-AppleLanguages '(en)'` 再出一份英文的，看有没有字被截断。
- 拾字界面上的中文直接写在代码里，英文写进 `scripts/app/en.lproj/Localizable.strings`（键是中文原文，占位符 `Int` 用 `%lld`、`String` 用 `%@`）。
  SwiftUI 接口直接收字面量的（`Text("…")`、`Button("…")`、`.help("…")`……）自己会按语言取字；先存进 `String` 的要写成 `String(localized: "…")`。
  句子里别直接插小数：`Double` 插进去会被格式化成 0.500000（中文界面也是），先转成文字。不是给人看的中文（存设置的键、发给判定服务的题目、
  写进别的程序的字、用户的内容）不翻，加进 `LocalizationTests` 的 `untranslated`。漏翻的、用不上的英文，`LocalizationTests` 都会报。
- 识别核心、MCP 服务、判定插件里给人看的字（工具说明和回复、命令行提示、结果里的说明、插件报的错）写成 `Texts.text("…")`，
  英文进同一张对照表；语言跟 App 一样定（`Sources/OCRCore/Texts.swift`，插件里有一份拷贝，改了两边一起改）。翻过的字别存进
  `static let` 或全局 `let`：测试要在一个进程里来回切中英文。发给判定服务的题目、匹配用的字表这些不是给人看的，别包。
  分类的默认类别包了（编辑框里、筛选条上都给人看），但中文那份一个字都别改：用它分好的照片按这几行字算的指纹找分数，测试钉着指纹。
  固定标签（待确认、符合条件、不符合条件）也算在指纹里，一直存中文，只在显示时翻。
  `EnglishOutputTests` 在英文下跑一遍工具说明、命令行、结果排版、认图、写文件，输出里有汉字就报。
- 改了识别流程（`Pipeline`、`Tiles`、`Document`、`Rectify`、`Reading`、`Lines` 里的判断）要跑验收：
  改之前先跑 `node bench/bench.mjs <研究目录> --label 改前` 当基准，改完再跑 `--label 改后`，比两次的平均分、低于研究最好的张数和耗时
  （结果在 `bench/out/`，不进仓库）。分数掉了要么修，要么在提交说明里写清原因。
  研究目录：`~/.claude/projects/-Users-jeff-code-workspace-lingxi-new/research/2026-10-09-apple-ocr-limits/`（不在仓库里）。
- 仓库是公开的（MIT）。真文件里的人名、公司名、工程名、金额别抄进注释、测试、文档、提交说明，要举例就编（「某某路桥建设」「王小明」）；
  签名身份、密钥、局域网里的地址也别写进来，本机路径只留上面研究目录那一条。真文件和它们的标准答案只放研究目录。
- 合成测试图比真文件干净，改识别流程最好再拿一份真扫描件或真照片看一眼（真扫描件上查出过合成图看不出的毛病：认文档在扫描件上字差，逐行识别遇到表格顺序乱）。
- 每个门槛、每条规则都写清「为什么」，照现有注释的写法讲理由。实测数字、测试文件的代号和页码不写进注释、文档（仓库是公开的），
  记在本机的方案里（`docs/plans/`）。注释、文档、给人看的输出都用中文、大白话。
- README 和 docs/ 里的原理、插件约定都有两份：英文的用原名（README.md 是 GitHub 首页），中文的是同名加 .zh-CN.md。
  改了一份要同步改另一份，内容一一对应。
- 坐标一律 0–1、左上角为原点；系统接口是左下角为原点，进出时各翻一次。
- 插件只给概率，所有门槛和「怎么认」都由核心定；核心不认任何插件的名字，不写默认地址；密钥不进任何文件。
- 已知的坑：
  - 调插件时管道要关 SIGPIPE、写管道用 `write(contentsOf:)`，否则插件不读输入就退出会把服务带崩。
  - 新编译的程序访问局域网会被 macOS「本地网络」保护拦（连得上、收不到回复），所以插件发请求用 `/usr/bin/curl`。
  - zsh 里变量不会按空格拆成几个参数，写测试命令别指望它。
  - 判定插件的密钥只经系统自带的 `/usr/bin/security` 读写（拾字存、插件读都用它），换成系统接口存，插件去读会弹确认。
    存的时候密钥写成十六进制、从标准输入给 `security -i`，别放进命令行参数。钥匙串那条路平时的测试不碰，改了相关代码跑
    `SHIZI_KEYCHAIN_TEST=1 ./scripts/test.sh --filter 钥匙串`。
  - 系统的文字识别（macOS 26）内部要用 Swift 并发的协作线程。在协作线程上同时同步调太多识别，会把这些线程全占住、互相等死：
    测试并行时卡死过，所以 `scripts/test.sh` 一条条跑。App 里认字放到专门的线程或串行队列上，别在一堆 Task 里同步调。
  - 照片授权跟着签名走：本机自签的 App 每编一次都算新程序，授权就丢了。试照片用 `scripts/build-app.sh --sign` 编，
    在仓库根目录用 `open -a "$PWD/.build/app/Shizi.app"` 启动（`open -a` 只认绝对路径，给 `.build/…` 这种相对路径会说找不到 App；
    在终端里直接跑里面的可执行文件，授权会算到终端头上）。
    自检：`open -a "$PWD/.build/app/Shizi.app" --args --photos-check 报告.json`，报告别放桌面、文稿、下载（这几个文件夹要另外授权）。
  - PhotoKit 取图的回调在主线程上来：识别队列上等它可以，主线程不能反过来等识别队列。
  - SwiftUI 重建列表、网格时，新格子的 onAppear 常常先于旧格子的 onDisappear（同一个编号）。靠这两个记「哪些格子露着」的，
    按个数记，别按有没有记：不然旧格子一收，新格子的东西也跟着放掉了（拾字的照片网格撞上过：刚打开拾字点相簿一片空白）。
  - 中栏连续滚动不能只靠 `scrollPosition(id:)` 报的中间页：横版末页到不了中线，滚到底会漏选。现在用原生滚动容器的实际位置，
    首尾短页局部补偿；主动跳页与滚动选页分开，不用固定时间屏蔽回调。定位等排版完成，并扣掉工具栏占位（本机顶部是 -52，不是 0）。
  - PDF 横竖混排不能让 `LazyVStack` 估页高：长文件上它估的总高跟实际差得远，模型已经选中后面的页，原图却还没滚到。
    按已知页尺寸排好位置，只建可见页和前后各一页；测试同时查原图实际位置、页码、右栏，不能只查选中了第几页。
  - 屏幕外窗口没有正常的显示刷新，合成滚轮事件不能可靠驱动滚动动画。离屏测试和截图可以直接改 `NSClipView` 位置来验联动，
    鼠标、触控板的输入和惯性手感仍要在屏幕上的窗口里亲手试，不能拿前一种测试代替。
  - 系统的文字识别不指定语言时，是一行一行判断用哪种语言的模型：字母、数字多的行用西文模型，行里的汉字认成乱码；短的中文常被当成日文。
    指定语言时只用列表里第一个语言的模型（`["en-US","zh-Hans"]` 只用英文模型，汉字认不出）。中文模型认西文页反而更慢，
    还会丢掉 á、ñ 这类字母，所以「中文优先」要有改回自动判断的兜底。这些合成测试图量不出来（图小、中文行很少夹算式），改语言相关的要拿研究目录 `real/` 的真文件看。
  - 系统「找字的位置」（`VNDetectTextRectanglesRequest`）会把卡通插画、大图里第一遍认不清的小字也当成字块，只看盖住率会把中文页误判成「中文认不了」。
  - 跑验收时插件和识别语言照配置文件走：拾字里开了「中文优先」，验收就是中文优先的分数。要比默认做法，用 `SHIZI_CONFIG` 指一份空配置。
  - PDF 文字层：PDFKit 的 `characterBounds(at:)` 在浏览器导出的 PDF 上跟 `page.string` 的下标对不上（取出来是别的字的框），
    位置只能用 `page.selection(for: 范围).bounds(for:)`；偶尔一个字的选区框从页顶跨到页底（PDFKit 也找不到它），这种段不给框。
    PDFKit 照样把扫描件上的隐形 OCR 字当文字给出来，所以先用 `CGPDFScanner` 数可见字、隐形字（文字模式 3、7）、图片，再决定用不用。
  - PDF 页面的资源（图片、字体）可以写在上级页面树节点里，`CGPDFPageGetDictionary` 不帮你合并，要顺着 `Parent` 往上找（`pageResources`）。
    `CGPDFScanner` 的回调里别弹超过操作数的个数：栈弹空了 CoreGraphics 会记一条「stack underflow」、终端里多一句「has logged an error」。
    文字层上框选要用 PDFKit 按框选字（`page.selection(for:)`），按整行中心筛会取不到半行、或带出框外的字。
  - 测试里 `Fixtures.pdf` 现画的 PDF 有文字层，默认走文字层、不认图：要测认图的，用只有图片的页（`makePDF` + `picture`）或者 `textLayer = false`。
  - 光看行框分不清「一格折成三行」和「三排单行格子」（扫描的表格上，两个三行的格子一行对一行，几何上跟三排单行一样），所以按格子排只认表格线（`Rules.swift`），
    没画线的页照旧一行行排。别拿缝宽、对齐去猜着并格子：收据、紧排的键值表会被出成一整列品名再一整列价钱。
    整页外面套一个框（证书、试卷、带边框的表单）时，框里的行四面也有线：框里的字自己又分成两栏的不能当一格（`holdsColumns`），不然两栏一行行交错。
    系统会把挨得近的相邻两格认成一行（「施工某某路桥建设」），这一行整个归进一格；要切开得有每个字的位置，现在只有切块贴边的行才算。
  - 量阅读顺序时，西文数字 PDF 的答案是它自带的文字，表格里是一行行横着扫的（标签夹在它自己那几条中间），按格子读反而算错；
    表格页用研究目录 `real/gt/` 里按格子读的那份答案，原答案只当回归闸（原来没错的页还得没错）。
  - 照片库是 WAL 模式的 SQLite。MCP 服务那边「只读」是读写方式打开再禁写（`query_only`）：系统的 SQLite 用只读方式开 WAL 库，
    旁边的 -wal、-shm 文件不在就打不开。

## 提交

- 克隆后先跑一次 `scripts/setup-hooks.sh`。
- 提交钩子做两件事：
  1. **CHANGELOG**：改了程序（`Sources/` 或 `Package.swift`）的提交，必须在 `CHANGELOG.md` 的「## [未发布]」下面写上改了什么，并且暂存。只改文档、测试、脚本的不用。不改行为的重构可以 `SKIP_CHANGELOG=1 git commit …`。
  2. **版本号**：`0.0.x` 每次提交自动 +1（只改文档也 +1），写进 `VERSION` 和 `Sources/OCRCore/Version.swift`，并把「未发布」那段落成这个版本号。要跳到 `0.1.0` 之类就手动改 `VERSION` 再提交，钩子照它的。改上一次提交（`--amend`）不再进位。别手改 `Version.swift`。
- 钩子会改 `VERSION`、`Version.swift`、`CHANGELOG.md`，所以这三个文件提交前不能有没暂存的改动。
- 别用 `--no-verify` 跳过钩子。改了钩子要跑 `scripts/test-hooks.sh`。
- 提交信息：`类型: 中文标题`，类型用 feat / fix / docs / test / chore。正文写清：问题是什么、改完以后怎样、关键做法，以及实际跑了哪些验证（单元测试、验收分数、真文件），没验的也写上。
- CHANGELOG 写给用这个工具的人看：改了什么、对使用有什么影响，不写实现细节。
