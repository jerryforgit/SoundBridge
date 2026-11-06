import Foundation
import Darwin

// MARK: - CLI

struct Options {
    var inputUID = kDefaultInputUID
    var outputUID = kDefaultOutputUID
    var duration: Double? = nil
    var logPath = "~/Library/Logs/SoundBridge/engine.log"
}

func printUsage() {
    print("""
    SoundBridge engine v0

    Usage:
      ./engine [options]

    Options:
      --input-uid <uid>   default: \(kDefaultInputUID)
      --output-uid <uid>  default: \(kDefaultOutputUID) (LECOO)
      --duration <sec>    stop after N seconds
      --log <path>        default: ~/Library/Logs/SoundBridge/engine.log
      -h, --help
    """)
}

func parseOptions() -> Options {
    var options = Options()
    var index = 1
    let args = CommandLine.arguments
    while index < args.count {
        switch args[index] {
        case "--input-uid":
            index += 1
            if index < args.count { options.inputUID = args[index] }
        case "--output-uid":
            index += 1
            if index < args.count { options.outputUID = args[index] }
        case "--duration":
            index += 1
            if index < args.count, let value = Double(args[index]) { options.duration = value }
        case "--log":
            index += 1
            if index < args.count { options.logPath = args[index] }
        case "-h", "--help":
            printUsage()
            exit(0)
        default:
            fputs("unknown argument: \(args[index])\n", stderr)
            printUsage()
            exit(2)
        }
        index += 1
    }
    return options
}

let options = parseOptions()
let logger = Logger(path: options.logPath)
logger.log("==== engine log opened: \(options.logPath) ====")

var outputUID = options.outputUID
if findDevice(uid: outputUID) == nil,
   let detected = physicalDisplayOutputs().first,
   let detectedUID = deviceUID(detected) {
    outputUID = detectedUID
    logger.log("output UID not found; auto-detected physical output: id=\(detected) " +
               "name=\(deviceName(detected) ?? "?") uid=\(detectedUID) transport=\(transportName(detected))")
}

let engine = Engine(inputUID: options.inputUID, outputUID: outputUID, log: logger)

signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigintSource.setEventHandler { engine.stop(reason: "SIGINT"); exit(0) }
sigintSource.resume()
let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigtermSource.setEventHandler { engine.stop(reason: "SIGTERM"); exit(0) }
sigtermSource.resume()

if let duration = options.duration, duration > 0 {
    DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
        engine.stop(reason: "duration \(duration)s reached")
        exit(0)
    }
}

engine.start()
RunLoop.main.run()
