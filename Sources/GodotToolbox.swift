//  Created by Kevin Watters on 1/10/24.

import Foundation
import libgodot
import SwiftGodot
import SwiftGodotKit

extension String {
    func removingStringPrefix(_ prefix: String) -> String {
        if starts(with: prefix) {
            let r = index(startIndex, offsetBy: prefix.count)..<endIndex
            return String(self[r])
        }
        
        return self
    }
}

func getPackFileURLString() -> String {
    guard let url = Bundle.main.url(forResource: "minimal", withExtension: "pck") else {
        fatalError("ERROR: could not find minimal.pck in Bundle.main")
    }
    
    // Godot is expecting a path without the file:// part for the packfile
    return url.absoluteString.removingStringPrefix("file://")
}

public func discoverGodotProjectsInBundle() async -> [URL] {
    var godotProjectFiles = [URL]()
    if let resourceURL = Bundle.main.resourceURL, let enumerator = FileManager.default.enumerator(at: resourceURL, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
        for case let fileURL as URL in enumerator {
            let fileAttributes: URLResourceValues
            do {
                fileAttributes = try fileURL.resourceValues(forKeys:[.isRegularFileKey])
            } catch {
                print(error, fileURL)
                continue
            }
            
            if fileAttributes.isRegularFile ?? false, fileURL.pathExtension == "godot" {
                godotProjectFiles.append(fileURL)
            }
        }
    }
    
    let regex = try! Regex("config/name=\"(.+)\"")
    //let regex = /foo/
    for godotProjectFile in godotProjectFiles {
        do {
            for try await line in godotProjectFile.lines {
                // config/name="Gazewords"
                if let match = line.firstMatch(of: regex), match.count > 0, let substring = match[1].substring {
                    let projectName = String(substring)
                    print("PROJECT NAME", projectName)
                }

            }
        } catch {
            print(error)
        }
    }
    
    
    return .init()
    
}

func fileUrl(forGodotResourcePath resourcePath: String) -> URL {
    getGodotProjectURL().appendingPathComponent(resourcePath.removingStringPrefix("res://"))
}

func getGodotProjectURL() -> URL {
    
    /*
    print("------getGodotProjectURL------")
    
    

    
    for file in godotProjectFiles {
        
        print("  \(file)")
    }
     */
    
    
    
    let projectFolderName = "Godot_Project"
    guard let url = Bundle.main.url(forResource: projectFolderName, withExtension: nil) else {
        fatalError("ERROR: could not find '\(projectFolderName)' folder in Bundle.main")
    }
    return url
}

func getProjectDir() -> String {
    // Godot is expecting a path without the file:// part for the packfile
    getGodotProjectURL().absoluteString.removingStringPrefix("file://")
}

@Godot
class GodotSwiftBridge: Node3D {
    static var _instance: GodotSwiftBridge? = nil
    static var instance: GodotSwiftBridge {
        if _instance == nil {
            _instance = .init()
        }
        return _instance!
    }
    
    var onAudioStreamPlayed: ((_ playInfo: AudioStreamPlay) -> ())? = nil
    
    static func runLater(cb: @escaping () -> Void) {
        lock.withLock {
            cbs.append(cb)
        }
    }
    
    @Callable func onAudioStreamPlayerPlayed(audioStreamPlayer3D: AudioStreamPlayer3D) {
        onPlayOrPreload(audioStreamPlayer3D: audioStreamPlayer3D, prepareOnly: false)
    }
    
    @Callable func onAudioStreamPlayerPrepare(audioStreamPlayer3D: AudioStreamPlayer3D) {
        onPlayOrPreload(audioStreamPlayer3D: audioStreamPlayer3D, prepareOnly: true)
    }
    
    private func onPlayOrPreload(audioStreamPlayer3D: AudioStreamPlayer3D, prepareOnly: Bool) {
            
        if let resourcePath = audioStreamPlayer3D.stream?.resourcePath {
            let godotInstanceID = audioStreamPlayer3D.getInstanceId()
            onAudioStreamPlayed?(.init(godotInstanceID: Int64(godotInstanceID),
                                       resourcePath: resourcePath,
                                       volumeDb: audioStreamPlayer3D.volumeDb,
                                       prepareOnly: prepareOnly))
        }
    }
    
    private static func runCbs() {
        let callbacks = lock.withLock {
            let callbacks = cbs
            cbs.removeAll()
            return callbacks
        }
        
        for cb in callbacks {
            cb()
        }
    }
    
    static var lock = NSLock()
    static var cbs: [() -> Void] = []

    override func _input (event: InputEvent) {
        guard event.isPressed () && !event.isEcho () else { return }
        print ("SpinningCube: event: isPressed ")
    }
    
    public override func _process(delta: Double) {
        rotateY(angle: delta)
        
        Self.runCbs()
    }
}

func initHook(_ level: GDExtension.InitializationLevel) {
    switch level {
    case .scene:
        SwiftGodot.register(type: GodotSwiftBridge.self)
    default:
        ()
    }
}

//
// error logging
//

private func stripFunctionName(_ functionName: String) -> String {
    if let idx = functionName.firstIndex(of: Character("(")) {
        return String(functionName.prefix(upTo: idx))
    } else {
        return functionName
    }
}

func logError(_ message: String, functionName: String = #function) {
    print("⚠️ \(stripFunctionName(functionName)) ERROR: \(message)")
}

func logError(_ error: any Error, functionName: String = #function) {
    print("⚠️ \(stripFunctionName(functionName)) ERROR: \(error)")
}

func doLoggingErrors<R>(_ block: () throws -> R, functionName: String = #function) -> R? {
    do {
        return try block()
    } catch {
        logError(error, functionName: functionName)
    }
    
    return nil
}
