import Foundation

struct NvidiaNemotronASRModelSpec: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let note: String
    let huggingFaceID: String
    let files: [NvidiaNemotronASRFileSpec]
}

struct NvidiaNemotronASRFileSpec: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let filename: String
    let pathKey: String
    let urlKey: String
    let defaultPath: String
    let defaultURL: String
    let expectedBytes: Int64
}

enum NvidiaNemotronASRModelCatalog {
    static let defaultID = "nemotron-3.5-asr-streaming-0.6b"
    static let bundledHelperName = "typeforme-nemotron-asr"
    static let bundledResourceSubdirectory = "nvidia-nemotron"
    private static let hfBase = "https://huggingface.co/altunenes/parakeet-rs/resolve/main/nemotron-3.5-asr-streaming-0.6b-onnx"

    static let all: [NvidiaNemotronASRModelSpec] = [
        NvidiaNemotronASRModelSpec(
            id: "nemotron-3.5-asr-streaming-0.6b",
            label: "NVIDIA Nemotron 3.5 ASR Streaming 0.6B",
            note: "Multilingual local speech recognition model.",
            huggingFaceID: "nvidia/nemotron-3.5-asr-streaming-0.6b",
            files: [
                NvidiaNemotronASRFileSpec(
                    id: "encoder",
                    label: "Encoder",
                    filename: "encoder.onnx",
                    pathKey: AppSettings.Keys.asrNvidiaNemotronEncoderPath,
                    urlKey: AppSettings.Keys.asrNvidiaNemotronEncoderDownloadURL,
                    defaultPath: AppPaths.nvidiaNemotronEncoderFile.path,
                    defaultURL: "\(hfBase)/encoder.onnx?download=true",
                    expectedBytes: 42_164_972
                ),
                NvidiaNemotronASRFileSpec(
                    id: "encoder-data",
                    label: "Encoder data",
                    filename: "encoder.onnx.data",
                    pathKey: AppSettings.Keys.asrNvidiaNemotronEncoderDataPath,
                    urlKey: AppSettings.Keys.asrNvidiaNemotronEncoderDataDownloadURL,
                    defaultPath: AppPaths.nvidiaNemotronEncoderDataFile.path,
                    defaultURL: "\(hfBase)/encoder.onnx.data?download=true",
                    expectedBytes: 2_454_405_120
                ),
                NvidiaNemotronASRFileSpec(
                    id: "decoder-joint",
                    label: "Decoder joint",
                    filename: "decoder_joint.onnx",
                    pathKey: AppSettings.Keys.asrNvidiaNemotronDecoderJointPath,
                    urlKey: AppSettings.Keys.asrNvidiaNemotronDecoderJointDownloadURL,
                    defaultPath: AppPaths.nvidiaNemotronDecoderJointFile.path,
                    defaultURL: "\(hfBase)/decoder_joint.onnx?download=true",
                    expectedBytes: 97_590_054
                ),
                NvidiaNemotronASRFileSpec(
                    id: "tokenizer",
                    label: "Tokenizer",
                    filename: "tokenizer.model",
                    pathKey: AppSettings.Keys.asrNvidiaNemotronTokenizerPath,
                    urlKey: AppSettings.Keys.asrNvidiaNemotronTokenizerDownloadURL,
                    defaultPath: AppPaths.nvidiaNemotronTokenizerFile.path,
                    defaultURL: "\(hfBase)/tokenizer.model?download=true",
                    expectedBytes: 406_554
                ),
            ]
        ),
    ]

    static func spec(for id: String) -> NvidiaNemotronASRModelSpec {
        all.first { $0.id == id } ?? all[0]
    }
}
