# Judgment plugins

English | [简体中文](plugins.zh-CN.md)

A judgment plugin is an optional, separate small program. Shizi's core asks it a few questions before recognition, after
recognition, and when classifying photos. The plugin only returns probabilities; every threshold and every decision about how to
recognize stays in the core. Without a plugin, Shizi works as usual and sends nothing anywhere.

## Configuration

Plugins go under `plugins` in the configuration file `~/.config/shizi/config.json` (or the file named by the `SHIZI_CONFIG`
environment variable), one entry per plugin. You choose the `name`; it is also the keychain account that holds the plugin's API key:

```json
{
  "plugins": [
    {
      "name": "clef",
      "command": ["/absolute/path/to/ocr-plugin-systemone"],
      "hooks": ["route", "review"],
      "env": { "SYSTEMONE_URL": "http://<host>:<port>", "SYSTEMONE_MODEL": "clef" }
    },
    {
      "name": "jev",
      "command": ["/absolute/path/to/ocr-plugin-systemone"],
      "hooks": ["review"],
      "env": { "SYSTEMONE_URL": "https://api.typesafe.ai", "SYSTEMONE_MODEL": "jev-latest" },
      "enabled": false
    }
  ]
}
```

Each entry can also have `timeoutMs` (how long to wait per call; 1500 for route and 3000 for review by default) and
`enabled: false` (to turn the plugin off for now). Settings › Judgment Plugins in Shizi edits this part of the file: you can add,
edit, turn off, and delete plugins. If you change a plugin's URL without entering its API key again, the old key is deleted.

## Protocol (version 2)

A plugin is a separate small program. The core starts it for each call and writes one line to its standard input,
`{"protocol":2,"hook":"<hook>","input":{...}}`; the plugin replies with one line on its standard output, `{"output":{...}}` or
`{"error":"reason"}`. A timeout, an error, or a reply that isn't JSON is treated as if there were no plugin for that step: the core
goes on with its own rules and adds a note to the result.

The plugin process receives only a few environment variables (`HOME`, `LOGNAME`, `PATH`, `SHELL`, `TERM`, `USER`, `LANG`,
`TMPDIR`, `LC_*`, `XDG_*`), plus `OCR_PLUGIN_NAME` (the entry's `name`) and the entry's `env`. Other environment variables, which
may hold keys for other services, are not passed on.

| Hook | Input | Output |
|---|---|---|
| `describe` | `{"hooks":[the hooks this entry uses]}` | Anything; `ocr_status` shows it as is, listing `warnings` (an array of strings) separately |
| `route` (before recognition) | `{"image":{"data","width","height"}}`: `data` is a base64 PNG (at most 1600 px on the long side); width and height are the original's | `{"signals":{"vertical","table","columns","photo","curved","tiny"}}`, each from 0 to 1; any subset is fine |
| `review` (after recognition) | `{"lines":[{"id","text","confidence"}],"candidates":[id]}` | `{"suspects":{"<id>": probability that it's misrecognized}}`, for the candidates only |
| `classify` (photo classification) | `{"questions":[{"id","criteria"}],"text":"recognized text"}` or `{"questions":[…],"image":{"data","type":"jpeg","width","height"}}`: a set of questions (id and criteria) plus either text (the core splits long text into chunks of at most 1600 characters) or a downscaled photo (a base64 JPEG, 360 px on the long side; width and height are those of the image sent) | `{"scores":{"<id>": probability of yes}}`, for every question |

How the core uses the probabilities:

- At 0.5, `table`, `columns`, and `vertical` trigger document recognition, `photo` triggers straightening, and `tiny` triggers
  splitting into tiles; `curved` only adds a note.
- A `review` probability of 0.5 or more marks the line as suspicious.
- `classify` needs 0.8 for a yes. When sorting into categories, a photo belongs to every category that reaches 0.8; if none does,
  it is Unsure. When finding photos that match a condition, 0.8 or more is a match, under 0.2 is not, and anything in between is
  Unsure. Long text is split into chunks of 1600 characters that overlap by 100, and each question takes the highest score among
  the chunks.

Plugins aren't called on every page: `route` runs only when the recognition mode is Automatic, and `review` runs only when there are
long lines the system isn't sure about, which clean screenshots often don't have. Photos are recognized without plugins by default.

To see what the plugins did on a page, click Recognition Details (ⓘ) in Shizi's toolbar: it shows what the image check reported,
how many lines were reviewed, and how long it took, or why a plugin wasn't used. Lines a plugin looked at are marked in Line by Line.
In the `detail=full` JSON, each page's `steps` include `route` and `review` (one item per plugin: name, time, and result or error),
`reviewedLines` (line number → probability the plugin thinks it's misrecognized), and `reviewCandidates` (how many lines on the page
needed review); they are left out when no plugin is configured.

## The System One judgment plugin

`ocr-plugin-systemone` hands image checks, reviews, and classification to a System One judgment service. Clef, TypeSafe Jev, and
Lingxi's judgment gateway all speak this protocol (`POST /v1/systemone`: `{model, state, questions}` → `answers[id].noul`), so this
is the only plugin you need; which service it talks to and what it's called are set in the configuration.

- `SYSTEMONE_URL`: required. The service URL, with or without `/v1/systemone` at the end, and without a user name or password.
- `SYSTEMONE_MODEL`: required. The model name, such as `clef`, `jev-latest`, or `lingxi-decision`.
- `SYSTEMONE_PROXY`: set it when the service can only be reached through a proxy; connections are direct by default.
- The API key is stored in the keychain, with the entry's `name` as the account. Enter it in Shizi's Settings, or run
  `security add-generic-password -s shizi -a <name> -w` (with `-w` last, you type the key after pressing Return, so it doesn't end
  up in your command history). Never put it in the configuration file. Keys stored under `-s mac-ocr-mcp` before the rename still work.
- `shizi-mcp status` and Test Connection in Shizi's Settings check the service: they ask a question with an obvious answer and
  count the service as working only if it answers correctly, show the time taken and the model version the service reports, and
  then check whether it accepts images. `route` and classifying by image send images, so a service that doesn't accept images
  (such as Lingxi's judgment gateway) can only be used for `review` and classifying by text; you are warned if `route` is set up
  on one. Errors are reported as one of a few fixed messages, never in the service's own words.

The plugin sends requests with the system's own `/usr/bin/curl`. macOS's Local Network privacy protection stops newly built
programs that haven't been allowed from reaching devices on the local network (they can connect to the service but never receive a
reply), and the system curl isn't affected. The API key is passed to curl through an environment variable, never on the command line.
