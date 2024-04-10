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

func fileUrl(forGodotResourcePath resourcePath: String) -> URL {
    getGodotProjectURL().appendingPathComponent(resourcePath.removingStringPrefix("res://"))
}

func getGodotProjectURL() -> URL {
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
