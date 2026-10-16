# Buildroot global patch directory (BR2_GLOBAL_PATCH_DIR).
#
# Intentionally empty. merge-defconfig.sh points BR2_GLOBAL_PATCH_DIR here so
# per-package patches can be dropped in as <pkg>/<nnnn-desc.patch> without
# editing the submodule. The directory MUST exist even when empty: HAOS 18.x's
# Buildroot hard-fails ("BR2_GLOBAL_PATCH_DIR contains nonexistent directory")
# if the configured patch dir is missing, whereas 17.x tolerated it.
