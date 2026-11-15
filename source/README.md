# Source of the app in the Releases

`windowsios-full.patch` is the complete source change of `AppleVM-unsigned.ipa` relative to
[WindowsiOS](https://github.com/ammaarreshi/WindowsiOS) commit `0071d69` (GPL-2.0-or-later):

```bash
git clone https://github.com/ammaarreshi/WindowsiOS && cd WindowsiOS
git checkout 0071d69
git apply /path/to/windowsios-full.patch
```

Build: `make -j8 all ios-lib`, then the Xcode project in `ios/` (`xcodegen generate --spec ios/project.yml`), then
`scripts/embed_gpu3d.sh` copies the 3D frameworks from the UTM iOS app into it. The Arch Linux installer disk is made by
`scripts/build_arch_installer.py` (it builds the installer inside a running Arch Linux machine). Device identifiers in
the developer helper scripts (`scripts/arch_dev.sh`, `scripts/win_dev.sh`, ...) are placeholders: put in your own.

Not in the patch: the upstream `scripts/optimize_windows_lite.py` changes (not part of the app).

## The KosmicKrisp binary patch

The IPA's `vulkan_kosmickrisp.framework` is the one from UTM's iOS build (Mesa `osy/mesa` commit
`eed3e1d9bff9eb38890e0f241e87846cdd729fdf`) with one change in `kk_image_layout_init` (file offsets 0xedcf0 and
0x322450): an image gets the 2D-array texture type for input-attachment use only when its tiling is optimal,
so linear and DRM-modifier images stay plain 2D textures, which Metal requires for textures on a buffer. In C, in
`src/kosmickrisp/vulkan/kk_image_layout.c`, `vk_image_to_mtl_texture_type()`:

```c
if (array_layers > 1 ||
    ((image->usage & VK_IMAGE_USAGE_INPUT_ATTACHMENT_BIT) && image->tiling == VK_IMAGE_TILING_OPTIMAL))
```
