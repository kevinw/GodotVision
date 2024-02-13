/**
 
Convert Godot Resources (meshes, textures, materials, etc.) to their RealityKit counterparts.
 
 */

//  Created by Kevin Watters on 1/19/24.

import SwiftGodot
import RealityKit
import Foundation


class ResourceCache {
    var meshes:    [SwiftGodot.Mesh: MeshEntry] = .init()
    var materials: [SwiftGodot.Material: MaterialEntry] = .init()
    var textures:  [SwiftGodot.Texture: TextureEntry] = .init()
    
    func reset() {
        meshes.removeAll()
        materials.removeAll()
        textures.removeAll()
    }
    
    func meshEntry(forGodotMesh godotMesh: SwiftGodot.Mesh) -> MeshEntry {
        if meshes[godotMesh] == nil {
            meshes[godotMesh] = MeshEntry(godotResource: godotMesh)
        }
        return meshes[godotMesh]!
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
}

class ResourceEntry<G, R> where G: SwiftGodot.Resource {
    fileprivate var godotResource: G? = nil
    fileprivate var _createdRealityKitResource: R? = nil
    fileprivate var changedToken: SwiftGodot.Object? = nil
    
    func onChanged() {
        // TODO: haven't actually verified this works...
        
        print("\(Self.self) CHANGED", String(describing: godotResource))
        DispatchQueue.main.async {
            self._createdRealityKitResource = nil
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
        if _createdRealityKitResource == nil, let godotResource {
            if let stdMat = godotResource as? StandardMaterial3D {
                var rkMat = PhysicallyBasedMaterial()
                
                // TODO: flesh this out so that we respect as many Godot PBR fields as possible.
                // also should work for godot's ORMMaterial as well
                
                if let albedoTexture = stdMat.albedoTexture {
                    let textureEntry = resourceCache.textureEntry(forGodotTexture: albedoTexture)
                    let rkTexture = textureEntry.getTexture(resourceCache: resourceCache)
                    rkMat.baseColor = .init(tint: uiColor(forGodotColor: stdMat.albedoColor), texture: .init(rkTexture))
                    rkMat.metallic = PhysicallyBasedMaterial.Metallic(floatLiteral: Float(stdMat.metallic))
                    rkMat.roughness = PhysicallyBasedMaterial.Roughness(floatLiteral: Float(stdMat.roughness))
                } else {
                    if stdMat.transparency == .alpha {
                        rkMat.baseColor = .init(tint: uiColor(forGodotColor: stdMat.albedoColor).withAlphaComponent(1.0))
                        rkMat.blending = .transparent(opacity: .init(floatLiteral: stdMat.albedoColor.alpha))
                    } else {
                        rkMat.baseColor = .init(tint: uiColor(forGodotColor: stdMat.albedoColor))
                    }
                    rkMat.metallic = PhysicallyBasedMaterial.Metallic(floatLiteral: Float(stdMat.metallic))
                    rkMat.roughness = PhysicallyBasedMaterial.Roughness(floatLiteral: Float(stdMat.roughness))
                }
                _createdRealityKitResource = rkMat
            }
        }
        
        if _createdRealityKitResource == nil {
            print("ERROR: generating material from", String(describing: godotResource))
            _createdRealityKitResource = SimpleMaterial(color: .systemPink, isMetallic: false)
        }
        
        return _createdRealityKitResource!
    }
}

/// Generates a RealityKit mesh from a Godot mesh.
class MeshEntry: ResourceEntry<SwiftGodot.Mesh, RealityKit.MeshResource> {
    var meshResource: MeshResource {
        if _createdRealityKitResource == nil, let godotResource {
            if let descriptors = createRealityKitMeshFromGodot(mesh: godotResource) {
                do {
                    _createdRealityKitResource = try MeshResource.generate(from: descriptors)
                } catch {
                    print("ERROR", error)
                }
            }
        }
        
        if _createdRealityKitResource == nil {
            print("ERROR: generating sphere as error mesh")
            _createdRealityKitResource = MeshResource.generateSphere(radius: 1.0)
        }
        
        return _createdRealityKitResource!
    }
}

private func createRealityKitMeshFromGodot(mesh: SwiftGodot.Mesh) -> [MeshDescriptor]? {
    if mesh.getSurfaceCount() == 0 {
        fatalError("TODO: how to handle a Godot mesh with zero surfaces?")
    }
    
    enum ArrayType: Int { // TODO: are these already exposed from SwiftGodot somewhere?
        case ARRAY_VERTEX = 0
        case ARRAY_TEX_UV = 4
        case ARRAY_INDEX = 12
    }
    
    var meshDescriptors: [MeshDescriptor] = []
    for surfIdx in 0..<mesh.getSurfaceCount() {
        let surfaceArrays = mesh.surfaceGetArrays(surfIdx: surfIdx)
        
        MEMORY_LEAK_TO_PREVENT_REFCOUNT_CRASH.append(surfaceArrays)
        
        guard let vertices = surfaceArrays[ArrayType.ARRAY_VERTEX.rawValue].cast(as: PackedVector3Array.self, debugName: "mesh vertices") else { continue }
        guard let indices = surfaceArrays[ArrayType.ARRAY_INDEX.rawValue].cast(as: PackedInt32Array.self, debugName: "mesh indices") else { continue }
        
        var meshDescriptor = MeshDescriptor(name: "vertices for godot mesh " + mesh.resourceName)
        meshDescriptor.positions = MeshBuffer(vertices.map { simd_float3($0) })
        meshDescriptor.primitives = .triangles(reverseWindingOrder(ofIndexBuffer: indices.map { UInt32($0) }))
        
        let uvsVariant = surfaceArrays[ArrayType.ARRAY_TEX_UV.rawValue]
        
        if uvsVariant.gtype != .nil, let uvs = uvsVariant.cast(as: PackedVector2Array.self, debugName: "uvs") {
            meshDescriptor.textureCoordinates = .init(uvs.map { simd_float2($0.x, 1.0 - $0.y) })
        }
        
        meshDescriptors.append(meshDescriptor)
    }
    
    return meshDescriptors
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
