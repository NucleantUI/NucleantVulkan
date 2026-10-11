//! Vulkan's `COMBINED_IMAGE_SAMPLER` is one descriptor; WebGPU has no such
//! thing — a texture and a sampler are separate bindings. glslang (and
//! PyShader) express it as a *global* of `OpTypeSampledImage`, which naga's
//! SPIR-V frontend does not read: it understands `OpSampledImage` made inside
//! a function from a separate image and sampler.
//!
//! This pass rewrites each such global into an image variable plus a sampler
//! variable, and every `OpLoad` of it into two loads and an `OpSampledImage`.
//! The image keeps the original (set, binding); the sampler goes into the
//! same set at `binding + SAMPLER_BINDING_OFFSET`. The host builds its
//! WebGPU bind group layouts from the reflection, so a descriptor written at
//! binding `b` fills both `b` (texture view) and `b + SAMPLER_BINDING_OFFSET`
//! (sampler) — the one Vulkan descriptor becomes the two WebGPU entries it
//! always was underneath.

use std::collections::HashMap;

/// WebGPU binding numbers stay below `maxBindingsPerBindGroup` (1000 by
/// default), so a combined sampler's own binding may be at most 487.
pub const SAMPLER_BINDING_OFFSET: u32 = 512;

const OP_DECORATE: u16 = 71;
const OP_TYPE_SAMPLER: u16 = 26;
const OP_TYPE_SAMPLED_IMAGE: u16 = 27;
const OP_TYPE_POINTER: u16 = 32;
const OP_VARIABLE: u16 = 59;
const OP_LOAD: u16 = 61;
const OP_SAMPLED_IMAGE: u16 = 86;
const STORAGE_UNIFORM_CONSTANT: u32 = 0;
const DECORATION_BINDING: u32 = 33;
const DECORATION_DESCRIPTOR_SET: u32 = 34;

struct Inst {
    op: u16,
    /// Operands after the opcode word, result ids included.
    words: Vec<u32>,
}

impl Inst {
    fn encode(&self, out: &mut Vec<u32>) {
        out.push(((self.words.len() as u32 + 1) << 16) | self.op as u32);
        out.extend_from_slice(&self.words);
    }
}

fn parse(words: &[u32]) -> Result<Vec<Inst>, String> {
    let mut insts = Vec::new();
    let mut i = 0;
    while i < words.len() {
        let count = (words[i] >> 16) as usize;
        if count == 0 || i + count > words.len() {
            return Err("truncated SPIR-V instruction".into());
        }
        insts.push(Inst { op: (words[i] & 0xffff) as u16, words: words[i + 1..i + count].to_vec() });
        i += count;
    }
    Ok(insts)
}

/// `words` with every combined image-sampler global split in two. Returns the
/// input unchanged when the module has none.
pub fn split(words: &[u32]) -> Result<Vec<u32>, String> {
    if words.len() < 5 || words[0] != 0x0723_0203 {
        return Err("not a little-endian SPIR-V module".into());
    }
    let mut bound = words[3];
    let body = parse(&words[5..])?;

    // sampled-image type id -> image type id
    let sampled_types: HashMap<u32, u32> = body
        .iter()
        .filter(|i| i.op == OP_TYPE_SAMPLED_IMAGE)
        .map(|i| (i.words[0], i.words[1]))
        .collect();
    // UniformConstant pointer type id -> sampled-image type id
    let sampled_pointers: HashMap<u32, u32> = body
        .iter()
        .filter(|i| {
            i.op == OP_TYPE_POINTER
                && i.words[1] == STORAGE_UNIFORM_CONSTANT
                && sampled_types.contains_key(&i.words[2])
        })
        .map(|i| (i.words[0], i.words[2]))
        .collect();
    // variable id -> sampled-image type id
    let sampled_vars: HashMap<u32, u32> = body
        .iter()
        .filter(|i| i.op == OP_VARIABLE && sampled_pointers.contains_key(&i.words[0]))
        .map(|i| (i.words[1], sampled_pointers[&i.words[0]]))
        .collect();
    if sampled_vars.is_empty() {
        return Ok(words.to_vec());
    }

    let mut fresh = || {
        let id = bound;
        bound += 1;
        id
    };
    let sampler_type = fresh();
    let sampler_ptr = fresh();
    // image type id -> new UniformConstant pointer type to it
    let mut image_ptrs: HashMap<u32, u32> = HashMap::new();
    for &image_type in sampled_types.values() {
        image_ptrs.entry(image_type).or_insert_with(&mut fresh);
    }
    // variable id -> its new sampler variable id
    let sampler_vars: HashMap<u32, u32> = sampled_vars.keys().map(|&v| (v, fresh())).collect();

    let mut out: Vec<Inst> = Vec::with_capacity(body.len() + 16);
    let mut declared_image_ptrs: Vec<u32> = Vec::new();
    let mut types_declared = false;
    for inst in body {
        match inst.op {
            OP_DECORATE if sampler_vars.contains_key(&inst.words[0]) => {
                let sampler_var = sampler_vars[&inst.words[0]];
                match inst.words[1] {
                    DECORATION_BINDING => out.push(Inst {
                        op: OP_DECORATE,
                        words: vec![sampler_var, DECORATION_BINDING, inst.words[2] + SAMPLER_BINDING_OFFSET],
                    }),
                    DECORATION_DESCRIPTOR_SET => out.push(Inst {
                        op: OP_DECORATE,
                        words: vec![sampler_var, DECORATION_DESCRIPTOR_SET, inst.words[2]],
                    }),
                    _ => {}
                }
                out.push(inst);
            }
            OP_TYPE_SAMPLED_IMAGE => {
                out.push(inst);
                if !types_declared {
                    out.push(Inst { op: OP_TYPE_SAMPLER, words: vec![sampler_type] });
                    out.push(Inst {
                        op: OP_TYPE_POINTER,
                        words: vec![sampler_ptr, STORAGE_UNIFORM_CONSTANT, sampler_type],
                    });
                    types_declared = true;
                }
            }
            OP_TYPE_POINTER if sampled_pointers.contains_key(&inst.words[0]) => {
                let image_type = sampled_types[&sampled_pointers[&inst.words[0]]];
                out.push(inst);
                let ptr = image_ptrs[&image_type];
                if !declared_image_ptrs.contains(&ptr) {
                    out.push(Inst { op: OP_TYPE_POINTER, words: vec![ptr, STORAGE_UNIFORM_CONSTANT, image_type] });
                    declared_image_ptrs.push(ptr);
                }
            }
            OP_VARIABLE if sampled_vars.contains_key(&inst.words[1]) => {
                let var = inst.words[1];
                let image_type = sampled_types[&sampled_vars[&var]];
                out.push(Inst { op: OP_VARIABLE, words: vec![image_ptrs[&image_type], var, STORAGE_UNIFORM_CONSTANT] });
                out.push(Inst { op: OP_VARIABLE, words: vec![sampler_ptr, sampler_vars[&var], STORAGE_UNIFORM_CONSTANT] });
            }
            OP_LOAD if sampled_vars.contains_key(&inst.words[2]) => {
                let var = inst.words[2];
                let sampled_type = sampled_vars[&var];
                let image_type = sampled_types[&sampled_type];
                let image = fresh();
                let sampler = fresh();
                out.push(Inst { op: OP_LOAD, words: vec![image_type, image, var] });
                out.push(Inst { op: OP_LOAD, words: vec![sampler_type, sampler, sampler_vars[&var]] });
                out.push(Inst { op: OP_SAMPLED_IMAGE, words: vec![sampled_type, inst.words[1], image, sampler] });
            }
            _ => out.push(inst),
        }
    }

    let mut result = words[..5].to_vec();
    result[3] = bound;
    for inst in &out {
        inst.encode(&mut result);
    }
    Ok(result)
}
