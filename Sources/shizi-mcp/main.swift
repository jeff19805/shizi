import Foundation
import OCRCore
import OCRServer

// 改名前（mac-ocr-mcp）的配置文件复制到新位置，只第一次。放在程序入口、不放进 CLI.main：测试会直接调 CLI 里的东西，不能动到真的配置。
OCRConfig.copyOldConfigIfNeeded()
exit(CLI.main(CommandLine.arguments))
