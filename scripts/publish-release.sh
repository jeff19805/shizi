#!/bin/sh
# 把 scripts/build-app.sh --release 打好的包发到 GitHub 的 Releases 页：标签 v版本号，附上 dmg 和 zip，
# 说明里先讲怎么装（英文、中文各一段），再附 CHANGELOG 里自上次发布以来各版的条目（头一回发只附这一版的）。
#   ./scripts/publish-release.sh           直接发布：是公开的，谁都能下载，跑之前先问用户。
#   ./scripts/publish-release.sh --draft   只存成草稿，在网页上看过再点发布。
#   ./scripts/publish-release.sh --notes   只把说明印出来看看，什么都不发。
# 次序：提交 → 推到 origin 的 main → build-app.sh --release → 这个脚本。包里记着从哪个提交编的，发的就是那个提交：
# 编完别的会话又提交了也不要紧，标签照样打在编包的提交上，不用重编。
# 用 gh 发：gh 登录的账号要能往这个仓库推；不是的话设 GH_TOKEN（细粒度令牌要有这个仓库 Contents 的读写权限）。
set -e
cd "$(dirname "$0")/.."
MODE=${1:-publish}
case "$MODE" in
publish | --draft | --notes) ;;
*)
	echo "用法：scripts/publish-release.sh [--draft | --notes]" >&2
	exit 2
	;;
esac
fail() {
	echo "$1" >&2
	exit 1
}
command -v gh > /dev/null || fail "要先装 GitHub 的命令行工具 gh（brew install gh）。"

OUT=.build/app/release
# 发哪个提交：有包就是编包的那个提交；还没编包时 --notes 看 HEAD 的。
if [ -f "$OUT/提交.txt" ]; then
	COMMIT=$(cat "$OUT/提交.txt")
elif [ "$MODE" = --notes ]; then
	COMMIT=$(git rev-parse HEAD)
else
	fail "没有 $OUT/提交.txt：先跑 scripts/build-app.sh --release。"
fi
# 版本号、更新记录都从这个提交里取，不读工作区：工作区里可能有别的会话还没提交的改动。
VERSION=$(git show "$COMMIT:VERSION" | tr -d ' \n')
TAG=v$VERSION
NAME=Shizi-$VERSION-mac-universal
REPO=$(git remote get-url origin | sed -E 's#^(https://github\.com/|git@github\.com:)##; s#\.git$##')
[ "$COMMIT" = "$(git rev-parse HEAD)" ] || echo "（发的是编包的提交 $(git rev-parse --short "$COMMIT")，$TAG；HEAD 已经往后走了）" >&2

# 说明。上一次发布的版本号问 GitHub（不靠本机的标签：本机不一定拉过）。
PREV=$(gh release view --repo "$REPO" --json tagName --jq .tagName 2> /dev/null | sed 's/^v//' || true)
CHANGES=$(git show "$COMMIT:CHANGELOG.md" | awk -v cur="$VERSION" -v prev="$PREV" '
	function key(v, a) { split(v, a, "."); return (a[1] * 1000 + a[2]) * 1000 + a[3] }
	/^## / {
		v = $0
		sub(/^## \[/, "", v)
		sub(/\].*$/, "", v)
		on = v ~ /^[0-9]+\.[0-9]+\.[0-9]+$/ && key(v) <= key(cur) && (prev == "" ? (key(v) == key(cur)) : (key(v) > key(prev)))
		if (on) print "### " v
		next
	}
	on { print }
')
NOTES=$(mktemp)
trap 'rm -f "$NOTES"' EXIT
{
	# 一段写成一行：发布说明里的换行在 GitHub 上会照样断开，折行会把句子断在半截。
	cat << EOF
**Install**: download \`$NAME.dmg\`, open it, and drag Shizi to Applications. It is signed with a Developer ID and notarized by Apple. It runs on Macs with Apple silicon or Intel processors and macOS 14 or later; tables, columns, and vertical text need macOS 26. The \`.zip\` holds the same app. The MCP server is inside the app: \`/Applications/Shizi.app/Contents/MacOS/shizi-mcp\`.

**安装**：下载 \`$NAME.dmg\`，打开后把拾字拖进「应用程序」。用 Developer ID 签名、经苹果公证。Apple 芯片和 Intel 的 Mac 都能用，要 macOS 14 或更新（表格、多栏、竖排要 macOS 26）。\`.zip\` 里是同一个 App。MCP 服务在 App 里：\`/Applications/Shizi.app/Contents/MacOS/shizi-mcp\`。
EOF
	[ -z "$CHANGES" ] || printf '\n## What’s changed / 改了什么\n\n%s\n' "$CHANGES"
	printf '\nFull change log (in Chinese) / 全部改动：[CHANGELOG.md](https://github.com/%s/blob/%s/CHANGELOG.md)\n' "$REPO" "$TAG"
} > "$NOTES"
if [ "$MODE" = --notes ]; then
	cat "$NOTES"
	exit 0
fi

# 1. 包是这个版本的。
for f in "$OUT/$NAME.dmg" "$OUT/$NAME.zip"; do
	[ -f "$f" ] || fail "没有 $f：先跑 scripts/build-app.sh --release。"
done

# 2. 提交已经在 GitHub 的 main 上：标签要打在别人拉得到的提交上，下载的 App 和源码才对得上。
git fetch -q origin main
git merge-base --is-ancestor "$COMMIT" origin/main || fail "提交 $COMMIT 还没推到 origin 的 main：先推（git push origin main）。"

# 3. 这个版本还没发过；gh 的账号能往仓库推。
if gh release view "$TAG" --repo "$REPO" > /dev/null 2>&1; then
	fail "$TAG 已经发过（或者存着同名的草稿）：https://github.com/$REPO/releases/tag/$TAG"
fi
[ -z "$(git ls-remote --tags origin "refs/tags/$TAG")" ] || fail "GitHub 上已经有标签 $TAG，却没有对应的发布：先看看它指着哪个提交。"
[ "$(gh api "repos/$REPO" --jq .permissions.push 2> /dev/null || true)" != false ] ||
	fail "gh 现在登录的账号不能往 $REPO 推：换个账号（gh auth switch），或者设 GH_TOKEN。"

# 4. 发。标签让 GitHub 打在这个提交上，不在本机打了再推：推标签容易顺手把别的引用也带上去。
if [ "$MODE" = --draft ]; then set -- --draft; else set --; fi
gh release create "$TAG" "$OUT/$NAME.dmg" "$OUT/$NAME.zip" --repo "$REPO" --target "$COMMIT" \
	--title "Shizi $VERSION" --notes-file "$NOTES" "$@"

# 5. 校验 GitHub 上的文件跟本机的一模一样。正式发布的从公开地址整个下载下来比：别人下载到的就是它；
#    草稿还没有公开地址，比 GitHub 给每个附件算的 sha256。
for f in "$NAME.dmg" "$NAME.zip"; do
	want=$(shasum -a 256 "$OUT/$f" | cut -d ' ' -f 1)
	if [ "$MODE" = --draft ]; then
		got=$(gh release view "$TAG" --repo "$REPO" --json assets --jq ".assets[] | select(.name == \"$f\") | .digest // empty")
		got=${got#sha256:}
		[ -n "$got" ] || { echo "GitHub 没给 $f 的校验值，没比。" >&2; continue; }
	else
		got=$(curl -sfL --retry 3 --retry-all-errors "https://github.com/$REPO/releases/download/$TAG/$f" | shasum -a 256 | cut -d ' ' -f 1)
	fi
	[ "$got" = "$want" ] || fail "GitHub 上的 $f 跟本机的不一样：在网页上删掉这个发布（连标签）再重发。"
done
URL=$(gh release view "$TAG" --repo "$REPO" --json url --jq .url)
if [ "$MODE" = --draft ]; then
	echo "存成草稿了：$URL（在网页上看过再点 Publish release）"
else
	echo "发布了：$URL"
fi
