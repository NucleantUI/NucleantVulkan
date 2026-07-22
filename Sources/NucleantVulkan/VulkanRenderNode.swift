//
//  VulkanRenderNode.swift
//
import CVulkan
import Observation

public protocol VulkanRenderNode: AnyObject, Observable, Sendable {
    // var computePipeline:      VkPipeline?       { get }
    // var computeLayout:        VkPipelineLayout? { get }
    // var computeDescriptorSet: VkDescriptorSet?  { get }
    // ^ the compute trio became { get set } and width/height/storageCapable
    //   joined the protocol: CanvasShader installs a post pipeline through
    //   this protocol now, so it works on every node kind (thor, shader,
    //   pixel_buffer) instead of being hardwired to ThorShaderNode.
    var width:                UInt32            { get }
    var height:               UInt32            { get }
    var image:                VkImage           { get }
    var imageView:            VkImageView       { get }
    var storageCapable:       Bool              { get }
    var computePipeline:      VkPipeline?       { get set }
    var computeLayout:        VkPipelineLayout? { get set }
    var computeDescriptorSet: VkDescriptorSet?  { get set }
    var dirty:                Bool              { get set }
    
    associatedtype ContainerNode: RenderContainerNode
    associatedtype Engine: VulkanRenderEngine<ContainerNode>
    
    func update(_ engine: Engine, slot: ContainerNode, cmd: VkCommandBuffer)
}
