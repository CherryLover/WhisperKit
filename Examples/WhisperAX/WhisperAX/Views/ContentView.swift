//  For licensing see accompanying LICENSE.md file.
//  Copyright © 2024 Argmax, Inc. All rights reserved.

import SwiftUI
import WhisperKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
import AVFoundation
import CoreML

struct ContentView: View {
    @State var whisperKit: WhisperKit? = nil
    #if os(macOS)
    @State var audioDevices: [AudioDevice]? = nil
    #endif
    @State var isRecording: Bool = false
    @State var isTranscribing: Bool = false
    @State var currentText: String = ""
    @State var currentChunks: [Int: (chunkText: [String], fallbacks: Int)] = [:]
    // TODO: Make this configurable in the UI
    @State var modelStorage: String = "huggingface/models/argmaxinc/whisperkit-coreml"

    // MARK: Model management

    @State private var modelState: ModelState = .unloaded
    @State private var localModels: [String] = []
    @State private var localModelPath: String = ""
    @State private var availableModels: [String] = []
    @State private var availableLanguages: [String] = []
    @State private var disabledModels: [String] = WhisperKit.recommendedModels().disabled

    @AppStorage("selectedAudioInput") private var selectedAudioInput: String = "No Audio Input"
    @AppStorage("selectedModel") private var selectedModel: String = WhisperKit.recommendedModels().default
    @AppStorage("selectedTab") private var selectedTab: String = "Transcribe"
    @AppStorage("selectedTask") private var selectedTask: String = "transcribe"
    @AppStorage("selectedLanguage") private var selectedLanguage: String = "english"
    @AppStorage("repoName") private var repoName: String = "argmaxinc/whisperkit-coreml"
    @AppStorage("enableTimestamps") private var enableTimestamps: Bool = true
    @AppStorage("enablePromptPrefill") private var enablePromptPrefill: Bool = true
    @AppStorage("enableCachePrefill") private var enableCachePrefill: Bool = true
    @AppStorage("enableSpecialCharacters") private var enableSpecialCharacters: Bool = false
    @AppStorage("enableEagerDecoding") private var enableEagerDecoding: Bool = false
    @AppStorage("enableDecoderPreview") private var enableDecoderPreview: Bool = true
    @AppStorage("temperatureStart") private var temperatureStart: Double = 0
    @AppStorage("fallbackCount") private var fallbackCount: Double = 5
    @AppStorage("compressionCheckWindow") private var compressionCheckWindow: Double = 60
    @AppStorage("sampleLength") private var sampleLength: Double = 224
    @AppStorage("silenceThreshold") private var silenceThreshold: Double = 0.3
    @AppStorage("useVAD") private var useVAD: Bool = true
    @AppStorage("tokenConfirmationsNeeded") private var tokenConfirmationsNeeded: Double = 2
    @AppStorage("concurrentWorkerCount") private var concurrentWorkerCount: Int = 4
    @AppStorage("chunkingStrategy") private var chunkingStrategy: ChunkingStrategy = .vad
    @AppStorage("encoderComputeUnits") private var encoderComputeUnits: MLComputeUnits = .cpuAndNeuralEngine
    @AppStorage("decoderComputeUnits") private var decoderComputeUnits: MLComputeUnits = .cpuAndNeuralEngine

    // MARK: Standard properties

    @State private var loadingProgressValue: Float = 0.0
    @State private var specializationProgressRatio: Float = 0.7
    @State private var isFilePickerPresented = false
    @State private var firstTokenTime: TimeInterval = 0
    @State private var pipelineStart: TimeInterval = 0
    @State private var effectiveRealTimeFactor: TimeInterval = 0
    @State private var effectiveSpeedFactor: TimeInterval = 0
    @State private var totalInferenceTime: TimeInterval = 0
    @State private var tokensPerSecond: TimeInterval = 0
    @State private var currentLag: TimeInterval = 0
    @State private var currentFallbacks: Int = 0
    @State private var currentEncodingLoops: Int = 0
    @State private var currentDecodingLoops: Int = 0
    @State private var lastBufferSize: Int = 0
    @State private var lastConfirmedSegmentEndSeconds: Float = 0
    @State private var requiredSegmentsForConfirmation: Int = 4
    @State private var bufferEnergy: [Float] = []
    @State private var bufferSeconds: Double = 0
    @State private var confirmedSegments: [TranscriptionSegment] = []
    @State private var unconfirmedSegments: [TranscriptionSegment] = []

    // MARK: Eager mode properties

    @State private var eagerResults: [TranscriptionResult?] = []
    @State private var prevResult: TranscriptionResult?
    @State private var lastAgreedSeconds: Float = 0.0
    @State private var prevWords: [WordTiming] = []
    @State private var lastAgreedWords: [WordTiming] = []
    @State private var confirmedWords: [WordTiming] = []
    @State private var confirmedText: String = ""
    @State private var hypothesisWords: [WordTiming] = []
    @State private var hypothesisText: String = ""

    // MARK: UI properties

    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showComputeUnits: Bool = true
    @State private var showAdvancedOptions: Bool = false
    @State private var transcriptionTask: Task<Void, Never>? = nil
    @State private var selectedCategoryId: MenuItem.ID?
    @State private var transcribeTask: Task<Void, Never>? = nil

    @AppStorage("enableTextUpload") private var enableTextUpload: Bool = false
    @AppStorage("enableAudioUpload") private var enableAudioUpload: Bool = false
    @AppStorage("textUploadURL") private var textUploadURL: String = ""
    @AppStorage("audioUploadURL") private var audioUploadURL: String = ""

    struct MenuItem: Identifiable, Hashable {
        var id = UUID()
        var name: String
        var image: String
        var nameId: String
    }

    private var menu = [
        MenuItem(name: "Transcribe", image: "book.pages", nameId: "tab_transcribe"),
        MenuItem(name: "Stream", image: "waveform.badge.mic", nameId: "tab_stream"),
    ]

    private var isStreamMode: Bool {
        self.selectedCategoryId == menu.first(where: { $0.name == "Stream" })?.id
    }

    func getComputeOptions() -> ModelComputeOptions {
        return ModelComputeOptions(audioEncoderCompute: encoderComputeUnits, textDecoderCompute: decoderComputeUnits)
    }

    // MARK: Views

    func resetState() {
        transcribeTask?.cancel()
        isRecording = false
        isTranscribing = false
        whisperKit?.audioProcessor.stopRecording()
        currentText = ""
        currentChunks = [:]

        pipelineStart = Double.greatestFiniteMagnitude
        firstTokenTime = Double.greatestFiniteMagnitude
        effectiveRealTimeFactor = 0
        effectiveSpeedFactor = 0
        totalInferenceTime = 0
        tokensPerSecond = 0
        currentLag = 0
        currentFallbacks = 0
        currentEncodingLoops = 0
        currentDecodingLoops = 0
        lastBufferSize = 0
        lastConfirmedSegmentEndSeconds = 0
        requiredSegmentsForConfirmation = 2
        bufferEnergy = []
        bufferSeconds = 0
        confirmedSegments = []
        unconfirmedSegments = []

        eagerResults = []
        prevResult = nil
        lastAgreedSeconds = 0.0
        prevWords = []
        lastAgreedWords = []
        confirmedWords = []
        confirmedText = ""
        hypothesisWords = []
        hypothesisText = ""
    }

    // 添加这个函数到 ContentView 结构体中
    func localizedString(_ key: String) -> String {
        return NSLocalizedString(key, comment: "")
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            VStack(alignment: .leading) {
                modelSelectorView
                    .padding(.vertical)
                computeUnitsView
                    .disabled(modelState != .loaded && modelState != .unloaded)
                    .padding(.bottom)

                List(menu, selection: $selectedCategoryId) { item in
                    HStack {
                        Image(systemName: item.image)
                        Text(localizedString(item.nameId))
                            .font(.system(.title3))
                            .bold()
                    }
                }
                .onChange(of: selectedCategoryId) {
                    selectedTab = menu.first(where: { $0.id == selectedCategoryId })?.name ?? "Transcribe"
                }
                .disabled(modelState != .loaded)
                .foregroundColor(modelState != .loaded ? .secondary : .primary)
            }
            .navigationTitle(localizedString("whisperax"))
            .navigationSplitViewColumnWidth(min: 300, ideal: 350)
            .padding(.horizontal)
            Spacer()
        } detail: {
            VStack {
                #if os(iOS)
                modelSelectorView
                    .padding()
                transcriptionView
                #elseif os(macOS)
                VStack(alignment: .leading) {
                    transcriptionView
                }
                .padding()
                #endif
                controlsView
            }
            .toolbar(content: {
                ToolbarItem {
                    Button {
                        if !enableEagerDecoding {
                            let fullTranscript = formatSegments(confirmedSegments + unconfirmedSegments, withTimestamps: enableTimestamps).joined(separator: "\n")
                            #if os(iOS)
                            UIPasteboard.general.string = fullTranscript
                            #elseif os(macOS)
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(fullTranscript, forType: .string)
                            #endif
                        } else {
                            #if os(iOS)
                            UIPasteboard.general.string = confirmedText + hypothesisText
                            #elseif os(macOS)
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(confirmedText + hypothesisText, forType: .string)
                            #endif
                        }
                    } label: {
                        Label(localizedString("copy_text"), systemImage: "doc.on.doc")
                    }
                    .keyboardShortcut("c", modifiers: .command)
                    .foregroundColor(.primary)
                    .frame(minWidth: 0, maxWidth: .infinity)
                }
            })
        }
        .onAppear {
            #if os(macOS)
            selectedCategoryId = menu.first(where: { $0.name == selectedTab })?.id
            #endif
            fetchModels()
        }
    }

    // MARK: - Transcription

    var transcriptionView: some View {
        VStack {
            if !bufferEnergy.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 1) {
                        let startIndex = max(bufferEnergy.count - 300, 0)
                        ForEach(Array(bufferEnergy.enumerated())[startIndex...], id: \.element) { _, energy in
                            ZStack {
                                RoundedRectangle(cornerRadius: 2)
                                    .frame(width: 2, height: CGFloat(energy) * 24)
                            }
                            .frame(maxHeight: 24)
                            .background(energy > Float(silenceThreshold) ? Color.green.opacity(0.2) : Color.red.opacity(0.2))
                        }
                    }
                }
                .defaultScrollAnchor(.trailing)
                .frame(height: 24)
                .scrollIndicators(.never)
            }

            ScrollView {
                VStack(alignment: .leading) {
                    if enableEagerDecoding && isStreamMode {
                        let startSeconds = eagerResults.first??.segments.first?.start ?? 0
                        let endSeconds = lastAgreedSeconds > 0 ? lastAgreedSeconds : eagerResults.last??.segments.last?.end ?? 0
                        let timestampText = (enableTimestamps && eagerResults.first != nil) ? "[\(String(format: "%.2f", startSeconds)) --> \(String(format: "%.2f", endSeconds))]" : ""
                        Text("\(timestampText) \(Text(confirmedText).fontWeight(.bold))\(Text(hypothesisText).fontWeight(.bold).foregroundColor(.gray))")
                            .font(.headline)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if enableDecoderPreview {
                            Text("\(currentText)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top)
                        }
                    } else {
                        ForEach(Array(confirmedSegments.enumerated()), id: \.element) { _, segment in
                            let timestampText = enableTimestamps ? "[\(String(format: "%.2f", segment.start)) --> \(String(format: "%.2f", segment.end))]" : ""
                            Text(timestampText + segment.text)
                                .font(.headline)
                                .fontWeight(.bold)
                                .tint(.green)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        ForEach(Array(unconfirmedSegments.enumerated()), id: \.element) { _, segment in
                            let timestampText = enableTimestamps ? "[\(String(format: "%.2f", segment.start)) --> \(String(format: "%.2f", segment.end))]" : ""
                            Text(timestampText + segment.text)
                                .font(.headline)
                                .fontWeight(.bold)
                                .foregroundColor(.gray)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if enableDecoderPreview {
                            Text("\(currentText)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .defaultScrollAnchor(.bottom)
            .textSelection(.enabled)
            .padding()
            if let whisperKit,
               !isStreamMode,
               isTranscribing,
               let task = transcribeTask,
               !task.isCancelled,
               whisperKit.progress.fractionCompleted < 1
            {
                HStack {
                    ProgressView(whisperKit.progress)
                        .progressViewStyle(.linear)
                        .labelsHidden()
                        .padding(.horizontal)

                    Button {
                        transcribeTask?.cancel()
                        transcribeTask = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(BorderlessButtonStyle())
                }
            }
        }
    }

    // MARK: - Models

    var modelSelectorView: some View {
        Group {
            VStack {
                HStack {
                    Image(systemName: "circle.fill")
                        .foregroundStyle(modelState == .loaded ? .green : (modelState == .unloaded ? .red : .yellow))
                        .symbolEffect(.variableColor, isActive: modelState != .loaded && modelState != .unloaded)
                    Text(localizedString(modelState.description.lowercased()))

                    Spacer()

                    if availableModels.count > 0 {
                        Picker("", selection: $selectedModel) {
                            ForEach(availableModels, id: \.self) { model in
                                HStack {
                                    let modelIcon = localModels.contains { $0 == model.description } ? "checkmark.circle" : "arrow.down.circle.dotted"
                                    Text("\(Image(systemName: modelIcon)) \(model.description.components(separatedBy: "_").dropFirst().joined(separator: " "))").tag(model.description)
                                }
                            }
                        }
                        .pickerStyle(MenuPickerStyle())
                        .onChange(of: selectedModel, initial: false) { _, _ in
                            modelState = .unloaded
                        }
                    } else {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle())
                            .scaleEffect(0.5)
                    }

                    Button(action: {
                        deleteModel()
                    }, label: {
                        Image(systemName: "trash")
                    })
                    .help("Delete model")
                    .buttonStyle(BorderlessButtonStyle())
                    .disabled(localModels.count == 0)
                    .disabled(!localModels.contains(selectedModel))

                    #if os(macOS)
                    Button(action: {
                        let folderURL = whisperKit?.modelFolder ?? (localModels.contains(selectedModel) ? URL(fileURLWithPath: localModelPath) : nil)
                        if let folder = folderURL {
                            NSWorkspace.shared.open(folder)
                        }
                    }, label: {
                        Image(systemName: "folder")
                    })
                    .buttonStyle(BorderlessButtonStyle())
                    #endif
                    Button(action: {
                        if let url = URL(string: "https://huggingface.co/\(repoName)") {
                            #if os(macOS)
                            NSWorkspace.shared.open(url)
                            #else
                            UIApplication.shared.open(url)
                            #endif
                        }
                    }, label: {
                        Image(systemName: "link.circle")
                    })
                    .buttonStyle(BorderlessButtonStyle())
                }

                if modelState == .unloaded {
                    Divider()
                    Button {
                        resetState()
                        loadModel(selectedModel)
                        modelState = .loading
                    } label: {
                        Text(localizedString("load_model"))
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                    }
                    .buttonStyle(.borderedProminent)
                } else if loadingProgressValue < 1.0 {
                    VStack {
                        HStack {
                            ProgressView(value: loadingProgressValue, total: 1.0)
                                .progressViewStyle(LinearProgressViewStyle())
                                .frame(maxWidth: .infinity)

                            Text(String(format: "%.1f%%", loadingProgressValue * 100))
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                        if modelState == .prewarming {
                            Text(String(format: NSLocalizedString("specializing_text", comment: ""), selectedModel))
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                    }
                }
            }
        }
    }

    var computeUnitsView: some View {
        DisclosureGroup(isExpanded: $showComputeUnits) {
            VStack(alignment: .leading) {
                HStack {
                    Image(systemName: "circle.fill")
                        .foregroundStyle((whisperKit?.audioEncoder as? WhisperMLModel)?.modelState == .loaded ? .green : (modelState == .unloaded ? .red : .yellow))
                        .symbolEffect(.variableColor, isActive: modelState != .loaded && modelState != .unloaded)
                    Text(localizedString("audio_encoder"))
                    Spacer()
                    Picker("", selection: $encoderComputeUnits) {
                        Text(localizedString("cpu")).tag(MLComputeUnits.cpuOnly)
                        Text(localizedString("gpu")).tag(MLComputeUnits.cpuAndGPU)
                        Text(localizedString("neural_engine")).tag(MLComputeUnits.cpuAndNeuralEngine)
                    }
                    .onChange(of: encoderComputeUnits, initial: false) { _, _ in
                        loadModel(selectedModel)
                    }
                    .pickerStyle(MenuPickerStyle())
                    .frame(width: 150)
                }
                HStack {
                    Image(systemName: "circle.fill")
                        .foregroundStyle((whisperKit?.textDecoder as? WhisperMLModel)?.modelState == .loaded ? .green : (modelState == .unloaded ? .red : .yellow))
                        .symbolEffect(.variableColor, isActive: modelState != .loaded && modelState != .unloaded)
                    Text(localizedString("text_decoder"))
                    Spacer()
                    Picker("", selection: $decoderComputeUnits) {
                        Text(localizedString("cpu")).tag(MLComputeUnits.cpuOnly)
                        Text(localizedString("gpu")).tag(MLComputeUnits.cpuAndGPU)
                        Text(localizedString("neural_engine")).tag(MLComputeUnits.cpuAndNeuralEngine)
                    }
                    .onChange(of: decoderComputeUnits, initial: false) { _, _ in
                        loadModel(selectedModel)
                    }
                    .pickerStyle(MenuPickerStyle())
                    .frame(width: 150)
                }
            }
            .padding(.top)
        } label: {
            Button {
                showComputeUnits.toggle()
            } label: {
                Text(localizedString("compute_units"))
                    .font(.headline)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Controls

    var audioDevicesView: some View {
        Group {
            #if os(macOS)
            HStack {
                if let audioDevices = audioDevices, audioDevices.count > 0 {
                    Picker("", selection: $selectedAudioInput) {
                        ForEach(audioDevices, id: \.self) { device in
                            Text(device.name).tag(device.name)
                        }
                    }
                    .frame(width: 250)
                    .disabled(isRecording)
                }
            }
            .onAppear {
                audioDevices = AudioProcessor.getAudioDevices()
                if let audioDevices = audioDevices,
                   !audioDevices.isEmpty,
                   selectedAudioInput == "No Audio Input",
                   let device = audioDevices.first
                {
                    selectedAudioInput = device.name
                }
            }
            #endif
        }
    }

    var controlsView: some View {
        VStack {
            basicSettingsView

            if let selectedCategoryId, let item = menu.first(where: { $0.id == selectedCategoryId }) {
                switch item.name {
                    case "Transcribe":
                        VStack {
                            HStack {
                                Button {
                                    resetState()
                                } label: {
                                    Label(localizedString("reset"), systemImage: "arrow.clockwise")
                                }
                                .buttonStyle(.borderless)

                                Spacer()

                                audioDevicesView

                                Spacer()

                                Button {
                                    showAdvancedOptions.toggle()
                                } label: {
                                    Label(localizedString("settings"), systemImage: "slider.horizontal.3")
                                }
                                .buttonStyle(.borderless)
                            }

                            HStack {
                                let color: Color = modelState != .loaded ? .gray : .red
                                Button(action: {
                                    withAnimation {
                                        selectFile()
                                    }
                                }) {
                                    Text(localizedString("from_file"))
                                        .font(.headline)
                                        .foregroundColor(color)
                                        .padding()
                                        .cornerRadius(40)
                                        .frame(minWidth: 70, minHeight: 70)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 40)
                                                .stroke(color, lineWidth: 4)
                                        )
                                }
                                .fileImporter(
                                    isPresented: $isFilePickerPresented,
                                    allowedContentTypes: [.audio],
                                    allowsMultipleSelection: false,
                                    onCompletion: handleFilePicker
                                )
                                .lineLimit(1)
                                .contentTransition(.symbolEffect(.replace))
                                .buttonStyle(BorderlessButtonStyle())
                                .disabled(modelState != .loaded)
                                .frame(minWidth: 0, maxWidth: .infinity)
                                .padding()

                                ZStack {
                                    Button(action: {
                                        withAnimation {
                                            toggleRecording(shouldLoop: false)
                                        }
                                    }) {
                                        if !isRecording {
                                            Text(localizedString("record"))
                                                .font(.headline)
                                                .foregroundColor(color)
                                                .padding()
                                                .cornerRadius(40)
                                                .frame(minWidth: 70, minHeight: 70)
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 40)
                                                        .stroke(color, lineWidth: 4)
                                                )
                                        } else {
                                            Image(systemName: "stop.circle.fill")
                                                .resizable()
                                                .scaledToFit()
                                                .frame(width: 70, height: 70)
                                                .padding()
                                                .foregroundColor(modelState != .loaded ? .gray : .red)
                                        }
                                    }
                                    .lineLimit(1)
                                    .contentTransition(.symbolEffect(.replace))
                                    .buttonStyle(BorderlessButtonStyle())
                                    .disabled(modelState != .loaded)
                                    .frame(minWidth: 0, maxWidth: .infinity)
                                    .padding()

                                    if isRecording {
                                        Text("\(String(format: "%.1f", bufferSeconds)) s")
                                            .font(.caption)
                                            .foregroundColor(.gray)
                                            .offset(x: 80, y: 0)
                                    }
                                }
                            }
                        }
                    case "Stream":
                        VStack {
                            HStack {
                                Button {
                                    resetState()
                                } label: {
                                    Label(localizedString("reset"), systemImage: "arrow.clockwise")
                                }
                                .frame(minWidth: 0, maxWidth: .infinity)
                                .buttonStyle(.borderless)

                                Spacer()

                                audioDevicesView

                                Spacer()

                                VStack {
                                    Button {
                                        showAdvancedOptions.toggle()
                                    } label: {
                                        Label(localizedString("settings"), systemImage: "slider.horizontal.3")
                                    }
                                    .frame(minWidth: 0, maxWidth: .infinity)
                                    .buttonStyle(.borderless)
                                }
                            }

                            ZStack {
                                Button {
                                    withAnimation {
                                        toggleRecording(shouldLoop: true)
                                    }
                                } label: {
                                    Image(systemName: !isRecording ? "record.circle" : "stop.circle.fill")
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 70, height: 70)
                                        .padding()
                                        .foregroundColor(modelState != .loaded ? .gray : .red)
                                }
                                .contentTransition(.symbolEffect(.replace))
                                .buttonStyle(BorderlessButtonStyle())
                                .disabled(modelState != .loaded)
                                .frame(minWidth: 0, maxWidth: .infinity)

                                VStack {
                                    Text(String(format: NSLocalizedString("encoder_runs", comment: ""), currentEncodingLoops))
    .font(.caption)

Text(String(format: NSLocalizedString("decoder_runs", comment: ""), currentDecodingLoops))
    .font(.caption)

                                }
                                .offset(x: -120, y: 0)

                                if isRecording {
                                    Text("\(String(format: "%.1f", bufferSeconds)) s")
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                        .offset(x: 80, y: 0)
                                }
                            }
                        }
                    default:
                        EmptyView()
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal)
        .sheet(isPresented: $showAdvancedOptions, content: {
            advancedSettingsView
                .presentationDetents([.medium, .large])
                .presentationBackgroundInteraction(.enabled)
                .presentationContentInteraction(.scrolls)
        })
    }

    var basicSettingsView: some View {
        VStack {
            HStack {
                Picker("", selection: $selectedTask) {
                    ForEach(DecodingTask.allCases, id: \.self) { task in
                        Text(localizedString("decode_type_\(task.description)")).tag(task.description)
                    }
                }
                .pickerStyle(SegmentedPickerStyle())
                .disabled(!(whisperKit?.modelVariant.isMultilingual ?? false))
            }
            .padding(.horizontal)

            LabeledContent {
                Picker("", selection: $selectedLanguage) {
                    ForEach(availableLanguages, id: \.self) { language in
//                        Text(language.description).tag(language.description)
                        Text(localizedString("language_\(language.description.replacingOccurrences(of: " ", with: "_"))")).tag(language.description)
                    }
                }
                .disabled(!(whisperKit?.modelVariant.isMultilingual ?? false))
            } label: {
                Label(localizedString("source_language"), systemImage: "globe")
            }
            .padding(.horizontal)
            .padding(.top)

            HStack {
                Text(effectiveRealTimeFactor.formatted(.number.precision(.fractionLength(3))) + " RTF")
                    .font(.system(.body))
                    .lineLimit(1)
                Spacer()
                #if os(macOS)
                Text(effectiveSpeedFactor.formatted(.number.precision(.fractionLength(1))) + " Speed Factor")
                    .font(.system(.body))
                    .lineLimit(1)
                Spacer()
                #endif
                Text(tokensPerSecond.formatted(.number.precision(.fractionLength(0))) + " tok/s")
                    .font(.system(.body))
                    .lineLimit(1)
                Spacer()
                Text("First token: " + (firstTokenTime - pipelineStart).formatted(.number.precision(.fractionLength(2))) + "s")
                    .font(.system(.body))
                    .lineLimit(1)
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
    }

    var advancedSettingsView: some View {
        #if os(iOS)
        NavigationView {
            settingsForm
                .navigationBarTitleDisplayMode(.inline)
        }
        #else
        VStack {
            Text(localizedString("decoding_options"))
                .font(.title2)
                .padding()
            settingsForm
                .frame(minWidth: 500, minHeight: 500)
        }
        #endif
    }

    var settingsForm: some View {
        List {
            HStack {
                Text(localizedString("show_timestamps"))
                InfoButton(localizedString("hint_show_timestamps"))
                Spacer()
                Toggle("", isOn: $enableTimestamps)
            }
            .padding(.horizontal)

            HStack {
                Text(localizedString("special_characters"))
                InfoButton(localizedString("hint_special_characters"))
                Spacer()
                Toggle("", isOn: $enableSpecialCharacters)
            }
            .padding(.horizontal)

            HStack {
                Text(localizedString("show_decoder_preview"))
                InfoButton(localizedString("hint_show_decoder_preview"))
                Spacer()
                Toggle("", isOn: $enableDecoderPreview)
            }
            .padding(.horizontal)

            HStack {
                Text(localizedString("prompt_prefill"))
                InfoButton(localizedString("hint_prompt_prefill"))
                Spacer()
                Toggle("", isOn: $enablePromptPrefill)
            }
            .padding(.horizontal)

            HStack {
                Text(localizedString("cache_prefill"))
                InfoButton(localizedString("hint_cache_prefill"))
                Spacer()
                Toggle("", isOn: $enableCachePrefill)
            }
            .padding(.horizontal)

            HStack {
                Text(localizedString("chunking_strategy"))
                InfoButton(localizedString("hint_chunking_strategy"))
                Spacer()
                Picker("", selection: $chunkingStrategy) {
                    Text(localizedString("none")).tag(ChunkingStrategy.none)
                    Text(localizedString("vad")).tag(ChunkingStrategy.vad)
                }
                .pickerStyle(SegmentedPickerStyle())
            }
            .padding(.horizontal)
            .padding(.bottom)

            VStack {
                Text(localizedString("starting_temperature"))
                HStack {
                    Slider(value: $temperatureStart, in: 0...1, step: 0.1)
                    Text(temperatureStart.formatted(.number))
                    InfoButton(localizedString("hint_starting_temperature"))
                }
            }
            .padding(.horizontal)

            VStack {
                Text(localizedString("max_fallback_count"))
                HStack {
                    Slider(value: $fallbackCount, in: 0...5, step: 1)
                    Text(fallbackCount.formatted(.number))
                        .frame(width: 30)
                    InfoButton(localizedString("hint_max_fallback_count"))
                }
            }
            .padding(.horizontal)

            VStack {
                Text(localizedString("compression_check_tokens"))
                HStack {
                    Slider(value: $compressionCheckWindow, in: 0...100, step: 5)
                    Text(compressionCheckWindow.formatted(.number))
                        .frame(width: 30)
                    InfoButton(localizedString("hint_compression_check_tokens"))
                }
            }
            .padding(.horizontal)

            VStack {
                Text(localizedString("max_tokens_per_loop"))
                HStack {
                    Slider(value: $sampleLength, in: 0...Double(min(whisperKit?.textDecoder.kvCacheMaxSequenceLength ?? Constants.maxTokenContext, Constants.maxTokenContext)), step: 10)
                    Text(sampleLength.formatted(.number))
                        .frame(width: 30)
                    InfoButton(localizedString("hint_max_tokens_per_loop"))
                }
            }
            .padding(.horizontal)

            VStack {
                Text(localizedString("silence_threshold"))
                HStack {
                    Slider(value: $silenceThreshold, in: 0...1, step: 0.05)
                    Text(silenceThreshold.formatted(.number))
                        .frame(width: 30)
                    InfoButton(localizedString("hint_silence_threshold"))
                }
            }
            .padding(.horizontal)

            Section(header: Text(localizedString("experimental"))) {
                HStack {
                    Text(localizedString("eager_streaming_mode"))
                    InfoButton(localizedString("hint_eager_streaming_mode"))
                    Spacer()
                    Toggle("", isOn: $enableEagerDecoding)
                }
                .padding(.horizontal)
                .padding(.top)

                VStack {
                    Text(localizedString("token_confirmations"))
                    HStack {
                        Slider(value: $tokenConfirmationsNeeded, in: 1...10, step: 1)
                        Text(tokenConfirmationsNeeded.formatted(.number))
                            .frame(width: 30)
                        InfoButton(localizedString("hint_token_confirmations"))
                    }
                }
                .padding(.horizontal)
            }
            
            Section(header: Text(localizedString("actions_after_completion"))) {
                HStack {
                    Text(localizedString("upload_text"))
                    InfoButton(localizedString("hint_upload_text"))
                    Spacer()
                    Toggle("", isOn: $enableTextUpload)
                }
                .padding(.horizontal)
                
                if enableTextUpload {
                    TextField(localizedString("text_upload_url"), text: $textUploadURL)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .padding(.horizontal)
                }
                
                // HStack {
                //     Text(localizedString("upload_audio"))
                //     InfoButton(localizedString("hint_upload_audio"))
                //     Spacer()
                //     Toggle("", isOn: $enableAudioUpload)
                // }
                // .padding(.horizontal)
                
                // if enableAudioUpload {
                //     TextField(localizedString("audio_upload_url"), text: $audioUploadURL)
                //         .textFieldStyle(RoundedBorderTextFieldStyle())
                //         .padding(.horizontal)
                // }
            }
        }
        .navigationTitle(localizedString("decoding_options"))
        .toolbar(content: {
            ToolbarItem {
                Button {
                    showAdvancedOptions = false
                } label: {
                    Label(localizedString("done"), systemImage: "xmark.circle.fill")
                        .foregroundColor(.primary)
                }
            }
        })
    }

    struct InfoButton: View {
        var infoText: String
        @State private var showInfo = false

        init(_ infoText: String) {
            self.infoText = infoText
        }

        var body: some View {
            Button(action: {
                self.showInfo = true
            }) {
                Image(systemName: "info.circle")
                    .foregroundColor(.blue)
            }
            .popover(isPresented: $showInfo) {
                Text(infoText)
                    .padding()
            }
            .buttonStyle(BorderlessButtonStyle())
        }
    }

    // MARK: - Logic

    func fetchModels() {
        availableModels = [selectedModel]

        // First check what's already downloaded
        if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let modelPath = documents.appendingPathComponent(modelStorage).path

            // Check if the directory exists
            if FileManager.default.fileExists(atPath: modelPath) {
                localModelPath = modelPath
                do {
                    let downloadedModels = try FileManager.default.contentsOfDirectory(atPath: modelPath)
                    for model in downloadedModels where !localModels.contains(model) {
                        localModels.append(model)
                    }
                } catch {
                    print("Error enumerating files at \(modelPath): \(error.localizedDescription)")
                }
            }
        }

        localModels = WhisperKit.formatModelFiles(localModels)
        for model in localModels {
            if !availableModels.contains(model) {
                availableModels.append(model)
            }
        }

        print("Found locally: \(localModels)")
        print("Previously selected model: \(selectedModel)")

        Task {
            let remoteModelSupport = await WhisperKit.recommendedRemoteModels()
            await MainActor.run {
                for model in remoteModelSupport.supported {
                    if !availableModels.contains(model) {
                        availableModels.append(model)
                    }
                }
                for model in remoteModelSupport.disabled {
                    if !disabledModels.contains(model) {
                        disabledModels.append(model)
                    }
                }
            }
        }
    }

    func loadModel(_ model: String, redownload: Bool = false) {
        print("Selected Model: \(UserDefaults.standard.string(forKey: "selectedModel") ?? "nil")")
        print("""
            Computing Options:
            - Mel Spectrogram:  \(getComputeOptions().melCompute.description)
            - Audio Encoder:    \(getComputeOptions().audioEncoderCompute.description)
            - Text Decoder:     \(getComputeOptions().textDecoderCompute.description)
            - Prefill Data:     \(getComputeOptions().prefillCompute.description)
        """)

        whisperKit = nil
        Task {
            let config = WhisperKitConfig(computeOptions: getComputeOptions(),
                                          verbose: true,
                                          logLevel: .debug,
                                          prewarm: false,
                                          load: false,
                                          download: false)
            whisperKit = try await WhisperKit(config)
            guard let whisperKit = whisperKit else {
                return
            }

            var folder: URL?

            // Check if the model is available locally
            if localModels.contains(model) && !redownload {
                // Get local model folder URL from localModels
                // TODO: Make this configurable in the UI
                folder = URL(fileURLWithPath: localModelPath).appendingPathComponent(model)
            } else {
                // Download the model
                folder = try await WhisperKit.download(variant: model, from: repoName, progressCallback: { progress in
                    DispatchQueue.main.async {
                        loadingProgressValue = Float(progress.fractionCompleted) * specializationProgressRatio
                        modelState = .downloading
                    }
                })
            }

            await MainActor.run {
                loadingProgressValue = specializationProgressRatio
                modelState = .downloaded
            }

            if let modelFolder = folder {
                whisperKit.modelFolder = modelFolder

                await MainActor.run {
                    // Set the loading progress to 90% of the way after prewarm
                    loadingProgressValue = specializationProgressRatio
                    modelState = .prewarming
                }

                let progressBarTask = Task {
                    await updateProgressBar(targetProgress: 0.9, maxTime: 240)
                }

                // Prewarm models
                do {
                    try await whisperKit.prewarmModels()
                    progressBarTask.cancel()
                } catch {
                    print("Error prewarming models, retrying: \(error.localizedDescription)")
                    progressBarTask.cancel()
                    if !redownload {
                        loadModel(model, redownload: true)
                        return
                    } else {
                        // Redownloading failed, error out
                        modelState = .unloaded
                        return
                    }
                }

                await MainActor.run {
                    // Set the loading progress to 90% of the way after prewarm
                    loadingProgressValue = specializationProgressRatio + 0.9 * (1 - specializationProgressRatio)
                    modelState = .loading
                }

                try await whisperKit.loadModels()

                await MainActor.run {
                    if !localModels.contains(model) {
                        localModels.append(model)
                    }

                    availableLanguages = Constants.languages.map { $0.key }.sorted()
                    loadingProgressValue = 1.0
                    modelState = whisperKit.modelState
                }
            }
        }
    }

    func deleteModel() {
        if localModels.contains(selectedModel) {
            let modelFolder = URL(fileURLWithPath: localModelPath).appendingPathComponent(selectedModel)

            do {
                try FileManager.default.removeItem(at: modelFolder)

                if let index = localModels.firstIndex(of: selectedModel) {
                    localModels.remove(at: index)
                }

                modelState = .unloaded
            } catch {
                print("Error deleting model: \(error)")
            }
        }
    }

    func updateProgressBar(targetProgress: Float, maxTime: TimeInterval) async {
        let initialProgress = loadingProgressValue
        let decayConstant = -log(1 - targetProgress) / Float(maxTime)

        let startTime = Date()

        while true {
            let elapsedTime = Date().timeIntervalSince(startTime)

            // Break down the calculation
            let decayFactor = exp(-decayConstant * Float(elapsedTime))
            let progressIncrement = (1 - initialProgress) * (1 - decayFactor)
            let currentProgress = initialProgress + progressIncrement

            await MainActor.run {
                loadingProgressValue = currentProgress
            }

            if currentProgress >= targetProgress {
                break
            }

            do {
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch {
                break
            }
        }
    }

    func selectFile() {
        isFilePickerPresented = true
    }

    func handleFilePicker(result: Result<[URL], Error>) {
        switch result {
            case let .success(urls):
                guard let selectedFileURL = urls.first else { return }
                if selectedFileURL.startAccessingSecurityScopedResource() {
                    do {
                        // Access the document data from the file URL
                        let audioFileData = try Data(contentsOf: selectedFileURL)

                        // Create a unique file name to avoid overwriting any existing files
                        let uniqueFileName = UUID().uuidString + "." + selectedFileURL.pathExtension

                        // Construct the temporary file URL in the app's temp directory
                        let tempDirectoryURL = FileManager.default.temporaryDirectory
                        let localFileURL = tempDirectoryURL.appendingPathComponent(uniqueFileName)

                        // Write the data to the temp directory
                        try audioFileData.write(to: localFileURL)

                        print("File saved to temporary directory: \(localFileURL)")

                        transcribeFile(path: selectedFileURL.path)
                    } catch {
                        print("File selection error: \(error.localizedDescription)")
                    }
                }
            case let .failure(error):
                print("File selection error: \(error.localizedDescription)")
        }
    }

    func transcribeFile(path: String) {
        resetState()
        whisperKit?.audioProcessor = AudioProcessor()
        self.transcribeTask = Task {
            isTranscribing = true
            do {
                try await transcribeCurrentFile(path: path)
                
                // 在转录完成后上传文本和音频
                await MainActor.run {
                    if enableTextUpload {
                        uploadTranscribedText(type: "transcribeFile")
                    }
                    if enableAudioUpload {
                        if let audioData = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                            uploadAudioFile(audioData, type: "transcribeFile")
                        }
                    }
                }
            } catch {
                print("File selection error: \(error.localizedDescription)")
            }
            isTranscribing = false
        }
    }

    func toggleRecording(shouldLoop: Bool) {
        isRecording.toggle()

        if isRecording {
            resetState()
            startRecording(shouldLoop)
        } else {
            stopRecording(shouldLoop)
        }
    }

    func startRecording(_ loop: Bool) {
        if let audioProcessor = whisperKit?.audioProcessor {
            Task(priority: .userInitiated) {
                guard await AudioProcessor.requestRecordPermission() else {
                    print("Microphone access was not granted.")
                    return
                }

                var deviceId: DeviceID?
                #if os(macOS)
                if self.selectedAudioInput != "No Audio Input",
                   let devices = self.audioDevices,
                   let device = devices.first(where: { $0.name == selectedAudioInput })
                {
                    deviceId = device.id
                }

                // There is no built-in microphone
                if deviceId == nil {
                    throw WhisperError.microphoneUnavailable()
                }
                #endif

                try? audioProcessor.startRecordingLive(inputDeviceID: deviceId) { _ in
                    DispatchQueue.main.async {
                        bufferEnergy = whisperKit?.audioProcessor.relativeEnergy ?? []
                        bufferSeconds = Double(whisperKit?.audioProcessor.audioSamples.count ?? 0) / Double(WhisperKit.sampleRate)
                    }
                }

                // Delay the timer start by 1 second
                isRecording = true
                isTranscribing = true
                if loop {
                    realtimeLoop()
                }
            }
        }
    }

    func stopRecording(_ loop: Bool) {
        isRecording = false
        stopRealtimeTranscription()
        if let audioProcessor = whisperKit?.audioProcessor {
            audioProcessor.stopRecording()
        }

        finalizeText()

        // 如果不是循环模式，转录完整缓冲区
        if !loop {
            self.transcribeTask = Task {
                isTranscribing = true
                do {
                    try await transcribeCurrentBuffer()
                } catch {
                    print("错误 real: \(error.localizedDescription)")
                }
                isTranscribing = false
            }
            
            // 创建一个新的任务来处理上传
            Task {
                await transcribeTask?.value // 等待转录任务完成
                
                await MainActor.run {
                    print("检查是否需要上传文本")
                    if enableTextUpload {
                        uploadTranscribedText(type: "stopRecording")
                    }
                    if enableAudioUpload {
                        if let audioData = try? Data(contentsOf: URL(fileURLWithPath: "path_to_audio_file")) {
                            uploadAudioFile(audioData, type: "stopRecording")
                        }
                    }
                }
            }
        }
    }

    func finalizeText() {
        // Finalize unconfirmed text
        Task {
            await MainActor.run {
                if hypothesisText != "" {
                    confirmedText += hypothesisText
                    hypothesisText = ""
                }

                if unconfirmedSegments.count > 0 {
                    confirmedSegments.append(contentsOf: unconfirmedSegments)
                    unconfirmedSegments = []
                }
            }
        }
    }

    // 添加新的上传文本函数
    func uploadTranscribedText(type: String) {
        print("上传类型: \(type)")
        print("开始上传转录文本")
        guard let url = URL(string: textUploadURL) else {
            print("无效的上传URL: \(textUploadURL)")
            return
        }
        
        let fullText: String
        if enableEagerDecoding {
            fullText = confirmedText + hypothesisText
        } else {
            fullText = formatSegments(confirmedSegments + unconfirmedSegments, withTimestamps: enableTimestamps).joined(separator: "\n")
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let uploadData = ["text": fullText]
        
        do {
            request.httpBody = try JSONEncoder().encode(uploadData)
        } catch {
            print("编码上传数据时出错: \(error)")
            return
        }
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                print("上传文本时出错: \(error)")
                return
            }
            
            if let httpResponse = response as? HTTPURLResponse {
                print("上传文本响应状态码: \(httpResponse.statusCode)")
            }
            
            if let data = data, let responseString = String(data: data, encoding: .utf8) {
                print("上传文本响应: \(responseString)")
            }
        }.resume()
    }

    // 添加新的上传音频函数
    func uploadAudioFile(_ audioData: Data, type: String) {
        print("上传音频类型: \(type)")
        print("开始上传音频文件")
        guard let url = URL(string: audioUploadURL) else {
            print("无效的上传URL: \(audioUploadURL)")
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        
        // 设置 Content-Type 为 multipart/form-data
        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        // 创建 multipart/form-data body
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"audio_file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        
        request.httpBody = body
        
        URLSession.shared.uploadTask(with: request, from: body) { data, response, error in
            if let error = error {
                print("上传音频时出错: \(error)")
                return
            }
            
            if let httpResponse = response as? HTTPURLResponse {
                print("上传音频响应状态码: \(httpResponse.statusCode)")
            }
            
            if let data = data, let responseString = String(data: data, encoding: .utf8) {
                print("上传音频响应: \(responseString)")
            }
        }.resume()
    }

    // MARK: - Transcribe Logic

    func transcribeCurrentFile(path: String) async throws {
        // Load and convert buffer in a limited scope
        Logging.debug("Loading audio file: \(path)")
        let loadingStart = Date()
        let audioFileSamples = try await Task {
            try autoreleasepool {
                return try AudioProcessor.loadAudioAsFloatArray(fromPath: path)
            }
        }.value
        Logging.debug("Loaded audio file in \(Date().timeIntervalSince(loadingStart)) seconds")


        let transcription = try await transcribeAudioSamples(audioFileSamples)

        await MainActor.run {
            currentText = ""
            guard let segments = transcription?.segments else {
                return
            }

            self.tokensPerSecond = transcription?.timings.tokensPerSecond ?? 0
            self.effectiveRealTimeFactor = transcription?.timings.realTimeFactor ?? 0
            self.effectiveSpeedFactor = transcription?.timings.speedFactor ?? 0
            self.currentEncodingLoops = Int(transcription?.timings.totalEncodingRuns ?? 0)
            self.firstTokenTime = transcription?.timings.firstTokenTime ?? 0
            self.pipelineStart = transcription?.timings.pipelineStart ?? 0
            self.currentLag = transcription?.timings.decodingLoop ?? 0

            self.confirmedSegments = segments
        }
    }

    func transcribeAudioSamples(_ samples: [Float]) async throws -> TranscriptionResult? {
        guard let whisperKit = whisperKit else { return nil }

        let languageCode = Constants.languages[selectedLanguage, default: Constants.defaultLanguageCode]
        let task: DecodingTask = selectedTask == "transcribe" ? .transcribe : .translate
        let seekClip: [Float] = [lastConfirmedSegmentEndSeconds]

        let options = DecodingOptions(
            verbose: true,
            task: task,
            language: languageCode,
            temperature: Float(temperatureStart),
            temperatureFallbackCount: Int(fallbackCount),
            sampleLength: Int(sampleLength),
            usePrefillPrompt: enablePromptPrefill,
            usePrefillCache: enableCachePrefill,
            skipSpecialTokens: !enableSpecialCharacters,
            withoutTimestamps: !enableTimestamps,
            wordTimestamps: true,
            clipTimestamps: seekClip,
            concurrentWorkerCount: concurrentWorkerCount,
            chunkingStrategy: chunkingStrategy
        )

        // Early stopping checks
        let decodingCallback: ((TranscriptionProgress) -> Bool?) = { (progress: TranscriptionProgress) in
            DispatchQueue.main.async {
                let fallbacks = Int(progress.timings.totalDecodingFallbacks)
                let chunkId = isStreamMode ? 0 : progress.windowId

                // First check if this is a new window for the same chunk, append if so
                var updatedChunk = (chunkText: [progress.text], fallbacks: fallbacks)
                if var currentChunk = self.currentChunks[chunkId], let previousChunkText = currentChunk.chunkText.last {
                    if progress.text.count >= previousChunkText.count {
                        // This is the same window of an existing chunk, so we just update the last value
                        currentChunk.chunkText[currentChunk.chunkText.endIndex - 1] = progress.text
                        updatedChunk = currentChunk
                    } else {
                        // This is either a new window or a fallback (only in streaming mode)
                        if fallbacks == currentChunk.fallbacks && isStreamMode {
                            // New window (since fallbacks havent changed)
                            updatedChunk.chunkText = [updatedChunk.chunkText.first ?? "" + progress.text]
                        } else {
                            // Fallback, overwrite the previous bad text
                            updatedChunk.chunkText[currentChunk.chunkText.endIndex - 1] = progress.text
                            updatedChunk.fallbacks = fallbacks
                            print("Fallback occured: \(fallbacks)")
                        }
                    }
                }

                // Set the new text for the chunk
                self.currentChunks[chunkId] = updatedChunk
                let joinedChunks = self.currentChunks.sorted { $0.key < $1.key }.flatMap { $0.value.chunkText }.joined(separator: "\n")

                self.currentText = joinedChunks
                self.currentFallbacks = fallbacks
                self.currentDecodingLoops += 1
            }

            // Check early stopping
            let currentTokens = progress.tokens
            let checkWindow = Int(compressionCheckWindow)
            if currentTokens.count > checkWindow {
                let checkTokens: [Int] = currentTokens.suffix(checkWindow)
                let compressionRatio = compressionRatio(of: checkTokens)
                if compressionRatio > options.compressionRatioThreshold! {
                    Logging.debug("Early stopping due to compression threshold")
                    return false
                }
            }
            if progress.avgLogprob! < options.logProbThreshold! {
                Logging.debug("Early stopping due to logprob threshold")
                return false
            }
            return nil
        }

        let transcriptionResults: [TranscriptionResult] = try await whisperKit.transcribe(
            audioArray: samples,
            decodeOptions: options,
            callback: decodingCallback
        )

        let mergedResults = mergeTranscriptionResults(transcriptionResults)

        return mergedResults
    }

    // MARK: Streaming Logic

    func realtimeLoop() {
        transcriptionTask = Task {
            while isRecording && isTranscribing {
                do {
                    try await transcribeCurrentBuffer()
                } catch {
                    print("Error: \(error.localizedDescription)")
                    break
                }
            }
        }
    }

    // 在停止实时转录后执行上传
    func stopRealtimeTranscription() {
        isTranscribing = false
        transcriptionTask?.cancel()

        // 在停��实时转录后��行上传
        Task {
            await MainActor.run {
                print("检查是否需要上传文本")
                if enableTextUpload {
                    uploadTranscribedText(type: "stopRealtimeTranscription")
                }
                if enableAudioUpload {
                    if let audioData = try? Data(contentsOf: URL(fileURLWithPath: "path_to_audio_file")) {
                        uploadAudioFile(audioData, type: "stopRealtimeTranscription")
                    }
                }
            }
        }
    }

    func transcribeCurrentBuffer() async throws {
        guard let whisperKit = whisperKit else { return }

        // Retrieve the current audio buffer from the audio processor
        let currentBuffer = whisperKit.audioProcessor.audioSamples

        // Calculate the size and duration of the next buffer segment
        let nextBufferSize = currentBuffer.count - lastBufferSize
        let nextBufferSeconds = Float(nextBufferSize) / Float(WhisperKit.sampleRate)

        // Only run the transcribe if the next buffer has at least 1 second of audio
        guard nextBufferSeconds > 1 else {
            await MainActor.run {
                if currentText == "" {
                    currentText = localizedString("waiting_for_speech")
                }
            }
            try await Task.sleep(nanoseconds: 100_000_000) // sleep for 100ms for next buffer
            return
        }

        if useVAD {
            let voiceDetected = AudioProcessor.isVoiceDetected(
                in: whisperKit.audioProcessor.relativeEnergy,
                nextBufferInSeconds: nextBufferSeconds,
                silenceThreshold: Float(silenceThreshold)
            )
            // Only run the transcribe if the next buffer has voice
            guard voiceDetected else {
                await MainActor.run {
                    if currentText == "" {
                        currentText = localizedString("waiting_for_speech")
                    }
                }

                // TODO: Implement silence buffer purging
//                if nextBufferSeconds > 30 {
//                    // This is a completely silent segment of 30s, so we can purge the audio and confirm anything pending
//                    lastConfirmedSegmentEndSeconds = 0
//                    whisperKit.audioProcessor.purgeAudioSamples(keepingLast: 2 * WhisperKit.sampleRate) // keep last 2s to include VAD overlap
//                    currentBuffer = whisperKit.audioProcessor.audioSamples
//                    lastBufferSize = 0
//                    confirmedSegments.append(contentsOf: unconfirmedSegments)
//                    unconfirmedSegments = []
//                }

                // Sleep for 100ms and check the next buffer
                try await Task.sleep(nanoseconds: 100_000_000)
                return
            }
        }

        // Store this for next iterations VAD
        lastBufferSize = currentBuffer.count

        if enableEagerDecoding && isStreamMode {
            // Run realtime transcribe using word timestamps for segmentation
            let transcription = try await transcribeEagerMode(Array(currentBuffer))
            await MainActor.run {
                currentText = ""
                self.tokensPerSecond = transcription?.timings.tokensPerSecond ?? 0
                self.firstTokenTime = transcription?.timings.firstTokenTime ?? 0
                self.pipelineStart = transcription?.timings.pipelineStart ?? 0
                self.currentLag = transcription?.timings.decodingLoop ?? 0
                self.currentEncodingLoops = Int(transcription?.timings.totalEncodingRuns ?? 0)

                let totalAudio = Double(currentBuffer.count) / Double(WhisperKit.sampleRate)
                self.totalInferenceTime = transcription?.timings.fullPipeline ?? 0
                self.effectiveRealTimeFactor = Double(totalInferenceTime) / totalAudio
                self.effectiveSpeedFactor = totalAudio / Double(totalInferenceTime)
            }
        } else {
            // Run realtime transcribe using timestamp tokens directly
            let transcription = try await transcribeAudioSamples(Array(currentBuffer))

            // We need to run this next part on the main thread
            await MainActor.run {
                currentText = ""
                guard let segments = transcription?.segments else {
                    return
                }

                self.tokensPerSecond = transcription?.timings.tokensPerSecond ?? 0
                self.firstTokenTime = transcription?.timings.firstTokenTime ?? 0
                self.pipelineStart = transcription?.timings.pipelineStart ?? 0
                self.currentLag = transcription?.timings.decodingLoop ?? 0
                self.currentEncodingLoops += Int(transcription?.timings.totalEncodingRuns ?? 0)

                let totalAudio = Double(currentBuffer.count) / Double(WhisperKit.sampleRate)
                self.totalInferenceTime += transcription?.timings.fullPipeline ?? 0
                self.effectiveRealTimeFactor = Double(totalInferenceTime) / totalAudio
                self.effectiveSpeedFactor = totalAudio / Double(totalInferenceTime)

                // Logic for moving segments to confirmedSegments
                if segments.count > requiredSegmentsForConfirmation {
                    // Calculate the number of segments to confirm
                    let numberOfSegmentsToConfirm = segments.count - requiredSegmentsForConfirmation

                    // Confirm the required number of segments
                    let confirmedSegmentsArray = Array(segments.prefix(numberOfSegmentsToConfirm))
                    let remainingSegments = Array(segments.suffix(requiredSegmentsForConfirmation))

                    // Update lastConfirmedSegmentEnd based on the last confirmed segment
                    if let lastConfirmedSegment = confirmedSegmentsArray.last, lastConfirmedSegment.end > lastConfirmedSegmentEndSeconds {
                        lastConfirmedSegmentEndSeconds = lastConfirmedSegment.end
                        print("Last confirmed segment end: \(lastConfirmedSegmentEndSeconds)")

                        // Add confirmed segments to the confirmedSegments array
                        for segment in confirmedSegmentsArray {
                            if !self.confirmedSegments.contains(segment: segment) {
                                self.confirmedSegments.append(segment)
                            }
                        }
                    }

                    // Update transcriptions to reflect the remaining segments
                    self.unconfirmedSegments = remainingSegments
                } else {
                    // Handle the case where segments are fewer or equal to required
                    self.unconfirmedSegments = segments
                }
            }
        }
    }

    func transcribeEagerMode(_ samples: [Float]) async throws -> TranscriptionResult? {
        guard let whisperKit = whisperKit else { return nil }

        guard whisperKit.textDecoder.supportsWordTimestamps else {
            confirmedText = "Eager mode requires word timestamps, which are not supported by the current model: \(selectedModel)."
            return nil
        }

        let languageCode = Constants.languages[selectedLanguage, default: Constants.defaultLanguageCode]
        let task: DecodingTask = selectedTask == "transcribe" ? .transcribe : .translate
        print(selectedLanguage)
        print(languageCode)

        let options = DecodingOptions(
            verbose: true,
            task: task,
            language: languageCode,
            temperature: Float(temperatureStart),
            temperatureFallbackCount: Int(fallbackCount),
            sampleLength: Int(sampleLength),
            usePrefillPrompt: enablePromptPrefill,
            usePrefillCache: enableCachePrefill,
            skipSpecialTokens: !enableSpecialCharacters,
            withoutTimestamps: !enableTimestamps,
            wordTimestamps: true, // required for eager mode
            firstTokenLogProbThreshold: -1.5 // higher threshold to prevent fallbacks from running to often
        )

        // Early stopping checks
        let decodingCallback: ((TranscriptionProgress) -> Bool?) = { progress in
            DispatchQueue.main.async {
                let fallbacks = Int(progress.timings.totalDecodingFallbacks)
                if progress.text.count < currentText.count {
                    if fallbacks == self.currentFallbacks {
                        //                        self.unconfirmedText.append(currentText)
                    } else {
                        print("Fallback occured: \(fallbacks)")
                    }
                }
                self.currentText = progress.text
                self.currentFallbacks = fallbacks
                self.currentDecodingLoops += 1
            }
            // Check early stopping
            let currentTokens = progress.tokens
            let checkWindow = Int(compressionCheckWindow)
            if currentTokens.count > checkWindow {
                let checkTokens: [Int] = currentTokens.suffix(checkWindow)
                let compressionRatio = compressionRatio(of: checkTokens)
                if compressionRatio > options.compressionRatioThreshold! {
                    Logging.debug("Early stopping due to compression threshold")
                    return false
                }
            }
            if progress.avgLogprob! < options.logProbThreshold! {
                Logging.debug("Early stopping due to logprob threshold")
                return false
            }

            return nil
        }

        Logging.info("[EagerMode] \(lastAgreedSeconds)-\(Double(samples.count) / 16000.0) seconds")

        let streamingAudio = samples
        var streamOptions = options
        streamOptions.clipTimestamps = [lastAgreedSeconds]
        let lastAgreedTokens = lastAgreedWords.flatMap { $0.tokens }
        streamOptions.prefixTokens = lastAgreedTokens
        do {
            let transcription: TranscriptionResult? = try await whisperKit.transcribe(audioArray: streamingAudio, decodeOptions: streamOptions, callback: decodingCallback).first
            await MainActor.run {
                var skipAppend = false
                if let result = transcription {
                    hypothesisWords = result.allWords.filter { $0.start >= lastAgreedSeconds }

                    if let prevResult = prevResult {
                        prevWords = prevResult.allWords.filter { $0.start >= lastAgreedSeconds }
                        let commonPrefix = findLongestCommonPrefix(prevWords, hypothesisWords)
                        Logging.info("[EagerMode] Prev \"\((prevWords.map { $0.word }).joined())\"")
                        Logging.info("[EagerMode] Next \"\((hypothesisWords.map { $0.word }).joined())\"")
                        Logging.info("[EagerMode] Found common prefix \"\((commonPrefix.map { $0.word }).joined())\"")

                        if commonPrefix.count >= Int(tokenConfirmationsNeeded) {
                            lastAgreedWords = commonPrefix.suffix(Int(tokenConfirmationsNeeded))
                            lastAgreedSeconds = lastAgreedWords.first!.start
                            Logging.info("[EagerMode] Found new last agreed word \"\(lastAgreedWords.first!.word)\" at \(lastAgreedSeconds) seconds")

                            confirmedWords.append(contentsOf: commonPrefix.prefix(commonPrefix.count - Int(tokenConfirmationsNeeded)))
                            let currentWords = confirmedWords.map { $0.word }.joined()
                            Logging.info("[EagerMode] Current:  \(lastAgreedSeconds) -> \(Double(samples.count) / 16000.0) \(currentWords)")
                        } else {
                            Logging.info("[EagerMode] Using same last agreed time \(lastAgreedSeconds)")
                            skipAppend = true
                        }
                    }
                    prevResult = result
                }

                if !skipAppend {
                    eagerResults.append(transcription)
                }
            }

            await MainActor.run {
                let finalWords = confirmedWords.map { $0.word }.joined()
                confirmedText = finalWords

                // Accept the final hypothesis because it is the last of the available audio
                let lastHypothesis = lastAgreedWords + findLongestDifferentSuffix(prevWords, hypothesisWords)
                hypothesisText = lastHypothesis.map { $0.word }.joined()
            }
        } catch {
            Logging.error("[EagerMode] Error: \(error)")
            finalizeText()
        }

        let mergedResult = mergeTranscriptionResults(eagerResults, confirmedWords: confirmedWords)

        return mergedResult
    }
}

#Preview {
    ContentView()
    #if os(macOS)
        .frame(width: 800, height: 500)
    #endif
}
