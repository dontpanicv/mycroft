#!/bin/sh
# Downloads the Parakeet TDT 0.6B v3 speech model (CoreML, ~460 MB) that the app bundles for dictation, into
# ios/Models (not in git). The build copies it into the app; without it, dictation offers Apple's model only.
# NVIDIA's model, CC-BY-4.0, converted by FluidInference: https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml
set -eu
REPO=FluidInference/parakeet-tdt-0.6b-v3-coreml
REVISION=7dd20fe6b1797d35f5e3307e8b1732d9a178edfe
DEST="$(cd "$(dirname "$0")/.." && pwd)/Models/parakeet-tdt-0.6b-v3"
FILES="parakeet_vocab.json"
for model in Preprocessor Encoder Decoder JointDecisionv3; do
  for part in coremldata.bin metadata.json model.mil weights/weight.bin analytics/coremldata.bin; do
    FILES="$FILES $model.mlmodelc/$part"
  done
done
for file in $FILES; do
  [ -s "$DEST/$file" ] && continue
  mkdir -p "$(dirname "$DEST/$file")"
  echo "fetching $file"
  curl -fL --retry 3 -sS -o "$DEST/$file.part" "https://huggingface.co/$REPO/resolve/$REVISION/$file"
  mv "$DEST/$file.part" "$DEST/$file"
done
echo "$REVISION" > "$DEST/REVISION"
du -sh "$DEST"
