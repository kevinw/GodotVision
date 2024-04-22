//  Created by Kevin Watters on 1/10/24.

import Foundation
import libgodot
import SwiftGodot
import SwiftGodotKit

extension Object {
    func getMetaBool(_ name: String, defaultValue: Bool) -> Bool {
        Bool(getMeta(name: StringName(name), default: Variant(defaultValue))) ?? defaultValue
    }
}

extension PackedByteArray {
    /// Returns a new Data object with a copy of the data contained by this PackedByteArray
    public func asDataNoCopy() -> Data? {
        withUnsafeMutableAccessToData { ptr, count in 
            Data(bytesNoCopy: ptr, count: count, deallocator: .none)
        }
    }
}

extension String {
    func removingStringPrefix(_ prefix: String) -> String {
        if starts(with: prefix) {
            let r = index(startIndex, offsetBy: prefix.count)..<endIndex
            return String(self[r])
        }
        
        return self
    }
}

func initHook(_ level: GDExtension.InitializationLevel) {
    switch level {
    case .scene:
        // SwiftGodot.register(type: MyCustomGodotObjectTypeHere.self)
        ()
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
