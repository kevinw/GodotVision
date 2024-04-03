/**
 
Mirror Node3Ds from Godot to RealityKit.
 
 */

//  Created by Kevin Watters on 1/3/24.

let HANDLE_RUNLOOP_MANUALLY = true
let DO_EXTRA_DEBUGGING = false

import Foundation
import SwiftUI
import RealityKit
import SwiftGodot
import SwiftGodotKit

private let whiteNonMetallic = SimpleMaterial(color: .white, isMetallic: false)

let VISION_VOLUME_CAMERA_GODOT_NODE_NAME = "VisionVolumeCamera"
let SHOW_CORNERS = false

enum ShapeSubType {
    case None
    case Box(size: simd_float3)
    case Sphere(radius: Float)
    case Capsule(height: Float, radius: Float)
    case Mesh(SwiftGodot.Mesh, Skeleton3D?)
}

// TODO: Maybe remove this struct entirely? we used to run Godot on a background thread, and used this to communicate all the "rendering" data back to the main thread. but now that the two loops are intertwined it may not be necessary.
struct DrawEntry {
    var name: String? = nil
    var instanceId: Int64 = 0
    var parentId: Int64 = 0
    var inputRayPickable: ShapeSubType? = nil
    var hoverEffect: Bool = false
    // properties to split off into an "instantiation packet"
    var shape: ShapeSubType = .None
    var materials: [MaterialEntry] = []
    var node: SwiftGodot.Node3D
}

struct InterThread {
    var drawEntries: [DrawEntry] = []
    var generation: UInt64 = 0
    
}

struct AudioStreamPlay {
    var godotInstanceID: Int64 = 0
    var resourcePath: String
    var volumeDb: Double = 0
}

public class GodotVisionCoordinator: NSObject, ObservableObject {
    struct InitOptions {
        var godotProjectFileUrl: URL? = nil /// Where to find the Godot project files. Defaults to `Godot_Project` in the main application bundle.
    }
    
    private var godotInstanceIDToEntityID: [Int64: Entity.ID] = [:]
    
    private var godotEntitiesParent: Entity! = nil /// The tree of RealityKit Entities mirroring Godot Node3Ds gets parented here.
    private var eventSubscription: EventSubscription? = nil
    private var nodeAddedToken: SwiftGodot.Object? = nil
    private var nodeRemovedToken: SwiftGodot.Object? = nil
    private var processFrameToken: SwiftGodot.Object? = nil
    private var receivedRootNode = false
    private var mirroredGodotNodes: [Node3D] = [] /// Godot Node3Ds whose transforms we synchronize to RealityKit.
    private var interThread: InterThread = .init()
    private var resourceCache: ResourceCache = .init()
    private var lastRendereredGeneration: UInt64 = .max
    private var sceneTree: SceneTree? = nil
    private var volumeCamera: SwiftGodot.Node3D? = nil
    private var audioStreamPlays: [AudioStreamPlay] = []
    private var _audioResources: [String: AudioFileResource] = [:]
    
    private var godotInstanceIDsRemovedFromTree: Set<UInt> = .init()
    private var volumeCameraPosition: simd_float3 = .zero
    private var volumeCameraBoxSize: simd_float3 = .one
    private var realityKitVolumeSize: simd_double3 = .one /// The size we think the RealitKit volume is, in meters, as an application in the user's AR space.
    private var godotToRealityKitRatio: Float = 0.05 // default ratio - this is adjusted when realityKitVolumeSize size changes
    
    public func changeScaleIfVolumeSizeChanged(_ volumeSize: simd_double3) {
        if volumeSize != realityKitVolumeSize {
            realityKitVolumeSize = volumeSize
            let ratio  = simd_float3(realityKitVolumeSize) / volumeCameraBoxSize
            godotToRealityKitRatio = max(max(ratio.x, ratio.y), ratio.z)
            self.godotEntitiesParent.scale = .one * godotToRealityKitRatio
        }
    }
    
    public func reloadScene() {
        print("reloadScene currently doesn't work for loading a new version of the scene saved from the editor, since Xcode copies the Godot_Project into the application's bundle only once at build time.")
        resetRealityKit()
        if let sceneFilePath = self.sceneTree?.currentScene?.sceneFilePath {
            self.changeSceneToFile(atResourcePath: sceneFilePath)
        } else {
            logError("cannot reload, no .sceneFilePath")
        }
    }

    public func changeSceneToFile(atResourcePath sceneResourcePath: String) {
        guard let sceneTree else { return }
        print("CHANGING SCENE TO", sceneResourcePath)
        
        self.receivedRootNode = false // we will "regrab" the root node and do init stuff with it again.
        
        let callbackRunner = GodotSwiftBridge.instance
        if let parent = callbackRunner.getParent() {
            parent.removeChild(node: callbackRunner)
        }
        
        let result = sceneTree.changeSceneToFile(path: sceneResourcePath)
        if SwiftGodot.GodotError.ok != result {
            logError("changeSceneToFile result was not ok: \(result)")
        }
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
        nodeAddedToken = sceneTree.nodeAdded.connect(onNodeAdded)
        nodeRemovedToken = sceneTree.nodeRemoved.connect(onNodeRemoved)
        processFrameToken = sceneTree.processFrame.connect(onGodotFrame)
        
        self.sceneTree = sceneTree
    }
    
    private func onNodeRemoved(_ node: SwiftGodot.Node) {
        if let index = mirroredGodotNodes.firstIndex(where: { $0 == node }) {
            mirroredGodotNodes.remove(at: index)
        }
        
        // Tell RealityKit to remove its entity for this.
        let instanceID = node.getInstanceId()
        let _ = godotInstanceIDsRemovedFromTree.insert(instanceID)
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
                audioStreamPlays.append(playInfo)
            }
        }
    }
    
    private func startMirroringMeshForNode(_ node: SwiftGodot.Node3D) {
        if mirroredGodotNodes.firstIndex(of: node) != nil {
            logError("already mirroring node \(node)")
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
            logError("expected node '\(VISION_VOLUME_CAMERA_GODOT_NODE_NAME)' to be an Area3D, but it was a \(node.godotClassName)")
            return
        }
        
        let collisionShape3Ds = area3D.findChildren(pattern: "*", type: "CollisionShape3D")
        if collisionShape3Ds.count != 1 {
            logError("expected \(VISION_VOLUME_CAMERA_GODOT_NODE_NAME) to have exactly one child with CollisionShape3D, but got \(collisionShape3Ds.count)")
            return
        }
        
        guard let collisionShape3D = collisionShape3Ds[0] as? CollisionShape3D else {
            logError("Could not cast child as CollisionShape3D")
            return
        }
        
        guard let boxShape3D = collisionShape3D.shape as? BoxShape3D else {
            logError("Could not cast shape as BoxShape3D in CollisionShape3D child of \(VISION_VOLUME_CAMERA_GODOT_NODE_NAME)")
            return
        }
        
        let godotVolumeBoxSize = simd_float3(boxShape3D.size)
        volumeCameraBoxSize = godotVolumeBoxSize
        
        let ratio = simd_float3(realityKitVolumeSize) / godotVolumeBoxSize
        
        // Check that the boxes (realtikit and godot) have the same "shape"
        if !(ratio.x.isApproximatelyEqualTo(ratio.y) && ratio.y.isApproximatelyEqualTo(ratio.z)) {
            logError("expected the proportions of the RealityKit volume to match the godot volume! the camera volume may be off.")
        }
        godotToRealityKitRatio = max(max(ratio.x, ratio.y), ratio.z)
        self.godotEntitiesParent.scale = .one * godotToRealityKitRatio
    }
    
    func resetRealityKit() {
        assert(Thread.current.isMainThread)
        audioStreamPlays.removeAll()
        mirroredGodotNodes.removeAll()
        resourceCache.reset()
        for child in godotEntitiesParent.children.map({ $0 }) {
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
                        logError("ownerId < 0")
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
                                  inputRayPickable: inputRayPickable,
                                  hoverEffect: .init(node.getMeta(name: "hover_effect", default: Variant(false))) ?? false,
                                  node: node)
            
            entry.shape = .None
            
            if let meshInstance3D = node as? MeshInstance3D {
                if let mesh = meshInstance3D.mesh {
                    let skeleton3D = meshInstance3D.skeleton.isEmpty() ? nil : (meshInstance3D.getNode(path: meshInstance3D.skeleton) as? Skeleton3D)
                    entry.shape = .Mesh(mesh, skeleton3D)
                    for i in 0...mesh.getSurfaceCount() - 1 {
                        var material: SwiftGodot.Material? = nil
                        material = meshInstance3D.getActiveMaterial(surface: i)
                        if let material {
                            entry.materials.append(resourceCache.materialEntry(forGodotMaterial: material))
                        }
                    }
                }
            }
            
            shapes.append(entry)
        }
        
        interThread.drawEntries = shapes
        interThread.generation += 1
        if let volumeCamera {
            // should do rotation too, but idk how to go from godot rotation to RK 'orientation'
            // ie: physicsEntitiesParent.orientation = some_function(volumeCamera.rotation)
            // use scale here too
            volumeCameraPosition = simd_float3(volumeCamera.globalPosition) * -1 * godotToRealityKitRatio
        }
    }
    
    public func setupRealityKitScene(_ content: RealityViewContent, volumeSize: simd_double3) -> Entity {
        assert(Thread.current.isMainThread)
        
        realityKitVolumeSize = volumeSize
        
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
        
        // Register a per-frame RealityKit update function.
        eventSubscription = content.subscribe(to: SceneEvents.Update.self, realityKitPerFrameTick)
        
        // Create a root Entity to store all our mirrored Godot nodes-turned-RealityKit entities.
        let godotEntitiesParent = Entity()
        godotEntitiesParent.name = "GODOTRK_ROOT"
        self.godotEntitiesParent = godotEntitiesParent
        
        metaRoot.name = "META_ROOT"
        metaRoot.addChild(godotEntitiesParent)
        content.add(metaRoot)
        
        return godotEntitiesParent
    }
    
    var metaRoot: Entity = Entity()

    public func viewDidDisappear() {
        if let eventSubscription {
            eventSubscription.cancel()
            self.eventSubscription = nil
        }
        
        // Disconnect SceneTree signals
        if let sceneTree {
            if let nodeAddedToken {
                sceneTree.nodeAdded.disconnect(nodeAddedToken)
                self.nodeAddedToken = nil
            }
            if let nodeRemovedToken {
                sceneTree.nodeRemoved.disconnect(nodeRemovedToken)
                self.nodeRemovedToken = nil
            }
            if let processFrameToken {
                sceneTree.processFrame.disconnect(processFrameToken)
                self.processFrameToken = nil
            }
            self.sceneTree = nil
        }
    }
    
    private func cacheAudioResource(resourcePath: String) -> AudioFileResource? {
        var audioResource: AudioFileResource? = _audioResources[resourcePath]
        if audioResource == nil {
            do {
                audioResource = try AudioFileResource.load(contentsOf: fileUrl(forGodotResourcePath: resourcePath))
            } catch {
                logError(error)
                return nil
            }
            
            _audioResources[resourcePath] = audioResource
        }
        return audioResource
    }
    
    func realityKitPerFrameTick(_ event: SceneEvents.Update) {
        if stepGodotFrame() {
            print("GODOT HAS QUIT")
            // TODO: ask visionOS application to quit? or...?
        }
        
        defer { 
            audioStreamPlays.removeAll()
            godotInstanceIDsRemovedFromTree.removeAll()
        }
        
        let (drawEntries, generation) = (interThread.drawEntries, interThread.generation)

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
        
        godotEntitiesParent.position = volumeCameraPosition
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
                if !drawEntry.materials.isEmpty {
                    materials = drawEntry.materials.map { entry in
                        entry.getMaterial(resourceCache: resourceCache)
                    }
                }
                
                var modelEntity: Entity
                
                switch drawEntry.shape {
                case .Mesh(let mesh, let skeleton3D):
                    if let mesh = createRealityKitMesh(node: drawEntry.node,
                                                       godotMesh: mesh,
                                                       godotSkeleton: skeleton3D)
                    {
                        modelEntity = ModelEntity(mesh: mesh, materials: materials ?? [whiteNonMetallic])
                    } else {
                        modelEntity = Entity()
                    }
                case .None:
                    modelEntity = Entity()
                default:
                    modelEntity = Entity()
                }
                
                modelEntity.name = "\(drawEntry.name ?? "Entity")(bodyID=\(drawEntry.instanceId))"
                entityID = modelEntity.id
                entity = modelEntity
                godotInstanceIDToEntityID[drawEntry.instanceId] = modelEntity.id
                godotEntitiesParent.addChild(modelEntity)
                
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
                        
                        modelEntity.components.set(InputTargetComponent())
                        if drawEntry.hoverEffect {
                            modelEntity.components.set(HoverEffectComponent())
                        }
                        modelEntity.components.set(collision)
                        
                    }
                }
            }
            
            if let entity {
                let parentRKID = godotInstanceIDToEntityID[drawEntry.parentId]
                if drawEntry.parentId > 0 && parentRKID == nil {
                    if retriedIndex[index] ?? false {
                        logError("no parent in bodyIDToEntityMap for \(drawEntry.parentId)")
                    } else {
                        // Account for if drawEntries has children specified before parents (just put this entity back on the list to try later)
                        retriedIndex[index] = true
                        indices.append(index)
                    }
                } else {
                    let parent = parentRKID != nil ? event.scene.findEntity(id: parentRKID!) : nil
                    if entity.parent != parent {
                        entity.setParent(parent)
                    }
                }
                entity.transform = Transform(drawEntry.node.transform) // TODO: this should be equivalent to the above lines; but the Z is reversed .... fix the Transform() constructor!
                entity.isEnabled = drawEntry.node.visible // TODO: Godot visibility might still do _process..., but I'm pretty sure Entity.isEnabled with false will disable processing for the corresponding RealityKit Entity. This will probably be a problem.
                
                // TODO: we might be able to register for an event when the bone poses change, and respond to that, instead of doing a per frame check. @Perf
                if let modelEntity = entity as? ModelEntity, let model = modelEntity.model, let _ = model.mesh.contents.skeletons.first(where: { _ in true /* TODO: hack, no */ }) {
                    if let meshInstance3D = drawEntry.node as? MeshInstance3D, let skeleton = meshInstance3D.getNode(path: meshInstance3D.skeleton) as? Skeleton3D {
                        var transforms: [Transform] = []
                        var jointNames: [String] = []
                        
                        for boneIdx in 0..<skeleton.getBoneCount() {
                            transforms.append(Transform(skeleton.getBonePose(boneIdx: boneIdx)))
                            if DO_EXTRA_DEBUGGING {
                                jointNames.append(skeleton.getBoneName(boneIdx: boneIdx))
                            }
                        }
                        
                        modelEntity.jointTransforms = transforms
                        if DO_EXTRA_DEBUGGING {
                            if jointNames != modelEntity.jointNames {
                                logError("joint names do not match \(jointNames) \(modelEntity.jointNames)")
                            }
                        }
                    }
                }
            }
        }
        
    }
    
    func godotInstanceFromRealityKitEntityID(_ eID: Entity.ID) -> SwiftGodot.Object? {
        for (godotInstanceID, rkEntityID) in godotInstanceIDToEntityID where rkEntityID == eID {
            guard let godotInstance = GD.instanceFromId(instanceId: godotInstanceID) else {
                logError("could not get Godot instance from id \(godotInstanceID)")
                continue
            }
            
            return godotInstance
        }
        
        return nil
    }
    
    func rkGestureLocationToGodotWorldPosition(_ value: EntityTargetValue<DragGesture.Value>, _ point3D: Point3D) -> SwiftGodot.Vector3 {
        //
        // TODO: this is 100% not actually correct.
        //
        let sceneLoc = value.convert(point3D, from: .local, to: .scene)
        let godotLoc = godotEntitiesParent.convert(position: simd_float3(sceneLoc), from: nil) + simd_float3(0, 0, volumeCameraBoxSize.z * 0.5)
        return .init(godotLoc)
    }
    
    func receivedDrag(_ value: EntityTargetValue<DragGesture.Value>) {
        guard let obj = self.godotInstanceFromRealityKitEntityID(value.entity.id) else { return }
        if !obj.hasSignal("drag") {
            return
        }
            
        let godotStartLocation = rkGestureLocationToGodotWorldPosition(value, value.startLocation3D)
        let godotLocation = rkGestureLocationToGodotWorldPosition(value, value.location3D)
        let godotPredictedEndLocation = rkGestureLocationToGodotWorldPosition(value, value.predictedEndLocation3D)
        
        obj.emitSignal("drag", Variant(godotLocation), Variant(godotStartLocation), Variant(godotPredictedEndLocation))
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
        var godotLocation = godotEntitiesParent.convert(position: simd_float3(sceneLoc), from: nil)
        godotLocation += .init(0, 0, volumeCameraBoxSize.z * 0.5)
        
        // TODO: hack. this normal is not always right. currently this just pretends everything you tap is a sphere???
        
        let realityKitNormal = normalize(event.entity.position(relativeTo: nil) - sceneLoc)
        let godotNormal = realityKitNormal
        
        guard let obj = self.godotInstanceFromRealityKitEntityID(event.entity.id) else { return }
            
        // Construct an InputEventMouseButton to send to Godot.
        
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
