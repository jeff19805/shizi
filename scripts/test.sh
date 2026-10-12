#!/bin/sh
# 跑单元测试。没装 Xcode 时，命令行工具里的测试框架（Swift Testing）不在默认搜索路径上，要手动指一下。
# 一条一条地跑（--no-parallel）：系统的文字识别内部要用 Swift 并发的协作线程，测试并行时十几条一起同步调识别，
# 把协作线程全占住，识别自己要的那一个线程等不到，整个测试卡死（并行时卡过很久都跑不完；一条条跑反而很快）。
set -e
cd "$(dirname "$0")/.."
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
L=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
if [ -d "$F/Testing.framework" ] && ! xcode-select -p | grep -q Xcode.app; then
	exec swift test -Xswiftc -F -Xswiftc "$F" -Xlinker -F -Xlinker "$F" -Xlinker -rpath -Xlinker "$F" -Xlinker -rpath -Xlinker "$L" --no-parallel "$@"
fi
exec swift test --no-parallel "$@"
