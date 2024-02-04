//  Created by Kevin Watters on 1/3/24.

let HANDLE_RUNLOOP_MANUALLY = true

import Foundation
import SwiftUI
import RealityKit
import SwiftGodot
import SwiftGodotKit

private let whiteNonMetallic = SimpleMaterial(color: .white, isMetallic: false)

let VISION_VOLUME_CAMERA_GODOT_NODE_NAME = "VisionVolumeCamera"
let REVIEW_REQUEST_NODE_NAME = "RequestReview"
let SHOW_CORNERS = false

enum ShapeSubType {
    case None
    case Box(size: simd_float3)
    case Sphere(radius: Float)
    case Capsule(height: Float, radius: Float)
    case Mesh(MeshEntry)
}

struct MaterialDesc {
    var albedoColor: SwiftGodot.Color = .white
    
}

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
            .onAppear {
                coordinator.initGodot()
            }
            .onDisappear {
                coordinator.viewDidDisappear()
            }
    }
}

struct DrawEntry {
    var name: String? = nil
    var instanceId: Int64 = 0
    var parentId: Int64 = 0
    var position: simd_float3 = .zero
    var rotation: simd_quatf = .init()
    var scale: simd_float3 = .one
    var inputRayPickable: ShapeSubType? = nil
    var visible: Bool = true
    
    // properties to split off into an "instantiation packet"
    var shape: ShapeSubType = .None
    var material: MaterialEntry? = nil
}

struct InterThread {
    var drawEntries: [DrawEntry] = []
    var generation: UInt64 = 0
    var godotInstanceIDsRemovedFromTree: Set<UInt> = .init()
    var volumeCameraPosition: simd_float3 = .zero
    var volumeCameraBoxSize: simd_float3 = .one
    var realityKitVolumeSize: simd_double3 = .one /// The size we think the RealitKit volume is, in meters, as an application in the user's AR space.
    
    var audioStreamPlays: [AudioStreamPlay] = []
}

struct AudioStreamPlay {
    var godotInstanceID: Int64 = 0
    var resourcePath: String
    var volumeDb: Double = 0
}

public class GodotVisionCoordinator: NSObject, ObservableObject {
    private var godotInstanceIDToEntityID: [Int64: Entity.ID] = [:]
    
    private var physicsEntitiesParent: Entity! = nil
    private var frameCount = 0
    private var eventSubscription: EventSubscription? = nil
    private var sceneTreeListenerTokens: [SwiftGodot.Object] = []
    private var receivedRootNode = false
    private var mirroredGodotNodes: [Node3D] = []
    private var interThread: InterThread = .init()
    private var resourceCache: ResourceCache = .init()
    private var lastRendereredGeneration: UInt64 = .max
    private var sceneTree: SceneTree? = nil
    private var volumeCamera: SwiftGodot.Node3D? = nil
    
    func reloadScene() {
        print("reloadScene currently doesn't work for loading a new version of the scene saved from the editor, since Xcode copies the Godot_Project into the application's bundle only once at build time.")
        resetRealityKit()
        if let sceneFilePath = self.sceneTree?.currentScene?.sceneFilePath {
            self.changeSceneToFile(atResourcePath: sceneFilePath)
        } else {
            print("ERROR: cannot reload, no .sceneFilePath")
        }
    }
    
    // TODO: move me out of GodotVision
    private func getAllScenes() -> [String] {
        var allScenes: [String] = []
        guard let enumerator = FileManager.default.enumerator(atPath: getProjectDir()) else {
            print("ERROR: could not create DirectoryEnumerator")
            return []
        }
        for case let filePath as String in enumerator {
            if !filePath.starts(with: "scenes/") {
                continue
            }
            do {
                let fileURL = URL(filePath: filePath)
                let fileAttributes = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
                if fileAttributes.isRegularFile ?? false, fileURL.pathExtension.lowercased() == "tscn" {
                    print(fileURL.pathExtension, filePath)
                    allScenes.append(filePath)
                }
            } catch {
                print(error, filePath)
            }
        }
        return allScenes
    }

    func changeSceneToFile(atResourcePath sceneResourcePath: String) {
        guard let sceneTree else { return }
        print("CHANGING SCENE TO", sceneResourcePath)
        
        self.receivedRootNode = false // we will "regrab" the root node and do init stuff with it again.
        
        let callbackRunner = GodotSwiftBridge.instance
        if let parent = callbackRunner.getParent() {
            parent.removeChild(node: callbackRunner)
        }
        
        let result = sceneTree.changeSceneToFile(path: sceneResourcePath)
        if SwiftGodot.GodotError.ok != result {
            print("ERROR:", result)
        }
    }
    
    func executeGodotTick() -> /* should_quit: */ Bool {
        stepGodotFrame()
    }
    
    public func initGodot() {
        var args = [
            ".",  // TODO: not sure about this, I think it's the "project directory" -- ios build command line eats the first argument.
            
            // We want Godot to run in headless mode, meaning: don't open windows, don't render anything, don't play sounds.
            "--headless",
            
            // The GodotVision Godot fork sees this argument and assumes that we will tick the main loop manually.
            "--runLoopHandledByHost"
        ]
        
        // Here we tell Godot where to find our Godot project.
        
        // args.append(contentsOf: ["--main-pack", getPackFileURLString()])
        args.append(contentsOf: ["--path", getProjectDir()])
        
        // This is the SwiftGodotKit "entry" point
        runGodot(args: args,
                 initHook: initHook,
                 loadScene: self.receivedSceneTree,
                 loadProjectSettings: { _ in },
                 verbose: true)
    }
    
    private func receivedSceneTree(sceneTree: SwiftGodot.SceneTree) {
        print("loadSceneCallback", sceneTree.getInstanceId(), sceneTree)
        // the packfile load happens after this callback. so as a hack we use nodeAdded for now to notice a specially named root node coming into being.
        sceneTreeListenerTokens.append(contentsOf: [
            sceneTree.nodeAdded.connect(onNodeAdded),
            sceneTree.nodeRemoved.connect(onNodeRemoved),
            sceneTree.processFrame.connect(onGodotFrame),
        ])
        self.sceneTree = sceneTree
    }
    
    private func onNodeRemoved(_ node: SwiftGodot.Node) {
        if let index = mirroredGodotNodes.firstIndex(where: { $0 == node }) {
            mirroredGodotNodes.remove(at: index)
        }
        
        // Tell RealityKit to remove its entity for this.
        let instanceID = node.getInstanceId()
        let _ = interThread.godotInstanceIDsRemovedFromTree.insert(instanceID)
    }
    
    private func onNodeAdded(_ node: SwiftGodot.Node) {
        // TODO: this is a hack to get around the fact that the nodes coming in don't cast properly as their subclass yet
        let id = Int64(node.getInstanceId())
        GodotSwiftBridge.runLater {
            guard let obj = GD.instanceFromId(instanceId: id) else { return }
            
            if let node3D = obj as? Node3D {
                self.startMirroringMeshForNode(node3D)
            }
            
            if obj is AudioStreamPlayer3D {
                if obj.hasSignal("on_play") {
                    let _ = obj.connect(signal: "on_play", callable: .init(object: GodotSwiftBridge.instance, method: .init("onAudioStreamPlayerPlayed")))
                } else {
                    print("WARNING: You're using AudioStreamPlayer3D, but we couldn't find an 'on_play' signal. Did you use RKAudioStreamPlayer? Remember to call '.play_rk()' to trigger the sound effect as well.")
                }
            }
        }
        
        let isRoot = node.getParent() == node.getTree()?.root
        if isRoot && !receivedRootNode {
            receivedRootNode = true
            // print("GOT ROOT NODE, attaching callback runner", node)
            node.addChild(node: GodotSwiftBridge.instance)
            GodotSwiftBridge.instance.onAudioStreamPlayed = { [weak self] (playInfo: AudioStreamPlay) -> Void in
                guard let self else { return }
                interThread.audioStreamPlays.append(playInfo)
            }
        }
    }
    
    private func startMirroringMeshForNode(_ node: SwiftGodot.Node3D) {
        if mirroredGodotNodes.firstIndex(of: node) != nil {
            print("ERROR: already mirroring node \(node)")
            return
        }
        
        mirroredGodotNodes.append(node)
        
        // we notice a specially named node for the "bounds"
        if node.name == VISION_VOLUME_CAMERA_GODOT_NODE_NAME {
            didReceiveGodotVolumeCamera(node)
        }
    }
    
    private func didReceiveGodotVolumeCamera(_ node: Node3D) {
        volumeCamera = node
        
        guard let area3D = volumeCamera as? Area3D else {
            print("ERROR: expected node '\(VISION_VOLUME_CAMERA_GODOT_NODE_NAME)' to be an Area3D, but it was a \(node.godotClassName)")
            return
        }
        
        let collisionShape3Ds = area3D.findChildren(pattern: "*", type: "CollisionShape3D")
        if collisionShape3Ds.count != 1 {
            print("ERROR: expected \(VISION_VOLUME_CAMERA_GODOT_NODE_NAME) to have exactly one child with CollisionShape3D, but got \(collisionShape3Ds.count)")
            return
        }
        
        guard let collisionShape3D = collisionShape3Ds[0] as? CollisionShape3D else {
            print("ERROR: Could not cast child as CollisionShape3D")
            return
        }
        
        guard let boxShape3D = collisionShape3D.shape as? BoxShape3D else {
            print("ERROR: Could not cast shape as BoxShape3D in CollisionShape3D child of \(VISION_VOLUME_CAMERA_GODOT_NODE_NAME)")
            return
        }
        
        let godotVolumeBoxSize = simd_float3(boxShape3D.size)
        interThread.volumeCameraBoxSize = godotVolumeBoxSize
        
        let realityKitVolumeSize = interThread.realityKitVolumeSize
        let ratio = simd_float3(realityKitVolumeSize) / godotVolumeBoxSize
        // print("VOLUME RATIO", ratio)
        
        // Check that the boxes (realtikit and godot) have the same "shape"
        if !(ratio.x.isApproximatelyEqualTo(ratio.y) && ratio.y.isApproximatelyEqualTo(ratio.z)) {
            print("ERROR: expected the proportions of the RealityKit volume to match the godot volume! the camera volume may be off.")
        }
        
        DispatchQueue.main.async {
            self.physicsEntitiesParent.scale = .one * max(max(ratio.x, ratio.y), ratio.z)
        }
    }
    
    func resetRealityKit() {
        assert(Thread.current.isMainThread)
        interThread.audioStreamPlays.removeAll()
        mirroredGodotNodes.removeAll()
        resourceCache.reset()
        for child in physicsEntitiesParent.children.map({ $0 }) {
            child.removeFromParent()
        }
    }
    
    private func onGodotFrame() {
        var shapes: [DrawEntry] = []

        for node in mirroredGodotNodes {
            /* NOTE: this isInstanceIdValid check is suspect, but I get crashes without it. with it, I get this message in godot:
             
                    USER ERROR: Condition "slot >= slot_max" is true. Returning: nullptr
                       at: get_instance (./core/object/object.h:1033)
             
            There's something about nodes being freed which we don't pick up on fast enough.
             
             */
            if !GD.isInstanceIdValid(id: Int64(node.getInstanceId())) || !node.isInsideTree() {
                onNodeRemoved(node)
                continue
            }
            
            // TODO: separate these into "update" packets and "init" packets...
            if let colObj3D = node as? CollisionObject3D, colObj3D.inputRayPickable {
                let owner_ids = colObj3D.getShapeOwners()
                for ownerId in owner_ids {
                    if ownerId < 0 {
                        print("error: ownerId < 0")
                        continue
                    }
                    let owner_id = UInt32(ownerId)
                    let shapeCount = colObj3D.shapeOwnerGetShapeCount(ownerId: owner_id)
                    for _ in 0..<shapeCount {
                        // let shape = colObj3D.shapeOwnerGetShape(ownerId: owner_id, shapeId: shape_id)
                        // print("SHAPE", shape)
                    }
                }
            }
            
            // TODO: this is wrong, just using it as a marker for now
            let inputRayPickable: ShapeSubType? = ((node as? CollisionObject3D)?.inputRayPickable ?? false) ? .Box(size: .one) : nil
            
            var entry = DrawEntry(name: node.name.description, // TODO: only use name on debug builds??
                                  instanceId: Int64(node.getInstanceId()),
                                  parentId: Int64(node.getParent()?.getInstanceId() ?? 0),
                                  position: .init(node.position),
                                  rotation: .init(node.basis.getRotationQuaternion()),
                                  scale: .init(node.scale),
                                  inputRayPickable: inputRayPickable,
                                  visible: node.visible
            )
            
            // TODO: maybe just always use the exact triangles from Godot? Not sure we even need to use box/sphere/capsule/etc from RealityKit...
            entry.shape = .None
            
            if let meshInstance3D = node as? MeshInstance3D {
                var material: SwiftGodot.Material? = nil
                if let mesh = meshInstance3D.mesh {
                    if let box = mesh as? BoxMesh {
                        entry.shape = .Box(size: simd_float3(box.size))
                    } else if let sphere = mesh as? SphereMesh {
                        entry.shape = .Sphere(radius: Float(sphere.radius))
                    } else if let capsule = mesh as? CapsuleMesh {
                        entry.shape = .Capsule(height: Float(capsule.height), radius: Float(capsule.radius))
                    } else {
                        entry.shape = .Mesh(resourceCache.meshEntry(forGodotMesh: mesh))
                    }
                    
                    if mesh.getSurfaceCount() > 1 {
                        print("WARNING: mesh has more than one surface")
                    }
                    material = meshInstance3D.getActiveMaterial(surface: 0)
                }
                
                if let material {
                    entry.material = resourceCache.materialEntry(forGodotMaterial: material)
                }
            }
            
            shapes.append(entry)
        }
        
        interThread.drawEntries = shapes
        interThread.generation += 1
        if let volumeCamera {
            // should do rotation too, but idk how to go from godot rotation to RK 'orientation'
            // ie: physicsEntitiesParent.orientation = some_function(volumeCamera.rotation)
            interThread.volumeCameraPosition = simd_float3(volumeCamera.globalPosition) * -0.1
        }
    }
    
    public func setupRealityKitScene(_ content: RealityViewContent, volumeSize: simd_double3) -> Entity {
        assert(Thread.current.isMainThread)
        
        interThread.realityKitVolumeSize = volumeSize
        
        if SHOW_CORNERS {
            // Place some cubes to show the edges of the realitykit volume.
            let volumeDebugParent = Entity()
            volumeDebugParent.name = "volumeDebugParent"
            
            let debugCube = MeshResource.generateBox(size: 0.1)
            func addAtPoint(_ p: simd_float3) {
                let e = ModelEntity(mesh: debugCube, materials: [whiteNonMetallic])
                e.position = p
                content.add(e)
            }
            
            let half = simd_float3(volumeSize * 0.5)
            addAtPoint(.init(half.x, half.y, -half.z))
            addAtPoint(.init(half.x, -half.y, -half.z))
            addAtPoint(.init(-half.x, -half.y, -half.z))
            addAtPoint(.init(-half.x, -half.y, -half.z))
            
            addAtPoint(.init(half.x, half.y, half.z))
            addAtPoint(.init(half.x, -half.y, half.z))
            addAtPoint(.init(-half.x, -half.y, half.z))
            addAtPoint(.init(-half.x, -half.y, half.z))
        }
        
        let physicsEntitiesParent = Entity()
        physicsEntitiesParent.name = "physicsEntitiesParent"
        
        self.physicsEntitiesParent = physicsEntitiesParent
        content.add(physicsEntitiesParent)
        eventSubscription = content.subscribe(to: SceneEvents.Update.self, realityKitPerFrameTick)
        return physicsEntitiesParent
    }
    
    public func viewDidDisappear() {
        if let eventSubscription {
            eventSubscription.cancel()
            self.eventSubscription = nil
        }
    }
    
    private var _audioResources: [String: AudioFileResource] = [:]
    
    func cacheAudioResource(resourcePath: String) -> AudioFileResource? {
        let fileUrl = getGodotProjectURL().appendingPathComponent(resourcePath.removingStringPrefix("res://"))
        
        var audioResource: AudioFileResource? = _audioResources[resourcePath]
        if audioResource == nil {
            do {
                audioResource = try AudioFileResource.load(contentsOf: fileUrl)
            } catch {
                print("ERROR:", error)
                return nil
            }
            
            _audioResources[resourcePath] = audioResource
        }
        
        return audioResource
    }
    
    func realityKitPerFrameTick(_ event: SceneEvents.Update) {
        if executeGodotTick() {
            print("GODOT HAS QUIT")
        }
        
        let (drawEntries, generation, volumeCameraPosition, godotInstanceIDsRemovedFromTree, audioStreamPlays) = (interThread.drawEntries, interThread.generation, interThread.volumeCameraPosition, interThread.godotInstanceIDsRemovedFromTree, interThread.audioStreamPlays)
        
        func entity(forGodotInstanceID godotInstanceId: Int64) -> Entity? {
            if let entityID = godotInstanceIDToEntityID[godotInstanceId] {
               return event.scene.findEntity(id: entityID)
            }
            
            return nil
        }
        
        // Play any AudioStreamPlayer3D sounds
        for audioStreamPlay in audioStreamPlays {
            if let entity = entity(forGodotInstanceID: audioStreamPlay.godotInstanceID),
               let audioResource = cacheAudioResource(resourcePath: audioStreamPlay.resourcePath)
            {
                let audioPlaybackController = entity.playAudio(audioResource)
                audioPlaybackController.gain = audioStreamPlay.volumeDb
            }
        }
        
        // Remove any RealityKit Entities for Godot nodes that were removed from the Godot tree.
        for instanceIdRemovedFromTree in godotInstanceIDsRemovedFromTree {
            guard let entityID = godotInstanceIDToEntityID[Int64(instanceIdRemovedFromTree)] else { continue }
            guard let entity = event.scene.findEntity(id: entityID) else { continue }
            entity.removeFromParent()
        }
        
        physicsEntitiesParent.position = volumeCameraPosition
        if generation == lastRendereredGeneration { return }
        lastRendereredGeneration = generation
        
        var retriedIndex: [Int: Bool] = [:]
        var indices = Array(0..<drawEntries.count)
        
        for index in 0..<indices.count {
            let drawEntry = drawEntries[index]
            var entityID = godotInstanceIDToEntityID[drawEntry.instanceId]
            var entity: Entity? = nil
            if let entityID {
                entity = event.scene.findEntity(id: entityID)
            } else {
                var materials: [RealityKit.Material]? = nil
                if let materialEntry = drawEntry.material {
                    materials = [materialEntry.getMaterial(resourceCache: resourceCache)]
                }
                
                var modelEntity: ModelEntity
                
                switch drawEntry.shape {
                case .Sphere(let radius):
                    let meshResource = MeshResource.generateSphere(radius: radius)
                    modelEntity = ModelEntity(mesh: meshResource, materials: materials ?? [whiteNonMetallic])
                case .Box(let size):
                    let meshResource = MeshResource.generateBox(size: size)
                    modelEntity = ModelEntity(mesh: meshResource, materials: materials ?? [whiteNonMetallic])
                case .Capsule(let height, let radius):
                    let size = simd_float3(radius * 2, height, radius * 2)
                    let meshResource = MeshResource.generateBox(size: size, cornerRadius: radius)
                    modelEntity = ModelEntity(mesh: meshResource, materials: materials ?? [whiteNonMetallic])
                case .Mesh(let meshEntry):
                    modelEntity = ModelEntity(mesh: meshEntry.meshResource, materials: materials ?? [whiteNonMetallic])
                    // let bounds = modelEntity.visualBounds(relativeTo: nil)
                case .None:
                    modelEntity = ModelEntity()
                }
                
                modelEntity.name = "\(drawEntry.name ?? "Entity")(bodyID=\(drawEntry.instanceId))"
                entityID = modelEntity.id
                entity = modelEntity
                godotInstanceIDToEntityID[drawEntry.instanceId] = modelEntity.id
                physicsEntitiesParent.addChild(modelEntity)
                
                // we only want to set shadows on entities with a mesh
                switch drawEntry.shape {
                case .None:
                    fallthrough
                default:
                    // commenting out shadow for now because it really slows things down
                    modelEntity.components.set(GroundingShadowComponent(castsShadow: true))
//                    modelEntity.components.set(GroundingShadowComponent(castsShadow: false))
                }
                
                if drawEntry.inputRayPickable != nil {
                    DispatchQueue.main.async {
                        let bounds = modelEntity.visualBounds(relativeTo: modelEntity.parent)
                        let collisionShape: RealityKit.ShapeResource = .generateBox(size: bounds.extents)
                        
                        var collision = CollisionComponent(shapes: [collisionShape])
                        collision.filter = .init(group: [], mask: []) // disable for collision detection
                        
                        // TODO: this is a dummy collision shape from the visual bounds of the entity. we can do something smarter based on the actual godot shapes!
                        
                        modelEntity.components.set(InputTargetComponent()) // TODO: we probably don't ALWAYS want the visual highlight for pickable things. how to configure this from Godot?
                        modelEntity.components.set(HoverEffectComponent())
                        modelEntity.components.set(collision)
                        
                    }
                }
            }
            
            frameCount += 1
            if let entity {
                let parentRKID = godotInstanceIDToEntityID[drawEntry.parentId]
                if drawEntry.parentId > 0 && parentRKID == nil {
                    if retriedIndex[index] ?? false {
                        print("ERROR: no parent in bodyIDToEntityMap for", drawEntry.parentId)
                    } else {
                        retriedIndex[index] = true
                        indices.append(index)
                    }
                } else {
                    let parent = parentRKID != nil ? event.scene.findEntity(id: parentRKID!) : nil
                    if entity.parent != parent {
                        entity.setParent(parent)
                    }
                }
                entity.position = drawEntry.position
                entity.orientation = drawEntry.rotation
                entity.scale = drawEntry.scale
                entity.isEnabled = drawEntry.visible // TODO: Godot visibility might still do _process..., but I'm pretty sure Entity.isEnabled with false will disable processing for the corresponding RealityKit Entity. maybe not a problem?
            }
        }
        
    }
    
    func godotInstanceFromRealityKitEntityID(_ eID: Entity.ID) -> SwiftGodot.Object? {
        for (godotInstanceID, rkEntityID) in godotInstanceIDToEntityID where rkEntityID == eID {
            guard let godotInstance = GD.instanceFromId(instanceId: godotInstanceID) else {
                print("ERROR: could not get Godot instance from id \(godotInstanceID)")
                continue
            }
            
            return godotInstance
        }
        
        return nil
    }
    
    func receivedDrag(_ value: EntityTargetValue<DragGesture.Value>) {
        let startLocation3D = value.convert(value.startLocation3D, from: .local, to: .scene)
        let location3D = value.convert(value.location3D, from: .local, to: .scene)
        
        let godotStartLocation = physicsEntitiesParent.convert(position: simd_float3(startLocation3D), from: nil)
        let godotLocation = physicsEntitiesParent.convert(position: simd_float3(location3D), from: nil) + simd_float3(0, 0, interThread.volumeCameraBoxSize.z * 0.5)
        
        guard let obj = self.godotInstanceFromRealityKitEntityID(value.entity.id) else { return }
        if obj.hasSignal("drag") {
            obj.emitSignal("drag", Variant(SwiftGodot.Vector3(godotLocation)), Variant(SwiftGodot.Vector3(godotStartLocation)))
        }
    }
    
    func receivedDragEnded(_ value: EntityTargetValue<DragGesture.Value>) {
        guard let obj = godotInstanceFromRealityKitEntityID(value.entity.id) else { return }
        if obj.hasSignal("drag_ended") {
            obj.emitSignal("drag_ended")
        }
    }
    
    /// RealityKit has received a SpatialTapGesture in the RealityView
    func receivedTap(event: EntityTargetValue<SpatialTapGesture.Value>) {
        
        let sceneLoc = event.convert(event.location3D, from: .local, to: .scene)
        var godotLocation = physicsEntitiesParent.convert(position: simd_float3(sceneLoc), from: nil)
        godotLocation += .init(0, 0, interThread.volumeCameraBoxSize.z * 0.5)
        
        // TODO: hack. not always right. currently this just pretends everything you tap is a sphere???
        let realityKitNormal = normalize(event.entity.position(relativeTo: nil) - sceneLoc)
        let godotNormal = realityKitNormal
        
        guard let obj = self.godotInstanceFromRealityKitEntityID(event.entity.id) else { return }
            
        let godotEvent = InputEventMouseButton()
        godotEvent.buttonIndex = .left
        godotEvent.doubleClick = false // TODO
        godotEvent.pressed = true
        
        let position = SwiftGodot.Vector3(godotLocation)
        let normal = SwiftGodot.Vector3(godotNormal)
        let shape_idx = 0
        
        // TODO: I think SwiftGodot provides a better way to emit signals than all these Variant() constructors
        obj.emitSignal("input_event", Variant.init(), Variant(godotEvent), Variant(position), Variant(normal), Variant(shape_idx))
    }
}
