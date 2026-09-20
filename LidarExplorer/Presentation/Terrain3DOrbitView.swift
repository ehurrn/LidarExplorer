//
//  Terrain3DOrbitView.swift
//  LidarExplorer
//
//  A 3D view of the ground under the map: the viewport's terrain as a metric mesh, draped with the same shaded
//  image the map shows, with orbit, zoom and vertical exaggeration.
//

#if canImport(SceneKit) && canImport(UIKit)
import SceneKit
import SwiftUI
import UIKit

public struct Terrain3DOrbitView: View {

    let scene: Terrain3DScene
    @Environment(\.dismiss) private var dismiss
    @State private var exaggeration: Float = 2
    @State private var resetToken = 0

    public init(scene: Terrain3DScene) {
        self.scene = scene
    }

    public var body: some View {
        ZStack(alignment: .bottom) {
            TerrainSceneView(scene: scene, exaggeration: exaggeration, resetToken: resetToken)
                .ignoresSafeArea()

            VStack(spacing: 10) {
                HStack {
                    Image(systemName: "arrow.up.and.down")
                    Slider(value: $exaggeration, in: 1...10, step: 0.5)
                    Text("\(exaggeration, specifier: "%.1f")x")
                        .font(.callout.monospacedDigit())
                        .frame(width: 44, alignment: .trailing)
                }
                HStack {
                    Button {
                        resetToken += 1
                    } label: {
                        Label("Reset view", systemImage: "arrow.counterclockwise")
                    }
                    Spacer()
                    Button("Done") { dismiss() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(16)
        }
    }
}

private struct TerrainSceneView: UIViewRepresentable {

    let scene: Terrain3DScene
    let exaggeration: Float
    let resetToken: Int

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = UIColor(white: 0.08, alpha: 1)
        view.antialiasingMode = .multisampling4X
        view.autoenablesDefaultLighting = false
        let coordinator = context.coordinator
        view.scene = coordinator.buildScene(from: scene)
        view.pointOfView = coordinator.cameraNode

        let orbit = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.orbit(_:)))
        let zoom = UIPinchGestureRecognizer(target: coordinator, action: #selector(Coordinator.zoom(_:)))
        let reset = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.reset))
        reset.numberOfTapsRequired = 2
        [orbit, zoom, reset].forEach(view.addGestureRecognizer)
        coordinator.applyCamera()
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        let coordinator = context.coordinator
        // Scaling the node stretches the relief without rebuilding the mesh; SceneKit lights it with the
        // matching normal matrix.
        coordinator.terrainNode?.scale = SCNVector3(1, exaggeration, 1)
        if coordinator.lastResetToken != resetToken {
            coordinator.lastResetToken = resetToken
            coordinator.reset()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject {
        let cameraNode = SCNNode()
        var terrainNode: SCNNode?
        var lastResetToken = 0

        private var azimuth: Float = .pi / 4
        private var elevation: Float = 0.6
        private var distance: Float = 200
        private var defaultDistance: Float = 200
        private var focus = SCNVector3Zero

        func buildScene(from data: Terrain3DScene) -> SCNScene {
            let mesh = data.mesh
            let scene = SCNScene()

            let positions = SCNGeometrySource(vertices: mesh.positions.map { SCNVector3($0.x, $0.y, $0.z) })
            let normals = SCNGeometrySource(normals: mesh.normals.map { SCNVector3($0.x, $0.y, $0.z) })
            let uvs = SCNGeometrySource(textureCoordinates: mesh.uvs.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) })
            let element = SCNGeometryElement(indices: mesh.indices, primitiveType: .triangles)
            let geometry = SCNGeometry(sources: [positions, normals, uvs], elements: [element])

            let material = SCNMaterial()
            material.lightingModel = .lambert
            material.isDoubleSided = true
            if let texture = data.texture {
                material.diffuse.contents = texture
                // The mesh's v runs north to south, as the image's rows do; SceneKit's origin is the other corner.
                material.diffuse.contentsTransform = SCNMatrix4MakeScale(1, -1, 1)
                material.diffuse.wrapT = .repeat
            } else {
                material.diffuse.contents = UIColor(white: 0.7, alpha: 1)
            }
            geometry.materials = [material]
            let node = SCNNode(geometry: geometry)
            scene.rootNode.addChildNode(node)
            terrainNode = node

            let sun = SCNNode()
            sun.light = SCNLight()
            sun.light?.type = .directional
            sun.light?.intensity = 900
            sun.eulerAngles = SCNVector3(-Float.pi / 3, Float.pi / 4, 0)
            scene.rootNode.addChildNode(sun)
            let ambient = SCNNode()
            ambient.light = SCNLight()
            ambient.light?.type = .ambient
            ambient.light?.intensity = 350
            scene.rootNode.addChildNode(ambient)

            let camera = SCNCamera()
            camera.zNear = 0.5
            camera.zFar = 100_000
            camera.fieldOfView = 45
            cameraNode.camera = camera
            scene.rootNode.addChildNode(cameraNode)

            let extent = max(mesh.bounds.maximum.x - mesh.bounds.minimum.x, mesh.bounds.maximum.z - mesh.bounds.minimum.z, 1)
            defaultDistance = extent * 1.4
            distance = defaultDistance
            focus = SCNVector3(0, (mesh.bounds.maximum.y) / 4, 0)
            return scene
        }

        func applyCamera() {
            let horizontal = distance * cos(elevation)
            cameraNode.position = SCNVector3(
                focus.x + horizontal * sin(azimuth), focus.y + distance * sin(elevation), focus.z + horizontal * cos(azimuth))
            cameraNode.look(at: focus)
        }

        @objc func orbit(_ recognizer: UIPanGestureRecognizer) {
            let delta = recognizer.translation(in: recognizer.view)
            recognizer.setTranslation(.zero, in: recognizer.view)
            azimuth -= Float(delta.x) * 0.008
            elevation = min(max(elevation + Float(delta.y) * 0.006, 0.08), 1.5)
            applyCamera()
        }

        @objc func zoom(_ recognizer: UIPinchGestureRecognizer) {
            distance = min(max(distance / Float(recognizer.scale), defaultDistance * 0.15), defaultDistance * 5)
            recognizer.scale = 1
            applyCamera()
        }

        @objc func reset() {
            azimuth = .pi / 4
            elevation = 0.6
            distance = defaultDistance
            applyCamera()
        }
    }
}
#endif
