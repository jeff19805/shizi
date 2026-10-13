#!/bin/sh
# 编出「拾字」App：swift build → 组装 .build/app/Shizi.app → 签名。
#   ./scripts/build-app.sh            本机自签（ad-hoc）：自己用、开发用。
#   ./scripts/build-app.sh --sign     用 Developer ID 签名，不公证：本机先试正式的签名。
#   ./scripts/build-app.sh --release  Developer ID 签名 → 公证（App 会传给苹果）→ 钉上票据 → 打 zip、dmg → 逐项校验。
#                                     产物在 .build/app/release/。要先提交：App 的版本号得跟提交对得上。
#                                     发到 GitHub 的 Releases 页用 scripts/publish-release.sh。
# --sign、--release 用谁的身份签名因人而异，不写进仓库：设环境变量，或者写进本机的 scripts/app/signing.env（不进仓库），脚本会读它。
#   SHIZI_MAC_IDENTITY        必填，「Developer ID Application: 名字 (十位团队号)」
#   SHIZI_MAC_KEYCHAIN        证书所在的钥匙串，默认是登录钥匙串
#   SHIZI_MAC_NOTARY_PROFILE  --release 必填：xcrun notarytool store-credentials 存进那个钥匙串的公证配置名
#   SHIZI_MAC_UNLOCK_SCRIPT   签名前先跑的解锁钥匙串的脚本，不填就不解锁
# App 里带上 shizi-mcp（给灵犀、Claude Code 用的识别服务）和 ocr-plugin-systemone（判定插件），跟 App 同一个版本。
# App 本身签名时带上 scripts/app/Shizi.entitlements：开了 hardened runtime 的 App 不声明「照片图库」，系统不让它读照片。
set -e
cd "$(dirname "$0")/.."
MODE=${1:-local}
case "$MODE" in
local | --sign | --release) ;;
*)
	echo "用法：scripts/build-app.sh [--sign | --release]" >&2
	exit 2
	;;
esac
if [ "$MODE" = "--release" ]; then
	if [ -n "$(git status --porcelain -- Sources Package.swift scripts VERSION)" ]; then
		echo "有没提交的改动：先提交再出正式版（App 的版本号要跟提交对得上）。" >&2
		exit 1
	fi
	# 只有出正式版要 git：从发布页下的源码包里没有 .git，本机自签照样能编。
	COMMIT=$(git rev-parse HEAD)
fi
# 签名的设置先查齐，免得编了一分钟才发现没设。
if [ "$MODE" != "local" ]; then
	if [ -f scripts/app/signing.env ]; then . scripts/app/signing.env; fi
	IDENTITY=${SHIZI_MAC_IDENTITY:-}
	KEYCHAIN=${SHIZI_MAC_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}
	PROFILE=${SHIZI_MAC_NOTARY_PROFILE:-}
	UNLOCK=${SHIZI_MAC_UNLOCK_SCRIPT:-}
	[ -n "$IDENTITY" ] || { echo "没设签名身份：设 SHIZI_MAC_IDENTITY，或者写进 scripts/app/signing.env（见脚本开头）。" >&2; exit 1; }
	TEAM=$(printf '%s' "$IDENTITY" | sed -n 's/.*(\([A-Z0-9]\{10\}\))$/\1/p')
	[ -n "$TEAM" ] || { echo "身份「$IDENTITY」末尾要带十位的团队号，如 (ABCDE12345)" >&2; exit 1; }
	[ "$MODE" != "--release" ] || [ -n "$PROFILE" ] || { echo "要公证得先设 SHIZI_MAC_NOTARY_PROFILE（见脚本开头）。" >&2; exit 1; }
fi
VERSION=$(tr -d ' \n' < VERSION)
swift build -c release --product Shizi
swift build -c release --product shizi-mcp
swift build -c release --product ocr-plugin-systemone
BIN=$(swift build -c release --show-bin-path)
APP=.build/app/Shizi.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Shizi" "$BIN/shizi-mcp" "$BIN/ocr-plugin-systemone" "$APP/Contents/MacOS/"
sed "s/__VERSION__/$VERSION/g" scripts/app/Info.plist > "$APP/Contents/Info.plist"
# 界面的语言包：英文对照表（en.lproj/Localizable.strings）、简体和繁体中文，还有各语言的 App 名、照片权限的说明。
cp -R scripts/app/*.lproj "$APP/Contents/Resources/"
# 图标用代码画（scripts/app/make-icon.swift），画一次存在 .build 里，脚本改了再重画。
ICON=.build/app/Shizi.icns
if [ ! -f "$ICON" ] || [ scripts/app/make-icon.swift -nt "$ICON" ]; then
	rm -rf .build/app/Shizi.iconset
	swift scripts/app/make-icon.swift .build/app/Shizi.iconset
	iconutil -c icns .build/app/Shizi.iconset -o "$ICON"
fi
cp "$ICON" "$APP/Contents/Resources/Shizi.icns"

if [ "$MODE" = "local" ]; then
	# 由里到外签：先签带着的两个小程序，最后签 App 本身（不用 --deep，免得把别的东西也签上）。
	for f in shizi-mcp ocr-plugin-systemone; do
		codesign --force --sign - --options runtime "$APP/Contents/MacOS/$f"
	done
	codesign --force --sign - --options runtime --entitlements scripts/app/Shizi.entitlements "$APP"
	codesign --verify --strict "$APP"
	echo "$APP（$VERSION，本机自签）"
	exit 0
fi

# ---- Developer ID 签名（身份、钥匙串、公证配置在开头查过了）----
if [ -n "$UNLOCK" ] && [ -x "$UNLOCK" ]; then "$UNLOCK" > /dev/null; fi
security find-identity -v -p codesigning "$KEYCHAIN" | grep -F "\"$IDENTITY\"" > /dev/null ||
	{ echo "钥匙串 $KEYCHAIN 里没有能用的「$IDENTITY」" >&2; exit 1; }

sign() {
	# 第一个参数是要签的东西，后面的另加给 codesign（要签的东西得放在最后）。
	# 签名要连苹果的时间戳服务器（timestamp.apple.com）；连不上时 codesign 报「A timestamp was expected」。
	target=$1
	shift
	codesign --sign "$IDENTITY" --force --keychain "$KEYCHAIN" --timestamp --options runtime "$@" "$target" ||
		{ echo "签名没成：$target。要是报 timestamp，多半是连不上 timestamp.apple.com（公司网络要走代理）。" >&2; exit 1; }
}
for f in shizi-mcp ocr-plugin-systemone; do sign "$APP/Contents/MacOS/$f"; done
sign "$APP" --entitlements scripts/app/Shizi.entitlements

# 校验一个 App：签名完整、是这个身份和团队、开了 hardened runtime、带时间戳、带「照片图库」权限；要求公证过时再看票据和 Gatekeeper 的判定。
check() {
	app=$1
	notarized=$2
	codesign --verify --deep --strict --verbose=2 "$app" 2> /dev/null || { echo "签名校验没过：$app" >&2; exit 1; }
	info=$(codesign -dvv "$app" 2>&1)
	for want in "Authority=$IDENTITY" "TeamIdentifier=$TEAM" "Timestamp=" "Identifier=com.jiecan.shizi"; do
		printf '%s\n' "$info" | grep -F "$want" > /dev/null || { echo "签名里没有「$want」：$app" >&2; exit 1; }
	done
	printf '%s\n' "$info" | grep -E "flags=.*runtime" > /dev/null || { echo "没开 hardened runtime：$app" >&2; exit 1; }
	codesign -d --entitlements - "$app" 2>&1 | grep -F "com.apple.security.personal-information.photos-library" > /dev/null ||
		{ echo "签名里没有「照片图库」权限：$app" >&2; exit 1; }
	for f in shizi-mcp ocr-plugin-systemone; do
		codesign -dvv "$app/Contents/MacOS/$f" 2>&1 | grep -F "TeamIdentifier=$TEAM" > /dev/null || { echo "$f 没用同一个身份签：$app" >&2; exit 1; }
	done
	if [ "$notarized" = yes ]; then
		xcrun stapler validate "$app" > /dev/null || { echo "没钉上公证票据：$app" >&2; exit 1; }
		spctl --assess --type execute --verbose=2 "$app" 2>&1 | grep -F "source=Notarized Developer ID" > /dev/null ||
			{ echo "Gatekeeper 不认：$app" >&2; exit 1; }
	fi
}
check "$APP" no
if [ "$MODE" = "--sign" ]; then
	echo "$APP（$VERSION，Developer ID 签名，没公证）"
	exit 0
fi

# ---- 公证、钉票据、打包（只公证、钉 .app；dmg 不另签，靠里面钉好的 App，跟灵犀一样）----
OUT=.build/app/release
rm -rf "$OUT"
mkdir -p "$OUT"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/公证用.zip"
echo "公证中（把 App 传给苹果，一般几分钟）……"
xcrun notarytool submit "$OUT/公证用.zip" --keychain "$KEYCHAIN" --keychain-profile "$PROFILE" --wait --output-format json > "$OUT/公证结果.json" || true
STATUS=$(plutil -extract status raw -o - "$OUT/公证结果.json" 2> /dev/null || echo "")
if [ "$STATUS" != "Accepted" ]; then
	ID=$(plutil -extract id raw -o - "$OUT/公证结果.json" 2> /dev/null || echo "")
	echo "公证没过（${STATUS:-没拿到结果}）。" >&2
	[ -n "$ID" ] && xcrun notarytool log "$ID" --keychain "$KEYCHAIN" --keychain-profile "$PROFILE" >&2
	exit 1
fi
rm "$OUT/公证用.zip"
xcrun stapler staple -v "$APP" > /dev/null
check "$APP" yes

NAME="Shizi-$VERSION-mac-arm64"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/$NAME.zip"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
# dmg 的卷名、拖放用的快捷方式都用英文名：下载的人什么语言都有，中文系统上「应用程序」文件夹的本名也是 Applications。
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Shizi" -srcfolder "$STAGE" -ov -format UDZO "$OUT/$NAME.dmg" > /dev/null
rm -rf "$STAGE"

# 从打好的包里拿出来再校验一遍：别人下载到的就是这个。
UNZIP=$(mktemp -d)
ditto -x -k "$OUT/$NAME.zip" "$UNZIP"
check "$UNZIP/Shizi.app" yes
rm -rf "$UNZIP"
MOUNT=$(mktemp -d)
hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT" "$OUT/$NAME.dmg" > /dev/null
check "$MOUNT/Shizi.app" yes
hdiutil detach "$MOUNT" > /dev/null
# 编、公证的这几分钟里别的会话可能提交或改了代码：那包里是哪一版就说不清了，不能拿去发。
# 对得上就记下提交号，publish-release.sh 照它把标签打在编包的提交上。
if [ "$(git rev-parse HEAD)" != "$COMMIT" ] || [ -n "$(git status --porcelain -- Sources Package.swift scripts VERSION)" ]; then
	echo "编的时候代码变了（有了新提交或没提交的改动），包对不上提交 $COMMIT，别发：等代码停下来再重出。" >&2
	exit 1
fi
printf '%s\n' "$COMMIT" > "$OUT/提交.txt"
echo "$OUT/$NAME.zip"
echo "$OUT/$NAME.dmg"
echo "（$VERSION，Developer ID 签名，公证过，票据钉好了）"
