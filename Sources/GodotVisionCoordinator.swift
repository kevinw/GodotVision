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
import GameController

private let whiteNonMetallic = SimpleMaterial(color: .white, isMetallic: false)

let VISION_VOLUME_CAMERA_GODOT_NODE_NAME = "VisionVolumeCamera"
let SHOW_CORNERS = false
let DEFAULT_PROJECT_FOLDER_NAME = "Godot_Project"

struct AudioStreamPlay {
    var godotInstanceID: Int64 = 0
    var resourcePath: String
    var volumeDb: Double = 0
    var prepareOnly: Bool = false
    var retryCount = 0
}

public class GodotVisionCoordinator: NSObject, ObservableObject {
    private var godotInstanceIDToEntity: [Int64: Entity] = [:]
    
    private var godotEntitiesParent = Entity() /// The tree of RealityKit Entities mirroring Godot Node3Ds gets parented here.
    private var godotEntitiesScale = Entity() /// Applies a global scale to the godot scene based on the volume size and the godot camera volume.
    
    private var eventSubscription: EventSubscription? = nil
    private var nodeTransformsChangedToken: SwiftGodot.Object? = nil
    private var nodeAddedToken: SwiftGodot.Object? = nil
    private var nodeRemovedToken: SwiftGodot.Object? = nil
    private var audioStreamPlayerPlaybackToken: SwiftGodot.Object? = nil
    private var receivedRootNode = false
    private var resourceCache: ResourceCache = .init()
    private var sceneTree: SceneTree? = nil
    private var volumeCamera: SwiftGodot.Node3D? = nil

    private var multipeerJoystickPosition: simd_float2? = nil
    private var audioStreamPlays: [AudioStreamPlay] = []
    private var _audioResources: [String: AudioFileResource] = [:]
    
    private var godotInstanceIDsRemovedFromTree: Set<UInt> = .init()
    private var volumeCameraBoxSize: simd_float3 = .one
    private var realityKitVolumeSize: simd_double3 = .one /// The size we think the RealityKit volume is, in meters, as an application in the user's AR space.
    private var godotToRealityKitRatio: Float = 0.05 // default ratio - this is adjusted when realityKitVolumeSize size changes
    
    private var projectContext: GodotProjectContext = .init()
    private var skeletonEntities: Set<Entity> = .init() /// Entities we need to apply bone transform updates to every frame.

    // explanation in comment below
    let volumeRatioDebouncer = Debouncer(delay: 2)
    
    // we expect changeScaleIfVolumeSizeChanged to be called...
    // - from didReceiveGodotVolumeCamera, when Volume Camera node is first recognized
    // - from SwiftUI RealityView update method in ContentView
    //     - VisionOS seems to size the volume in a few steps
    //     - when a user changes the zoom level in system settings while the app is open
    // we debounce ratio mismatch error log so we only check the ratio when the visionOS volume size settles
    // one other note, visionOS clamps volume size in all dimensions to 0.2352 to 1.9852
    public func changeScaleIfVolumeSizeChanged(_ volumeSize: simd_double3) {
        if volumeSize != realityKitVolumeSize {
            realityKitVolumeSize = volumeSize
            let ratio  = simd_float3(realityKitVolumeSize) / volumeCameraBoxSize
            godotToRealityKitRatio = max(max(ratio.x, ratio.y), ratio.z)
            volumeRatioDebouncer.debounce {
                if !(ratio.x.isApproximatelyEqualTo(ratio.y) && ratio.y.isApproximatelyEqualTo(ratio.z)) {
                    logError("expected the proportions of the RealityKit volume to match the godot volume! the camera volume may be off.")
                }
            }
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
        
        let result = sceneTree.changeSceneToFile(path: sceneResourcePath)
        if SwiftGodot.GodotError.ok != result {
            logError("changeSceneToFile result was not ok: \(result)")
        }
    }
    
    func initGodot() {
        var args = [
            ".",  // TODO: not sure about this, I think it's the "project directory" -- ios build command line eats the first argument.
            
            // We want Godot to run in headless mode, meaning: don't open windows, don't render anything, don't play sounds.
            "--headless",
            
            // The GodotVision Godot fork sees this argument and assumes that we will tick the main loop manually.
            "--runLoopHandledByHost"
        ]
        
        // Here we tell Godot where to find our Godot project.
        
        args.append(contentsOf: ["--path", projectContext.getProjectDir()])
        
        // This is the SwiftGodotKit "entry" point
        runGodot(args: args,
                 initHook: initHook,
                 loadScene: self.receivedSceneTree,
                 loadProjectSettings: { _ in },
                 verbose: true)
    }
    
    private func receivedSceneTree(sceneTree: SwiftGodot.SceneTree) {
        // print("loadSceneCallback", sceneTree.getInstanceId(), sceneTree)
        // print(sceneTree.currentScene?.sceneFilePath)
        
        nodeTransformsChangedToken     = sceneTree.nodeTransformsChanged.connect(onNodeTransformsChanged)
        nodeAddedToken                 = sceneTree.nodeAdded.connect(onNodeAdded)
        nodeRemovedToken               = sceneTree.nodeRemoved.connect(onNodeRemoved)
        audioStreamPlayerPlaybackToken = sceneTree.audioStreamPlayerPlayback.connect(onAudioStreamPlayerPlayback)
        
        self.sceneTree = sceneTree
        
        #if false // show the nodes in the RealityKit hierarchy
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            print("RK HIEARCHY-------")
            printEntityTree(self.godotEntitiesParent)
        }
        #endif
    }
    
    struct AudioToProcess {
        var instanceId: Int64
        var state: Int64
        var flags: Int64
        var from_pos: Double
    }
    private var audioToProcess: [AudioToProcess] = []
    
    // callback for custom signal on SceneTree from GodotVision's libgodot fork which gets called for all AudioStreamPlayer[3D] play/stop
    private func onAudioStreamPlayerPlayback(obj: SwiftGodot.Object, state: Int64, flags: Int64, from_pos: Double) {
        // TODO: once we fix the casting of Nodes from signal calls, we don't need audioToProcess at all. but until then, obj as? AudioStreamPlayer3D will always fail from within this method. :SignalsWithNodeArguments
        audioToProcess.append(.init(instanceId: Int64(obj.getInstanceId()),
                                    state: state,
                                    flags: flags,
                                    from_pos: from_pos))
    }
    
    private func onNodeRemoved(_ node: SwiftGodot.Node) {
        let _ = godotInstanceIDsRemovedFromTree.insert(node.getInstanceId())
    }
    
    private func onNodeTransformsChanged(_ packedByteArray: PackedByteArray) {
        guard let data = packedByteArray.asDataNoCopy() else {
            return
        }
        
        struct NodeData {
            enum Flags: UInt32 {
                case VISIBLE = 1
            }
            
            // We receive a PackedByteArray of these structs from a special Godot SceneTree signal created for GodotVision. See "node_transforms_changed" in the Godot source.
            // The idea is, for performance, to just receive an array of plain data structs, and not incur the costs of gdextension method calls for each Node.
            
            var objectID: Int64
            var parentID: Int64
            var pos: simd_float4
            var rot: simd_quatf
            var scl: simd_float4
            
            var nativeHandle: UnsafeRawPointer
            var flags: UInt32
            var pad0: Float
        }

        data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            ptr.withMemoryRebound(to: NodeData.self) { nodeDatas in
                _receivedNodeDatas(nodeDatas)
            }
        }
        
        func _receivedNodeDatas(_ nodeDatas: UnsafeBufferPointer<NodeData>) {
#if false
        var transformSetCount = 0
        let swiftStride = MemoryLayout<NodeData>.stride
        let swiftSize = MemoryLayout<NodeData>.size
        //print("SWIFT offsetof transform", MemoryLayout<NodeData>.offset(of: \.transform))
        print("SWIFT offsetof rotation", MemoryLayout<NodeData>.offset(of: \.rot))
        print("SWIFT stride", swiftStride, "size", swiftSize)
        print("Swift bound array has", nodeDatas.count, "items.")
        print("DATA", ptr.baseAddress, "has", data.count, "bytes of raw data")
#endif
        for nodeData in nodeDatas {
            if nodeData.objectID == 0 { continue }
            
            guard let entity = godotInstanceIDToEntity[nodeData.objectID] else {
                continue
            }
            
            // Update Transform
            var t = RealityKit.Transform()
            t.translation = .init(nodeData.pos.x, nodeData.pos.y, nodeData.pos.z)
            t.rotation = nodeData.rot
            t.scale = .init(nodeData.scl.x, nodeData.scl.y, nodeData.scl.z)
            entity.transform = t
            entity.isEnabled = (nodeData.flags & NodeData.Flags.VISIBLE.rawValue) != 0
        }
    }

    }
    
    private var nodeIdsForNewlyEnteredNodes: [(Int64, Bool)] = []
    
    private func onNodeAdded(_ node: SwiftGodot.Node) {
        let isRoot = node.getParent() == node.getTree()?.root
        
        // TODO: Hack to get around the fact that the nodes coming in don't cast properly as their subclass yet. outside of this signal handler they do, so we store the id for later. :SignalsWithNodeArguments
        nodeIdsForNewlyEnteredNodes.append((Int64(node.getInstanceId()), isRoot))
        
        if isRoot && !receivedRootNode {
            receivedRootNode = true
            resetRealityKit()
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
        
        changeScaleIfVolumeSizeChanged(realityKitVolumeSize)
    }
    
    func resetRealityKit() {
        assert(Thread.current.isMainThread)
        audioStreamPlays.removeAll()
        resourceCache.reset()
        skeletonEntities.removeAll()
        for child in godotEntitiesParent.children.map({ $0 }) {
            child.removeFromParent()
        }
    }
    
    private static var didInitGodot = false
    
    public func setupRealityKitScene(_ content: RealityViewContent, volumeSize: simd_double3, projectFileDir: String? = nil) -> Entity {
        assert(Thread.current.isMainThread)
        
        projectContext.projectFolderName = projectFileDir ?? DEFAULT_PROJECT_FOLDER_NAME
        resourceCache.projectContext = projectContext
        
        if Self.didInitGodot {
            print("ERROR: Currently only one godot instance at a time is possible.")
        }
        initGodot()
        Self.didInitGodot = true
        
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
        godotEntitiesParent.name = "GODOTRK_ROOT"
        godotEntitiesScale.addChild(godotEntitiesParent)
        
        // A root of that entity will also apply scale.
        godotEntitiesScale.name = "GODOTRK_SCALE"
        content.add(godotEntitiesScale)
        
        return godotEntitiesParent
    }

    public func viewDidDisappear() {
        print("Cleaning up GodotVisionCoordinator.")
        
        if let eventSubscription {
            eventSubscription.cancel()
            self.eventSubscription = nil
        }
        
        // Disconnect SceneTree signals
        if let sceneTree {
            if let nodeTransformsChangedToken {
                sceneTree.nodeTransformsChanged.disconnect(nodeTransformsChangedToken)
                self.nodeTransformsChangedToken = nil
            }
            if let nodeAddedToken {
                sceneTree.nodeAdded.disconnect(nodeAddedToken)
                self.nodeAddedToken = nil
            }
            if let nodeRemovedToken {
                sceneTree.nodeRemoved.disconnect(nodeRemovedToken)
                self.nodeRemovedToken = nil
            }
            self.sceneTree = nil
        }
    }
    
    private func cacheAudioResource(resourcePath: String) -> AudioFileResource? {
        var audioResource: AudioFileResource? = _audioResources[resourcePath]
        if audioResource == nil {
            do {
                audioResource = try AudioFileResource.load(contentsOf: projectContext.fileUrl(forGodotResourcePath: resourcePath))
            } catch {
                logError(error)
                return nil
            }
            
            _audioResources[resourcePath] = audioResource
        }
        return audioResource
    }
    
    private func _onMeshResourceChanged(meshEntry: MeshEntry) {
        for entity in meshEntry.entities {
            if let node = entity.components[GodotNode.self]?.node3D {
                let _ = self._updateModelEntityMesh(node, entity)
            }
        }
    }
    
    private func _updateModelEntityMesh(_ node: Node, _ existingEntity: ModelEntity?) -> ModelEntity? {
        // Inspect the Godot node to see if we have a mesh, materials, and a skeleton.
        var materials: [SwiftGodot.Material]? = nil
        
        var mesh: SwiftGodot.Mesh? = nil
        var skeleton3D: SwiftGodot.Skeleton3D? = nil
        var flipFacesIfNoIndexBuffer: Bool = false
        
        if let meshInstance3D = node as? MeshInstance3D {
            //
            // MeshInstance3D
            //
            skeleton3D = meshInstance3D.skeleton.isEmpty() ? nil : (meshInstance3D.getNode(path: meshInstance3D.skeleton) as? Skeleton3D)
            mesh = meshInstance3D.mesh
            if let mesh {
                materials = (0..<mesh.getSurfaceCount()).compactMap { meshInstance3D.getActiveMaterial(surface: $0) }
            }
        } else if let csgShape = node as? CSGShape3D, csgShape.isRootShape() {
            //
            // CSG meshes
            //
            let transformAndMesh = csgShape.getMeshes() // returns [Transform, Mesh]
            if transformAndMesh.count >= 2 {
                flipFacesIfNoIndexBuffer = true
                mesh = transformAndMesh[1].asObject(SwiftGodot.Mesh.self)
                materials = []
                if let mesh {
                    materials = (0..<mesh.getSurfaceCount()).compactMap { mesh.surfaceGetMaterial(surfIdx: $0) }
                }
            }
        }
        
        var entity: ModelEntity? = nil
        if let mesh, let node3D = node as? Node3D {
            let meshCreationInfo = MeshCreationInfo(godotMesh: mesh, godotSkeleton: skeleton3D, flipFacesIfNoIndexBuffer: flipFacesIfNoIndexBuffer)
            
            if let existingEntity, let oldMeshEntry = existingEntity.components[GodotNode.self]?.meshEntry {
                oldMeshEntry.entities.remove(existingEntity)
            }
            
            if let rkMeshEntry = createRealityKitMesh(debugName: String(node3D.name), meshCreationInfo: meshCreationInfo, onResourceChange: _onMeshResourceChanged) {
                let rkMaterials = (materials?.count ?? 0 == 0)
                    ? [SimpleMaterial(color: .white, isMetallic: false)]
                    : materials!.map { resourceCache.rkMaterial(forGodotMaterial: $0) }
                if let existingEntity {
                    existingEntity.model = .init(mesh: rkMeshEntry.meshResource, materials: rkMaterials)
                    entity = existingEntity
                } else {
                    entity = ModelEntity(mesh: rkMeshEntry.meshResource, materials: rkMaterials)
                }
                
                if let entity {
                    rkMeshEntry.entities.insert(entity)
                }
            }
        }
        
        if let entity {
            if let node3D = node as? Node3D {
                entity.components.getOrMake { (godotNode: inout GodotNode) in
                    godotNode.node3D = node3D
                }
            }
            
            // Set grounding shadows on entities with a mesh (unless a metadata entry for 'grounding_shadow' exists and is false
            if mesh != nil && node.getMetaBool("grounding_shadow", defaultValue: true) {
                entity.components.set(GroundingShadowComponent(castsShadow: true))
            } else {
                entity.components.remove(GroundingShadowComponent.self)
            }
        }
        
        return entity
        
    }
    
    private func _createRealityKitEntityForNewNode(_ node: SwiftGodot.Node) -> Entity {
        // Construct a ModelEntity with our mesh data if we have one.
        let entity = _updateModelEntityMesh(node, nil) ?? Entity()
        entity.name = "\(node.name)"
        let instanceID = Int64(node.getInstanceId())
        godotInstanceIDToEntity[instanceID] = entity
        godotEntitiesParent.addChild(entity)
        
        // Setup a node to be tappable with the `InputTargetComponent()` if necessary..
        // TODO: we could have more fine-graned input ray pickable shapes based on the Godot collision shapes. Currently we just put a box around the visual bounds.
        let inputRayPickable: Bool = (node as? CollisionObject3D)?.inputRayPickable ?? false
        if inputRayPickable {
            DispatchQueue.main.async { // TODO: this doesn't need to be dispatched unitl later anymore.
                let bounds = entity.visualBounds(relativeTo: entity.parent)
                let collisionShape: RealityKit.ShapeResource = .generateBox(size: bounds.extents)
                var collision = CollisionComponent(shapes: [collisionShape])
                collision.filter = .init(group: [], mask: []) // disable for collision detection
                entity.components.set(InputTargetComponent())
                
                // If there's a metadata entry for 'hover_effect' with the boolean value of true, we add a RealityKit HoverEffectComponent.
                if node.getMetaBool("hover_effect", defaultValue: false) {
                    entity.components.set(HoverEffectComponent())
                }
                entity.components.set(collision)
            }
        }
        
        // Finally, initialize the position/rotation/scale.
        if let node3D = node as? Node3D {
            entity.transform = RealityKit.Transform(node3D.transform)
            entity.isEnabled = node3D.visible
        }
        
        return entity
    }

    private func updateSkeletonNode(node: SwiftGodot.Node3D, entity: RealityKit.Entity) {
        // TODO: we might be able to register for an event when the bone poses change, and respond to that, instead of doing a per frame check. @Perf
        if let modelEntity = entity as? ModelEntity, let model = modelEntity.model, let _ = model.mesh.contents.skeletons.first(where: { _ in true /* TODO: hack, no */ }) {
            if let meshInstance3D = node as? MeshInstance3D, let skeleton = meshInstance3D.getNode(path: meshInstance3D.skeleton) as? Skeleton3D {
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
    
    
    private func realityKitPerFrameTick(_ event: SceneEvents.Update) {
        if stepGodotFrame() {
            print("GODOT HAS QUIT")
            // TODO: ask visionOS application to quit? or...?
        }
        
        var x: Double?
        var y: Double?
        
        // need to check if this is connected
        if let multipeerJoystickPosition = multipeerJoystickPosition {
            x = Double(multipeerJoystickPosition.x)
            y = Double(multipeerJoystickPosition.y)
        } else if let leftThumbstick = GCController.current?.input.dpads[.leftThumbstick] {
            if #available(visionOS 1.1, *) {
                x = Double(leftThumbstick.xAxis.value)
                y = Double(leftThumbstick.yAxis.value)
            }
        }
        
        if let x = x, let y = y {
            if (x != .zero) {
                SwiftGodot.Input.actionRelease(action: x > 0 ? "ui_left" : "ui_right")
                SwiftGodot.Input.actionPress(action: x > 0 ? "ui_right" : "ui_left", strength: abs(x))
            } else {
                SwiftGodot.Input.actionRelease(action: "ui_right")
                SwiftGodot.Input.actionRelease(action: "ui_left")
            }
            if (y != .zero) {
                SwiftGodot.Input.actionRelease(action: y > 0 ? "ui_down" : "ui_up")
                SwiftGodot.Input.actionPress(action: y > 0 ? "ui_up" : "ui_down", strength: abs(y))
            } else {
                SwiftGodot.Input.actionRelease(action: "ui_up")
                SwiftGodot.Input.actionRelease(action: "ui_down")
            }
        }
        
        for (id, isRoot) in nodeIdsForNewlyEnteredNodes {
            guard let node = GD.instanceFromId(instanceId: id) as? Node else {
                logError("No new Node instance for id \(id)")
                continue
            }
            
            let entity = _createRealityKitEntityForNewNode(node)
            if let node3D = node as? Node3D, isSkeletonNode(node: node3D, entity: entity) {
                entity.components.set(GodotNode(node3D: node3D))
                skeletonEntities.insert(entity)
            }
            
            // we notice a specially named node for the "bounds"
            if node.name == VISION_VOLUME_CAMERA_GODOT_NODE_NAME, let node3D = node as? Node3D {
                didReceiveGodotVolumeCamera(node3D)
            }
            
            
            if node.hasSignal("spatial_drag") {
                // TODO: check if it's a collision object? warn if not?
                entity.components.set(GodotVisionDraggable())
            }
            
            if let audioStreamPlayer3D = node as? AudioStreamPlayer3D {
                // See if we need to prepare the audio resource (prevents a hitch on first play).
                if audioStreamPlayer3D.getMetaBool("gv.auto_prepare", defaultValue: true) {
                    if let resourcePath = audioStreamPlayer3D.stream?.resourcePath {
                        audioStreamPlays.append(.init(godotInstanceID: Int64(audioStreamPlayer3D.getInstanceId()),
                                                      resourcePath: resourcePath,
                                                      volumeDb: audioStreamPlayer3D.volumeDb,
                                                      prepareOnly: true))
                    }
                }
            }
            
            if !isRoot, let nodeParent = node.getParent() {
                let parentId = Int64(nodeParent.getInstanceId())
                if let parent = godotInstanceIDToEntity[parentId] {
                    entity.setParent(parent)
                } else {
                    logError("could not find parent for id \(parentId)")
                }
            }
        }
        nodeIdsForNewlyEnteredNodes.removeAll()

        var retries: [AudioStreamPlay] = []
        defer {
            audioStreamPlays = retries
            godotInstanceIDsRemovedFromTree.removeAll()
        }
        
        do {
            let newAudios = audioToProcess
            audioToProcess.removeAll()
            enum State: Int64 {
                case UNKNOWN = 0
                case PLAY = 1
                case STOP = 2
            }
            
            for newAudio in newAudios {
                let node = GD.instanceFromId(instanceId: newAudio.instanceId)
                if let audioStreamPlayer3D = node as? AudioStreamPlayer3D {
                    if let resourcePath = audioStreamPlayer3D.stream?.resourcePath {
                        if newAudio.state == State.PLAY.rawValue {
                            audioStreamPlays.append(.init(godotInstanceID: Int64(audioStreamPlayer3D.getInstanceId()),
                                                          resourcePath: resourcePath,
                                                          volumeDb: audioStreamPlayer3D.volumeDb,
                                                          prepareOnly: false))
                        }
                    }
                }
            }
        }
        
        // Play any AudioStreamPlayer3D sounds
        for var audioStreamPlay in audioStreamPlays {
            guard let entity = godotInstanceIDToEntity[audioStreamPlay.godotInstanceID] else {
                audioStreamPlay.retryCount += 1
                if audioStreamPlay.retryCount < 100 {
                    retries.append(audioStreamPlay) // we may not have seen the instance yet.
                }
                continue
            }
            
            if let audioResource = cacheAudioResource(resourcePath: audioStreamPlay.resourcePath) {
                if audioStreamPlay.prepareOnly {
                    let _ = entity.prepareAudio(audioResource)
                } else {
                    let audioPlaybackController = entity.playAudio(audioResource)
                    audioPlaybackController.gain = audioStreamPlay.volumeDb
                }
            }
        }
        
        // Remove any RealityKit Entities for Godot nodes that were removed from the Godot tree.
        for instanceIdRemovedFromTree in godotInstanceIDsRemovedFromTree {
            guard let entity = godotInstanceIDToEntity[Int64(instanceIdRemovedFromTree)] else { continue }
            if let godotNode = entity.components[GodotNode.self] {
                if let meshEntry = godotNode.meshEntry, let modelEntity = entity as? ModelEntity {
                    meshEntry.entities.remove(modelEntity)
                }
                entity.components.remove(GodotNode.self)
            }
            entity.components.remove(GodotNode.self)
            entity.removeFromParent()
            skeletonEntities.remove(entity)
            godotInstanceIDToEntity.removeValue(forKey: Int64(instanceIdRemovedFromTree))
        }
        
        // Update skeletons
        for entity in skeletonEntities {
            if let node = entity.components[GodotNode.self]?.node3D {
                updateSkeletonNode(node: node, entity: entity)
            }
        }
        
        if let volumeCamera {
            // Movement and rotation in the Godot camera (or our GodotVision camera volume node) get reflected
            // in our scene by applying the inverse transform of the camera to the parent Entity of Godot objects.
            godotEntitiesParent.transform = .init(volumeCamera.globalTransform.affineInverse())
            godotEntitiesScale.scale = .one * godotToRealityKitRatio
        }
    }
    
    // TODO: remove this function and use the `GodotNode` Component to link Entity -> Node3D
    func godotInstanceFromRealityKitEntityID(_ eID: Entity.ID) -> SwiftGodot.Object? {
        for (godotInstanceID, rkEntity) in godotInstanceIDToEntity where rkEntity.id == eID {
            guard let godotInstance = GD.instanceFromId(instanceId: godotInstanceID) else {
                logError("could not get Godot instance from id \(godotInstanceID)")
                continue
            }
            
            return godotInstance
        }
        
        return nil
    }
    
    public func receivedMultipeerJoystick(_ multipeerJoystickPosition: simd_float2) {
        self.multipeerJoystickPosition = multipeerJoystickPosition
    }
    
    /// A visionOS drag is starting or being updated. We emit a signal with information about the gesture so that Godot code can respond.
    func receivedDrag(_ value: EntityTargetValue<DragGesture.Value>, ended: Bool = false) {
        let entity = value.entity
        
        // See if this Node has a 'drag' signal
        guard let obj = self.godotInstanceFromRealityKitEntityID(entity.id) else { return }
        if !obj.hasSignal("spatial_drag") {
            return
        }
        
        guard var dragCtx = entity.components[GodotVisionDraggable.self] else { return }
        defer { entity.components.set(dragCtx) }
        
        var origPos = dragCtx.originalPosition
        var began = false
        if origPos == nil {
            origPos = entity.position(relativeTo: nil)
            dragCtx.originalPosition = origPos
            began = true
        }
        
        var origRotation = dragCtx.originalRotation
        if origRotation == nil {
            origRotation = Rotation3D(entity.orientation(relativeTo: nil))
            dragCtx.originalRotation = origRotation
        }
        
        // Rotation
        var newOrientation = entity.orientation(relativeTo: nil)
        let localToScene = value.transform(from: .local, to: .scene) // an AffineTransform3D which maps .local to .scene
        if let startInputDevicePose3D = value.startInputDevicePose3D,
            let inputDevicePose3D = value.inputDevicePose3D,
           let startRotation = (localToScene * AffineTransform3D(pose: startInputDevicePose3D)).rotation,
           let currentRotation = (localToScene * AffineTransform3D(pose: inputDevicePose3D)).rotation
        {
            // "add" the original pose and the delta of the (current pose - start pose)
            newOrientation = .init((currentRotation * startRotation.inverse) * origRotation!)
        }
        
        // Position
        // Note that we ignore the position of the pose3D objects above--they are actually more noisy than the smoothed out version we get in
        // the gesture value.
        let startPos = value.convert(value.startLocation3D, from: .local, to: .scene)
        let currentPos = value.convert(value.location3D, from: .local, to: .scene)
        let newPosition = (currentPos - startPos) + origPos!
        
        let scale = entity.scale(relativeTo: nil) // TODO: test dragging nodes with different scales to make sure this is right
        
        let gdStartGlobalTransform = godotEntitiesParent.convert(transform: .init(scale: scale, rotation: .init(origRotation!), translation: .init(origPos!)), from: nil)
        let gdGlobalTransform = godotEntitiesParent.convert(transform: .init(scale: scale, rotation: newOrientation, translation: newPosition), from: nil)
        
        // pass a dictionary of values to the drag signal
        let dict: GDictionary = .init()
        dict["global_transform"] = Variant(Transform3D(gdGlobalTransform))
        dict["start_global_transform"] = Variant(Transform3D(gdStartGlobalTransform))
        dict["phase"] = Variant(ended ? "ended" : (began ? "began" : "changed"))
        
        obj.emitSignal("spatial_drag", Variant(dict))
        
        if ended {
            dragCtx.reset()
        }
    }
    
    /// A visionOS drag has ended. We emit a signal to inform Godot land.
    func receivedDragEnded(_ value: EntityTargetValue<DragGesture.Value>) {
        receivedDrag(value, ended: true)
    }
    
    /// RealityKit has received a SpatialTapGesture in the RealityView
    func receivedTap(event: EntityTargetValue<SpatialTapGesture.Value>) {
        let sceneLoc = event.convert(event.location3D, from: .local, to: .scene)
        let godotLocation = godotEntitiesParent.convert(position: simd_float3(sceneLoc), from: nil)
        
        // TODO: hack. this normal is not always right. currently this just pretends everything you tap is a sphere???
        
        let realityKitNormal = normalize(event.entity.position(relativeTo: nil) - sceneLoc)
        
        // TODO: need to convert the normal to global or local space?
        
        let godotNormal = realityKitNormal
        
        guard let obj = self.godotInstanceFromRealityKitEntityID(event.entity.id) else { return }
            
        // Construct an InputEventMouseButton to send to Godot.
        
        let godotEvent = InputEventMouseButton()
        godotEvent.buttonIndex = .left
        godotEvent.doubleClick = false // TODO
        godotEvent.pressed = true
        
        let position = SwiftGodot.Vector3(godotLocation) // TODO: check if this should be global or local.
        let normal = SwiftGodot.Vector3(godotNormal)
        let shape_idx = 0
        
        // TODO: I think SwiftGodot provides a better way to emit signals than all these Variant() constructors
        obj.emitSignal("input_event", Variant.init(), Variant(godotEvent), Variant(position), Variant(normal), Variant(shape_idx))
    }
}


/// Stores a reference to a Godot Node3D in the RealityKit ECS for an Entity.
struct GodotNode: Component {
    var node3D: Node3D? = nil
    var meshEntry: MeshEntry? = nil
}

/// Contains the notion of where in the application bundle to find the Godot .project file.
class GodotProjectContext {
    var projectFolderName: String? = nil
    
    func fileUrl(forGodotResourcePath resourcePath: String) -> URL {
        getGodotProjectURL().appendingPathComponent(resourcePath.removingStringPrefix("res://"))
    }

    func getGodotProjectURL() -> URL {
        if projectFolderName == nil {
            print("*** WARNING, defaulting to DEFAULT_PROJECT_FOLDER_NAME")
        }
        let dirName = projectFolderName ?? DEFAULT_PROJECT_FOLDER_NAME
        guard let url = Bundle.main.url(forResource: dirName, withExtension: nil) else {
            fatalError("ERROR: could not find '\(dirName)' Godot project folder in Bundle.main")
        }
        return url
    }

    func getProjectDir() -> String {
        // Godot is expecting a path without the file:// part for the packfile
        getGodotProjectURL().absoluteString.removingStringPrefix("file://")
    }
}



struct GodotVisionDraggable: Component {
    var originalPosition: simd_float3? = nil
    var originalRotation: Rotation3D? = nil
    
    mutating func reset() {
        originalPosition = nil
        originalRotation = nil
    }
}
    
private func isSkeletonNode(node: SwiftGodot.Node3D, entity: RealityKit.Entity) -> Bool {
    if let modelEntity = entity as? ModelEntity, let model = modelEntity.model, let _ = model.mesh.contents.skeletons.first(where: { _ in true /* TODO: hack, no */ }) {
        if let meshInstance3D = node as? MeshInstance3D, let _ = meshInstance3D.getNode(path: meshInstance3D.skeleton) as? Skeleton3D {
            return true
        }
    }
    
    return false
}

protocol TriviallyInitializableComponent: Component { init() }
extension GodotNode: TriviallyInitializableComponent {}
    
extension Entity.ComponentSet {
    mutating func getOrMake<T>(_ cb: (inout T) -> Void) where T: TriviallyInitializableComponent {
        var componentData = self[T.self] ?? .init()
        cb(&componentData)
        self[T.self] = componentData
    }
    
    mutating func modifyIfExists<T>(_ cb: (inout T) -> Void) where T: Component {
        if var componentData = self[T.self] {
            cb(&componentData)
            self[T.self] = componentData
        }
    }
}

