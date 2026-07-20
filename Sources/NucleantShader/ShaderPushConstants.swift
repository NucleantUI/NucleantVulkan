//
//  ShaderPushConstants.swift
//  NucleantVulkan
//
//  Created by CodeBuilder on 20/07/2026.
//


// MARK: - Push Constants

public struct ShaderPushConstants {
    public var time: Float = 0
    public var _pad0: Float = 0
    public var resolutionX: Float = 0
    public var resolutionY: Float = 0
    public var mouseX: Float = 0
    public var mouseY: Float = 0
    
    public init() {}
    
    public init(time: Float, resolution: (Float, Float), mouse: (Float, Float) = (0, 0)) {
        self.time = time
        self.resolutionX = resolution.0
        self.resolutionY = resolution.1
        self.mouseX = mouse.0
        self.mouseY = mouse.1
    }
}