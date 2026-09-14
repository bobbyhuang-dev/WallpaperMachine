#include "Resource/TextureResourceResolver.hpp"

#include "SpecTexs.hpp"

namespace wallpaper
{

TextureResourceKind ClassifyTextureResource(std::string_view name)
{
    if (sstart_with(name, WE_ALIAS_PREFIX)) return TextureResourceKind::AliasRenderTarget;
    if (sstart_with(name, WE_IMAGE_LAYER_COMPOSITE_PREFIX)) return TextureResourceKind::LinkedRenderTarget;
    if (IsSpecTex(name)) return TextureResourceKind::BuiltInRenderTarget;
    return TextureResourceKind::AssetTexture;
}

} // namespace wallpaper
