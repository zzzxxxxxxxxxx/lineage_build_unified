#!/bin/bash
echo ""
echo "LineageOS 18.x Unified Buildbot"
echo "ATTENTION: this script syncs repo on each run"
echo "Executing in 5 seconds - CTRL-C to exit"
echo ""
sleep 5

if [ $# -lt 2 ]
then
    echo "Not enough arguments - exiting"
    echo ""
    exit 1
fi

MODE=${1}
if [ ${MODE} != "device" ] && [ ${MODE} != "treble" ]
then
    echo "Invalid mode - exiting"
    echo ""
    exit 1
fi

PERSONAL=false
if [ ${!#} == "personal" ]
then
    PERSONAL=true
fi

# Abort early on error
set -eE
trap '(\
echo;\
echo \!\!\! An error happened during script execution;\
echo \!\!\! Please check console output for bad sync,;\
echo \!\!\! failed patch application, etc.;\
echo\
)' ERR

START=`date +%s`
BUILD_DATE="$(date +%Y%m%d)"
WITHOUT_CHECK_API=true
WITH_SU=true

echo "Preparing local manifests"
mkdir -p .repo/local_manifests
cp ./lineage_build_unified/local_manifests_${MODE}/*.xml .repo/local_manifests
echo ""

echo "Syncing repos"
repo sync -c --force-sync --no-clone-bundle --no-tags -j4
echo ""

echo "Setting up build environment"
source build/envsetup.sh &> /dev/null
mkdir -p ~/build-output
echo ""

echo "Enabling ccache"
export USE_CCACHE=1
export CCACHE_EXEC=$(which ccache)
ccache -M 50G
echo "ccache enabled, max size: 50G"
echo ""

# Fix mke2fs incompatibility with newer host e2fsprogs config
# soong_ui filters env vars, so we wrap the mke2fs binary instead
fix_mke2fs() {
    local MKE2FS_BIN="out/soong/host/linux-x86/bin/mke2fs"
    local MKE2FS_CONF="out/soong/host/linux-x86/bin/mke2fs.conf"
    if [ -f "$MKE2FS_BIN" ] && [ ! -L "$MKE2FS_BIN" ] && [ ! -f "${MKE2FS_BIN}.real" ]; then
        # Create a minimal mke2fs.conf compatible with old mke2fs (no orphan_file)
        cat > "$MKE2FS_CONF" << 'CONFEOF'
[defaults]
	base_features = sparse_super,large_file,filetype,resize_inode,dir_index,ext_attr
	default_mntopts = acl,user_xattr
	enable_periodic_fsck = 0
	blocksize = 4096
	inode_size = 256
	inode_ratio = 16384

[fs_types]
	ext4 = {
		features = has_journal,extent,huge_file,flex_bg,metadata_csum,metadata_csum_seed,64bit,dir_nlink,extra_isize
	}
CONFEOF
        mv "$MKE2FS_BIN" "${MKE2FS_BIN}.real"
        printf '#!/bin/bash\nexport MKE2FS_CONFIG="%s"\nexec "%s" "$@"\n' "$MKE2FS_CONF" "${MKE2FS_BIN}.real" > "$MKE2FS_BIN"
        chmod +x "$MKE2FS_BIN"
        echo "mke2fs wrapper installed"
    fi
}
echo ""

apply_patches() {
    echo "Applying patch group ${1}"
    bash ./lineage_build_unified/apply_patches.sh ./lineage_patches_unified/${1}
}

prep_device() {
    :
}

prep_treble() {
    apply_patches patches_treble_prerequisite
    apply_patches patches_treble_phh
}

finalize_device() {
    :
}

finalize_treble() {
    rm -f device/*/sepolicy/common/private/genfs_contexts
    cd device/phh/treble
    git clean -fdx
    bash generate.sh lineage
    cd ../../..
}

build_device() {
    if [[ ${1} == *N* ]]; then
        WITH_SU=false
    fi
    fix_mke2fs
    brunch ${1}
    mv $OUT/lineage-*.zip ~/build-output/lineage-18.1-$BUILD_DATE-UNOFFICIAL-${1}$($PERSONAL && echo "-personal" || echo "").zip
}

build_treble() {
    TARGET=${1}
    if [[ ${TARGET} == *N* ]]; then
        WITH_SU=false
    fi
    lunch lineage_${TARGET}-userdebug
    make installclean
    fix_mke2fs
    make -j$(nproc --all) systemimage
    make vndk-test-sepolicy
    mv $OUT/system.img ~/build-output/lineage-18.1-$BUILD_DATE-UNOFFICIAL-${TARGET}$(${PERSONAL} && echo "-personal" || echo "").img
}

echo "Applying patches"
prep_${MODE}
apply_patches patches_platform
apply_patches patches_${MODE}
if ${PERSONAL}
then
    apply_patches patches_platform_personal
    apply_patches patches_${MODE}_personal
fi
finalize_${MODE}
echo ""

for var in "${@:2}"
do
    if [ ${var} == "personal" ]
    then
        continue
    fi
    echo "Starting $(${PERSONAL} && echo "personal " || echo "")build for ${MODE} ${var}"
    build_${MODE} ${var}
done
ls ~/build-output | grep 'lineage' || true

END=`date +%s`
ELAPSEDM=$(($(($END-$START))/60))
ELAPSEDS=$(($(($END-$START))-$ELAPSEDM*60))
echo "Buildbot completed in $ELAPSEDM minutes and $ELAPSEDS seconds"
echo ""
