//
//  RenderNode.swift
//  PyNucleantUI
//

import VulkanCore
import CVulkan
import Observation

public protocol RenderContainerNode: AnyObject, Identifiable, Observable, Sendable {
    var id: Int { get }
    var context: Context { get }

    init(id: Int, context: Context)

    
    associatedtype Context: RenderNodeContext
    func observeContext()
    func observe<Node: VulkanRenderNode>(_ node: Node)
    
    var needsRender: Bool { get set }
    
    
    func update(engine: Engine, cmd: VkCommandBuffer)

    // recordComposite lives on the engine, not here: sampling a node's
    // published image onto the swapchain is identical for every node kind
    // (it only needs `getImageView()`), so it's engine-generic — see
    // VulkanRenderEngine.recordComposite(of:). Per-node work that actually
    // differs (canvas draw + layout barriers) is what `update` carries.

    func destroyResources(engine: Engine)
    
    func getImageView() -> VkImageView?
}

extension RenderContainerNode {
    
    public typealias Engine = VulkanRenderEngine<Self>
    /// Arm one observation over the node's render-affecting state. A
        /// registration fires exactly once, so `onChange` re-arms; `node` is
        /// captured weakly because the node's registrar holds this closure —
        /// a strong capture would be a self-retain-cycle on the node.
        public func observe<Node: VulkanRenderNode>(_ node: Node) {
            withObservationTracking { [weak node] in
                guard let node else { return }
                _ = node.dirty
                _ = node.computePipeline
                _ = node.computeLayout
                _ = node.computeDescriptorSet
            } onChange: { [weak self, weak node] in
                guard let self = self, let node else { return }
                self.needsRender = true
                self.observe(node)
            }
        }

    static func new(id: Int, context: Context) -> Self {
        let new = Self.init(id: id, context: context)
        new.observeContext()
        return new
    }

}

public protocol RenderNodeContext {
    
}


// MARK: - Node type

// public struct RenderNode {
// ^ promoted to a class: the slot carries mutable engine-facing state
//   (`needsRender`) fed by Observation tracking, which a value copy would
//   silently fork.

/// One composite slot in the engine's `nodes` list. `id` is the stable
/// identity shared with the canvas side (the owning `PyCanvasBase.id`,
/// a `UUID().hashValue`) — every engine-internal map (descriptor sets,
/// readable state, warn-once markers) is keyed by it.
///
/// The slot watches its shader node through the Observation framework:
/// canvas code mutates its own node (`dirty`, compute pipeline swap) and
/// `needsRender` flips here, so neither the canvas nor the shader node
/// ever needs a reference back to the slot or the engine's list.
// public final class __RenderNode {
//     public let id: Int

//     public let context: Context

//     /// Consumed by the engine: checked at the top of the per-frame node
//     /// update and cleared after a successful draw. Starts `true` so a
//     /// fresh slot renders its first frame unprompted.
//     var needsRender: Bool = true

//     init(id: Int, context: Context) {
//         self.id = id
//         self.context = context
//         observeContext()
//     }

//     private func observeContext() {
//         switch context {
//         case .thor(let node):
//             observe(node)
//         case .skia(let node):
//             observe(node)
//         case .shader(let node):
//             observe(node)
//         case .pixel_buffer(let node):
//             observe(node)
//         case .group, .texture_group:
//             // No observable payload of their own — a group's children are
//             // RenderNodes tracking themselves, and texture groups aren't
//             // driven by anything yet.
//             break
//         }
//     }

//     /// Arm one observation over the node's render-affecting state. A
//     /// registration fires exactly once, so `onChange` re-arms; `node` is
//     /// captured weakly because the node's registrar holds this closure —
//     /// a strong capture would be a self-retain-cycle on the node.
//     private func observe<Node: VulkanRenderNode & Observable>(_ node: Node) {
//         withObservationTracking { [weak node] in
//             guard let node else { return }
//             _ = node.dirty
//             _ = node.computePipeline
//             _ = node.computeLayout
//             _ = node.computeDescriptorSet
//         } onChange: { [weak self, weak node] in
//             guard let self, let node else { return }
//             self.needsRender = true
//             self.observe(node)
//         }
//     }
// }
