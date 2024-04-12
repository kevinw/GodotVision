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
        content
            .gesture(SpatialTapGesture().targetedToAnyEntity().onEnded { event in
                if event.entity.components.has(InputTargetComponent.self) {
                    coordinator.receivedTap(event: event)
                }
            })
            .gesture(DragGesture().targetedToAnyEntity().onChanged({value in
                if value.entity.components.has(InputTargetComponent.self) {
                    coordinator.receivedDrag(value)
                }
            }).onEnded({value in
                if value.entity.components.has(InputTargetComponent.self) {
                    coordinator.receivedDragEnded(value)
                }
            }))
            .onDisappear {
                coordinator.viewDidDisappear()
            }
    }
}
