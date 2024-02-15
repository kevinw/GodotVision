/**

Extensions for interop between RealityKit and SwiftGodot types.

*/

//  Created by Kevin Watters on 1/3/24.

import Foundation
import SwiftGodot
import RealityKit
import Spatial
import SwiftUI

func uiColor(forGodotColor c: SwiftGodot.Color) -> UIColor {
    .init(red: .init(c.red), green: .init(c.green), blue: .init(c.blue), alpha: .init(c.alpha))
}

extension SwiftGodot.Vector3 {
    init(_ point3D: Spatial.Point3D) {
        self.init(x: Float(point3D.x), y: Float(point3D.y), z: Float(point3D.z))
    }
    
    init(_ v: simd_float3) {
        self.init(x: v.x, y: v.y, z: v.z)
    }
}

extension simd_float3 {
    init(_ godotVector: SwiftGodot.Vector3) {
        self.init(godotVector.x, godotVector.y, godotVector.z)
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

extension SwiftGodot.Quaternion {
    init(_ quat: simd_quatf) {
        self.init()
        let imaginary = quat.imag
        self.w = quat.real
        self.z = imaginary.z
        self.y = imaginary.y
        self.x = imaginary.x
    }
    
    init(_ quat: simd_quatd) {
        self.init()
        let imaginary = quat.imag
        self.w = Float(quat.real)
        self.z = Float(imaginary.z)
        self.y = Float(imaginary.y)
        self.x = Float(imaginary.x)
    }
}

extension simd_quatf {
    init(_ godotQuat: SwiftGodot.Quaternion) {
        self.init(ix: godotQuat.x, iy: godotQuat.y, iz: godotQuat.z, r: godotQuat.w)
    }
}

protocol InitsFromVariant {
    init?(_ variant: Variant)
}

extension PackedInt32Array: InitsFromVariant {}
extension PackedVector3Array: InitsFromVariant {}
extension PackedVector2Array: InitsFromVariant {}

extension SwiftGodot.Variant {
    /// A utility method for initializing a specific type from a Variant. Prints an error message if the cast fails.
    func cast<T>(as t: T.Type, debugName: String = "value", printError: Bool = true) -> T? where T: InitsFromVariant {
        guard let result = T(self) else {
            if printError { print("expected \(debugName) to be castable to a \(T.self) - gtype is \(gtype)") }
            return nil
        }
        
        return result
    }
}

extension Float {
    // TODO: probably shouldn't be here
    func isApproximatelyEqualTo(_ f: Self) -> Bool {
        abs(self - f) < 0.000001
    }
}

extension simd_float3 {
    // TODO: probably shouldn't be here
    func isApproximatelyEqualTo(_ v: Self) -> Bool {
        x.isApproximatelyEqualTo(v.x) &&
        y.isApproximatelyEqualTo(v.y) &&
        z.isApproximatelyEqualTo(v.z)
    }
}
