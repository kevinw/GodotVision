# GodotVision

Godot headless on visionOS, rendered with RealityKit. 

See [GodotVisionExample](https://github.com/kevinw/GodotVisionExample) for a simple repository you can clone and run in Xcode.

![example image](https://raw.githubusercontent.com/kevinw/GodotVisionExample/main/docs/screenshot1.jpg)

## Limitations

* No skinned meshes yet.
* No shaders yet.
* Not all of PBR material options yet (this is an easier pull request!)
* Lots of unpicked low hanging performance fruit on the tree:
    * Some modifications to Godot proper reserving us a bit somewhere for "node position/rotation/scale" changed might mean that static objects have almost no performance cost.
* Any native GDExtensions you want to use need to be compiled for visionOS.

## Roadmap

To fix

* Print statements appear twice in the Xcode console
* Cleanup / document the notion of scale
* By default, scale should be 1 meter in Godot equals 1 meter in RealityKit
* Document the [minor changes we made to Godot's ios backend](https://github.com/multijam/godot)

To add

* Live reload of Godot scene if saved from the editor
    * HTTP server serving the PCK file? Or simply the directory? Investigate how easy it would be to add (or use an existing) network layer to the Godot filesystem stuff.
* ~~Audio sound effects via AudioStreamPlayer3D~~
* Undo ugly InterThread/locking stuff now that we’re running on the main thread
* More (prettier!) example scenes!
* Skinned meshes
* Use SwiftUI attachments in godot scene?
* Loading scenes from within Godot should work seamlessly
* Support updating Godot project for released apps without an app store review cycle
* Find a way to use the .godot compressed and imported textures/assets directly from builds, so that we don’t have to include what is essentially two copies of all assets.
* Possibly use Godot’s CompressedTexture2D directly to load textures, etc.

Long term

* Use the upcoming Godot Metal port and share textures/buffers directly when possible. Find out what kinds of shader translation are "easy" in this shiny new Metal world
