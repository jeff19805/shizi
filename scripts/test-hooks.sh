#!/bin/sh
# 在临时仓库里把各种提交情况真跑一遍，检验 .githooks/pre-commit。改了钩子就跑。
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
repo=$(mktemp -d)
trap 'rm -rf "$repo"' EXIT
cd "$repo"
git init -q
mkdir -p .githooks Sources/OCRCore Tests
cp "$here/.githooks/pre-commit" .githooks/
git config core.hooksPath .githooks
git config user.name 钩子测试
git config user.email hook-test@example.invalid
pass=0
fails=0
ok() { pass=$((pass + 1)); printf '  对  %s\n' "$1"; }
bad() { fails=$((fails + 1)); printf '  错  %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
commit() { git commit -q "$@" >/dev/null 2>"$repo/.err"; }
version() { cat VERSION; }
changelog() { git show HEAD:CHANGELOG.md; }

printf '# 更新记录\n\n## [未发布]\n\n- 第一版\n' >CHANGELOG.md
echo 'print(1)' >Sources/OCRCore/A.swift
git add -A
commit -m 第一次
check "第一次提交版本号 0.0.1" '[ "$(version)" = 0.0.1 ]'
check "「未发布」落成 0.0.1" 'changelog | grep -q "^## \[0.0.1\] - " && [ -z "$(changelog | awk "/^## \\[未发布\\]/{f=1;next} /^## /{f=0} f&&NF")" ]'
check "条目挪到了 0.0.1 下面" 'changelog | awk "/^## \\[0.0.1\\]/{f=1;next} f" | grep -q "^- 第一版"'
check "生成的 Version.swift 跟着变" 'grep -q "\"0.0.1\"" Sources/OCRCore/Version.swift'

echo 'print(2)' >>Sources/OCRCore/A.swift
git add -A
if commit -m 没写记录; then bad "改了程序没写 CHANGELOG 应该被拦"; else ok "改了程序没写 CHANGELOG 被拦下"; fi
check "被拦时说清原因" 'grep -q "CHANGELOG" "$repo/.err"'
git reset -q

echo 文档 >README.md
git add README.md
commit -m 只改文档
check "只改文档不用写 CHANGELOG，版本号照样 +1 到 0.0.2" '[ "$(version)" = 0.0.2 ]'

echo 'test' >Tests/T.swift
git add Tests/T.swift
commit -m 只改测试
check "只改测试不用写 CHANGELOG（0.0.3）" '[ "$(version)" = 0.0.3 ]'

git add Sources/OCRCore/A.swift
printf '# 更新记录\n\n## [未发布]\n\n- 修了一个问题\n\n## [0.0.1] - 2026-10-09\n\n- 第一版\n' >CHANGELOG.md
git add CHANGELOG.md
commit -m 改程序带记录
check "改程序带记录：0.0.4" '[ "$(version)" = 0.0.4 ] && changelog | grep -q "^## \[0.0.4\] - "'

printf '# 更新记录\n\n## [未发布]\n\n- 补一条\n' >/dev/null
awk '/^## \[未发布\]/{print; print ""; print "- 补一条"; next} {print}' CHANGELOG.md >"$repo/.cl" && mv "$repo/.cl" CHANGELOG.md
echo 'print(3)' >>Sources/OCRCore/A.swift
git add -A
commit --amend -m 改程序带记录（补）
check "改上一次提交不进位（还是 0.0.4）" '[ "$(version)" = 0.0.4 ]'
check "改上一次提交时新条目接在同一个版本下面，不重复加标题" '[ "$(changelog | grep -c "^## \[0.0.4\]")" = 1 ] && changelog | awk "/^## \\[0.0.4\\]/{f=1;next} /^## /{f=0} f" | grep -q "补一条"'

echo 'print(4)' >>Sources/OCRCore/A.swift
git add -A
SKIP_CHANGELOG=1 commit -m 重构
check "SKIP_CHANGELOG=1 放行（0.0.5）" '[ "$(version)" = 0.0.5 ]'

echo 0.1.0 >VERSION
echo 'print(5)' >>Sources/OCRCore/A.swift
awk '/^## \[未发布\]/{print; print ""; print "- 大改版"; next} {print}' CHANGELOG.md >"$repo/.cl" && mv "$repo/.cl" CHANGELOG.md
git add -A
commit -m 跳版本
check "手动改 VERSION 时照它的（0.1.0）" '[ "$(version)" = 0.1.0 ] && changelog | grep -q "^## \[0.1.0\] - "'
echo 'print(6)' >>Sources/OCRCore/A.swift
SKIP_CHANGELOG=1 commit -a -m 接着提交
check "之后接着 +1（0.1.1）" '[ "$(version)" = 0.1.1 ]'

echo 'print(7)' >>Sources/OCRCore/A.swift
git add -A
awk '/^## \[未发布\]/{print; print ""; print "- 没暂存的条目"; next} {print}' CHANGELOG.md >"$repo/.cl" && mv "$repo/.cl" CHANGELOG.md
if commit -m 有没暂存的记录; then bad "CHANGELOG 有没暂存的改动应该被拦"; else ok "CHANGELOG 有没暂存的改动被拦下"; fi
git add CHANGELOG.md
commit -m 补上暂存
check "暂存后照常提交（0.1.2）" '[ "$(version)" = 0.1.2 ] && changelog | awk "/^## \\[0.1.2\\]/{f=1;next} /^## /{f=0} f" | grep -q "没暂存的条目"'

echo 'print(8)' >>Sources/OCRCore/A.swift
awk '/^## \[未发布\]/{print; print ""; print "- 取消后重提"; next} {print}' CHANGELOG.md >"$repo/.cl" && mv "$repo/.cl" CHANGELOG.md
git add -A
GIT_EDITOR=false commit >/dev/null 2>&1 || true
check "提交到一半取消：没产生提交（还是 0.1.2）" '[ "$(git show HEAD:VERSION)" = 0.1.2 ]'
commit -m 重新提交
check "取消后重提不会被拦、也不跳号（0.1.3）" '[ "$(version)" = 0.1.3 ] && changelog | awk "/^## \\[0.1.3\\]/{f=1;next} /^## /{f=0} f" | grep -q "取消后重提"'

printf '\n钩子测试：%s 项对，%s 项错\n' "$pass" "$fails"
[ "$fails" = 0 ]
