/**
 
Convert Godot Resources (meshes, textures, materials, etc.) to their RealityKit counterparts.
 
 */

//  Created by Kevin Watters on 1/19/24.

import SwiftGodot
import RealityKit
import Foundation

class ResourceCache {
    var materials: [SwiftGodot.Material: MaterialEntry] = .init()
    var textures:  [SwiftGodot.Texture: TextureEntry] = .init()
    
    func reset() {
        materials.removeAll()
        textures.removeAll()
    }
    
    func materialEntry(forGodotMaterial godotMaterial: SwiftGodot.Material) -> MaterialEntry {
        if materials[godotMaterial] == nil {
            materials[godotMaterial] = MaterialEntry(godotResource: godotMaterial)
        }
        return materials[godotMaterial]!
    }
    
    func textureEntry(forGodotTexture godotTexture: SwiftGodot.Texture) -> TextureEntry {
        if textures[godotTexture] == nil {
            textures[godotTexture] = TextureEntry(godotResource: godotTexture)
        }
        return textures[godotTexture]!
    }
    
    func rkTexture(forGodotTexture godotTexture: SwiftGodot.Texture) -> RealityKit.TextureResource {
        textureEntry(forGodotTexture: godotTexture).getTexture(resourceCache: self)
    }
}

class ResourceEntry<G, R> where G: SwiftGodot.Resource {
    fileprivate var godotResource: G? = nil
    fileprivate var rkResource: R? = nil
    fileprivate var changedToken: SwiftGodot.Object? = nil
    
    private func onChanged() {
        // TODO: haven't actually verified this works...
        
        print("\(Self.self) CHANGED", String(describing: godotResource))
        DispatchQueue.main.async {
            self.rkResource = nil
        }
    }
    
    init(godotResource: G) {
        self.godotResource = godotResource
        changedToken = godotResource.changed.connect(onChanged)
    }
    
    deinit {
        if let changedToken, let godotResource {
            godotResource.changed.disconnect(changedToken)
        }
        
        changedToken = nil
        godotResource = nil
    }
}

class TextureEntry: ResourceEntry<SwiftGodot.Texture, RealityKit.TextureResource> {
    func getTexture(resourceCache: ResourceCache) -> RealityKit.TextureResource {
        if let godotTex = godotResource as? SwiftGodot.Texture2D {
            return try! .load(contentsOf: fileUrl(forGodotResourcePath: godotTex.resourcePath))
        }
        
        return try! .load(named: "error-unknown-texture")
    }
}

class MaterialEntry: ResourceEntry<SwiftGodot.Material, RealityKit.Material> {
    func getMaterial(resourceCache: ResourceCache) -> RealityKit.Material {
        if rkResource == nil, let godotResource {
            if let stdMat = godotResource as? StandardMaterial3D {
                var rkMat = PhysicallyBasedMaterial()
                
                // TODO: flesh this out so that we respect as many Godot PBR fields as possible.
                // also should work for godot's ORMMaterial as well
                
                //
                // ALBEDO (base color)
                //
                if let albedoTexture = stdMat.albedoTexture {
                    rkMat.baseColor = .init(tint: uiColor(forGodotColor: stdMat.albedoColor), texture: .init(resourceCache.rkTexture(forGodotTexture: albedoTexture)))
                } else {
                    if stdMat.transparency == .alpha {
                        rkMat.baseColor = .init(tint: uiColor(forGodotColor: stdMat.albedoColor).withAlphaComponent(1.0))
                        rkMat.blending = .transparent(opacity: .init(floatLiteral: stdMat.albedoColor.alpha))
                    } else {
                        rkMat.baseColor = .init(tint: uiColor(forGodotColor: stdMat.albedoColor))
                    }
                }
                
                rkMat.metallic = PhysicallyBasedMaterial.Metallic(floatLiteral: Float(stdMat.metallic))
                rkMat.roughness = PhysicallyBasedMaterial.Roughness(floatLiteral: Float(stdMat.roughness))
                rkMat.textureCoordinateTransform = .init(offset: SIMD2<Float>(x: stdMat.uv1Offset.x, y: stdMat.uv1Offset.y), scale: SIMD2<Float>(x: stdMat.uv1Scale.x, y: stdMat.uv1Scale.y))
                
                //
                // EMISSION
                //
                if stdMat.emissionEnabled {
                    let emissiveColor: PhysicallyBasedMaterial.EmissiveColor
                    if let emissionTexture = stdMat.emissionTexture {
                        emissiveColor  = .init(color: uiColor(forGodotColor: stdMat.emission), texture: .init(resourceCache.rkTexture(forGodotTexture: emissionTexture)))
                    } else {
                        emissiveColor = .init(color: uiColor(forGodotColor: stdMat.emission))
                    }
                    
                    rkMat.emissiveColor = emissiveColor
                    rkMat.emissiveIntensity = Float(stdMat.emissionIntensity / 1000.0) // TODO: Godot docs say Material.emission_intensity is specified in nits and defaults to 1000. not sure how to convert this, since the RealityKit docs don't specify a unit.
                }
                
                rkResource = rkMat
            }
        }
        
        if rkResource == nil {
            logError("generating material from \(String(describing: godotResource))")
            rkResource = SimpleMaterial(color: .systemPink, isMetallic: false)
        }
        
        return rkResource!
    }
}

struct MeshKey: Hashable {
    var godotMesh: SwiftGodot.Mesh
    var godotSkeleton: SwiftGodot.Skeleton3D? = nil
}

private var meshCache: [MeshKey: MeshResource] = [:] // TODO @Leak

func createRealityKitMesh(node: Node3D, godotMesh: SwiftGodot.Mesh, godotSkeleton: SwiftGodot.Skeleton3D? = nil) -> MeshResource? {
    let key = MeshKey(godotMesh: godotMesh, godotSkeleton: godotSkeleton)
    if let meshResource = meshCache[key] {
        return meshResource
    }
    
    var meshResource: MeshResource? = nil
    doLoggingErrors {
        let meshContents = try meshContents(node: node, fromGodotMesh: godotMesh, skeleton: godotSkeleton, verbose: true)
        meshResource = try MeshResource.generate(from: meshContents)
    }

    if let meshResource {
        meshCache[key] = meshResource
    }
    
    return meshResource
}

func createRealityKitSkeleton(skeleton: SwiftGodot.Skeleton3D) -> MeshResource.Skeleton? {
    var jointNames: [String] = []
    var inverseBindPoseMatrices: [simd_float4x4] = []
    var restPoseTransforms: [RealityKit.Transform] = []
    var parentIndices: [Int] = []

    for boneIdx in 0..<skeleton.getBoneCount() {
        jointNames.append(skeleton.getBoneName(boneIdx: boneIdx))
        inverseBindPoseMatrices.append(simd_inverse(simd_float4x4(skeleton.getBonePose(boneIdx: boneIdx)))) // TODO XXX does this need to be inverse?
        restPoseTransforms.append(RealityKit.Transform(skeleton.getBoneRest(boneIdx: boneIdx)))
        parentIndices.append(Int(skeleton.getBoneParent(boneIdx: boneIdx)))
    }
    
    let skeletonName = String(skeleton.name)
    return MeshResource.Skeleton(id: skeletonName.count > 0 ? skeletonName : "skeleton",
                                 jointNames: jointNames,
                                 inverseBindPoseMatrices: inverseBindPoseMatrices,
                                 restPoseTransforms: restPoseTransforms,
                                 parentIndices: parentIndices
    )
}

private func meshContents(node: Node3D,
                          fromGodotMesh mesh: SwiftGodot.Mesh,
                          skeleton: SwiftGodot.Skeleton3D? = nil,
                          verbose: Bool = false) throws -> MeshResource.Contents
{
    if mesh.getSurfaceCount() == 0 {
        fatalError("TODO: how to handle a Godot mesh with zero surfaces?")
    }
    
    enum ArrayType: Int { // TODO: are these already exposed from SwiftGodot somewhere?
        case ARRAY_VERTEX = 0
        case ARRAY_TEX_UV = 4
        case ARRAY_BONES = 10 /// PackedFloat32Array or PackedInt32Array of bone indices. Contains either 4 or 8 numbers per vertex depending on the presence of the ARRAY_FLAG_USE_8_BONE_WEIGHTS flag.
        case ARRAY_WEIGHTS = 11 /// PackedFloat32Array or PackedFloat64Array of bone weights in the range 0.0 to 1.0 (inclusive). Contains either 4 or 8 numbers per vertex depending on the presence of the ARRAY_FLAG_USE_8_BONE_WEIGHTS flag.
        case ARRAY_INDEX = 12
    }
    
    var meshDescriptors: [(descriptor: MeshDescriptor, jointInfluences: [MeshJointInfluence])] = []
    for surfIdx in 0..<mesh.getSurfaceCount() {
        let surfaceArrays = mesh.surfaceGetArrays(surfIdx: surfIdx)
        
        MEMORY_LEAK_TO_PREVENT_REFCOUNT_CRASH.append(surfaceArrays)
        
        guard let vertices = surfaceArrays[ArrayType.ARRAY_VERTEX.rawValue].cast(as: PackedVector3Array.self, debugName: "mesh vertices") else { continue }
        guard let indices = surfaceArrays[ArrayType.ARRAY_INDEX.rawValue].cast(as: PackedInt32Array.self, debugName: "mesh indices") else { continue }
        
        var jointInfluences: [MeshJointInfluence] = []
        
        // ARRAY_BONES
        do {
            let bonesVariant = surfaceArrays[ArrayType.ARRAY_BONES.rawValue]
            switch bonesVariant.gtype {
            case .nil:
                ()
            case .packedInt32Array:
                if let bones = bonesVariant.cast(as: PackedInt32Array.self, debugName: "ARRAY_BONES") {
                    jointInfluences = bones.map { boneIndex in MeshJointInfluence(jointIndex: Int(boneIndex), weight: 0) }
                }
            case .packedFloat32Array:
                if let bones = bonesVariant.cast(as: PackedFloat32Array.self, debugName: "ARRAY_BONES") {
                    jointInfluences = bones.map { MeshJointInfluence(jointIndex: Int($0), weight: 0) }
                }
            default:
                logError("ARRAY_BONES array had unexpected gtype: \(bonesVariant.gtype)")
            }
        }
        
        // ARRAY_WEIGHTS
        do {
            let weightsVariant = surfaceArrays[ArrayType.ARRAY_WEIGHTS.rawValue]
            switch weightsVariant.gtype {
            case .nil:
                if jointInfluences.count > 0 {
                    logError("nil ARRAY_WEIGHTS but ARRAY_BONES present")
                }
            case .packedFloat32Array:
                if let weights = weightsVariant.cast(as: PackedFloat32Array.self, debugName: "ARRAY_WEIGHTS") {
                    if jointInfluences.count <= weights.count {
                        weights.enumerated().forEach { (idx, weight) in jointInfluences[idx].weight = weight }
                    } else {
                        logError("more weights than bone indices")
                    }
                }
            case .packedFloat64Array:
                if let weights = weightsVariant.cast(as: PackedFloat64Array.self, debugName: "ARRAY_WEIGHTS") {
                    if jointInfluences.count <= weights.count {
                        weights.enumerated().forEach { (idx, weight) in jointInfluences[idx].weight = Float(weight) } // note: precision loss from 64 to 32 bit
                    } else {
                        logError("more weights than bone indices")
                    }
                }
            default:
                logError("ARRAY_WEIGHTS array had unexpected gtype: \(weightsVariant.gtype)")
            }
        }
        
        var meshDescriptor = MeshDescriptor(name: "vertices for godot mesh " + mesh.resourceName)
        meshDescriptor.materials = .allFaces(UInt32(surfIdx))
        meshDescriptor.positions = MeshBuffer(vertices.map { simd_float3($0) })
        meshDescriptor.primitives = .triangles(reverseWindingOrder(ofIndexBuffer: indices.map { UInt32($0) }))
        if let uvs = surfaceArrays[ArrayType.ARRAY_TEX_UV.rawValue].cast(as: PackedVector2Array.self, debugName: "uvs") {
            meshDescriptor.textureCoordinates = .init(uvs.map { point in
                simd_float2(x: point.x, y: 1 - point.y)
            })
        }
        
        
        meshDescriptors.append((descriptor: meshDescriptor, jointInfluences: jointInfluences))
    }
    
    let tempMesh = try MeshResource.generate(from: meshDescriptors.map { $0.descriptor })
    
    //
    // apparently realitykit doesn't (yet) let you set joint influences on a MeshDescriptor,
    // so we take a roundabout way of getting jointInfluences into the mesh by generating the mesh,
    // then iterating over its parts, applying the influences, and regenerating the mesh again.
    // not great.
    //
    
    var newContents = MeshResource.Contents()
    newContents.instances = tempMesh.contents.instances
    
    
    var rkSkeleton: MeshResource.Skeleton? = nil
    if let skeleton {
        if let newSkeleton = createRealityKitSkeleton(skeleton: skeleton) {
            rkSkeleton = newSkeleton
            newContents.skeletons = MeshSkeletonCollection([newSkeleton])
        }
    }
    
    var index = 0
    var modelCollection = MeshModelCollection()
    tempMesh.contents.models.forEach {
        let newParts: [MeshResource.Part] = $0.parts.map {
            var newPart = $0
            if meshDescriptors[index].jointInfluences.count > 0 {
                let jointInfluences = MeshBuffers.JointInfluences(meshDescriptors[index].jointInfluences)
                let influencesPerVertex: Int = jointInfluences.count / $0.positions.count
                if !(influencesPerVertex == 4 || influencesPerVertex == 8) {
                    fatalError("should be 4 or 8")
                }
                
                // NOTE: RealityKit will silently set 'skeletonID' to nil here if the MeshContents does not
                // already have a matching skeleton in its .skeletons collection!
                newPart.jointInfluences = .init(influences: MeshBuffers.JointInfluences(jointInfluences), influencesPerVertex: influencesPerVertex)
                newPart.skeletonID = rkSkeleton?.id
                if let skeletonID = newPart.skeletonID {
                    if newContents.skeletons[skeletonID] == nil {
                        logError("no skeleton for id '\(skeletonID)'")
                    }
                }
            }
            index += 1
            return newPart
        }
        modelCollection.insert(MeshResource.Model(id: $0.id, parts: newParts))
    }
    newContents.models = modelCollection
    

    return newContents
}

private var MEMORY_LEAK_TO_PREVENT_REFCOUNT_CRASH: [GArray] = []

private func reverseWindingOrder<T>(ofIndexBuffer buffer: [T]) -> [T]  where T: BinaryInteger {
    var result: [T] = Array.init(repeating: T(), count: buffer.count)
    
    assert(buffer.count % 3 == 0)
    
    var i = 0
    while i < buffer.count {
        result[i + 0] = buffer[i + 0]
        result[i + 1] = buffer[i + 2]
        result[i + 2] = buffer[i + 1]
        
        i += 3
    }
    
    return result
}
