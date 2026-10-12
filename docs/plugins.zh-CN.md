# 判定插件

[English](plugins.md) | 简体中文

判定插件是可选的独立小程序：核心在认之前、认完、给照片分类时问它几个问题，它只回概率，所有门槛和「怎么认」都由核心定。
不配插件，拾字照常工作，什么都不往外发。

## 配置

写在配置文件 `~/.config/shizi/config.json`（或环境变量 `SHIZI_CONFIG` 指定的文件）的 `plugins` 里，每个插件一项。
`name` 自己起，也是钥匙串里存它密钥的账号：

```json
{
  "plugins": [
    {
      "name": "clef",
      "command": ["/绝对路径/ocr-plugin-systemone"],
      "hooks": ["route", "review"],
      "env": { "SYSTEMONE_URL": "http://<地址>:<端口>", "SYSTEMONE_MODEL": "clef" }
    },
    {
      "name": "jev",
      "command": ["/绝对路径/ocr-plugin-systemone"],
      "hooks": ["review"],
      "env": { "SYSTEMONE_URL": "https://api.typesafe.ai", "SYSTEMONE_MODEL": "jev-latest" },
      "enabled": false
    }
  ]
}
```

每项还可以有 `timeoutMs`（每次最多等多久，默认 route 1500、review 3000）和 `enabled: false`（先停用）。
拾字的「设置 › 判定插件」改的就是这一段：可以加、改、停用、删；换了地址又没重填密钥，旧密钥会删掉。

## 约定（第 2 版）

插件是独立的小程序。核心每次调用时启动它，往标准输入写一行 `{"protocol":2,"hook":"<口子>","input":{...}}`，
它往标准输出回一行 `{"output":{...}}` 或 `{"error":"原因"}`。
超时、出错、回的不是 JSON，一律当这一步没有插件，照常按代码规则走，并在结果的说明里写一句。

插件进程只拿到几个环境变量（`HOME`、`LOGNAME`、`PATH`、`SHELL`、`TERM`、`USER`、`LANG`、`TMPDIR`、`LC_*`、`XDG_*`），
加上 `OCR_PLUGIN_NAME`（这一项的 `name`）、`OCR_PLUGIN_LANGUAGE`（核心给人看的字用的语言，`en` 或 `zh-Hans`，出错和说明照它写）
和这一项的 `env`；别的环境变量（里面可能有别的服务的密钥）不传。

| 口子 | 输入 | 输出 |
|---|---|---|
| `describe` | `{"hooks":[这一项接的口子]}` | 随意，`ocr_status` 原样显示；其中 `warnings`（字符串数组）单独列出来 |
| `route`（认之前） | `{"image":{"data","width","height"}}`：`data` 是 base64 的 PNG（长边不超过 1600），宽高是原图的 | `{"signals":{"vertical","table","columns","photo","curved","tiny"}}`，每项 0–1，可以只给一部分 |
| `review`（认完） | `{"lines":[{"id","text","confidence"}],"candidates":[id]}` | `{"suspects":{"<id>": 认错的概率}}`，只需回 candidates 里的 |
| `classify`（照片分类） | `{"questions":[{"id","criteria"}],"text":"认出的字"}` 或 `{"questions":[…],"image":{"data","type":"jpeg","width","height"}}`：一组题（编号、判断标准），加一段字（长字核心先分好段，每段最多 1600 字）或一张缩小的照片（base64 的 JPEG，长边 360，宽高是发过去的这张的） | `{"scores":{"<id>": 是的概率}}`，每道题都要回 |

核心怎么用这些概率：

- `table`、`columns`、`vertical` 到 0.5 就再认一遍文档，`photo` 到 0.5 就拉正，`tiny` 到 0.5 就切块细认，`curved` 只在说明里加一句。
- `review` 的概率到 0.5，这一行标成可疑。
- `classify` 到 0.8 才算是：按主题分时，到 0.8 算是这一类，可以同时是几类，都不到算「待确认」；按一句条件找时，
  到 0.8 算符合、不到 0.2 算不符合、中间算待确认。长字每 1600 字一段，段与段重叠 100 字，每道题取各段里最高的。

插件不是每页都会被叫到：`route` 只在认法是「自动」时走；`review` 只在有系统没把握的长行时走，干净的截图常常一行都没有；
拾字认照片默认不用插件。

想知道某一页插件做了什么，在拾字里点工具栏的「识别详情」（ⓘ）：看了图说了什么、复核了几行、花了多久，没用上也写明为什么；
逐行里插件看过的行会标出来。`detail=full` 的 JSON 里，每页的 `steps` 有 `route`、`review`（每个插件一项：名字、用时、结果或出错原因）、
`reviewedLines`（第几行 → 插件认为认错的概率）和 `reviewCandidates`（这一页有几行要复核），没配插件时不写这几项。

## System One 判定插件

`ocr-plugin-systemone` 把看图、复核、分类这几件事交给一个 System One 判定服务。Clef、TypeSafe Jev、灵犀的判定网关说的都是这个约定
（`POST /v1/systemone`：`{model, state, questions}` → `answers[id].noul`），所以只有这一个插件，接哪家、叫什么都写在配置里。

- `SYSTEMONE_URL`：必填，服务地址（末尾带不带 `/v1/systemone` 都行，不能带用户名密码）。
- `SYSTEMONE_MODEL`：必填，模型名，比如 `clef`、`jev-latest`、`lingxi-decision`。
- `SYSTEMONE_PROXY`：要经代理才连得上时填，默认直连。
- 密钥存钥匙串，账号就是这一项的 `name`：在拾字的设置里填，或者 `security add-generic-password -s shizi -a <name> -w`
  （`-w` 放在最后，回车以后再输密钥，密钥不进命令行记录）。别写进配置文件。改名前存在 `-s mac-ocr-mcp` 下面的也认。
- `shizi-mcp status` 和拾字设置里的「测试连接」会测一遍：先问一道答案明摆着的题，答对才算通，显示耗时和服务报的模型版本；再看收不收图。
  `route` 和看画面分类要发图，不收图的服务（比如灵犀的判定网关）只能接 `review` 和看字分类；`route` 接错了会提醒。
  出错时只说固定的几种话，不带服务的原话。

它用系统自带的 `/usr/bin/curl` 发请求：macOS 的「本地网络」隐私保护会拦下没被允许过的新程序访问局域网里的设备
（连得上服务、却收不到回复），系统自带的 curl 不受影响。密钥经环境变量交给 curl，不出现在命令行参数里。
