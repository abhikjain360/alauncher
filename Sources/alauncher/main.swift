import AppKit
import Core
import Dictation
import Launcher

// No arguments starts the app. A subcommand runs once in the terminal and exits.
// Microphone and keyboard features need the app launched through `open`, so macOS
// attributes the permissions to alauncher rather than to the terminal.

let arguments = Array(CommandLine.arguments.dropFirst())

let usage = """
    usage: alauncher [command]

      (no command)            run the app
      check-config            validate config.toml and secrets.toml
      search <query>          print launcher results
      calc <expression>       evaluate like the launcher's calculator row
      index                   list every launcher item
      transcribe <audio>      transcribe an audio file with the speech model
      cleanup <text>          run the dictation cleanup on text
      ask <question>          ask the Ask backend
      dictate-file <audio>    transcribe, then ask or clean up, and print

    """

func loadConfig() -> Config {
    do {
        let configText = (try? String(contentsOf: Paths.configFile, encoding: .utf8)) ?? ""
        let secretsText = try? String(contentsOf: Paths.secretsFile, encoding: .utf8)
        var config = try ConfigLoader.load(configText: configText, secretsText: secretsText)
        try ConfigLoader.resolveSecrets(&config, secretsText: secretsText)
        return config
    } catch {
        FileHandle.standardError.write(Data("alauncher: \(error)\n".utf8))
        exit(78)
    }
}

func runCommand(_ arguments: [String]) async -> Int32 {
    switch arguments.first {
    case "help", "-h", "--help":
        print(usage)
        return 0
    case "check-config":
        _ = loadConfig()
        print("config ok: \(Paths.configFile.path)")
        return 0
    case "search", "calc", "index":
        return await LauncherCLI.run(arguments, config: loadConfig())
    case "transcribe", "cleanup", "ask", "dictate-file":
        return await DictationCLI.run(arguments, config: loadConfig())
    default:
        FileHandle.standardError.write(Data("alauncher: unknown command \(arguments.first ?? "")\n\n\(usage)".utf8))
        return 64
    }
}

if let index = arguments.firstIndex(of: "--spike") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let spikeArguments = Array(arguments[(index + 1)...])
    DispatchQueue.main.async { Spike.run(spikeArguments) }
    app.run()
} else if let first = arguments.first, !first.hasPrefix("-") {
    // The main queue must stay free: Ask streaming delivers on it.
    Task { @MainActor in
        let status = await runCommand(arguments)
        Log.main.flush()
        exit(status)
    }
    dispatchMain()
} else {
    // Top-level code starts on the main thread.
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
