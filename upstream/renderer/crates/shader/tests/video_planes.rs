//! Direct NV12 plane sampling: the second variant of one author shader.
//!
//! What these cover is the compiler half of the fast path — that the variant is
//! a translation of the author's own program rather than a substitute for it,
//! that it declares the plane and the colour constants the renderer has to
//! bind, and that a shader doing anything this translation cannot reproduce is
//! refused instead of mistranslated. Nothing here draws a pixel.

use shader::{
    CompiledShaderProgram, MetalSlotKind, ShaderName, ShaderProgramRequest, ShaderStageKind,
    ShaderStageSource, ShaderTarget, ShaderTextureInfo, TextureFormatHint, TextureSlot,
    VideoPlaneLayout, compile::NagaCompiler, pipeline::DefaultShaderPipeline,
};

const VERTEX: &str = concat!(
    "uniform mat4 g_ModelViewProjectionMatrix;\n",
    "attribute vec3 a_Position;\n",
    "attribute vec2 a_TexCoord;\n",
    "varying vec2 v_TexCoord;\n",
    "void main() {\n",
    "  v_TexCoord = a_TexCoord;\n",
    "  gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1.0);\n",
    "}\n",
);

/// The shape an ordinary Wallpaper Engine image layer has: one video slot, one
/// ordinary image slot beside it, and a colour multiply over both.
const FRAGMENT: &str = concat!(
    "uniform sampler2D g_Texture0;\n",
    "uniform sampler2D g_Texture1;\n",
    "uniform vec4 g_Color;\n",
    "varying vec2 v_TexCoord;\n",
    "void main() {\n",
    "  vec4 video = texture2D(g_Texture0, v_TexCoord);\n",
    "  vec4 overlay = texture2D(g_Texture1, v_TexCoord);\n",
    "  gl_FragColor = video * overlay * g_Color;\n",
    "}\n",
);

fn pipeline() -> DefaultShaderPipeline<shader::InMemoryShaderSourceProvider> {
    DefaultShaderPipeline::new(
        shader::InMemoryShaderSourceProvider::default(),
        NagaCompiler,
    )
}

fn texture(slot: u8, planes: VideoPlaneLayout) -> ShaderTextureInfo {
    ShaderTextureInfo::new(
        TextureSlot::new(slot).expect("valid slot"),
        true,
        TextureFormatHint::Rgba8,
    )
    .with_video_planes(planes)
}

fn compile(
    name: &str,
    fragment: &str,
    planes: VideoPlaneLayout,
) -> shader::ShaderResult<CompiledShaderProgram> {
    let request = ShaderProgramRequest::builder(ShaderName::new(name).expect("valid name"))
        .target(ShaderTarget::MetalMsl)
        .stage(ShaderStageSource::new(ShaderStageKind::Vertex, VERTEX))
        .stage(ShaderStageSource::new(ShaderStageKind::Fragment, fragment))
        .texture(texture(0, planes))
        .texture(texture(1, VideoPlaneLayout::None))
        .build()
        .expect("request should be valid");
    pipeline().compile(&request)
}

fn stage_source(program: &CompiledShaderProgram, kind: ShaderStageKind) -> &str {
    program
        .stages()
        .iter()
        .find(|stage| stage.kind() == kind)
        .and_then(|stage| stage.legalized_source())
        .expect("legalized stage source is captured")
}

fn metal_source(program: &CompiledShaderProgram, kind: ShaderStageKind) -> &str {
    program
        .stages()
        .iter()
        .find(|stage| stage.kind() == kind)
        .and_then(shader::CompiledShaderStage::metal)
        .expect("metal stage code is produced")
        .source()
}

#[test]
fn plain_variant_is_unchanged_by_the_option_existing() {
    let plain = compile("video_plain", FRAGMENT, VideoPlaneLayout::None)
        .expect("the ordinary program compiles");
    let fragment = stage_source(&plain, ShaderStageKind::Fragment);

    assert!(
        fragment.contains("texture(sampler2D(g_Texture0, _we_Sampler_g_Texture0), v_TexCoord)"),
        "an unflagged slot keeps the ordinary split-sampler rewrite:\n{fragment}"
    );
    assert!(
        !fragment.contains("_we_VideoChroma"),
        "an unflagged slot declares no plane:\n{fragment}"
    );
    assert!(
        !fragment.contains("_we_VideoRange"),
        "an unflagged slot adds no colour constants:\n{fragment}"
    );
}

#[test]
fn plane_variant_translates_the_author_shader_rather_than_replacing_it() {
    let variant = compile("video_planes", FRAGMENT, VideoPlaneLayout::Nv12Biplanar)
        .expect("the plane variant compiles");
    let fragment = stage_source(&variant, ShaderStageKind::Fragment);

    // The author's own expression survives: only the video sample changed.
    assert!(
        fragment.contains("vec4 video = _we_SampleVideoNv12_0(v_TexCoord);"),
        "the video sample becomes a plane sample:\n{fragment}"
    );
    assert!(
        fragment
            .contains("texture(sampler2D(g_Texture1, _we_Sampler_g_Texture1), v_TexCoord)"),
        "the ordinary image beside it is untouched:\n{fragment}"
    );
    assert!(
        fragment.contains("gl_FragColor = video * overlay * g_Color;")
            || fragment.contains("_we_FragColor = video * overlay * g_Color;"),
        "the author's blend is preserved:\n{fragment}"
    );
    assert!(
        fragment.contains("uniform texture2D _we_VideoChroma0;"),
        "the chroma plane is declared:\n{fragment}"
    );
    assert!(
        fragment.contains("vec4 _we_VideoRange0;") && fragment.contains("vec4 _we_VideoMatrix0;"),
        "the colour constants become uniform members:\n{fragment}"
    );

    // The vertex stage samples nothing, so it declares no plane and no helper.
    let vertex = stage_source(&variant, ShaderStageKind::Vertex);
    assert!(
        !vertex.contains("_we_VideoChroma0"),
        "a stage that never samples the video declares no plane:\n{vertex}"
    );
    assert!(
        !vertex.contains("_we_SampleVideoNv12_0"),
        "a stage that never samples the video carries no helper:\n{vertex}"
    );
}

#[test]
fn plane_variant_reaches_metal_with_its_own_binding_plan() {
    let variant = compile("video_planes_metal", FRAGMENT, VideoPlaneLayout::Nv12Biplanar)
        .expect("the plane variant compiles");
    let fragment = metal_source(&variant, ShaderStageKind::Fragment);

    assert!(
        fragment.contains("#include <metal_stdlib>"),
        "the variant is real Metal source:\n{fragment}"
    );
    assert!(
        fragment.contains("_we_VideoChroma0"),
        "the chroma plane reaches Metal:\n{fragment}"
    );

    let metal = variant
        .stages()
        .iter()
        .find(|stage| stage.kind() == ShaderStageKind::Fragment)
        .and_then(shader::CompiledShaderStage::metal)
        .expect("metal stage code is produced");
    let chroma_texture = metal
        .bindings()
        .iter()
        .find(|binding| {
            binding.name().as_str() == "_we_VideoChroma0"
                && binding.slot_kind() == MetalSlotKind::Texture
        })
        .expect("the chroma plane has a Metal texture slot");
    let chroma_sampler = metal
        .bindings()
        .iter()
        .find(|binding| {
            binding.name().as_str() == "_we_Sampler__we_VideoChroma0"
                && binding.slot_kind() == MetalSlotKind::Sampler
        })
        .expect("the chroma plane has a Metal sampler slot");
    let luma_texture = metal
        .bindings()
        .iter()
        .find(|binding| {
            binding.name().as_str() == "g_Texture0" && binding.slot_kind() == MetalSlotKind::Texture
        })
        .expect("the luma plane keeps the material's own slot");
    assert_ne!(chroma_texture.slot(), luma_texture.slot());
    assert!(chroma_sampler.slot() <= MetalSlotKind::Sampler.max_slot());

    // The plane is a renderer resource, not a material texture slot: a name
    // that parsed as `g_TextureN` would claim a slot the material has not got.
    assert!(
        !variant
            .reflection()
            .descriptor_bindings()
            .iter()
            .any(|binding| {
                let name = format!("{}", binding.name());
                name.starts_with("g_Texture") && name.contains("Chroma")
            }),
    );
    assert_eq!(
        variant
            .metadata()
            .active_texture_slots()
            .iter()
            .map(|slot| slot.index())
            .collect::<Vec<_>>(),
        vec![0, 1],
        "only the material's own slots are reported active"
    );
}

#[test]
fn plane_variant_and_plain_variant_have_different_cache_keys() {
    let plain = compile("video_key", FRAGMENT, VideoPlaneLayout::None).expect("plain compiles");
    let variant =
        compile("video_key", FRAGMENT, VideoPlaneLayout::Nv12Biplanar).expect("variant compiles");

    assert_ne!(plain.cache_key().as_str(), variant.cache_key().as_str());
}

#[test]
fn explicit_lod_sampling_refuses_the_plane_variant() {
    const LOD_FRAGMENT: &str = concat!(
        "uniform sampler2D g_Texture0;\n",
        "varying vec2 v_TexCoord;\n",
        "void main() {\n",
        "  gl_FragColor = textureLod(g_Texture0, v_TexCoord, 0.0);\n",
        "}\n",
    );

    let _plain = compile("video_lod", LOD_FRAGMENT, VideoPlaneLayout::None)
        .expect("the ordinary program still compiles");
    let error = compile("video_lod", LOD_FRAGMENT, VideoPlaneLayout::Nv12Biplanar)
        .expect_err("an explicit-lod sample cannot be translated to planes");

    assert!(
        error.to_string().contains("cannot be sampled as planes"),
        "the refusal names the reason: {error}"
    );
}

#[test]
fn texture_size_query_refuses_the_plane_variant() {
    const SIZE_FRAGMENT: &str = concat!(
        "uniform sampler2D g_Texture0;\n",
        "varying vec2 v_TexCoord;\n",
        "void main() {\n",
        "  vec2 size = vec2(textureSize(g_Texture0, 0));\n",
        "  gl_FragColor = texture2D(g_Texture0, v_TexCoord + 1.0 / size);\n",
        "}\n",
    );

    let error = compile("video_size", SIZE_FRAGMENT, VideoPlaneLayout::Nv12Biplanar)
        .expect_err("a size query cannot be translated to planes");

    assert!(
        error.to_string().contains("cannot be sampled as planes"),
        "the refusal names the reason: {error}"
    );
}

#[test]
fn macro_sampling_of_the_video_slot_is_translated_like_any_other_call() {
    const MACRO_FRAGMENT: &str = concat!(
        "#define SAMPLE_VIDEO(uv) texture2D(g_Texture0, uv)\n",
        "uniform sampler2D g_Texture0;\n",
        "varying vec2 v_TexCoord;\n",
        "void main() {\n",
        "  gl_FragColor = SAMPLE_VIDEO(v_TexCoord);\n",
        "}\n",
    );

    let variant = compile("video_macro", MACRO_FRAGMENT, VideoPlaneLayout::Nv12Biplanar)
        .expect("a macro body is rewritten on the same terms as ordinary source");
    let fragment = stage_source(&variant, ShaderStageKind::Fragment);

    assert!(
        fragment.contains("#define SAMPLE_VIDEO(uv) _we_SampleVideoNv12_0(uv)"),
        "the macro body samples the planes:\n{fragment}"
    );
}

#[test]
fn an_unsupported_operation_inside_a_macro_refuses_the_plane_variant() {
    const MACRO_FRAGMENT: &str = concat!(
        "#define VIDEO_SIZE vec2(textureSize(g_Texture0, 0))\n",
        "uniform sampler2D g_Texture0;\n",
        "varying vec2 v_TexCoord;\n",
        "void main() {\n",
        "  gl_FragColor = texture2D(g_Texture0, v_TexCoord + 1.0 / VIDEO_SIZE);\n",
        "}\n",
    );

    let error = compile("video_macro_size", MACRO_FRAGMENT, VideoPlaneLayout::Nv12Biplanar)
        .expect_err("a size query inside a macro is still a size query");

    assert!(
        error.to_string().contains("cannot be sampled as planes"),
        "the refusal names the reason: {error}"
    );
}

#[test]
fn a_flag_on_a_slot_the_shader_does_not_declare_changes_nothing() {
    const ONE_SLOT: &str = concat!(
        "uniform sampler2D g_Texture0;\n",
        "varying vec2 v_TexCoord;\n",
        "void main() { gl_FragColor = texture2D(g_Texture0, v_TexCoord); }\n",
    );

    let request = ShaderProgramRequest::builder(
        ShaderName::new("video_absent_slot").expect("valid name"),
    )
    .target(ShaderTarget::MetalMsl)
    .stage(ShaderStageSource::new(ShaderStageKind::Vertex, VERTEX))
    .stage(ShaderStageSource::new(ShaderStageKind::Fragment, ONE_SLOT))
    .texture(texture(0, VideoPlaneLayout::None))
    .texture(texture(3, VideoPlaneLayout::Nv12Biplanar))
    .build()
    .expect("request should be valid");
    let program = pipeline()
        .compile(&request)
        .expect("a flag for a slot nothing declares is not a failure");

    assert!(
        !stage_source(&program, ShaderStageKind::Fragment).contains("_we_VideoChroma"),
        "no plane is declared for a slot the shader never samples"
    );
}
