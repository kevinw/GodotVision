# GodotVision

Godot headless on visionOS, rendered with RealityKit. 

## Roadmap

To add

* ~~Audio sound effects via AudioStreamPlayer3D~~
* Undo ugly InterThread/locking stuff now that we’re running on the main thread
* Skinned meshes
* Use SwiftUI attachments in godot scene?
* Loading scenes from within Godot should work seamlessly
* Live reload of Godot scene if saved from the editor
* HTTP server serving the PCK file? Or simply the directory? Investigate how easy it would be to add (or use an existing) network layer to the Godot filesystem stuff.
* Support updating Godot project for released apps without an app store review cycle
* Find a way to use the .godot compressed and imported textures/assets directly from builds, so that we don’t have to include what is essentially two copies of all assets.
* Possibly use Godot’s CompressedTexture2D directly to load textures, etc.

To fix

* Print statements appear twice in the Xcode console
* Cleanup / document the notion of scale
