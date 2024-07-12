//  Created by Kevin Watters on 2/5/24.

import Foundation
import SwiftUI
import RealityKit

public struct GodotVisionRealityViewModifier: ViewModifier {
    var coordinator: GodotVisionCoordinator
    
    //@GestureState private var zoomFactor: CGFloat = 1.0

    public init(coordinator: GodotVisionCoordinator) {
        self.coordinator = coordinator
    }

    public func body(content: Content) -> some View {
        let tapGesture = SpatialTapGesture().targetedToAnyEntity().onEnded { event in
            if event.entity.components.has(InputTargetComponent.self) {
                coordinator.receivedTap(event: event)
            }
        }
        
        let dragGesture = DragGesture(minimumDistance: 0.1, coordinateSpace: .local).targetedToAnyEntity().onChanged({ value in
            if value.entity.components.has(InputTargetComponent.self) {
                coordinator.receivedDrag(value)
            }
        }).onEnded({value in
            if value.entity.components.has(InputTargetComponent.self) {
                coordinator.receivedDragEnded(value)
            }
        })
        
        let magnifyGesture = MagnifyGesture(minimumScaleDelta: 0.01).targetedToAnyEntity()
        //.updating($zoomFactor, body: {value, scale, transaction in
        //    if value.entity.components.has(InputTargetComponent.self) {
        //        coordinator.receivedMagnify(value)
        //    }
        //})
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
        
        content
            .gesture(tapGesture)
            //.gesture(dragGesture)
            //.gesture(magnifyGesture)
            //.gesture(magnifyGesture.exclusively(before: dragGesture))
            .gesture(magnifyGesture.simultaneously(with: dragGesture))
            .onDisappear {
                coordinator.viewDidDisappear()
            }
    }
}
