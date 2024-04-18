# GodotVision

### Questions? Join the [GodotVision Discord](https://discord.gg/XvB4dwGUtF)

Godot headless on visionOS, rendered with RealityKit, so you can create shared-space visionOS experiences from Godot.

See [GodotVisionExample](https://github.com/kevinw/GodotVisionExample) for a simple repository you can clone and run in Xcode.

![example image](https://raw.githubusercontent.com/kevinw/GodotVisionExample/main/docs/screenshot1.jpg)

## What is this?

A big hack!

[SwiftGodotKit](https://github.com/migueldeicaza/SwiftGodotKit)'s Godot-as-a-library, compiled for visionOS. Godot ([slightly modified](https://github.com/multijam/godot/commits/visionos/?author=kevinw)) thinks it is a headless iOS template release build, and we add an extra ability--to tick the Godot loop from the "outside" host process. Then we intersperse the RealityKit main loop and the Godot main loop, and watch the Godot SceneTree for Node3Ds, and mirror meshes, textures, and sounds to the RealityKit world.

Check out the amazing [SwiftGodot](https://migueldeicaza.github.io/SwiftGodotDocs/documentation/swiftgodot/) documentation for how to hack on SwiftGodot/this project.


# Setup
Steps to add GodotVision to an existing VisionOS XCode project:

## Import Godot_Project
1. Copy Godot_Project folder from this repo to your target repo

## Add GodotVision Package dependency
1. Open App Settings by clicking on the App in the Navigator
1. Choose your Target from the target list
1. General -> Frameworks -> `+` -> "Add Other..." -> "Add Package Dependency..."
1. In "Search or Enter Package URL": Enter `https://github.com/kevinw/GodotVision.git` (Make sure to add `.git`)
1. "Add Package"

## Change Swift Compiler Language
1. Stay on the Target subpanel
1. Build Settings
1. "All" to open edit all options
1. Under "Swift Compiler - Language", change "Swift Compiler - Language" to "C++ / Objective-C++"

## Build
1. Product -> Build

## Limitations

* Missing:
    * Documentation
    * Shaders
    * Particle systems
    * Many PBR material options
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
* ~~Undo ugly InterThread/locking stuff now that we’re running on the main thread~~
* A nice way to substitute RealityKit authored stuff for Godot nodes; i.e., maybe you have a particle system you want to use based on some flag/layer/node name, etc.
* More (prettier!) example scenes!
* Map MultiMeshInstance3D to instanced RealityKit entities?
* ~~Skinned meshes~~
* Use SwiftUI attachments in Godot scene?
* Loading scenes from within Godot should work seamlessly
* Support updating Godot project for released apps without an app store review cycle
* Find a way to use the .godot compressed and imported textures/assets directly from builds, so that we don’t have to include what is essentially two copies of all assets.
* Possibly use Godot’s CompressedTexture2D directly to load textures, etc.

### Long term

* Use the upcoming Godot Metal port and share textures/buffers directly when possible. Find out what kinds of shader translation are "easy" in this shiny new Metal world
* A build system so you can make a super thin version of Godot without any of the modules you don't need, shrinking the final binary size.
* ~~Investigate creating a [Godot "server"](https://docs.godotengine.org/en/stable/tutorials/performance/using_servers.html) so we could do one per-frame memcopy for position/rotation/translation of Nodes which have moved.~~ (A version of this is implemented via a new [SceneTree signal](https://github.com/multijam/godot/commit/f09eb5198f52c3503eda82fc2986ab0e36a4ad17))

