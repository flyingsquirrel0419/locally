# Security

Threat model, mitigations, and residual risks for Locally. Every claim
references the source that implements it.

## Threat model

The app downloads model artifacts from Hugging Face and loads them into
native inference libraries (llama.cpp, MLX, Core ML). The adversaries we
design against:

1. **Malicious repository or model file** — a repo whose config, GGUF
   header, ZIP archive, or weights are crafted to crash, corrupt, or
   escape the app sandbox.
2. **Token theft** — the user's Hugging Face access token leaking via
   logs, crash reports, redirects, or on-disk persistence.
3. **Man-in-the-middle** — a network attacker substituting model bytes or
   API responses.
4. **Path traversal** — a remote file path (`../../...`, absolute paths,
   drive letters) that writes outside the model directory.
5. **Zip bombs / archive abuse** — tiny archives that expand to fill the
   disk, symlink entries, or hostile compression methods.
6. **Resource exhaustion** — oversized JSON/config/GGUF metadata that OOMs
   the parser, or downloads that exhaust storage.

## Mitigations

### No code execution from repositories

- Repository code is never executed. `trust_remote_code` style configs are
  detected (`ModelConfig.requiresRemoteCode`, via `auto_map` /
  custom `quant_method`, in `Sources/LocallyHF/ModelConfig.swift`), flagged
  into descriptor metadata (`RepositoryAnalyzer.swift`), and reported as
  unsupported by `CompatibilityEngine` (`Sources/LocallyCompatibility/
  CompatibilityEngine.swift`) — such models are refused, never run.
- No `Process`, `system`, `posix_spawn`, or `dlopen` of downloaded files
  anywhere in `Sources/` or `App/`. The one `dlopen` call
  (`Sources/LocallyDevice/SystemDeviceProfiler.swift`) is `dlopen(nil, …)`
  plus `dlsym("os_proc_available_memory")` — the process's own image and a
  system symbol only.
- Model files are treated as data. GGUF files are parsed by our own bounds-
  checked parser (`Sources/LocallyCore/GGUFParser.swift`) with hard caps
  (`maxKVCount` 1,000,000, `maxStringLength` 16 MiB, array-length caps)
  *before* llama.cpp ever opens the file; a hostile header fails closed.

### Token handling (Keychain only, never logged)

- Token persistence is Keychain-only on Apple platforms
  (`KeychainTokenStore`, `Sources/LocallyHF/TokenStore.swift`), with
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — never migrated to a
  new device via backup. Tests/Linux use a volatile in-memory store.
- The token is read fresh at request time (`ModelInstallService
  .authorizationHeader(for:)`) and attached only to hosts in the allowlist
  (`RedirectPolicy.allowedHFHosts` = huggingface.co, hf.co + subdomains,
  exact-or-subdomain match so `evilhuggingface.co` fails).
- The token is never logged, never in UserDefaults, never written to a
  file, never placed in a URL. `Log` (`Sources/LocallyCore/Log.swift`)
  documents this and the download layer logs only error descriptions, never
  request headers.

### HTTPS-only, redirect auth stripping

- All HF endpoints are HTTPS. `HFClient.get` rejects non-HTTPS URLs and
  non-allowlisted hosts before issuing a request.
- Every transport sanitizes redirects through
  `RedirectPolicy.sanitize(request:original:)`
  (`Sources/LocallyCore/RedirectPolicy.swift`), which strips the
  `Authorization` header when the redirect target leaves the allowed host
  set and refuses non-HTTPS redirects outright. Applied in all three
  transports: `URLSessionTransport` (HF API), `FoundationURLSessionTransport`
  (Linux/macOS downloads), `URLSessionBackgroundTransport` (iOS background
  downloads).

### Download integrity and disk safety

- Download URLs are constructed by the app from repo ID + revision +
  sanitized relative path (`ModelInstallService.sources(for:revision:)`),
  never taken from remote data.
- Every repo-relative path passes `PathSanitizer.sanitizeRepoPath`
  (rejects `..`, `.`, absolute paths, backslashes, NUL, empty components)
  and is re-validated against the destination root with
  `PathSanitizer.resolveUnder(base:relative:)`.
- When the HF API provides an LFS SHA-256, the downloaded bytes are
  verified against it (`DownloadManager`, streaming SHA-256 in
  `Sources/LocallyStorage/StreamingSHA256.swift`); a mismatch fails the
  file as corrupted.
- A storage preflight re-checks free space before every file with
  headroom of max(512 MB, 5%) (`DownloadManager.startFile`).

### Archive (ZIP) safety

Core ML `.mlmodelc` bundles arrive as ZIPs. `ZIPExtractionPlan`
(`Sources/LocallyStorage/Archive/ZIPExtractor.swift`) validates the whole
central directory before any byte is inflated or written:

- entry names pass `PathSanitizer` (traversal, drive letters rejected)
- symlink entries, encrypted entries, and non-store/non-deflate methods
  are rejected
- caps: 5,000 entries, 16 GiB total uncompressed, 8 GiB per entry,
  1000:1 max deflate ratio (zip-bomb guard)
- extraction streams in 512 KiB chunks with CRC-32 and exact-size
  verification per entry; the archive is never fully loaded into memory.

### Input size caps

- Small remote files (config.json, README) are fetched with a 4 MiB cap
  via HTTP Range and rejected if the server ignores it
  (`HFClient.fetchSmallFile`).
- GGUF header caps as above. Decision-schema inputs have hard limits on
  document bytes, state length, question count, and option count
  (`Sources/LocallyRuntime/Decision/DecisionSchema.swift`).
- Images are downsampled from the source before decode
  (`VLMRuntime.downsampledCIImage`), capped at 1536 px on the long edge;
  multi-image requests are capped per architecture
  (`VLMTypeRegistry.maxImagesPerRequest`).

## Residual risks

- **Weights parsing bugs in native libraries.** llama.cpp/MLX/Core ML
  parse complex binary formats; a malformed tensor file could trigger a
  native bug below our Swift validation layer. Mitigated only by pinning
  and updating dependencies (see DEPENDENCIES.md). The GGUF header
  pre-parse reduces, but does not eliminate, this surface.
- **SHA-256 availability.** Integrity verification applies only when HF
  publishes an LFS hash for the file; non-LFS files are size-checked only.
- **Model output is untrusted content.** Generated text is shown to the
  user but never executed; nonetheless, prompt-injection via model files
  or card data could produce misleading UI text.
- **Keychain strength is platform-provided**; a jailbroken device can
  extract Keychain items regardless of accessibility class.
- **Memory-pressure race**: a model that grows between load-time budget
  check and steady-state decode can still trigger jetsam before the
  policy observer reacts.

## Reporting

Report vulnerabilities privately to the maintainers (repository issue
tracker with a "security" prefix, or the contact in the repository
profile). Do not attach exploit model files to public issues.
