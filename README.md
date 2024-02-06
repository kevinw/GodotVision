# GodotVision

### Questions? Join the [SwiftGodot Slack](https://join.slack.com/t/swiftongodot/shared_invite/zt-2aqygohvb-stSRGEAN~c3awuMwtaqCAA)

Godot headless on visionOS, rendered with RealityKit, so you can create shared-space visionOS experiences from Godot.

See [GodotVisionExample](https://github.com/kevinw/GodotVisionExample) for a simple repository you can clone and run in Xcode.

![example image](https://raw.githubusercontent.com/kevinw/GodotVisionExample/main/docs/screenshot1.jpg)

## What is this?

A big hack!

[SwiftGodot](https://github.com/migueldeicaza/SwiftGodot)'s Godot-as-a-library, recompiled for visionOS. Godot thinks it is a headless iOS template release build, and we add an extra ability--to tick the Godot loop from the outside world. Then we intersperse the RealityKit main loop and the Godot main loop, and watch the Godot SceneTree for Node3Ds, and mirror meshes, textures, and sounds to the RealityKit world.

Check out the amazing [SwiftGodot](https://migueldeicaza.github.io/SwiftGodotDocs/documentation/swiftgodot/) documentation for how to hack on SwiftGodot/this project.

## Limitations

* Missing:
    * Documentation
    * Skinned meshes ([Skeleton3D](https://docs.godotengine.org/en/stable/classes/class_skeleton3d.html))
    * Shaders
    * Particle systems
    * Many PBR material options
* Lots of unpicked low hanging performance fruit on the tree:
    * Some modifications to Godot proper reserving us a bit somewhere for "node position/rotation/scale" changed might mean that static objects have almost no performance cost.
* Any native GDExtensions you want to use (godot-jolt, etc.) need to be compiled for visionOS.

## Roadmap

### To fix

* Pinch and drag should look more like the normal Godot input event flow; currently we manually look for `drag` and `drag_ended` signals. See the "hello" example.
* The logic for converting RealityKit gesture locations into Godot Vector3 world positions is a bit off, and may be very off if the "volume camera" moves
* Print statements appear twice in the Xcode console
* By default, scale should be 1 meter in Godot equals 1 meter in RealityKit
* Cleanup / document the notion of scale
* Document the [minor changes we made to Godot's ios backend](https://github.com/multijam/godot)
* The application view lifecycle is probably wrong. We throw away all state for SwiftUI .didDisappear.

### To add

* Live reload of Godot scene if saved from the editor 🤩
    * HTTP server serving the PCK file? Or simply the directory? Investigate how easy it would be to add (or use an existing) network layer to the Godot filesystem stuff.
* ~~Audio sound effects via AudioStreamPlayer3D~~
* Undo ugly InterThread/locking stuff now that we’re running on the main thread
* A nice way to substitute RealityKit authored stuff for Godot nodes; i.e., maybe you have a particle system you want to use based on some flag/layer/node name, etc.
* More (prettier!) example scenes!
* Skinned meshes
* Use SwiftUI attachments in Godot scene?
* Loading scenes from within Godot should work seamlessly
* Support updating Godot project for released apps without an app store review cycle
* Find a way to use the .godot compressed and imported textures/assets directly from builds, so that we don’t have to include what is essentially two copies of all assets.
* Possibly use Godot’s CompressedTexture2D directly to load textures, etc.

### Long term

* Use the upcoming Godot Metal port and share textures/buffers directly when possible. Find out what kinds of shader translation are "easy" in this shiny new Metal world
* A build system so you can make a super thin version of Godot without any of the modules you don't need, shrinking the final binary size.
