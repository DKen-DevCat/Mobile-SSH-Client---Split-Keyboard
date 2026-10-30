import Foundation

// splitterm: Mobile-SSH-Client---Split-Keyboard の設定と運用（docs/design.md「Get Started と MCP」）
let env = Environment.live()
let args = Array(CommandLine.arguments.dropFirst())

if args.first == "mcp" {
    MCPServer(commands: Commands(env: env), doctor: Doctor(env: env)).serve()
    exit(0)
}

let result = CLI.run(args, env: env)
if !result.output.isEmpty {
    let text = result.output + "\n"
    if result.exitCode == 0 {
        FileHandle.standardOutput.write(Data(text.utf8))
    } else {
        FileHandle.standardError.write(Data(text.utf8))
    }
}
exit(result.exitCode)
