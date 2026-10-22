#!/bin/sh
# Downloads Phonon 31m (Gradium, Apache-2.0; Core ML conversion by FluidInference), the English voice Mycroft speaks
# with in a conversation, into ios/Models (not in git), and checks every file against its pinned hash. ~150 MB: the
# model, its constants and the English voices. The build copies it into the app; without it there is no conversation
# mode. https://huggingface.co/FluidInference/pocket-tts-coreml/tree/main/phonon/phonon-31m-en
set -eu
REPO=FluidInference/pocket-tts-coreml
REVISION=b51c4854305532b182026259092cc53e4b600f49
DEST="$(cd "$(dirname "$0")/.." && pwd)/Models/phonon"
[ -f "$DEST/REVISION" ] && [ "$(cat "$DEST/REVISION")" = "$REVISION" ] && exit 0

# path, then its hash: sha256 for large files, the git blob id for small ones (as Hugging Face lists them).
FILES="
LICENSE 261eeb9e9f8b2b4b0d119366dda99c6fd7d35c64
README.md eb1e55b2bbbae87a8a7f3f7fb7f1e2f3f796d438
arch.json 9eac1fcecb043d8bb553b9811390777bf0bd6a43
constants_bin/bos_emb.bin 1010476e005ac8b08a2fb3d73d853327148d818ec09e4df99611840233081fac
constants_bin/default.safetensors 97e27eac43ac5b9e789db9a4789e2d1c80205bee59db9f51161309b53a3cc5eb
constants_bin/en_gb_Maeve.safetensors 7b425930d4fff6d9592e6d52ddde901777acd172e5f3515a80cd8aa61262603b
constants_bin/en_us_Easton.safetensors 9bf671faf8d513bf30ef40118709182061130581aec6afa31f3ea6706f61e748
constants_bin/en_us_Zoey.safetensors 4a51147a22b68b377b2dddcdb1e0b9a0985208eb4534da004ba3ae3f2f7b2856
constants_bin/input_bias.bin 413a43837805c4c2aecb37743799c7773b21a7decd9edd5d3c065600846a3871
constants_bin/speaker_proj_weight.bin 0f5d6b5433ce622fcb9b93885c5cab82ba1537ef6cea60de56a811f2b6f1c79c
constants_bin/text_embed_table.bin 4a41cf481b98ddad78ec6f50dda7eca2a5033ea75cd1fa54d7381231d65818e7
constants_bin/tokenizer.json 70d39980cb2154bd364dbed8424b1343923a03e2
constants_bin/tokenizer.model 82e4572006d64d483317074c22c368e87779640b6f3a9dcd07b7caae32b030ce
mimi_decoder.mlmodelc/analytics/coremldata.bin 12f9e3aea28056a789b9a35c7ffcb6eeb53a607d8358998c1d25a41fdc49ee17
mimi_decoder.mlmodelc/coremldata.bin 89525846d461c4dbc7a593c9719bfee18a7284b8d11f464d8860f37199dc875a
mimi_decoder.mlmodelc/model.mil 7a8257fd1383bdd25fd493708a0d9605ed49b234
mimi_decoder.mlmodelc/weights/weight.bin fc998dd13becc51a05e74b2f7efd4bc0f05defafdc6baefe0a424ee6f7427e5a
pocket_state.json 81dec973102a2455c55334905ab714acffd936f1
pocket_state.mlmodelc/analytics/coremldata.bin 931c1ec027815fbcfd55c4757a3d21c3c46ad12586a366ec24b16ed64e8439ef
pocket_state.mlmodelc/coremldata.bin 10091f1e21e7be6ad7be9f7509697b8ff075cdce3806f2eef3f582f5d45556c2
pocket_state.mlmodelc/model.mil c0456488bd0ea57550d57bc917ee4fa8608ffa04
pocket_state.mlmodelc/weights/weight.bin cbe7fe8d1843021a9ad2995fda682ef85f949290ef65a58b8976b2c2e2a64502
voices/default.safetensors 26960233b94ae69ab00a3580bd7c283f1c9dbaed513c653191360a3d0d676da5
voices/en_gb_Alfie.safetensors 928da5fe853e548488b72e4b021f00235612b5ca2b47facbf2bd0b489a2b955c
voices/en_gb_Bryony.safetensors c629fa40c4f9e467769fe5762e4957d40e135b64026bd1df1e89bd9e55b951ff
voices/en_gb_Edwin.safetensors 46c12febb46f0d21db6ab48842a6bad20440c5670f4f914129c432edc0712bac
voices/en_gb_Elodie-Rose.safetensors b55f81a8f4bebba232e9c324126f87253789bbd12608970e0eb837c469e3940a
voices/en_gb_Freya.safetensors 09609a149e2e6331b6ddc75168441e9bea013ad277c17dc8d01806afe7526e03
voices/en_gb_Hugh.safetensors 7ce9388b0e5122009280be57d0ce0a46151e92e1a1ec927f88e386b9e6d402a0
voices/en_gb_Imogen.safetensors b464982a70d2991318db971173e2f5c3fffb7d2bd11730be256eb3b434d88e2c
voices/en_gb_Lottie.safetensors 4f32bd8a11f8499c8abb333278c799a1c2370e1899c07a9caed07e33322d1233
voices/en_gb_Maeve.safetensors be1231af76129234ff1aa8b7d03531e2c1410d6599eb085c0e9bc7335bd79eb4
voices/en_gb_Pippa.safetensors d9dc45f9ebb4b4f702244ff10910929b86d9304f5fb815572355ee815a8e6954
voices/en_gb_Spencer.safetensors 44814129100cc56a90ee76c220c2565e3f6ddece97689c7a8eee3692aaaed900
voices/en_gb_Teddy.safetensors 6cca4e57bb4ebf644be9293bcabacb6f170ac9a7f092ada6567c5931d31db841
voices/en_gb_Toby.safetensors ff348465a91e0e0895df388746463a195d1c7482b82f04b2451650bd54597ca7
voices/en_us_Delia.safetensors 896122da57b3e7f83886f1c009b9b537cbf63c04e4cc592d72dd935622c3cb77
voices/en_us_Easton.safetensors 3fb875c9b120b314d7dac804812aeaf50f5d0c6e3a8be798951b792483078cd1
voices/en_us_Everly.safetensors 64c37adead347b6b4c5acfc3e5883341bcdcd94538a146e521a1f9ec0fad1d6b
voices/en_us_Hadley.safetensors 4c5e11a691dfe73d6dc307cf83cfb00df8c866cbdbf4e128561adddfbdd0820d
voices/en_us_Harper.safetensors 44bbecc069b7c1872ba548ceddde8064ff674feed9989313191449fce72d2a08
voices/en_us_Juniper.safetensors c79e69a6f8228c6e31dd5ae9e573a79ab23abfc0d9140f62e57e123f10a41822
voices/en_us_Micah.safetensors b32ba16219f3908461dcdeddd2aa9bf4e85a46fa165065b30a6e022476231684
voices/en_us_Miles.safetensors eb0e61e9354e1fa7c1647530ff0c5ce4ea6f96fa65729594e443765208fe761e
voices/en_us_Preston.safetensors e3448287e6555990069383a6e0bc3f3a27baa6be69b30e28844d6d569f3239c4
voices/en_us_Russell.safetensors 4f87038dbd52f1304be60288769c422d4335b78f14af6342341a4824e4e06231
voices/en_us_Trevor.safetensors 831bd36e9bda1a0471cb02ae281aefdcec403ba5e5abf73f0c240304c2e7a722
voices/en_us_Zoey.safetensors d867f9f751360f32540c0cfb32055f95b607e51f1b023b429edd739de2ad04ef
"
DOWNLOAD="$DEST/download"
echo "$FILES" | while read -r file hash; do
  [ -n "$file" ] || continue
  target="$DOWNLOAD/$file"
  if [ ! -s "$target" ]; then
    mkdir -p "$(dirname "$target")"
    echo "fetching $file"
    curl -fL --retry 3 -sS -o "$target.part" "https://huggingface.co/$REPO/resolve/$REVISION/phonon/phonon-31m-en/$file"
    mv "$target.part" "$target"
  fi
  if [ ${#hash} = 64 ]; then have="$(shasum -a 256 "$target" | cut -d' ' -f1)"; else have="$(git hash-object "$target")"; fi
  if [ "$have" != "$hash" ]; then
    mv "$target" "$target.bad"
    echo "error: $file doesn't match its pinned hash (moved aside as $file.bad)" >&2
    exit 1
  fi
done

mkdir -p "$DEST/model"
rsync -a --delete "$DOWNLOAD/" "$DEST/model/"
echo "$REVISION" > "$DEST/REVISION"
du -sh "$DEST/model"
