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

func getGodotProjectURL() -> URL {
    let projectFolderName = "Godot_Project"
    guard let url = Bundle.main.url(forResource: projectFolderName, withExtension: nil) else {
        fatalError("ERROR: could not find '\(projectFolderName)' folder in Bundle.main")
    }
    return url
}

func getProjectDir() -> String {
    // Godot is expecting a path without the file:// part for the packfile
    return getGodotProjectURL().absoluteString.removingStringPrefix("file://")
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
        if let resourcePath = audioStreamPlayer3D.stream?.resourcePath {
            let godotInstanceID = audioStreamPlayer3D.getInstanceId()
            onAudioStreamPlayed?(.init(godotInstanceID: Int64(godotInstanceID),
                                       resourcePath: resourcePath,
                                       volumeDb: audioStreamPlayer3D.volumeDb))
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

