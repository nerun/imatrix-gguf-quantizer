# Nerun's Imatrix GGUF Quantizer

`quantizer.sh` is a Bash script that turns a Hugging Face model into a full set of **imatrix-quantized GGUF files** for [llama.cpp](https://github.com/ggml-org/llama.cpp). It can also produce the **vision projector (mmproj)** and an **MTP (multi-token prediction) head**. Everything specific to one model lives in a small config file, `quantizer.conf`, so the same script works for any model llama.cpp can convert.

The script uses **prebuilt llama.cpp release binaries** (no compilation) and the matching `convert_hf_to_gguf.py` from the same release tag. It can be **interrupted and restarted at any point**: finished files are kept and skipped, and only the step that was running is redone.

## Contents

- [Features](#features)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Usage](#usage)
- [Stages](#stages)
- [Configuration reference](#configuration-reference)
- [MTP head](#mtp-head)
- [Output layout](#output-layout)
- [Interrupting and resuming](#interrupting-and-resuming)
- [Examples](#examples)
- [Troubleshooting](#troubleshooting)
- [Notes and limitations](#notes-and-limitations)
- [License](#license)

## Features

- **One config file per model.** Repository, file names, quant list, llama.cpp build, imatrix settings, mmproj types and MTP handling are all set in `quantizer.conf`.
- **Pinned llama.cpp build.** Downloads one specific release (default `b12503`) and never upgrades it on its own. An existing installation is reused as is.
- **imatrix pipeline.** Converts the model to BF16, makes a Q8_0 copy, computes the importance matrix from a calibration text, then quantizes every type in the list from the BF16 using that matrix.
- **Vision projector.** Optionally converts the mmproj in any number of types (for example `f16` and `q8_0`).
- **MTP head.** Optionally downloads a ready-made MTP head GGUF, or builds a donor GGUF with the MTP block from the checkpoint, taking the MTP tensors from a base model when the checkpoint lacks them. The result is verified to actually contain MTP tensors.
- **Model card.** Generates the `README.md` of the Hugging Face repository: front matter, file table with sizes, usage, how the files were made, the license and the original model card. A custom template can reorder or extend it.
- **Safe against interruption.** Every output is written to a temporary name and renamed only when complete; a Ctrl+C deletes the unfinished file.
- **Shared tools.** Several model folders can share one llama.cpp installation and Python environment.
- **Validation up front.** The config is checked before any work starts, with clear error messages.

## Requirements

- **Linux x86-64.** The default release package is `ubuntu-vulkan-x64`; other Linux distributions work too (tested target: Debian testing).
- **Bash 4.4 or later.**
- **Python 3** with the `venv` module, plus `git`, `curl` and `tar`. On Debian or Ubuntu:

  ```bash
  sudo apt install python3 python3-venv git curl tar
  ```

- **A Vulkan driver** for GPU use (`mesa-vulkan-drivers` and `libvulkan1` on Debian for AMD/Intel). Without a GPU, set `LLAMA_ASSET="ubuntu-x64"` for the CPU-only build.
- **Internet access** to github.com, huggingface.co and gist.githubusercontent.com.
- **Disk space.** Roughly the BF16 size four to five times over for the full quant list. A 9B model needs about **170 GB**: about 20 GB for the downloaded weights, 18 GB for the BF16, 10 GB for the Q8_0 copy and about 105 GB for 24 quants.
- **RAM.** Enough to hold the BF16 model while quantizing comfortably; 32 GB is plenty for a 9B model.

## Quick start

```bash
mkdir my-model && cd my-model
cp /path/to/quantizer.sh .
./quantizer.sh --init        # writes a commented quantizer.conf
nano quantizer.conf          # set at least REPO and NAME
./quantizer.sh show          # check the effective configuration
./quantizer.sh               # run every stage
```

When it finishes, the GGUF files are in `gguf/`.

A complete, working configuration (Qwen3.8-9B-Distill, with mmproj and a downloaded MTP head) is in [`quantizer.conf.example`](quantizer.conf.example). Copy it to `quantizer.conf` and edit it instead of starting from `--init` if you prefer.

If the repository is gated or you hit Hugging Face rate limits, export a token first:

```bash
export HF_TOKEN=hf_xxxxxxxxxxxxxxxx
```

## Usage

```
./quantizer.sh [options] [stage ...]
```

| Option | Meaning |
|---|---|
| `--config FILE` | Use another config file. Default: `quantizer.conf` in the current directory. |
| `--llama-build bNNNNN` | Use this llama.cpp build instead of `LLAMA_BUILD` from the config. |
| `--init` | Write a commented template config and exit. Refuses to overwrite an existing file. |
| `-h`, `--help` | Print the usage summary. |

With no stage names, all stages run in order. Naming stages runs only those, in the order given:

```bash
./quantizer.sh imatrix quant
./quantizer.sh --llama-build b12600 setup
```

The current directory is the working directory: the model, the outputs and (by default) the tools are placed there.

Two environment variables are also read:

| Variable | Meaning |
|---|---|
| `THREADS` | CPU threads for quantization and imatrix. Default: `nproc`. |
| `HF_TOKEN` | Hugging Face access token, used by `hf download`. |

## Stages

| Stage | What it does |
|---|---|
| `setup` | Downloads `llama-<build>-bin-<asset>.tar.gz` from the llama.cpp GitHub releases, clones the same tag (shallow) for `convert_hf_to_gguf.py` and `gguf-py`, and creates a Python venv with the converter requirements and `huggingface_hub`. Skipped if an installation already exists. |
| `download` | Downloads the model repository with `hf download` into `hf/<NAME>/`. Interrupted downloads resume. |
| `convert` | Converts the checkpoint to `<NAME>-bf16.gguf` (without the MTP block when `MAIN_NO_MTP=yes` and the converter supports `--no-mtp`), then quantizes it to `<NAME>-<IMATRIX_SRC_TYPE>.gguf` for the imatrix run. |
| `mmproj` | Converts the vision projector to `mmproj-<NAME>-<type>.gguf` for each entry of `MMPROJ_TYPES`. Does nothing when the list is empty. |
| `imatrix` | Downloads the calibration text and runs `llama-imatrix` on the Q8_0 copy, producing `<NAME>.imatrix.gguf`. |
| `quant` | Runs `llama-quantize --imatrix` from the BF16 for each type in `QUANTS`, producing `<NAME>.<QUANT_TAG>-<type>.gguf`. |
| `mtp` | Downloads or builds the MTP head according to `MTP_MODE`. Does nothing when `MTP_MODE=none`. |
| `card` | Writes `gguf/README.md`, the model card for the Hugging Face repository (see [Model card](#model-card)). Does nothing when `CARD="no"`. |
| `show` | Prints the effective configuration. Also printed at the start of every run. |

## Configuration reference

`quantizer.conf` is **sourced as Bash**, so values are shell assignments and lists use `( ... )`. The variable `$WORK` (the working directory) is available inside it. Because it is executed, only use config files you wrote or trust.

### Model

| Variable | Default | Description |
|---|---|---|
| `REPO` | *(required)* | Hugging Face repository, as `owner/name` or a URL such as `https://huggingface.co/owner/name`. |
| `NAME` | *(required)* | Base name of every output file. |

### llama.cpp

| Variable | Default | Description |
|---|---|---|
| `LLAMA_BUILD` | `b12503` | Release tag to download. Must look like `bNNNNN`. |
| `LLAMA_ASSET` | `ubuntu-vulkan-x64` | Release package variant, as it appears in the asset name `llama-<build>-bin-<asset>.tar.gz` (for example `ubuntu-x64`). |
| `TOOLS_DIR` | `$WORK` | Where `llama-bin/`, `llama.cpp/`, `venv/` and the helper script live. Point several model folders at one directory to share them. |

### imatrix

| Variable | Default | Description |
|---|---|---|
| `IMATRIX_SRC_TYPE` | `q8_0` | Type of the model copy used to compute the imatrix. `q8_0` is faster than BF16 and gives practically the same matrix. |
| `IMATRIX_NGL` | `99` | Layers offloaded to the GPU by `llama-imatrix`. Lower it if VRAM runs out (for example `26` for a 9B Q8_0 on an 8 GB card). |
| `CALIB_URL` | bartowski's `calibration_datav3.txt` | Calibration text used for the imatrix. |

### Quants

| Variable | Default | Description |
|---|---|---|
| `QUANTS` | `(Q4_K_M)` in the script, full list in the template | Quant types passed to `llama-quantize`, in order. |
| `QUANT_TAG` | `i1` | Tag in the file name: `<NAME>.<QUANT_TAG>-<type>.gguf`. |

The template lists 24 types from `IQ1_S` to `Q6_K`. Very low-bit types (`IQ1_*`, `IQ2_*`) require an imatrix, which this pipeline always provides.

### Vision projector

| Variable | Default | Description |
|---|---|---|
| `MMPROJ_TYPES` | `()` | Output types for the mmproj, for example `(f16 q8_0)`. Empty means the model has no vision tower and the stage is skipped. |

The mmproj is produced by `convert_hf_to_gguf.py --mmproj`, not by `llama-quantize`, so every type is converted directly from the original weights.

### MTP head

| Variable | Default | Description |
|---|---|---|
| `MTP_MODE` | `none` | `none`, `download` or `build`. See [MTP head](#mtp-head). |
| `MTP_HEAD_REPO` | *(empty)* | Repository holding a ready-made head (`download` mode). |
| `MTP_HEAD_FILES` | `()` | Files to download (`download` mode). Each entry is a file name inside `MTP_HEAD_REPO`, or a full Hugging Face file URL (`https://huggingface.co/owner/repo/blob/<rev>/<file>`), in which case `MTP_HEAD_REPO` is not needed. |
| `MTP_BASE_REPO` | *(empty)* | Base model to take the `mtp.*` tensors from when the checkpoint has none (`build` mode). |
| `MTP_DONOR_TYPE` | `q8_0` | Output type of the donor GGUF (`build` mode). |
| `MAIN_NO_MTP` | `yes` | Keep the MTP block out of the main BF16 and quants. |

### Model card

| Variable | Default | Description |
|---|---|---|
| `CARD` | `yes` | `yes` or `no`. |
| `CARD_LICENSE` | *(empty)* | License id for the front matter. Empty means: take `license:` from the original model card, and omit it if there is none. |
| `CARD_TAGS` | `()` | Extra tags. `gguf`, `imatrix` and `llama.cpp` are always included. |
| `CARD_INCLUDE_ORIGINAL` | `yes` | Append the original model card (from the downloaded checkpoint, without its front matter) at the end. |
| `CARD_SCRIPT_URL` | *(empty)* | Link to the script's repository, shown under "How it was made". Empty means no link. The `--init` template and `quantizer.conf.example` set it to `https://github.com/nerun/imatrix-gguf-quantizer`. |
| `CARD_TEMPLATE` | *(empty)* | Path to a custom Markdown template. Empty means the built-in one. |

The `card` stage looks at which files exist in `gguf/` when it runs, so run it last (it is the last default stage) and rerun it after adding or removing files. Files that do not exist yet are left out of the tables, with a note on stderr.

The generated card has these parts: front matter (`library_name: gguf`, `license`, `base_model`, `base_model_relation: quantized`, `tags`), the file table sorted by size (the imatrix quants and the plain `IMATRIX_SRC_TYPE` copy, labelled "(no imatrix)", then the BF16 and the imatrix), the mmproj table, the MTP head table, a `llama-server` usage example, "How it was made", the license and the original model card. Sizes are shown as GiB with the decimal GB in parentheses.

**Custom template.** A template is any Markdown file that uses these placeholders; unknown placeholders are left as they are:

| Placeholder | Content |
|---|---|
| `{{FRONT_MATTER}}` | The YAML front matter, including the `---` lines. |
| `{{NAME}}`, `{{REPO}}`, `{{LLAMA_BUILD}}` | Values from the config. |
| `{{FILE_TABLE}}` | Table of quants, BF16 and imatrix. |
| `{{MMPROJ_SECTION}}`, `{{MTP_SECTION}}` | The mmproj and MTP head sections, empty when there are no such files. |
| `{{USAGE}}`, `{{HOW_MADE}}`, `{{LICENSE_SECTION}}` | The corresponding sections. `{{USAGE}}` ends with a note that the files need llama.cpp `LLAMA_BUILD` or newer. |
| `{{ORIGINAL_CARD}}` | The original model card section. |
| `{{MARKER}}` | The marker line described below. |

**Manual edits are never overwritten.** The generated file contains a marker comment (`<!-- generated by quantizer.sh; ... -->`). If `gguf/README.md` exists and the marker is gone, the script writes `gguf/README.generated.md` instead and says so. To take over a card by hand, delete the marker line.

## MTP head

Some models (for example the Qwen3.5 family) ship an MTP block that llama.cpp can use for speculative decoding (`--spec-type draft-mtp`). This script keeps the MTP block **out of the main quants** (`MAIN_NO_MTP=yes`) so it does not take part in the imatrix and the low-bit quantization, and produces it separately:

- **`download`**: fetches a ready-made head GGUF into `gguf/mtp-head/` and checks that it contains `nextn`/`mtp` tensors.
- **`build`**: converts a donor GGUF (`<NAME>-MTP-donor-<type>.gguf`: full model plus MTP block) with the converter's `--mtp` option when available. If the checkpoint has no `mtp.*` tensors, they are copied from `MTP_BASE_REPO` into a merged checkpoint first (`hf/<NAME>-mtp-merged/`, made of symlinks plus one extra safetensors file). The donor is then checked; if it has no MTP tensors, the script stops, since an older converter drops them silently.

**Grafting the head into the quants is not done by this script.** Copy the `blk.<N>.nextn.*` tensors and the MTP metadata from the head or donor into each quant with a GGUF grafting tool. Alternatively, load the head as a separate draft model with `--model-draft`.

## Output layout

```
<working directory>/
├── quantizer.sh
├── quantizer.conf
├── calibration.txt                         # calibration text for the imatrix
├── hf/
│   ├── <NAME>/                             # downloaded checkpoint
│   ├── <base>/                             # MTP shards of MTP_BASE_REPO (build mode only)
│   └── <NAME>-mtp-merged/                  # checkpoint + MTP tensors (build mode only)
├── gguf/
│   ├── <NAME>-bf16.gguf
│   ├── <NAME>-q8_0.gguf                    # imatrix source
│   ├── <NAME>.imatrix.gguf
│   ├── <NAME>.i1-IQ1_S.gguf ... <NAME>.i1-Q6_K.gguf
│   ├── mmproj-<NAME>-f16.gguf
│   ├── mmproj-<NAME>-q8_0.gguf
│   ├── README.md                           # model card (card stage)
│   ├── mtp-head/                           # download mode
│   └── <NAME>-MTP-donor-q8_0.gguf          # build mode
└── (TOOLS_DIR, by default the same directory)
    ├── llama-bin/                          # prebuilt binaries and libraries
    ├── llama.cpp/                          # shallow clone: converter and gguf-py
    ├── venv/                               # Python environment
    ├── mtp_tools.py                        # helper, rewritten on every run
    ├── .llama_tag                          # installed build
    └── .llama_bin                          # path of the binaries
```

The BF16, the Q8_0 copy and the downloaded checkpoint are only needed while working; delete them once you are done to free space.

## Interrupting and resuming

You can stop the script at any time with Ctrl+C and start it again with the same command.

- Every output is first written as `.part-<file name>` in the same folder and renamed to its final name only when the command that produces it succeeds. A file with its final name is therefore always complete, and it is skipped (`skip <file>`) on the next run.
- On Ctrl+C or an error, the unfinished `.part-` file is deleted.
- The interrupted step restarts from the beginning; `llama-quantize`, `llama-imatrix` and the converter cannot resume halfway. For a single quant this costs a few minutes; for the imatrix it can cost more.
- Model downloads (`hf download`) resume where they stopped.

To redo a finished file, delete it and run the script again.

## Examples

### A text-only model without MTP

```bash
REPO="https://huggingface.co/someone/Some-Model-8B"
NAME="Some-Model-8B"
MMPROJ_TYPES=()
MTP_MODE="none"
QUANTS=(Q4_K_M Q5_K_M Q6_K)
```

### A vision model with a ready-made MTP head

```bash
REPO="empero-ai/Qwen3.8-9B-Distill"
NAME="Qwen3.8-9B-Distill"
IMATRIX_NGL=26
MMPROJ_TYPES=(f16 q8_0)
MTP_MODE="download"
MTP_HEAD_REPO="srmiles/Qwen3.8-9B-Distill-MTP-GGUF"
MTP_HEAD_FILES=(
    mtp-Qwen3.8-9B-Distill-head-BF16.gguf
    mtp-Qwen3.8-9B-Distill-head-Q8_0.gguf
)
```

### Building the MTP donor, borrowing the head from the base model

```bash
MTP_MODE="build"
MTP_BASE_REPO="Qwen/Qwen3.5-9B"
MTP_DONOR_TYPE="q8_0"
```

### Sharing one llama.cpp installation between models

In each model's `quantizer.conf`:

```bash
TOOLS_DIR="$HOME/.cache/quantizer"
```

The first run downloads llama.cpp and creates the venv there; later runs in other folders reuse them.

### CPU only

```bash
LLAMA_ASSET="ubuntu-x64"
IMATRIX_NGL=0
```

## Troubleshooting

**`config not found`**
Run the script from the folder that holds `quantizer.conf`, pass `--config`, or create one with `--init`.

**`llama.cpp bXXXXX is installed ... but bYYYYY was requested`**
The installed build differs from `LLAMA_BUILD` or `--llama-build`. The script never replaces an installation by itself: either set `LLAMA_BUILD` to the installed build, or delete `llama-bin/`, `llama.cpp/` and `.llama_tag` in `TOOLS_DIR` and run `setup` again.

**`llama-quantize does not run (missing libs?)`**
The release binaries need their bundled libraries (the script sets `LD_LIBRARY_PATH` for that) and, for Vulkan builds, the Vulkan loader (`libvulkan1`). Install it, or switch to `LLAMA_ASSET="ubuntu-x64"`.

**`curl: (22) ... 404` during setup**
The build or asset name does not exist. Check the asset list on the [llama.cpp releases page](https://github.com/ggml-org/llama.cpp/releases) and adjust `LLAMA_BUILD` or `LLAMA_ASSET`.

**Out of memory in `llama-imatrix`**
Lower `IMATRIX_NGL`.

**`The BPE pre-tokenizer was not recognized` or an unknown architecture in the converter**
The converter in the pinned build does not support this model. Use a newer `LLAMA_BUILD` (delete the old installation first, as above).

**`donor has no MTP/nextn tensors`**
The converter of the pinned build does not export MTP for this architecture. Use a newer build or `MTP_MODE="download"`.

**`... has no mtp.* tensors and MTP_BASE_REPO is not set`**
`MTP_MODE="build"` needs either MTP tensors in the checkpoint or a base model to take them from.

**Leftover `.part-*` files**
Only possible after a hard kill or power loss. They are overwritten on the next run, and can be deleted safely.

## Notes and limitations

- The MTP logic (`--no-mtp`/`--mtp`, the `mtp.*` tensor names, the graft into a merged checkpoint) was written for the Qwen3.5 family. For other architectures, use `MTP_MODE="none"` unless you know the converter handles their MTP the same way.
- The script does not graft the MTP head into the quants, and it does not upload anything to Hugging Face.
- Only Hugging Face safetensors checkpoints that `convert_hf_to_gguf.py` supports can be converted.
- `quantizer.conf` is executed as Bash. Do not use config files from untrusted sources.

## License

Copyright (c) 2026 Daniel Dias Rodrigues (a.k.a. "Nerun")

Released under the [MIT License](LICENSE).

This license covers the script and its documentation only. Models, GGUF files and calibration data processed with it keep their own licenses.
