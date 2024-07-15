//  Created by Kevin Watters on 2/5/24.

import Foundation
import SwiftUI
import RealityKit

public struct GodotVisionRealityViewModifier: ViewModifier {
    var coordinator: GodotVisionCoordinator

    public init(coordinator: GodotVisionCoordinator) {
        self.coordinator = coordinator
    }

    public func body(content: Content) -> some View {
        
        // MARK: - Tap Gesture Definition
        
        let tapGesture = SpatialTapGesture().targetedToAnyEntity().onEnded { event in
            if event.entity.components.has(InputTargetComponent.self) {
                coordinator.receivedTap(event: event)
            }
        }
        
        // MARK: - Drag Gesture Definition
        
        let dragGesture = DragGesture(minimumDistance: 0.1, coordinateSpace: .local).targetedToAnyEntity().onChanged({ value in
            if value.entity.components.has(InputTargetComponent.self) {
                coordinator.receivedDrag(value)
            }
        }).onEnded({value in
            if value.entity.components.has(InputTargetComponent.self) {
                coordinator.receivedDragEnded(value)
            }
        })
        
        // MARK: - Magnify Gesture Definition
        
        let magnifyGesture = MagnifyGesture(minimumScaleDelta: 0.01).targetedToAnyEntity()
        .onChanged({ value in
            if value.entity.components.has(InputTargetComponent.self) {
                coordinator.receivedMagnify(value)
            }
        })
        .onEnded({value in
            if value.entity.components.has(InputTargetComponent.self) {
                coordinator.receivedMagnifyEnded(value)
            }
        })
        
        // MARK: - Rotate3D Gesture Definition
        
        // constrainedToAxis can be set to nil, or an axis (like RotationAxis3D.y)
        // a combination axis (like RotationAxis3D.yz which is a single axis defined by the combo of the two),
        // nil allows for full rotation by default.
        let rotateGesture3D = RotateGesture3D(constrainedToAxis: nil, minimumAngleDelta: .degrees(1)).targetedToAnyEntity()
        .onChanged({ value in
            if value.entity.components.has(InputTargetComponent.self) {
                coordinator.receivedRotate3D(value)
            }
        })
        .onEnded({ value in
            if value.entity.components.has(InputTargetComponent.self) {
                coordinator.receivedRotate3DEnded(value)
            }
        })
        
        // MARK: - Content View Instantiation
        
        content
            //.gesture(tapGesture)
            //.gesture(dragGesture)
            //.gesture(rotateGesture3D)
            //.gesture(magnifyGesture)
            //.gesture(magnifyGesture.exclusively(before: tapGesture))
            .gesture(rotateGesture3D.simultaneously(with: dragGesture).simultaneously(with: magnifyGesture).exclusively(before: tapGesture))
            
            .onDisappear {
                coordinator.viewDidDisappear()
            }
    }
}
