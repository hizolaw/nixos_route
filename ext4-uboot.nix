# Same as nixpkgs' nixos/lib/make-ext4-fs.nix, but creates the filesystem
# without the two features that the board's U-Boot (2022.07) does not know:
#
#   orphan_file          - INCOMPAT, e2fsprogs >= 1.47 enables it by default,
#                          unknown to U-Boot <= 2023/2024.  U-Boot refuses to
#                          mount such a filesystem, so it never finds
#                          /boot/extlinux/extlinux.conf and nothing boots.
#   metadata_csum_seed   - RO_COMPAT, also unknown to that U-Boot.
#
# Everything else (extent, 64bit, metadata_csum, dir_index, …) is supported.
{
  pkgs,
  lib,
  # List of derivations to be included
  storePaths,
  # Whether or not to compress the resulting image with zstd
  compressImage ? false,
  zstd,
  # Shell commands to populate the ./files directory.
  # All files in that directory are copied to the root of the FS.
  populateImageCommands ? "",
  volumeLabel,
  uuid ? "44444444-4444-4444-8888-888888888888",
  e2fsprogs,
  libfaketime,
  perl,
  fakeroot,
}:

let
  sdClosureInfo = pkgs.buildPackages.closureInfo { rootPaths = storePaths; };
in
pkgs.stdenv.mkDerivation {
  name = "ext4-fs.img${lib.optionalString compressImage ".zst"}";

  nativeBuildInputs = [
    e2fsprogs.bin
    libfaketime
    perl
    fakeroot
  ]
  ++ lib.optional compressImage zstd;

  buildCommand = ''
    ${if compressImage then "img=temp.img" else "img=$out"}
    (
    mkdir -p ./files
    ${populateImageCommands}
    )

    echo "Preparing store paths for image..."

    # Create nix/store before copying path
    mkdir -p ./rootImage/nix/store

    xargs -I % cp -a --reflink=auto % -t ./rootImage/nix/store/ < ${sdClosureInfo}/store-paths
    (
      GLOBIGNORE=".:.."
      shopt -u dotglob

      for f in ./files/*; do
          cp -a --reflink=auto -t ./rootImage/ "$f"
      done
    )

    # Also include a manifest of the closures in a format suitable for nix-store --load-db
    cp ${sdClosureInfo}/registration ./rootImage/nix-path-registration

    # Make a crude approximation of the size of the target image.
    numInodes=$(find ./rootImage | wc -l)
    numDataBlocks=$(du -s -c -B 4096 --apparent-size ./rootImage | tail -1 | awk '{ print int($1 * 1.20) }')
    bytes=$((2 * 4096 * $numInodes + 4096 * $numDataBlocks))
    echo "Creating an EXT4 image of $bytes bytes (numInodes=$numInodes, numDataBlocks=$numDataBlocks)"

    mebibyte=$(( 1024 * 1024 ))
    if (( bytes % mebibyte )); then
      bytes=$(( ( bytes / mebibyte + 1) * mebibyte ))
    fi

    truncate -s $bytes $img

    faketime -f "1970-01-01 00:00:01" fakeroot mkfs.ext4 \
      -L ${volumeLabel} -U ${uuid} \
      -O ^orphan_file,^metadata_csum_seed \
      -d ./rootImage $img

    export EXT2FS_NO_MTAB_OK=yes
    if ! fsck.ext4 -n -f $img; then
      echo "--- Fsck failed for EXT4 image of $bytes bytes (numInodes=$numInodes, numDataBlocks=$numDataBlocks) ---"
      cat errorlog
      return 1
    fi

    # shrink to fit
    resize2fs -M $img

    # Add 16 MebiByte to the current_size
    new_size=$(dumpe2fs -h $img | awk -F: \
      '/Block count/{count=$2} /Block size/{size=$2} END{print (count*size+16*2**20)/size}')

    resize2fs $img $new_size

    if [ ${toString compressImage} ]; then
      echo "Compressing image"
      zstd -T$NIX_BUILD_CORES -v --no-progress ./$img -o $out
    fi
  '';
}
