/**

Extensions for interop between RealityKit and SwiftGodot types.

*/

//  Created by Kevin Watters on 1/3/24.

import Foundation
import SwiftGodot
import RealityKit
import Spatial
import SwiftUI

//
// RealityKit
//

func uiColor(forGodotColor c: SwiftGodot.Color) -> UIColor {
    .init(red: .init(c.red), green: .init(c.green), blue: .init(c.blue), alpha: .init(c.alpha))
}

extension RealityKit.Transform {
    init(_ godotTransform: SwiftGodot.Transform3D) {
        self.init(scale: .init(godotTransform.basis.getScale()),
                  rotation: .init(godotTransform.basis.getRotationQuaternion()),
                  translation: .init(godotTransform.origin))
    }
}

extension simd_float4x4 {
    init(_ godotTransform: SwiftGodot.Transform3D) {
        self = RealityKit.Transform(godotTransform).matrix
    }
}

extension simd_float3 {
    init(_ godotVector: SwiftGodot.Vector3) {
        self.init(godotVector.x, godotVector.y, godotVector.z)
    }
    
    // TODO: probably shouldn't be here
    func isApproximatelyEqualTo(_ v: Self) -> Bool {
        x.isApproximatelyEqualTo(v.x) &&
        y.isApproximatelyEqualTo(v.y) &&
        z.isApproximatelyEqualTo(v.z)
    }
}

extension simd_float4 {
    init(_ godotVector: SwiftGodot.Vector4) {
        self.init(godotVector.x, godotVector.y, godotVector.z, godotVector.w)
    }
}

extension simd_float2 {
    init(_ godotVector: SwiftGodot.Vector2) {
        self.init(godotVector.x, godotVector.y)
    }
}

extension simd_quatf {
    init(_ godotQuat: SwiftGodot.Quaternion) {
        self.init(ix: godotQuat.x, iy: godotQuat.y, iz: godotQuat.z, r: godotQuat.w)
    }
}

//
// Godot
//

extension SwiftGodot.Variant {
    /// A utility method for initializing a specific type from a Variant. Prints an error message if the cast fails.
    func cast<T>(as t: T.Type, debugName: String = "value", printError: Bool = true, functionName: String = #function) -> T? where T: InitsFromVariant {
        guard let result = T(self) else {
            if printError {
                logError("expected \(debugName) to be castable to a \(T.self)", functionName: functionName)
            }
            return nil
        }
        
        return result
    }
}

extension SwiftGodot.Vector3 {
    init(_ point3D: Spatial.Point3D) {
        self.init(x: Float(point3D.x), y: Float(point3D.y), z: Float(point3D.z))
    }
    
    init(_ v: simd_float3) {
        self.init(x: v.x, y: v.y, z: v.z)
    }
}


extension Float {
    // TODO: probably shouldn't be here
    func isApproximatelyEqualTo(_ f: Self) -> Bool {
        abs(self - f) < 0.000001
    }
}

protocol InitsFromVariant { init?(_ variant: Variant) }

extension PackedInt32Array: InitsFromVariant {}
extension PackedFloat32Array: InitsFromVariant {}
extension PackedFloat64Array: InitsFromVariant {}
extension PackedVector3Array: InitsFromVariant {}
extension PackedVector2Array: InitsFromVariant {}

