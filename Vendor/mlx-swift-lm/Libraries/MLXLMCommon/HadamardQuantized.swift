// Copyright © 2026 Apple Inc.

import Foundation
import MLX
import MLXNN

// MARK: - Rotation

/// A signed, blockwise Walsh–Hadamard rotation `R = H·S / √n` of an array's last axis.
///
/// `H` is the Sylvester Hadamard matrix of order `n`, the block size, and `S` is a diagonal of
/// ±1 signs. The transform runs in float32 and returns the input's dtype, like the reference.
public struct SignedBlockHadamard: Sendable, Equatable {

    /// Elements per Hadamard block along the last axis. A power of two.
    public let blockSize: Int

    private let scale: Float

    /// Creates a rotation over blocks of `blockSize` elements.
    public init(blockSize: Int) {
        precondition(Self.isValidBlockSize(blockSize), "blockSize must be a power of two")
        self.blockSize = blockSize
        self.scale = 1 / Float(blockSize).squareRoot()
    }

    /// Whether `blockSize` is a positive power of two, the only order Sylvester's construction
    /// defines.
    public static func isValidBlockSize(_ blockSize: Int) -> Bool {
        blockSize > 0 && blockSize & (blockSize - 1) == 0
    }

    /// `R·x` along the last axis: flip signs, then transform each block.
    public func forward(_ x: MLXArray, signs: MLXArray) -> MLXArray {
        transform(x.asType(.float32) * signs).asType(x.dtype)
    }

    /// `Rᵀ·x` along the last axis: transform each block, then flip signs.
    public func inverse(_ x: MLXArray, signs: MLXArray) -> MLXArray {
        (transform(x.asType(.float32)) * signs).asType(x.dtype)
    }

    private func transform(_ x: MLXArray) -> MLXArray {
        precondition(x.dim(-1) % blockSize == 0, "last axis must be a multiple of blockSize")
        let shape = x.shape
        return hadamardTransform(x.reshaped(-1, blockSize), scale: scale).reshaped(shape)
    }

    /// The two steps of ``forward(_:signs:)`` apart: the input with its signs flipped, in
    /// float32, and that transformed, in the input's dtype.
    func forwardSteps(_ x: MLXArray, signs: MLXArray) -> (signed: MLXArray, rotated: MLXArray) {
        let signed = x.asType(.float32) * signs
        return (signed, transform(signed).asType(x.dtype))
    }

    /// The sum of the rotated input over each run of `groupSize` elements, from the input
    /// before it is transformed. Nil when the runs do not divide the blocks evenly.
    ///
    /// A Sylvester matrix of order `n = q·g` is one of order `q` with each entry a matrix of order
    /// `g`, and every column of a Hadamard matrix but its first sums to nothing. So the sum of
    /// the transform over a run of `g` rows keeps only every `g`-th input, and is a transform of
    /// order `q` of those: 32 numbers in place of 4,096.
    func groupSums(ofSigned signed: MLXArray, groupSize: Int) -> MLXArray? {
        guard blockSize % groupSize == 0, Self.isValidBlockSize(groupSize), signed.dtype == .float32 else { return nil }
        let width = signed.dim(-1)
        let groups = width / groupSize
        let shape = Array(signed.shape.dropLast()) + [groups]
        let count = shape.reduce(1, *)
        return Self.sums(
            [signed, MLXArray(Float(groupSize) * scale)],
            template: [("IN", width), ("GROUPS", groups), ("RUNS", blockSize / groupSize), ("GROUP", groupSize)],
            grid: (count, 1, 1), threadGroup: (min(256, count), 1, 1),
            outputShapes: [shape], outputDTypes: [.float32])[0]
    }

    /// One step for the lot: picking out every `GROUP`-th input and transforming them apart
    /// took two, and a step costs more than this arithmetic.
    private static let sums = MLXFast.metalKernel(
        name: "resident_group_sums",
        inputNames: ["inp", "factor"],
        outputNames: ["out"],
        source: """
            uint elem = thread_position_in_grid.x;
            uint g = elem % GROUPS;
            uint a = g % RUNS;
            uint first = (elem / GROUPS) * IN + (g - a) * GROUP;
            float m = 0.0f;
            for (uint c = 0; c < RUNS; c++) {
                float v = inp[first + c * GROUP];
                m += (popcount(a & c) & 1u) ? -v : v;
            }
            out[elem] = m * factor;
            """)
}

// MARK: - Layers

/// A `QuantizedLinear` whose weights were quantized in a rotated input basis.
///
/// The forward pass rotates the input with ``SignedBlockHadamard/forward(_:signs:)`` before the
/// packed matmul. `signs` loads from the checkpoint like any other parameter.
open class HadamardQuantizedLinear: QuantizedLinear {

    /// The rotation folded into `weight`.
    public let rotation: SignedBlockHadamard

    /// The rotation's ±1 signs, one per input feature.
    public let signs: MLXArray

    /// Creates the layer from a checkpoint's packed arrays.
    public init(
        weight: MLXArray, bias: MLXArray? = nil, scales: MLXArray, biases: MLXArray?,
        signs: MLXArray, groupSize: Int, bits: Int, mode: QuantizationMode = .affine,
        rotation: SignedBlockHadamard
    ) {
        self.rotation = rotation
        self.signs = signs
        super.init(
            weight: weight, bias: bias, scales: scales, biases: biases, groupSize: groupSize,
            bits: bits, mode: mode)
        freeze()
    }

    /// A placeholder shaped like the checkpoint's arrays, which the loader fills.
    public convenience init(
        replacing linear: Linear, groupSize: Int, bits: Int, mode: QuantizationMode = .affine,
        rotation: SignedBlockHadamard
    ) {
        let (outputs, inputs) = linear.shape
        let groups = inputs / groupSize
        self.init(
            weight: MLXArray.zeros([outputs, inputs * bits / 32], dtype: .uint32),
            bias: linear.bias,
            scales: MLXArray.zeros([outputs, groups], dtype: .float16),
            biases: mode == .affine ? MLXArray.zeros([outputs, groups], dtype: .float16) : nil,
            signs: MLXArray.ones([inputs], dtype: .float32),
            groupSize: groupSize, bits: bits, mode: mode, rotation: rotation)
    }

    open override func callAsFunction(_ x: MLXArray) -> MLXArray {
        let (signed, rotated) = rotatedInput(x)
        let groups = scales.dim(-1)
        guard Self.sharesScales, mode == .affine, let path, Self.mirrored.contains(path),
            rotation.blockSize % groupSize == 0, SignedBlockHadamard.isValidBlockSize(groupSize),
            x.dim(-1) == groups * groupSize
        else {
            return super.callAsFunction(rotated)
        }
        // The packed matmul gives, for each output, the sum over groups of
        //     scale * (codes . x) + bias * sum(x)
        // With the scales standing in for the biases that is the wanted value plus twice
        // `scale * sum(x)` over the groups, which is then taken off.
        let packed = quantizedMM(
            rotated, weight, scales: scales, biases: scales, transpose: true,
            groupSize: groupSize, bits: bits, mode: mode)
        let positions = rotated.shape.dropLast().reduce(1, *)
        let sums = groupSums(x, signed: signed)
        var result = Self.corrected(packed, sums: sums, scales: scales)
        if Self.checksAgainstBiases, positions > 1, let biases {
            let reference = quantizedMM(
                rotated, weight, scales: scales, biases: biases, transpose: true,
                groupSize: groupSize, bits: bits, mode: mode
            ).asType(.float32)
            let plain = addMM(packed, sums.asType(packed.dtype), scales.T, alpha: -2, beta: 1).asType(.float32)
            let size = abs(reference).max() + 1e-9
            let off = stacked([abs(result.asType(.float32) - reference).max() / size, abs(plain - reference).max() / size])
                .asArray(Float.self)
            Self.largestDifference = max(Self.largestDifference, off[0])
            Self.largestPlainDifference = max(Self.largestPlainDifference, off[1])
            Self.differenceCount += 1
            Self.differenceSum += Double(off[0])
        }
        if let bias { result = result + bias }
        return result
    }

    // MARK: Resident: one rotation for layers given the same input

    /// The input with its signs flipped and that rotated, from the last layer with the same signs
    /// that was given this very array if there is one.
    ///
    /// A pack has one sign vector for each width, and layers side by side are given the same
    /// array: the three projections of an attention layer, the two inner ones of the feed-forward
    /// layer. Each rotated it for itself, four steps on the GPU each time, for the same result.
    /// A step costs much the same whatever its size, so on a model of a few hundred layers the
    /// steps saved are a tenth of the time a token takes.
    private func rotatedInput(_ x: MLXArray) -> (signed: MLXArray, rotated: MLXArray) {
        guard Self.sharesRotations, let path, let signs = Self.signClasses[path] else {
            return rotation.forwardSteps(x, signs: self.signs)
        }
        Self.rotationLock.lock()
        defer { Self.rotationLock.unlock() }
        // The array itself and what it holds: an array written to in place is the same object.
        if let last = Self.lastRotations[signs], last.input === x, last.handle == x.ctx.ctx,
            last.blockSize == rotation.blockSize
        {
            return (last.signed, last.rotated)
        }
        let steps = rotation.forwardSteps(x, signs: self.signs)
        Self.lastRotations[signs] = LastRotation(
            input: x, handle: x.ctx.ctx, blockSize: rotation.blockSize, signed: steps.signed, rotated: steps.rotated)
        return steps
    }

    /// The sum of the rotated input over each group, shared like the rotation it comes from.
    private func groupSums(_ x: MLXArray, signed: MLXArray) -> MLXArray {
        guard Self.sharesRotations, let path, let signs = Self.signClasses[path] else {
            return rotation.groupSums(ofSigned: signed, groupSize: groupSize)!
        }
        Self.rotationLock.lock()
        defer { Self.rotationLock.unlock() }
        if let last = Self.lastRotations[signs], last.input === x, last.handle == x.ctx.ctx,
            last.blockSize == rotation.blockSize, last.groupSize == groupSize, let sums = last.sums
        {
            return sums
        }
        let sums = rotation.groupSums(ofSigned: signed, groupSize: groupSize)!
        if var last = Self.lastRotations[signs], last.input === x, last.handle == x.ctx.ctx {
            last.sums = sums
            last.groupSize = groupSize
            Self.lastRotations[signs] = last
        }
        return sums
    }

    private struct LastRotation {
        let input: MLXArray
        let handle: UnsafeMutableRawPointer?
        let blockSize: Int
        let signed: MLXArray
        let rotated: MLXArray
        var sums: MLXArray?
        var groupSize = 0
    }

    /// Lets go of the arrays kept from the last layers that ran, when their model is unloaded.
    public static func forgetRotations() {
        rotationLock.lock()
        lastRotations = [:]
        rotationLock.unlock()
    }

    /// Off with `HARNESS_SHARE_ROTATIONS=0`, to measure what it saves.
    nonisolated(unsafe) public static var sharesRotations = ProcessInfo.processInfo.environment["HARNESS_SHARE_ROTATIONS"] != "0"
    nonisolated(unsafe) private static var lastRotations: [Int: LastRotation] = [:]
    private static let rotationLock = NSLock()
    /// Which sign vector each layer has, by where the layer is: layers with the same number have the same signs.
    nonisolated(unsafe) static var signClasses: [String: Int] = [:]

    // MARK: Resident: without the biases

    /// Computes a layer without reading its biases, when they are its scales negated.
    ///
    /// A ternary pack stores each weight as a code of 0, 1 or 2 with a scale and a bias for
    /// every group of weights, and the weight is `scale * code + bias`. For the values to be
    /// minus the scale, zero and plus the scale, the bias is always minus the scale: a tenth of
    /// the file that says nothing the scales do not. Read on every token like the rest, it is
    /// 420 MB of a 27B model that has to stay in memory. On a phone where the model fills the
    /// memory, that is the difference between every token waiting on storage and none.
    ///
    /// Off unless something turns it on before a model is loaded. Each layer's arrays are
    /// checked when the model loads (``HadamardQuantizedCheckpointPolicy/prepare(_:)``), and one
    /// whose biases are anything else is computed the ordinary way.
    nonisolated(unsafe) public static var sharesScales =
        ["1", "check"].contains(ProcessInfo.processInfo.environment["HARNESS_SHARE_SCALES"] ?? "")

    /// Where the layer is in the model, which is how what was found at load reaches it.
    var path: String?

    /// The layers whose biases were found to be exactly their scales negated.
    nonisolated(unsafe) static var mirrored: Set<String> = []

    /// `packed - 2 * (scales . sums)` for every position, where `sums` is the sum of the rotated
    /// input over each group (``SignedBlockHadamard/groupSums(ofSigned:groupSize:)``).
    ///
    /// One kernel, because a matmul of this shape (thousands of rows by a few dozen columns)
    /// cost as much again as the packed one it follows.
    private static func corrected(_ packed: MLXArray, sums: MLXArray, scales: MLXArray) -> MLXArray {
        let count = packed.size
        return correction(
            [packed, sums, scales],
            template: [("T", packed.dtype), ("OUT", scales.dim(0)), ("GROUPS", scales.dim(-1))],
            grid: (count, 1, 1), threadGroup: (min(256, count), 1, 1),
            outputShapes: [packed.shape], outputDTypes: [packed.dtype])[0]
    }

    private static let correction = MLXFast.metalKernel(
        name: "resident_ternary_correction",
        inputNames: ["packed", "sums", "scales"],
        outputNames: ["out"],
        source: """
            uint elem = thread_position_in_grid.x;
            uint row = elem % OUT;
            uint position = (elem / OUT) * GROUPS;
            float total = 0.0f;
            for (uint g = 0; g < GROUPS; g++) {
                total += float(scales[row * GROUPS + g]) * float(sums[position + g]);
            }
            out[elem] = T(float(packed[elem]) - 2.0f * total);
            """)

    /// Development aid: `HARNESS_SHARE_SCALES=check` also computes each layer the ordinary way
    /// while a prompt is read, and records how far the two are apart as a share of the largest value.
    static let checksAgainstBiases = ProcessInfo.processInfo.environment["HARNESS_SHARE_SCALES"] == "check"
    nonisolated(unsafe) public static var largestDifference: Float = 0
    nonisolated(unsafe) public static var largestPlainDifference: Float = 0
    nonisolated(unsafe) public static var differenceSum: Double = 0
    nonisolated(unsafe) public static var differenceCount = 0
}

/// A `QuantizedEmbedding` whose rows were quantized in a rotated basis.
///
/// Lookup un-rotates the dequantized rows. ``asLinear(_:)`` rotates its input before the packed
/// matmul, so a tied head shares the table as it would an unrotated `QuantizedEmbedding`.
open class HadamardQuantizedEmbedding: QuantizedEmbedding {

    /// The rotation's ±1 signs, one per embedding dimension.
    public let signs: MLXArray

    /// The rotation folded into `weight`.
    public let rotation: SignedBlockHadamard

    /// A placeholder shaped like the checkpoint's arrays, which the loader fills.
    ///
    /// The table quantizes lazily and is never evaluated, as in the loader's own quantize pass.
    public init(
        replacing embedding: Embedding, groupSize: Int, bits: Int,
        mode: QuantizationMode = .affine, rotation: SignedBlockHadamard
    ) {
        self.signs = MLXArray.ones([embedding.shape.1], dtype: .float32)
        self.rotation = rotation
        super.init(weight: embedding.weight, groupSize: groupSize, bits: bits, mode: mode)
        freeze()
    }

    open override func callAsFunction(_ x: MLXArray) -> MLXArray {
        rotation.inverse(super.callAsFunction(x), signs: signs)
    }

    open override func asLinear(_ x: MLXArray) -> MLXArray {
        super.asLinear(rotation.forward(x, signs: signs))
    }
}

// MARK: - Manifest

/// One module of a rotated checkpoint's manifest.
public struct HadamardQuantizedModule: Codable, Sendable, Equatable {

    /// The module's path relative to the language model, as `config.json` names it.
    public var path: String

    /// The Hadamard block size folded into this module's weights.
    public var block: Int

    /// Whether the module is an embedding table rather than a linear layer.
    public var embedding: Bool

    /// The activation dtype the module was packed for, such as `"float16"`.
    public var dtype: String?

    /// Creates a manifest entry.
    public init(path: String, block: Int, embedding: Bool = false, dtype: String? = nil) {
        self.path = path
        self.block = block
        self.embedding = embedding
        self.dtype = dtype
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        block = try container.decode(Int.self, forKey: .block)
        embedding = try container.decodeIfPresent(Bool.self, forKey: .embedding) ?? false
        dtype = try container.decodeIfPresent(String.self, forKey: .dtype)
    }
}

/// A rotated checkpoint's manifest in `config.json`: the modules that carry a folded rotation
/// and the quantization they share.
///
/// The keys follow the pack format PrismML ships. The base model's configuration sits beside
/// them in the same file.
public struct HadamardQuantizedManifest: Codable, Sendable {

    /// The manifest schema this implementation reads.
    public static let supportedSchemaVersion = 2

    /// The pack's schema version.
    public var schemaVersion: Int

    /// The `model_type` of the architecture the checkpoint runs.
    public var baseModelType: String?

    /// The tensor naming the pack uses, which fixes the module paths.
    public var tensorNamespace: String?

    /// How gated-delta activations are ordered; only `"grouped"` loads without a permutation.
    public var gdnActivationLayout: String?

    /// The modules whose weights carry a folded rotation.
    public var modules: [HadamardQuantizedModule]

    /// The quantization every manifest module shares.
    public var quantization: BaseConfiguration.Quantization

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case baseModelType = "base_model_type"
        case tensorNamespace = "tensor_namespace"
        case gdnActivationLayout = "gdn_activation_layout"
        case modules
        case quantization
    }

    /// Creates a manifest.
    public init(
        schemaVersion: Int = HadamardQuantizedManifest.supportedSchemaVersion,
        baseModelType: String? = nil, tensorNamespace: String? = nil,
        gdnActivationLayout: String? = nil, modules: [HadamardQuantizedModule],
        quantization: BaseConfiguration.Quantization
    ) {
        self.schemaVersion = schemaVersion
        self.baseModelType = baseModelType
        self.tensorNamespace = tensorNamespace
        self.gdnActivationLayout = gdnActivationLayout
        self.modules = modules
        self.quantization = quantization
    }

    func validate(baseModelType expectedType: String, tensorNamespace expectedNamespace: String)
        throws
    {
        guard schemaVersion == Self.supportedSchemaVersion else {
            throw HadamardQuantizedCheckpointError.unsupportedSchemaVersion(schemaVersion)
        }
        guard baseModelType == expectedType else {
            throw HadamardQuantizedCheckpointError.unsupportedBaseModelType(
                baseModelType, expected: expectedType)
        }
        guard tensorNamespace == expectedNamespace else {
            throw HadamardQuantizedCheckpointError.unsupportedTensorNamespace(
                tensorNamespace, expected: expectedNamespace)
        }
        if let layout = gdnActivationLayout, layout != "grouped" {
            throw HadamardQuantizedCheckpointError.unsupportedActivationLayout(layout)
        }
        guard !modules.isEmpty else {
            throw HadamardQuantizedCheckpointError.emptyManifest
        }
        var paths = Set<String>()
        for module in modules where !paths.insert(module.path).inserted {
            throw HadamardQuantizedCheckpointError.duplicateModule(module.path)
        }
        _ = try activationDType()
    }

    /// The one half-precision dtype the declaring entries agree on, or `nil` if none declares one.
    func activationDType() throws -> DType? {
        let declared = Set(modules.compactMap(\.dtype))
        guard let name = declared.first else { return nil }
        guard declared.count == 1 else {
            throw HadamardQuantizedCheckpointError.mixedActivationDTypes(declared.sorted())
        }
        switch name {
        case "float16": return .float16
        case "bfloat16": return .bfloat16
        default: throw HadamardQuantizedCheckpointError.unsupportedActivationDType(name)
        }
    }
}

/// Why a rotated checkpoint cannot be loaded.
public enum HadamardQuantizedCheckpointError: LocalizedError, Equatable {
    case unsupportedSchemaVersion(Int)
    case unsupportedBaseModelType(String?, expected: String)
    case unsupportedTensorNamespace(String?, expected: String)
    case unsupportedActivationLayout(String)
    case emptyManifest
    case duplicateModule(String)
    case mixedActivationDTypes([String])
    case unsupportedActivationDType(String)
    case moduleNotFound(String)
    case moduleNotSubstitutable(String, found: String)
    case unsupportedBlockSize(String, block: Int, width: Int)
    case invalidSigns(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let version):
            "Rotated checkpoint schema_version \(version) is not supported "
                + "(expected \(HadamardQuantizedManifest.supportedSchemaVersion))."
        case .unsupportedBaseModelType(let type, let expected):
            "Rotated checkpoint base_model_type \(type ?? "nil") is not \(expected)."
        case .unsupportedTensorNamespace(let namespace, let expected):
            "Rotated checkpoint tensor_namespace \(namespace ?? "nil") is not \(expected)."
        case .unsupportedActivationLayout(let layout):
            "Rotated checkpoint gdn_activation_layout \(layout) needs a permutation "
                + "this loader does not apply."
        case .emptyManifest:
            "Rotated checkpoint declares no modules."
        case .duplicateModule(let path):
            "Rotated checkpoint lists module \(path) more than once."
        case .mixedActivationDTypes(let names):
            "Rotated checkpoint modules disagree on their activation dtype: "
                + names.joined(separator: ", ") + "."
        case .unsupportedActivationDType(let name):
            "Rotated checkpoint activation dtype \(name) is not supported "
                + "(expected float16 or bfloat16)."
        case .moduleNotFound(let path):
            "Rotated checkpoint names a module the model does not have: \(path)."
        case .moduleNotSubstitutable(let path, let found):
            "Rotated checkpoint module \(path) is a \(found), not a plain Linear or Embedding."
        case .unsupportedBlockSize(let path, let block, let width):
            "Rotated checkpoint module \(path) declares block \(block) for input width \(width); "
                + "a block must be a power of two that divides the width."
        case .invalidSigns(let path):
            "Rotated checkpoint module \(path) has signs other than -1 and +1."
        }
    }
}

// MARK: - Checkpoint policy

/// How a model loads a rotated checkpoint: its validated manifest, applied to the model's layers
/// before the weights load and to the tensors in ``BaseLanguageModel/prepareCheckpoint(_:)``.
///
/// Create the policy before `super.init`, so a manifest the loader cannot honor fails before the
/// model allocates anything. Call ``substituteModules(in:)`` once the base model exists, and pass
/// the base model's prepared checkpoint through ``prepare(_:)``. The `PrismHadamardQwen35`
/// classes in MLXLLM and MLXVLM follow this pattern.
public struct HadamardQuantizedCheckpointPolicy: Sendable {

    /// The checkpoint's manifest.
    public let manifest: HadamardQuantizedManifest

    /// What the model prepends to the manifest's paths, such as `"language_model."`.
    public let pathPrefix: String

    /// The activation dtype the packed modules declare; `nil` leaves unpacked tensors as stored.
    public let activationDType: DType?

    /// Validates `manifest` for a model of `baseModelType` whose module paths follow
    /// `tensorNamespace`.
    ///
    /// - Throws: ``HadamardQuantizedCheckpointError`` when the manifest is not one this loader
    ///   can honor.
    public init(
        manifest: HadamardQuantizedManifest, baseModelType: String, tensorNamespace: String,
        pathPrefix: String = ""
    ) throws {
        try manifest.validate(baseModelType: baseModelType, tensorNamespace: tensorNamespace)
        self.manifest = manifest
        self.pathPrefix = pathPrefix
        self.activationDType = try manifest.activationDType()
    }

    /// Replaces each manifest module of `model` with a rotated placeholder that the loader fills.
    ///
    /// Call it before the weights load. The loader's quantize pass skips the placeholders, which
    /// already conform to `Quantized`.
    ///
    /// - Throws: ``HadamardQuantizedCheckpointError`` when a manifest module is missing, is not a
    ///   plain `Linear` or `Embedding` of the declared kind, or has a block that does not divide
    ///   its input width.
    public func substituteModules(in model: Module) throws {
        let modules = Dictionary(uniqueKeysWithValues: model.leafModules().flattened())
        let quantization = manifest.quantization
        var replacements = [(String, Module)]()
        for entry in manifest.modules {
            let path = pathPrefix + entry.path
            guard let module = modules[path] else {
                throw HadamardQuantizedCheckpointError.moduleNotFound(path)
            }
            let replacement: Module
            switch module {
            case let embedding as Embedding
            where entry.embedding && type(of: module) == Embedding.self:
                replacement = HadamardQuantizedEmbedding(
                    replacing: embedding, groupSize: quantization.groupSize,
                    bits: quantization.bits, mode: quantization.mode,
                    rotation: try Self.rotation(entry, at: path, width: embedding.shape.1))
            case let linear as Linear where !entry.embedding && type(of: module) == Linear.self:
                replacement = HadamardQuantizedLinear(
                    replacing: linear, groupSize: quantization.groupSize,
                    bits: quantization.bits, mode: quantization.mode,
                    rotation: try Self.rotation(entry, at: path, width: linear.shape.1))
            default:
                throw HadamardQuantizedCheckpointError.moduleNotSubstitutable(
                    path, found: "\(type(of: module))")
            }
            (replacement as? HadamardQuantizedLinear)?.path = path
            replacements.append((path, replacement))
        }
        model.update(modules: ModuleChildren.unflattened(replacements))
    }

    /// Checks the checkpoint's sign vectors and casts its unpacked floating-point tensors to the
    /// activation dtype.
    ///
    /// A pack can store norms and small projections in float32 beside float16 packed modules,
    /// which would promote the residual stream to float32. Like mlx-vlm's converter, the cast
    /// skips the packed modules' own tensors and `A_log`, which the recurrence reads in float32.
    ///
    /// - Throws: ``HadamardQuantizedCheckpointError/invalidSigns(_:)`` when a sign vector holds a
    ///   value other than -1 or +1.
    public func prepare(_ checkpoint: ModelCheckpoint) throws -> ModelCheckpoint {
        let packed = Set(manifest.modules.map { pathPrefix + $0.path })
        try Self.validateSigns(in: checkpoint.weights, packed: packed)
        Self.noteSharedParts(in: checkpoint.weights, packed: packed)
        guard let activationDType else { return checkpoint }

        var prepared = checkpoint
        for (key, value) in checkpoint.weights
        where value.dtype.isFloatingPoint && value.dtype != activationDType
            && !key.hasSuffix("A_log") && !packed.contains(Self.modulePath(of: key))
        {
            prepared.weights[key] = value.asType(activationDType)
        }
        return prepared
    }

    /// Records what layers have in common, for ``HadamardQuantizedLinear``: which have the same
    /// sign vector, and which have biases that are exactly their scales negated. Read here, once,
    /// the biases need not be read again.
    private static func noteSharedParts(in weights: [String: MLXArray], packed: Set<String>) {
        let paths = packed.sorted()
        // The first layer of each width stands for its sign vector; a layer whose signs differ
        // from it is in a class of its own.
        var first: [Int: MLXArray] = [:]
        let signs = paths.compactMap { path -> (path: String, width: Int, same: MLXArray)? in
            guard let values = weights[path + ".signs"], values.ndim == 1 else { return nil }
            let width = values.dim(0)
            if first[width] == nil { first[width] = values }
            return (path, width, (values .== first[width]!).all())
        }
        if !signs.isEmpty {
            let same = stacked(signs.map(\.same)).asArray(Bool.self)
            for (index, entry) in signs.enumerated() {
                HadamardQuantizedLinear.signClasses[entry.path] = same[index] ? entry.width : -(index + 1)
            }
        }

        guard HadamardQuantizedLinear.sharesScales else { return }
        let pairs = paths.compactMap { path -> (path: String, same: MLXArray)? in
            guard let scales = weights[path + ".scales"], let biases = weights[path + ".biases"],
                scales.shape == biases.shape
            else { return nil }
            return (path, (biases .== -scales).all())
        }
        guard !pairs.isEmpty else { return }
        let same = stacked(pairs.map(\.same)).asArray(Bool.self)
        for (pair, isSame) in zip(pairs, same) {
            if isSame {
                HadamardQuantizedLinear.mirrored.insert(pair.path)
            } else {
                HadamardQuantizedLinear.mirrored.remove(pair.path)
            }
        }
    }

    private static func rotation(_ entry: HadamardQuantizedModule, at path: String, width: Int)
        throws -> SignedBlockHadamard
    {
        guard SignedBlockHadamard.isValidBlockSize(entry.block), width % entry.block == 0 else {
            throw HadamardQuantizedCheckpointError.unsupportedBlockSize(
                path, block: entry.block, width: width)
        }
        return SignedBlockHadamard(blockSize: entry.block)
    }

    private static func validateSigns(in weights: [String: MLXArray], packed: Set<String>) throws {
        let signs = packed.sorted().compactMap { path in
            weights[path + ".signs"].map { (path: path, values: $0) }
        }
        guard !signs.isEmpty else { return }

        func isValid(_ values: MLXArray) -> MLXArray { (abs(values) .== 1).all() }
        if stacked(signs.map { isValid($0.values) }).all().item(Bool.self) { return }
        if let invalid = signs.first(where: { !isValid($0.values).item(Bool.self) }) {
            throw HadamardQuantizedCheckpointError.invalidSigns(invalid.path)
        }
    }

    private static func modulePath(of key: String) -> String {
        guard let dot = key.lastIndex(of: ".") else { return key }
        return String(key[..<dot])
    }
}
