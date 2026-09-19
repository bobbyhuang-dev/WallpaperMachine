use shader::{
    CompiledStageArtifact, MetalSlotKind, MetalStageCode, ShaderCompiler, ShaderError,
    ShaderStageKind, ShaderTarget, compile::NagaCompiler, legalize::CodegenStageSource,
};

/// Legalized textured-quad vertex stage, in the form the codegen pass emits.
const TEXTURED_QUAD_VERTEX: &str = r"#version 450
layout(location = 0) in vec2 a_Position;
layout(location = 1) in vec2 a_TexCoord;
layout(location = 0) out vec2 v_TexCoord;
void main() {
    v_TexCoord = a_TexCoord;
    gl_Position = vec4(a_Position, 0.0, 1.0);
}
";

/// Legalized textured-quad fragment stage with a uniform block, a sampled
/// texture, and the separate sampler the codegen pass generates for it.
const TEXTURED_QUAD_FRAGMENT: &str = r"#version 450
layout(set = 0, binding = 0) uniform texture2D g_Texture0;
layout(set = 0, binding = 1) uniform sampler _we_Sampler_g_Texture0;
layout(set = 0, binding = 2) uniform Globals {
    vec4 g_Color;
    vec2 g_TexelSize;
} u_Globals;
layout(location = 0) in vec2 v_TexCoord;
layout(location = 0) out vec4 frag_color;
void main() {
    frag_color = texture(sampler2D(g_Texture0, _we_Sampler_g_Texture0),
                         v_TexCoord + u_Globals.g_TexelSize) * u_Globals.g_Color;
}
";

#[test]
fn textured_quad_program_compiles_to_metal_source() {
    let vertex = compile_metal(ShaderStageKind::Vertex, TEXTURED_QUAD_VERTEX);
    let fragment = compile_metal(ShaderStageKind::Fragment, TEXTURED_QUAD_FRAGMENT);

    assert_eq!(vertex.language_version(), (2, 0));
    assert!(
        vertex.source().contains("#include <metal_stdlib>"),
        "{}",
        vertex.source()
    );

    // Naga renames entry points, so the reported name is the only thing the
    // renderer may look up; assert the report matches the emitted source.
    assert_ne!(vertex.entry_point(), "main");
    assert!(
        vertex
            .source()
            .contains(&format!("vertex main_Output {}(", vertex.entry_point())),
        "vertex entry point `{}` should be declared in the emitted source:\n{}",
        vertex.entry_point(),
        vertex.source()
    );
    assert!(
        fragment
            .source()
            .contains(&format!("fragment main_Output {}(", fragment.entry_point())),
        "fragment entry point `{}` should be declared in the emitted source:\n{}",
        fragment.entry_point(),
        fragment.source()
    );

    assert!(
        vertex
            .source()
            .contains("metal::float2 a_Position [[attribute(0)]]"),
        "vertex inputs should keep their declared locations:\n{}",
        vertex.source()
    );
    assert!(
        fragment.source().contains(
            "metal::texture2d<float, metal::access::sample> g_Texture0_ [[texture(0)]]"
        ),
        "sampled texture should be declared at its mapped texture slot:\n{}",
        fragment.source()
    );
    assert!(
        fragment
            .source()
            .contains("metal::sampler _we_Sampler_g_Texture0_ [[sampler(1)]]"),
        "generated sampler should be declared at its mapped sampler slot:\n{}",
        fragment.source()
    );
    assert!(
        fragment
            .source()
            .contains("constant Globals& u_Globals [[buffer(2)]]"),
        "uniform block should be declared at its mapped buffer slot:\n{}",
        fragment.source()
    );
}

#[test]
fn uniform_block_and_texture_get_distinct_deterministic_slots() {
    let first = compile_metal(ShaderStageKind::Fragment, TEXTURED_QUAD_FRAGMENT);
    let second = compile_metal(ShaderStageKind::Fragment, TEXTURED_QUAD_FRAGMENT);

    assert_eq!(
        binding_summary(&first),
        binding_summary(&second),
        "the metal binding map must be deterministic for identical input"
    );
    assert_eq!(
        binding_summary(&first),
        vec![
            ("g_Texture0".to_owned(), 0, MetalSlotKind::Texture, 0),
            (
                "_we_Sampler_g_Texture0".to_owned(),
                1,
                MetalSlotKind::Sampler,
                1
            ),
            ("u_Globals".to_owned(), 2, MetalSlotKind::Buffer, 2),
        ],
        "every metal slot must equal the resource's SPIR-V binding index"
    );

    let mut slots = first
        .bindings()
        .iter()
        .map(|binding| (binding.slot_kind(), binding.slot()))
        .collect::<Vec<_>>();
    let slot_count = slots.len();
    slots.sort_unstable();
    slots.dedup();
    assert_eq!(
        slots.len(),
        slot_count,
        "two resources must never share one metal argument-table slot"
    );

    for binding in first.bindings() {
        assert_eq!(binding.set(), 0);
    }
}

#[test]
fn global_outside_descriptor_set_zero_fails_instead_of_emitting_a_shader() {
    let source = r"#version 450
layout(set = 1, binding = 0) uniform texture2D g_Texture0;
layout(set = 0, binding = 1) uniform sampler _we_Sampler_g_Texture0;
layout(location = 0) in vec2 v_TexCoord;
layout(location = 0) out vec4 frag_color;
void main() {
    frag_color = texture(sampler2D(g_Texture0, _we_Sampler_g_Texture0), v_TexCoord);
}
";

    let message = compile_metal_error(ShaderStageKind::Fragment, source);

    assert!(
        message.contains("metal binding map cannot cover global `g_Texture0`"),
        "{message}"
    );
    assert!(message.contains("descriptor set 1"), "{message}");
}

#[test]
fn sampler_binding_beyond_the_argument_table_fails_instead_of_emitting_a_shader() {
    let source = r"#version 450
layout(set = 0, binding = 0) uniform texture2D g_Texture0;
layout(set = 0, binding = 16) uniform sampler _we_Sampler_g_Texture0;
layout(location = 0) in vec2 v_TexCoord;
layout(location = 0) out vec4 frag_color;
void main() {
    frag_color = texture(sampler2D(g_Texture0, _we_Sampler_g_Texture0), v_TexCoord);
}
";

    let error = NagaCompiler
        .compile_stage(
            ShaderTarget::MetalMsl,
            ShaderStageKind::Fragment,
            &legalized_source(ShaderStageKind::Fragment, source),
        )
        .expect_err("a slot outside the metal argument table must fail the compile");

    let ShaderError::Reflection { message } = error else {
        panic!("expected a reflection error for an unrepresentable metal slot");
    };
    assert!(
        message.contains("metal sampler slot 16 for `_we_Sampler_g_Texture0`"),
        "{message}"
    );
    assert!(message.contains("argument-table limit of 15"), "{message}");
}

#[test]
fn metal_output_does_not_adjust_clip_space_or_texture_origin() {
    let vertex = compile_metal(ShaderStageKind::Vertex, TEXTURED_QUAD_VERTEX);

    assert!(!vertex.conventions().clip_space_y_flipped());
    assert!(!vertex.conventions().clip_space_depth_remapped());
    assert!(!vertex.conventions().texture_origin_flipped());
    assert!(
        vertex
            .source()
            .contains("gl_Position = metal::float4(_e5.x, _e5.y, 0.0, 1.0);"),
        "the author's clip-space position must reach metal unmodified:\n{}",
        vertex.source()
    );
}

#[test]
fn metal_and_spirv_targets_produce_mutually_exclusive_code_for_one_source() {
    let source = legalized_source(ShaderStageKind::Fragment, TEXTURED_QUAD_FRAGMENT);

    let spirv = NagaCompiler
        .compile_stage(
            ShaderTarget::VulkanSpirv,
            ShaderStageKind::Fragment,
            &source,
        )
        .expect("fragment shader should compile to SPIR-V");
    let metal = NagaCompiler
        .compile_stage(ShaderTarget::MetalMsl, ShaderStageKind::Fragment, &source)
        .expect("fragment shader should compile to MSL");

    assert_eq!(spirv.stage().target(), ShaderTarget::VulkanSpirv);
    assert_eq!(metal.stage().target(), ShaderTarget::MetalMsl);
    assert!(spirv.stage().metal().is_none());
    assert!(metal.stage().spirv().is_none());
    assert_eq!(
        spirv.stage().legalized_source(),
        metal.stage().legalized_source(),
        "both targets must be generated from the same legalized source"
    );
}

fn compile_metal(stage: ShaderStageKind, source: &str) -> MetalStageCode {
    let artifact = NagaCompiler
        .compile_stage(
            ShaderTarget::MetalMsl,
            stage,
            &legalized_source(stage, source),
        )
        .unwrap_or_else(|error| {
            panic!(
                "{stage:?} shader should compile to MSL: {}",
                error.to_miette_report()
            )
        });
    metal(&artifact).clone()
}

fn compile_metal_error(stage: ShaderStageKind, source: &str) -> String {
    let error = NagaCompiler
        .compile_stage(
            ShaderTarget::MetalMsl,
            stage,
            &legalized_source(stage, source),
        )
        .expect_err("an uncoverable global must fail the compile");

    let ShaderError::Compile { diagnostics } = error else {
        panic!("expected a compile diagnostic error");
    };
    diagnostics
        .first()
        .expect("compile error should carry a diagnostic")
        .message()
        .to_owned()
}

fn metal<M>(artifact: &CompiledStageArtifact<M>) -> &MetalStageCode {
    artifact
        .stage()
        .metal()
        .expect("metal_msl target should produce Metal source")
}

fn legalized_source(stage: ShaderStageKind, source: &str) -> CodegenStageSource {
    CodegenStageSource::new(stage, source.to_owned(), Box::from([]))
}

fn binding_summary(metal: &MetalStageCode) -> Vec<(String, u32, MetalSlotKind, u32)> {
    metal
        .bindings()
        .iter()
        .map(|binding| {
            (
                binding.name().as_str().to_owned(),
                binding.binding(),
                binding.slot_kind(),
                binding.slot(),
            )
        })
        .collect()
}
