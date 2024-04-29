//  Created by Kevin Watters on 4/29/24.

import Foundation
import ARKit
import UIKit
import SwiftGodot
import RealityKit

struct ARState {
    var nodes: Set<Node3D> = .init()
    fileprivate var session: ARKitSession = .init()
    fileprivate var worldTracking: WorldTrackingProvider = .init()
    
    fileprivate var inited = false
}

extension GodotVisionCoordinator {
    func ensureARInited() {
        if ar.inited { return }
        ar.inited = true
        Task { await initAR() }
    }
    
    func initAR() async {
        do {
            try await ar.session.run([ar.worldTracking])
        } catch {
            logError("could not run ARSession wtp: \(error)")
        }
    }
    
    func arUpdate() {
        guard ar.nodes.count > 0, ar.worldTracking.state == .running, let deviceTransform = getDeviceTransform() else {
            return
        }
        
        let rkGlobalTransform = RealityKit.Transform(matrix: deviceTransform)
        let godotSpaceGlobalTransform = godotEntitiesParent.convert(transform: rkGlobalTransform, from: nil)
        let xform = Transform3D(godotSpaceGlobalTransform)
        
        Array(ar.nodes).forEach { node in
            if node.isInsideTree() {
                node.globalTransform = xform
            } else {
                ar.nodes.remove(node)
            }
        }
    }
    
    func getDeviceTransform() -> simd_float4x4? {
        guard let deviceAnchor = ar.worldTracking.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()) else { return nil }
        return deviceAnchor.originFromAnchorTransform
    }
}
