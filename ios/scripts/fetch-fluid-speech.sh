#!/bin/sh
# Downloads Fluid Speech Mini (Core ML, ~253 MB), the English speech model the app bundles for dictation, into
# ios/Models (not in git), and checks every file against its pinned hash. The build copies it into the app; without
# it, dictation offers Apple's model only.
# FluidVoice's model, CC-BY-4.0, built on NVIDIA's Parakeet TDT 0.6B v3 and Moondream's Parakeet Ultra:
# https://huggingface.co/FluidVoice-Labs/fluid-speech-mini-coreml
set -eu
REPO=FluidVoice-Labs/fluid-speech-mini-coreml
REVISION=d81c3160dfe5a5e1f8f7267164a07d30617a3a1a
DEST="$(cd "$(dirname "$0")/.." && pwd)/Models/fluid-speech-mini"
[ -f "$DEST/REVISION" ] && [ "$(cat "$DEST/REVISION")" = "$REVISION" ] && exit 0

# path, then its hash: sha256 for large files, the git blob id for small ones (as Hugging Face lists them).
FILES="
Preprocessor.mlmodelc/analytics/coremldata.bin c9beeb989c8d66f8be11df59bc6df277ec76cee404f6865b46243835ef562f6d
Preprocessor.mlmodelc/coremldata.bin dbde3f2300842c1fd51ef3ff948a0bcffe65ffd2dca10707f2509f32c1d65b1d
Preprocessor.mlmodelc/metadata.json 06162c58cf2f5343a0e60f36f843bcdf3cc58527
Preprocessor.mlmodelc/model.mil f987e2479228436c49189aa47edb376db74dcff5
Preprocessor.mlmodelc/weights/weight.bin 129b76e3aeafa8afa3ea76d995b964b145fe83700d579f6ff42c4c38fa0968ea
Encoder.mlmodelc/analytics/coremldata.bin 3a3caa2c6aec983d94a5659eff09a00f77077147ea6726b8ddfdf022f0238ce9
Encoder.mlmodelc/coremldata.bin 494d8e2ce30b37bcdf494b3ba7ddf6e1bc921b9a59e369a9efd44d013ca3bf7d
Encoder.mlmodelc/metadata.json 49b43277d5d42ac49af5a9e6bcec63195acbb76c
Encoder.mlmodelc/model.mil 69c0308b882eae9413bd787f757c80ee46a7f2bb
Encoder.mlmodelc/weights/weight.bin cf0b61022de8c698984a8c7185c2d093fa744694621881ff062c46fee2546131
Decoder.mlmodelc/analytics/coremldata.bin d4beee43a6eab29b2adcc298f2e8582e8fb79d5fe3aa9f1ab692ade681ca369d
Decoder.mlmodelc/coremldata.bin 6094d06d05c1ca4599c7b13c9a4ca7c00826ee2396796cf3084ce602a9884468
Decoder.mlmodelc/metadata.json a79debb5125b7c1a6a81e6a4445912c96474c0ee
Decoder.mlmodelc/model.mil 428742162c9e8b2b1a020e4a47da87adb87e7af0
Decoder.mlmodelc/weights/weight.bin d173e381488d07fd7648e2ccecbfb1bceff0457d75461550b26ba7fa2d23309a
JointDecision.mlmodelc/analytics/coremldata.bin 9e767d69e1092b27b28d9f236b9cbcded58ff3891e320cba7855e2c24e803d69
JointDecision.mlmodelc/coremldata.bin 284b235c08cd4769202af017f854deace69c0209c29f2253a2073bb68d58d38d
JointDecision.mlmodelc/metadata.json f838342b52059cd8b06bf6bedd185bb0c7ed1cac
JointDecision.mlmodelc/model.mil 18e706e2e2d4a78ad825a1a0542af639f52b3c62
JointDecision.mlmodelc/weights/weight.bin f991f65979c1b3fee3db39a645aa87e6bef1a304ed1816d074b17479bea797fc
parakeet_vocab.json c684822ec3b671ebc449c433a7012398d39b8bb0
LICENSE da6ab6cc8f333d7e89a99812866df8f24374d47c
NOTICE ab1383ddb9427e377b5752cea97d2a0a3411dbc9
"
DOWNLOAD="$DEST/download"
echo "$FILES" | while read -r file hash; do
  [ -n "$file" ] || continue
  target="$DOWNLOAD/$file"
  if [ ! -s "$target" ]; then
    mkdir -p "$(dirname "$target")"
    echo "fetching $file"
    curl -fL --retry 3 -sS -o "$target.part" "https://huggingface.co/$REPO/resolve/$REVISION/$file"
    mv "$target.part" "$target"
  fi
  if [ ${#hash} = 64 ]; then have="$(shasum -a 256 "$target" | cut -d' ' -f1)"; else have="$(git hash-object "$target")"; fi
  if [ "$have" != "$hash" ]; then
    mv "$target" "$target.bad"
    echo "error: $file doesn't match its pinned hash (moved aside as $file.bad)" >&2
    exit 1
  fi
done

# FluidAudio loads a Parakeet v3 package, whose joint network it names JointDecisionv3. This one has the same inputs
# and outputs (token, probability, duration), without the top-K ones FluidAudio reads only for language filtering.
mkdir -p "$DEST/model"
rsync -a --delete --exclude JointDecision.mlmodelc "$DOWNLOAD/" "$DEST/model/"
rsync -a --delete "$DOWNLOAD/JointDecision.mlmodelc/" "$DEST/model/JointDecisionv3.mlmodelc/"
echo "$REVISION" > "$DEST/REVISION"
du -sh "$DEST/model"
