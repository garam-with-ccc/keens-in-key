import Foundation
import KeensInKeyCore

// Minimal command-line front end: `kik analyze <files…>` prints key / BPM / energy / cues.

func usage() -> Never {
    let text = """
    Keens In Key command line

    Usage:
      kik analyze [--json] [--profile shaath|edma|krumhansl|temperley] [--similarity cosine|pearson] [--frame-norm]
                  [--min-bpm N] [--max-bpm N] <file|folder> …
      kik tags <file> …              Print the tags stored in files
      kik write [--key 8A] [--bpm 128] [--energy 7] [--notation camelot|openKey|traditional] [--no-comment] [--grouping] <file> …
                                     Write key / BPM / energy tags (uses the analysis result when --key is omitted)
      kik export --csv|--rekordbox|--m3u <out> <file|folder> …   Analyse and export
      kik keys                       Print the Camelot wheel
      kik compat <key>               Print keys compatible with <key> (e.g. 8A, Am, 1m)
    """
    print(text)
    exit(1)
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { usage() }
args.removeFirst()

func collectFiles(_ paths: [String]) -> [URL] {
    var urls: [URL] = []
    let fm = FileManager.default
    for p in paths {
        let url = URL(fileURLWithPath: p)
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue {
            if let e = fm.enumerator(at: url, includingPropertiesForKeys: nil) {
                for case let u as URL in e where AudioDecoder.isSupported(u) { urls.append(u) }
            }
        } else if AudioDecoder.isSupported(url) {
            urls.append(url)
        }
    }
    return urls.sorted { $0.path < $1.path }
}

switch command {
case "analyze":
    var json = false
    var options = TrackAnalyzer.Options()
    var paths: [String] = []
    var i = 0
    while i < args.count {
        let a = args[i]
        switch a {
        case "--json": json = true
        case "--profile":
            i += 1; if i < args.count, let p = KeyProfile(rawValue: args[i]) { options.keyProfile = p }
        case "--similarity":
            i += 1; if i < args.count, let p = KeyDetector.Similarity(rawValue: args[i]) { options.keySimilarity = p }
        case "--frame-norm": options.keyFrameNormalization = true
        case "--octaves": i += 1; if i < args.count, let v = Int(args[i]) { options.keyOctaves = v }
        case "--lowest-midi": i += 1; if i < args.count, let v = Int(args[i]) { options.keyLowestMIDI = v }
        case "--harmonics": i += 1; if i < args.count { options.keyHarmonicWeights = args[i].split(separator: ",").compactMap { Double($0) } }
        case "--octave-decay": i += 1; if i < args.count, let v = Double(args[i]) { options.keyOctaveDecay = v }
        case "--log": i += 1; if i < args.count, let v = Double(args[i]) { options.keyLogCompression = v }
        case "--prior-bpm": i += 1; if i < args.count, let v = Double(args[i]) { options.tempoPriorBPM = v }
        case "--prior-sigma": i += 1; if i < args.count, let v = Double(args[i]) { options.tempoPriorSigma = v }
        case "--tempo-flux": i += 1; if i < args.count, let v = Double(args[i]) { options.tempoFluxCompression = v }
        case "--tempo-bass": i += 1; if i < args.count, let v = Double(args[i]) { options.tempoBassWeight = v }
        case "--tempo-harmonics": i += 1; if i < args.count { options.tempoHarmonicWeights = args[i].split(separator: ",").compactMap { Double($0) } }
        case "--min-bpm":
            i += 1; if i < args.count, let v = Double(args[i]) { options.minBPM = v }
        case "--max-bpm":
            i += 1; if i < args.count, let v = Double(args[i]) { options.maxBPM = v }
        default: paths.append(a)
        }
        i += 1
    }
    let files = collectFiles(paths)
    if files.isEmpty { usage() }
    let analyzer = TrackAnalyzer(options: options)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    for url in files {
        let start = Date()
        do {
            let r = try analyzer.analyze(url: url)
            let elapsed = Date().timeIntervalSince(start)
            if json {
                var dict: [String: Any] = [
                    "file": url.path,
                    "key": r.key.key.camelot,
                    "keyName": r.key.key.traditional,
                    "keyConfidence": r.key.confidence,
                    "tuning": r.key.tuning,
                    "bpm": r.tempo.bpm,
                    "bpmConfidence": r.tempo.confidence,
                    "energy": r.energy,
                    "loudnessDb": r.loudnessDb,
                    "duration": r.duration,
                    "seconds": elapsed,
                    "cues": r.cuePoints.map { ["name": $0.name, "time": $0.time, "bar": $0.bar ?? 0, "energy": $0.energy] },
                    "keyCandidates": r.key.candidates.map { [$0.key.camelot, $0.score] },
                    "bpmCandidates": r.tempo.candidates.map { [$0.bpm, $0.score] },
                ]
                dict["firstDownbeat"] = r.tempo.firstDownbeat
                let data = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
                print(String(data: data, encoding: .utf8)!)
            } else {
                let cues = r.cuePoints.map { "\($0.name)@\($0.time.timeString)" }.joined(separator: ", ")
                print(String(format: "%@\n  key %@ (%@)  conf %.2f  tuning %+.1f | bpm %.2f conf %.2f | energy %d (%.1f dBFS) | %.1fs | %.2fs\n  cues: %@",
                             url.lastPathComponent, r.key.key.camelot, r.key.key.traditional, r.key.confidence, r.key.tuning,
                             r.tempo.bpm, r.tempo.confidence, r.energy, r.loudnessDb, r.duration, elapsed, cues))
            }
        } catch {
            print("\(url.lastPathComponent): ERROR \(error.localizedDescription)")
        }
    }
case "tags":
    let files = collectFiles(args)
    if files.isEmpty { usage() }
    let sem = DispatchSemaphore(value: 0)
    Task {
        for url in files {
            let f = await TagService.read(url)
            print(url.lastPathComponent)
            print("  title: \(f.title ?? "-")  artist: \(f.artist ?? "-")  album: \(f.album ?? "-")")
            print("  key: \(f.initialKey ?? "-")  bpm: \(f.bpm ?? "-")  energy: \(f.energy ?? "-")  grouping: \(f.grouping ?? "-")")
            print("  comment: \(f.comment ?? "-")")
        }
        sem.signal()
    }
    sem.wait()
case "write":
    var options = TagWritingOptions()
    var forcedKey: MusicalKey?
    var forcedBPM: Double?
    var forcedEnergy: Int?
    var paths: [String] = []
    var i = 0
    while i < args.count {
        let a = args[i]
        switch a {
        case "--key": i += 1; if i < args.count { forcedKey = MusicalKey.parse(args[i]) }
        case "--bpm": i += 1; if i < args.count { forcedBPM = Double(args[i]) }
        case "--energy": i += 1; if i < args.count { forcedEnergy = Int(args[i]) }
        case "--notation": i += 1; if i < args.count, let n = KeyNotation(rawValue: args[i]) { options.notation = n }
        case "--no-comment": options.writeComment = false
        case "--grouping": options.writeGrouping = true
        case "--overwrite-comment": options.commentMode = .overwrite
        case "--rename": options.renameFile = true
        case "--prefix-title": options.prefixTitle = true
        default: paths.append(a)
        }
        i += 1
    }
    let files = collectFiles(paths)
    if files.isEmpty { usage() }
    let analyzer = TrackAnalyzer()
    let sem = DispatchSemaphore(value: 0)
    Task {
        for url in files {
            do {
                let existing = await TagService.read(url)
                var result: AnalysisResult
                if let k = forcedKey, let b = forcedBPM {
                    let ke = KeyEstimate(key: k, confidence: 1, strength: 1, tuning: 0, chroma: [], candidates: [])
                    let te = TempoEstimate(bpm: b, confidence: 1, beats: [], downbeatPhase: 0, candidates: [])
                    result = AnalysisResult(duration: 0, key: ke, tempo: te, energy: forcedEnergy ?? 5, energyScore: 0.5, loudnessDb: -12, cuePoints: [], waveform: [], energyCurve: [])
                } else {
                    result = try analyzer.analyze(url: url)
                    if let k = forcedKey { result.key.key = k }
                    if let b = forcedBPM { result.tempo.bpm = b }
                    if let e = forcedEnergy { result.energy = e }
                }
                let title = existing.title ?? url.deletingPathExtension().lastPathComponent
                let artist = existing.artist ?? ""
                let fields = TagService.fields(for: result, existing: existing, options: options, title: title, artist: artist)
                let rename = options.renameFile ? options.expand(options.fileNameFormat, key: result.key.key, energy: result.energy, bpm: result.tempo.bpm, title: title, artist: artist) : nil
                let newURL = try await TagService.write(fields, to: url, rename: rename)
                print("\(url.lastPathComponent) -> key \(fields.initialKey ?? "-") bpm \(fields.bpm ?? "-") comment \"\(fields.comment ?? "-")\"\(newURL != url ? " renamed to \(newURL.lastPathComponent)" : "")")
            } catch {
                print("\(url.lastPathComponent): ERROR \(error.localizedDescription)")
            }
        }
        sem.signal()
    }
    sem.wait()
case "export":
    guard args.count >= 3 else { usage() }
    let mode = args[0]
    let outURL = URL(fileURLWithPath: args[1])
    let files = collectFiles(Array(args.dropFirst(2)))
    if files.isEmpty { usage() }
    let analyzer = TrackAnalyzer()
    let sem = DispatchSemaphore(value: 0)
    Task {
        var rows: [ExportTrack] = []
        for url in files {
            let tags = await TagService.read(url)
            let result = try? analyzer.analyze(url: url)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            rows.append(ExportTrack(url: url, title: tags.title ?? url.deletingPathExtension().lastPathComponent, artist: tags.artist ?? "", album: tags.album ?? "", genre: tags.genre ?? "", fileSize: size, result: result))
            print("analysed \(url.lastPathComponent)")
        }
        let text: String
        switch mode {
        case "--csv": text = Exporters.csv(rows, notation: .camelot)
        case "--rekordbox": text = Exporters.rekordboxXML(rows)
        case "--m3u": text = Exporters.m3u(rows)
        default: usage()
        }
        try? text.write(to: outURL, atomically: true, encoding: .utf8)
        print("wrote \(outURL.path)")
        sem.signal()
    }
    sem.wait()
case "keys":
    for n in 1...12 {
        let a = MusicalKey.fromCamelot(number: n, mode: .minor)
        let b = MusicalKey.fromCamelot(number: n, mode: .major)
        print(String(format: "%3dA %-4@ %-4@   %3dB %-4@ %-4@", n, a.traditional, a.openKey, n, b.traditional, b.openKey))
    }
case "compat":
    guard let k = args.first, let key = MusicalKey.parse(k) else { usage() }
    print("\(key.camelot) \(key.longName)")
    for c in key.compatibleKeys { print("  \(c.camelot)  \(c.traditional)  \(key.relation(to: c).label)") }
    print("  \(key.energyBoostKey.camelot)  \(key.energyBoostKey.traditional)  Energy boost")
default:
    usage()
}
