# GodotVision

Godot headless on visionOS, rendered with RealityKit, so you can create shared-space visionOS experiences from Godot.

### Questions? Join the [GodotVision Discord](https://discord.gg/XvB4dwGUtF)

### Documentation 

Documentation lives at the website — [https://godot.vision](https://godot.vision)

### Example Repo

See [GodotVisionExample](https://github.com/kevinw/GodotVisionExample) for a simple repository you can clone and run in Xcode.

![example image](https://raw.githubusercontent.com/kevinw/GodotVisionExample/main/docs/screenshot1.jpg)

## What is this?

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
    * Shaders
    * Particle systems
    * Many PBR material options
* Any native GDExtensions you want to use need to be compiled for visionOS.
