# Bundled whisper.cpp

This checkout carries an **arm64** macOS 13+ build of whisper.cpp **v1.8.2**,
upstream commit `4979e04f5dcaccb36057e059bbaed8a2f5288315`, with a narrow CPU
cancellation patch. It is not a universal binary. The public `whisper.h` matches
that upstream commit byte for byte (SHA-256
`0525b758571ab71c00ddd8ea2845f74af7c62dfa5100c5586655f75bdc5ef4be`).

`lib/` contains `libwhisper.dylib`, its two versioned aliases, and five retained
ggml libraries: base, CPU, BLAS, Metal and the backend registry. The aliases are
regular copies. Swift uses `module.modulemap` and the headers under `include/`.
Packaged apps resolve libraries from `Contents/lib`; release verification must
reject developer-directory runtime paths. Models are selected/downloaded by the
app and stored outside the application bundle.

## CPU cancellation repair

[`patches/v1.8.2-cancellable-cpu-graphs.patch`](patches/v1.8.2-cancellable-cpu-graphs.patch)
passes the owned abort token into each scheduled encoder/decoder graph and the
private language-detection path. A scoped cleanup clears borrowed backend
callbacks only after synchronous graph execution has joined. The public ABI and
uncancelled graph operations stay unchanged.

The CPU backend checks cancellation between graph nodes. An individual BLAS
operation and external encoders remain noninterruptible. The generic registry
does not expose Metal cancellation; this patch does not establish Metal support
or a worst-case bound for every model and input.

On 19 October the real small-model tests joined cancellation in 0.0076 s with
English selected and 0.0625 s during automatic language detection, then reused
the model successfully. The unpatched English case took 12.233 s. Full text,
timed words and spans on both uncancelled authored regressions were unchanged.
See [the recovery ledger](../../docs/recovery-20261019.md) for limits and receipts.

## Rebuild the patched library

Use an isolated source/build directory. Verify the exact upstream commit, apply
the versioned patch with `git apply --check` followed by `git apply`, then build:

```sh
cmake -S . -B build-retrace \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 -DBUILD_SHARED_LIBS=ON \
  -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=OFF \
  -DWHISPER_COREML=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON \
  -DGGML_BLAS=ON -DGGML_BLAS_VENDOR=Apple -DGGML_OPENMP=OFF
cmake --build build-retrace --config Release --parallel 2
```

Copy only `build-retrace/src/libwhisper.1.8.2.dylib` to a private staging location.
Remove all three absolute build rpaths (`ggml/src`, `ggml/src/ggml-blas`, and
`ggml/src/ggml-metal`) with `install_name_tool -delete_rpath`, then add
`@loader_path` using `-add_rpath`. Ad-hoc sign the staged binary for local native
tests. Confirm `otool -l` reports only `@loader_path` and `otool -L` retains the
same ggml dependency names. Do not promote newly rebuilt ggml backends as part
of this repair. Copy the verified native payload to all three vendored Whisper
names; packaging copies `libwhisper.1.dylib` and re-signs it before the app.

The normalized, ad-hoc-signed payload tested for this repair has SHA-256
`8afb4558cb047ffced1b58e063b13b943c076118fc9ca21baa15e4afeb2ac35a`.
Developer ID signing changes its file hash; retain both hashes in the release
receipt. Compiler/signing differences can change hashes on a rebuild, so new
payloads require their own native validation.

Run `WhisperModelResidencyTests` with `RETRACE_TEST_DISABLE_FILE_LOGGING=1` and
an explicit `RETRACE_WHISPER_WORD_TEST_MODEL_PATH`. The tests use authored audio,
cover English/automatic-language cancellation and reuse, and verify timed-word
coverage. A suite that skips these tests is not native cancellation acceptance.

## License

The upstream MIT license is retained in [LICENSE](LICENSE) and must accompany
redistributed libraries. Upstream: https://github.com/ggml-org/whisper.cpp.
