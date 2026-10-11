//! SPIR-V in, WGSL out, for NucleantVulkan's Vulkan-on-WebGPU stand-in.
//!
//! On wasm, `vkCreateGraphicsPipelines` / `vkCreateComputePipelines` hand the
//! JS bridge the same SPIR-V a Vulkan driver would get; browsers only take
//! WGSL, so the bridge runs it through here first. Besides translating, this
//! rewrites the three things Vulkan has and WebGPU does not, so the pipeline
//! behaves the way it would on a Vulkan driver:
//!
//! * Combined image samplers become a texture + a sampler binding
//!   (`split_combined`).
//! * Push constants (`AddressSpace::Immediate`) become a read-only storage
//!   buffer at `@group(draw_group) @binding(1)`. The host fills one slice of a
//!   per-submit buffer per draw/dispatch and binds it with a dynamic offset —
//!   what `vkCmdPushConstants` does per draw.
//! * Vulkan lets a viewport extend past the framebuffer; WebGPU requires it
//!   inside. A vertex entry point gets its clip-space position remapped by a
//!   per-draw `vec4<f32>` at `@group(draw_group) @binding(0)`, so the host can
//!   set the viewport clamped to the target and still have every vertex land
//!   where the unclamped Vulkan viewport would have put it.
//!
//! Calling convention matches the rest of the bridge: the host allocates with
//! `nv_alloc`, calls `nv_translate`, reads the result through
//! `nv_result_ptr` / `nv_result_len`, then frees it. The result is JSON:
//! `{"wgsl": "...", "entryPoint": "...", "bindings": [...], "drawData": {...}}`
//! on success, the error text on failure.

use naga::back::wgsl;
use naga::front::spv;
use naga::valid::{Capabilities, GlobalUse, ValidationFlags, Validator};
use naga::{
    AddressSpace, BinaryOperator, Binding, BuiltIn, Expression, ImageClass, ImageDimension, Module,
    ResourceBinding, ScalarKind, ShaderStage, Span, Statement, StorageAccess, StorageFormat, TypeInner,
};
use std::alloc::{alloc, dealloc, Layout};
use std::fmt::Write as _;

mod split_combined;

static mut RESULT: Vec<u8> = Vec::new();

fn store(bytes: Vec<u8>) {
    // Single-threaded wasm: only ever touched from the host's calls, one at a time.
    unsafe { RESULT = bytes };
}

/// Binding of the per-draw viewport remap inside the draw-data group.
const VIEWPORT_FIX_BINDING: u32 = 0;
/// Binding of the emulated push constants inside the draw-data group.
const PUSH_CONSTANT_BINDING: u32 = 1;

fn stage_from(code: u32) -> Result<ShaderStage, String> {
    match code {
        0 => Ok(ShaderStage::Vertex),
        1 => Ok(ShaderStage::Fragment),
        2 => Ok(ShaderStage::Compute),
        _ => Err(format!("unknown stage {code}")),
    }
}

fn stage_name(stage: ShaderStage) -> &'static str {
    match stage {
        ShaderStage::Vertex => "vertex",
        ShaderStage::Fragment => "fragment",
        ShaderStage::Compute => "compute",
        _ => "other",
    }
}

fn convert(words: &[u32], stage: ShaderStage, entry: &str, draw_group: u32) -> Result<String, String> {
    let words = split_combined::split(words)?;
    let options = spv::Options {
        // Vulkan clip space has y pointing down, WebGPU's points up; naga
        // flips gl_Position.y on the way out of every vertex entry point.
        adjust_coordinate_space: true,
        strict_capabilities: false,
        ..Default::default()
    };
    let bytes: Vec<u8> = words.iter().flat_map(|w| w.to_le_bytes()).collect();
    let mut module = spv::parse_u8_slice(&bytes, &options).map_err(|e| format!("spirv: {e}"))?;

    // Keep only the entry point the pipeline stage asked for — what Vulkan's
    // `pName` selects. Other entry points could carry names that collide in
    // WGSL, and their resources would leak into the reflection.
    let index = module
        .entry_points
        .iter()
        .position(|ep| ep.stage == stage && ep.name == entry)
        .ok_or_else(|| format!("no {} entry point named `{entry}`", stage_name(stage)))?;
    let ep = module.entry_points.swap_remove(index);
    module.entry_points.clear();
    module.entry_points.push(ep);

    let push_constant = lower_push_constants(&mut module, draw_group)?;
    let viewport_fix = if stage == ShaderStage::Vertex { add_viewport_fix(&mut module, draw_group)? } else { false };

    let info = Validator::new(ValidationFlags::all(), Capabilities::all())
        .validate(&module)
        .map_err(|e| format!("validation: {}", e.emit_to_string("")))?;
    let text = wgsl::write_string(&module, &info, wgsl::WriterFlags::empty()).map_err(|e| format!("wgsl: {e}"))?;

    let mut json = String::new();
    json.push_str("{\"wgsl\":");
    push_json_string(&mut json, &text);
    json.push_str(",\"entryPoint\":");
    push_json_string(&mut json, &module.entry_points[0].name);
    json.push_str(",\"stage\":");
    push_json_string(&mut json, stage_name(stage));
    if stage == ShaderStage::Compute {
        let size = module.entry_points[0].workgroup_size;
        let _ = write!(json, ",\"workgroupSize\":[{},{},{}]", size[0], size[1], size[2]);
    }
    json.push_str(",\"bindings\":[");
    let uses = info.get_entry_point(0);
    let mut first = true;
    for (handle, global) in module.global_variables.iter() {
        let Some(ResourceBinding { group, binding }) = global.binding else { continue };
        if uses[handle].is_empty() {
            continue;
        }
        if !first {
            json.push(',');
        }
        first = false;
        let _ = write!(json, "{{\"group\":{group},\"binding\":{binding},");
        json.push_str(&describe(&module, global.space, global.ty, uses[handle])?);
        json.push('}');
    }
    json.push(']');
    let _ = write!(
        json,
        ",\"drawData\":{{\"group\":{draw_group},\"viewportFix\":{viewport_fix},\"pushConstantSize\":{push_constant}}}}}"
    );
    Ok(json)
}

/// The WebGPU bind group layout entry for one resource, as JSON members.
fn describe(module: &Module, space: AddressSpace, ty: naga::Handle<naga::Type>, used: GlobalUse) -> Result<String, String> {
    match space {
        AddressSpace::Uniform => Ok("\"kind\":\"buffer\",\"type\":\"uniform\"".into()),
        AddressSpace::Storage { access } => {
            // WebGPU forbids writable storage in the vertex stage; naga
            // reports STORE only where the shader really writes.
            let writes = access.contains(StorageAccess::STORE) && used.contains(GlobalUse::WRITE);
            Ok(format!("\"kind\":\"buffer\",\"type\":\"{}\"", if writes { "storage" } else { "read-only-storage" }))
        }
        AddressSpace::Handle => match module.types[ty].inner {
            TypeInner::Sampler { comparison } => {
                Ok(format!("\"kind\":\"sampler\",\"type\":\"{}\"", if comparison { "comparison" } else { "filtering" }))
            }
            TypeInner::Image { dim, arrayed, class } => {
                let view = view_dimension(dim, arrayed);
                match class {
                    ImageClass::Sampled { kind, multi } => {
                        let sample_type = match kind {
                            ScalarKind::Sint => "sint",
                            ScalarKind::Uint => "uint",
                            _ => "float",
                        };
                        Ok(format!(
                            "\"kind\":\"texture\",\"sampleType\":\"{sample_type}\",\"viewDimension\":\"{view}\",\"multisampled\":{multi}"
                        ))
                    }
                    ImageClass::Depth { multi } => Ok(format!(
                        "\"kind\":\"texture\",\"sampleType\":\"depth\",\"viewDimension\":\"{view}\",\"multisampled\":{multi}"
                    )),
                    ImageClass::Storage { format, access } => {
                        let mode = if access.contains(StorageAccess::LOAD | StorageAccess::STORE) {
                            "read-write"
                        } else if access.contains(StorageAccess::STORE) {
                            "write-only"
                        } else {
                            "read-only"
                        };
                        Ok(format!(
                            "\"kind\":\"storageTexture\",\"format\":\"{}\",\"access\":\"{mode}\",\"viewDimension\":\"{view}\"",
                            storage_format(format)?
                        ))
                    }
                    ImageClass::External => Err("external textures have no Vulkan equivalent".into()),
                }
            }
            _ => Err("unsupported handle type".into()),
        },
        _ => Err("unsupported resource address space".into()),
    }
}

fn view_dimension(dim: ImageDimension, arrayed: bool) -> &'static str {
    match (dim, arrayed) {
        (ImageDimension::D1, _) => "1d",
        (ImageDimension::D2, false) => "2d",
        (ImageDimension::D2, true) => "2d-array",
        (ImageDimension::D3, _) => "3d",
        (ImageDimension::Cube, false) => "cube",
        (ImageDimension::Cube, true) => "cube-array",
    }
}

fn storage_format(format: StorageFormat) -> Result<&'static str, String> {
    Ok(match format {
        StorageFormat::R8Unorm => "r8unorm",
        StorageFormat::R8Snorm => "r8snorm",
        StorageFormat::R8Uint => "r8uint",
        StorageFormat::R8Sint => "r8sint",
        StorageFormat::R16Uint => "r16uint",
        StorageFormat::R16Sint => "r16sint",
        StorageFormat::R16Float => "r16float",
        StorageFormat::Rg8Unorm => "rg8unorm",
        StorageFormat::Rg8Snorm => "rg8snorm",
        StorageFormat::Rg8Uint => "rg8uint",
        StorageFormat::Rg8Sint => "rg8sint",
        StorageFormat::R32Uint => "r32uint",
        StorageFormat::R32Sint => "r32sint",
        StorageFormat::R32Float => "r32float",
        StorageFormat::Rg16Uint => "rg16uint",
        StorageFormat::Rg16Sint => "rg16sint",
        StorageFormat::Rg16Float => "rg16float",
        StorageFormat::Rgba8Unorm => "rgba8unorm",
        StorageFormat::Rgba8Snorm => "rgba8snorm",
        StorageFormat::Rgba8Uint => "rgba8uint",
        StorageFormat::Rgba8Sint => "rgba8sint",
        StorageFormat::Bgra8Unorm => "bgra8unorm",
        StorageFormat::Rgb10a2Uint => "rgb10a2uint",
        StorageFormat::Rgb10a2Unorm => "rgb10a2unorm",
        StorageFormat::Rg11b10Ufloat => "rg11b10ufloat",
        StorageFormat::Rg32Uint => "rg32uint",
        StorageFormat::Rg32Sint => "rg32sint",
        StorageFormat::Rg32Float => "rg32float",
        StorageFormat::Rgba16Uint => "rgba16uint",
        StorageFormat::Rgba16Sint => "rgba16sint",
        StorageFormat::Rgba16Float => "rgba16float",
        StorageFormat::Rgba32Uint => "rgba32uint",
        StorageFormat::Rgba32Sint => "rgba32sint",
        StorageFormat::Rgba32Float => "rgba32float",
        other => return Err(format!("storage format {other:?} has no WebGPU equivalent")),
    })
}

/// Moves the push-constant block into a read-only storage buffer of the
/// draw-data group. Returns its size in bytes (0 when the shader has none).
fn lower_push_constants(module: &mut Module, draw_group: u32) -> Result<u32, String> {
    let mut size = 0;
    let mut layouter = naga::proc::Layouter::default();
    layouter.update(module.to_ctx()).map_err(|e| format!("layout: {e}"))?;
    for (_, global) in module.global_variables.iter_mut() {
        if global.space != AddressSpace::Immediate {
            continue;
        }
        size = layouter[global.ty].size;
        global.space = AddressSpace::Storage { access: StorageAccess::LOAD };
        global.binding = Some(ResourceBinding { group: draw_group, binding: PUSH_CONSTANT_BINDING });
    }
    Ok(size)
}

/// Remaps the vertex entry point's returned clip-space position by the
/// per-draw `vec4<f32>(sx, sy, ox, oy)`: `pos.xy = pos.xy * s + o * pos.w`.
/// Identity is `(1, 1, 0, 0)`. Returns false when the entry point writes no
/// position (nothing to remap).
fn add_viewport_fix(module: &mut Module, draw_group: u32) -> Result<bool, String> {
    let function = &module.entry_points[0].function;
    let Some(result) = function.result.as_ref() else { return Ok(false) };

    // Where the position sits in what the entry point returns: the result
    // itself, or one member of the result struct.
    let member_index: Option<u32> = match result.binding {
        Some(Binding::BuiltIn(BuiltIn::Position { .. })) => None,
        _ => match module.types[result.ty].inner {
            TypeInner::Struct { ref members, .. } => {
                match members
                    .iter()
                    .position(|m| matches!(m.binding, Some(Binding::BuiltIn(BuiltIn::Position { .. }))))
                {
                    Some(i) => Some(i as u32),
                    None => return Ok(false),
                }
            }
            _ => return Ok(false),
        },
    };
    let position_ty = match member_index {
        None => result.ty,
        Some(i) => match module.types[result.ty].inner {
            TypeInner::Struct { ref members, .. } => members[i as usize].ty,
            _ => unreachable!(),
        },
    };
    let result_ty = result.ty;

    let fix_global = module.global_variables.append(
        naga::GlobalVariable {
            name: Some("nucleant_viewport_fix".into()),
            space: AddressSpace::Storage { access: StorageAccess::LOAD },
            binding: Some(ResourceBinding { group: draw_group, binding: VIEWPORT_FIX_BINDING }),
            ty: position_ty,
            init: None,
            memory_decorations: Default::default(),
        },
        Span::UNDEFINED,
    );

    let function = &mut module.entry_points[0].function;
    let last = function.body.len().checked_sub(1).ok_or("empty vertex entry point")?;
    let Statement::Return { value: Some(returned) } = function.body[last] else {
        return Err("vertex entry point does not end in a return".into());
    };
    function.body.cull(last..);

    let span = Span::UNDEFINED;
    let ex = &mut function.expressions;
    let fix_ptr = ex.append(Expression::GlobalVariable(fix_global), span);
    let mut emitter = naga::proc::Emitter::default();
    emitter.start(ex);
    let fix = ex.append(Expression::Load { pointer: fix_ptr }, span);
    let position = match member_index {
        None => returned,
        Some(i) => ex.append(Expression::AccessIndex { base: returned, index: i }, span),
    };
    let component = |ex: &mut naga::Arena<Expression>, base, index| ex.append(Expression::AccessIndex { base, index }, span);
    let (px, py, pz, pw) = (component(ex, position, 0), component(ex, position, 1), component(ex, position, 2), component(ex, position, 3));
    let (sx, sy, ox, oy) = (component(ex, fix, 0), component(ex, fix, 1), component(ex, fix, 2), component(ex, fix, 3));
    let remap = |ex: &mut naga::Arena<Expression>, p, s, o| {
        let scaled = ex.append(Expression::Binary { op: BinaryOperator::Multiply, left: p, right: s }, span);
        let offset = ex.append(Expression::Binary { op: BinaryOperator::Multiply, left: o, right: pw }, span);
        ex.append(Expression::Binary { op: BinaryOperator::Add, left: scaled, right: offset }, span)
    };
    let nx = remap(ex, px, sx, ox);
    let ny = remap(ex, py, sy, oy);
    let fixed = ex.append(Expression::Compose { ty: position_ty, components: vec![nx, ny, pz, pw] }, span);
    let new_result = match member_index {
        None => fixed,
        Some(i) => {
            let count = match module.types[result_ty].inner {
                TypeInner::Struct { ref members, .. } => members.len() as u32,
                _ => unreachable!(),
            };
            let components = (0..count)
                .map(|m| if m == i { fixed } else { ex.append(Expression::AccessIndex { base: returned, index: m }, span) })
                .collect();
            ex.append(Expression::Compose { ty: result_ty, components }, span)
        }
    };
    function.body.extend(emitter.finish(&function.expressions));
    function.body.push(Statement::Return { value: Some(new_result) }, span);
    Ok(true)
}

fn push_json_string(out: &mut String, text: &str) {
    out.push('"');
    for c in text.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => {
                let _ = write!(out, "\\u{:04x}", c as u32);
            }
            c => out.push(c),
        }
    }
    out.push('"');
}

#[no_mangle]
pub extern "C" fn nv_alloc(size: u32) -> *mut u8 {
    if size == 0 {
        return std::ptr::null_mut();
    }
    unsafe { alloc(Layout::from_size_align_unchecked(size as usize, 4)) }
}

#[no_mangle]
pub extern "C" fn nv_dealloc(ptr: *mut u8, size: u32) {
    if !ptr.is_null() && size > 0 {
        unsafe { dealloc(ptr, Layout::from_size_align_unchecked(size as usize, 4)) }
    }
}

/// `words`/`word_count`: the SPIR-V module. `stage`: 0 vertex, 1 fragment,
/// 2 compute. `entry`: the entry point name (UTF-8). `draw_group`: the bind
/// group index for the emulated per-draw data — one past the pipeline
/// layout's last descriptor set. Returns 0 on success (result = JSON), 1 on
/// failure (result = error text).
#[no_mangle]
pub extern "C" fn nv_translate(
    words: *const u32,
    word_count: u32,
    stage: u32,
    entry: *const u8,
    entry_len: u32,
    draw_group: u32,
) -> i32 {
    let words = unsafe { std::slice::from_raw_parts(words, word_count as usize) };
    let entry = unsafe { std::slice::from_raw_parts(entry, entry_len as usize) };
    let result = std::str::from_utf8(entry)
        .map_err(|_| "entry point name is not UTF-8".to_string())
        .and_then(|entry| convert(words, stage_from(stage)?, entry, draw_group));
    match result {
        Ok(text) => {
            store(text.into_bytes());
            0
        }
        Err(text) => {
            store(text.into_bytes());
            1
        }
    }
}

#[no_mangle]
pub extern "C" fn nv_result_ptr() -> *const u8 {
    unsafe { (*std::ptr::addr_of!(RESULT)).as_ptr() }
}

#[no_mangle]
pub extern "C" fn nv_result_len() -> u32 {
    unsafe { (*std::ptr::addr_of!(RESULT)).len() as u32 }
}

#[no_mangle]
pub extern "C" fn nv_result_free() {
    store(Vec::new());
}
