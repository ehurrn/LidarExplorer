//
//  SceneKitTextureProbe.swift
//
//  Renders a two-colour texture on the mesh layout Terrain3DOrbitView uses (uv (0,0) at the north-west corner, v
//  running south) and reports which colour lands at the top of the screen, with and without a vertical flip of the
//  material's contents. It settled which is right: with no flip the image's top row (north) is at the top.
//
//  Run: xcrun swiftc -O Tools/SceneKitTextureProbe.swift -o /tmp/probe && /tmp/probe
//  macOS only (SceneKit's texture-coordinate convention is shared with iOS, but this was not run on iOS).
//

import AppKit
import Metal
import SceneKit

/// Top two rows red, bottom two green: what an image of the ground looks like with north (top) red.
func makeImage() -> CGImage {
    var pixels = [UInt8](repeating: 255, count: 4 * 4 * 4)
    for row in 0..<4 { for col in 0..<4 {
        let o = (row * 4 + col) * 4
        let red = row < 2
        pixels[o] = red ? 255 : 0; pixels[o + 1] = red ? 0 : 255; pixels[o + 2] = 0; pixels[o + 3] = 255
    } }
    return CGImage(width: 4, height: 4, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(),
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                   provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}

func render(flip: Bool) -> (top: String, bottom: String, left: String, right: String) {
    // The mesh the app builds: x east, z south, uv (0,0) at the north-west corner, v running south.
    let positions = [SCNVector3(-1, 0, -1), SCNVector3(1, 0, -1), SCNVector3(-1, 0, 1), SCNVector3(1, 0, 1)]
    let uvs = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1)]
    let normals = [SCNVector3](repeating: SCNVector3(0, 1, 0), count: 4)
    let indices: [UInt32] = [0, 2, 1, 1, 2, 3]
    let geometry = SCNGeometry(
        sources: [SCNGeometrySource(vertices: positions), SCNGeometrySource(normals: normals), SCNGeometrySource(textureCoordinates: uvs)],
        elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
    let material = SCNMaterial()
    material.lightingModel = .constant
    material.isDoubleSided = true
    material.diffuse.contents = makeImage()
    if flip {
        material.diffuse.contentsTransform = SCNMatrix4MakeScale(1, -1, 1)
        material.diffuse.wrapT = .repeat
    }
    geometry.materials = [material]
    let scene = SCNScene()
    scene.rootNode.addChildNode(SCNNode(geometry: geometry))
    let camera = SCNNode()
    camera.camera = SCNCamera()
    camera.camera?.usesOrthographicProjection = true
    camera.camera?.orthographicScale = 1.2
    camera.position = SCNVector3(0, 5, 0)
    camera.eulerAngles = SCNVector3(-Double.pi / 2, 0, 0)     // looking straight down, north (-z) at the top of the screen
    scene.rootNode.addChildNode(camera)

    let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
    renderer.scene = scene
    renderer.pointOfView = camera
    let size = CGSize(width: 200, height: 200)
    let image = renderer.snapshot(atTime: 0, with: size, antialiasingMode: .none)
    var rep: NSBitmapImageRep?
    if let tiff = image.tiffRepresentation { rep = NSBitmapImageRep(data: tiff) }
    func name(_ x: Int, _ y: Int) -> String {
        guard let c = rep?.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return "?" }
        let r = c.redComponent, g = c.greenComponent
        return r > 0.8 && g < 0.2 ? "RED" : (g > 0.8 && r < 0.2 ? "GREEN" : String(format: "(%.2f,%.2f)", r, g))
    }
    // NSBitmapImageRep counts y from the top.
    return (name(100, 60), name(100, 140), name(60, 100), name(140, 100))
}

let plain = render(flip: false)
let flipped = render(flip: true)
print("north (top red image row) should be at the TOP of the screen")
print("no flip:   top=\(plain.top) bottom=\(plain.bottom)")
print("with flip: top=\(flipped.top) bottom=\(flipped.bottom)   <- what Terrain3DOrbitView does")
