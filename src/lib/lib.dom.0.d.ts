// ZTSC embedded DOM lib — real TypeScript DOM surface (browser globals).
// Assembled from @typescript/typescript-darwin-arm64@7.0.2 by src/lib/gen_lib.js — do not edit by hand.
//
// Concatenation of the lib.dom.d.ts chain (3 files, deps-first): the
// browser DOM globals (document, HTMLElement, Response, fetch, URLSearchParams,
// event types, …) plus the real `console` (a `Console`). The chain's es*
// reference deps (es2015 / es2018.asynciterable) are omitted: DOM is only ever
// loaded together with the esnext blob, which already provides them.
//
// Loaded when tsconfig `lib` includes "dom" (or by default, matching tsgo's
// target-esnext default which includes DOM). See src/modules.zig LibSet.

//========== lib.dom.d.ts ==========
/*! *****************************************************************************
Copyright (c) Microsoft Corporation. All rights reserved.
Licensed under the Apache License, Version 2.0 (the "License"); you may not use
this file except in compliance with the License. You may obtain a copy of the
License at http://www.apache.org/licenses/LICENSE-2.0

THIS CODE IS PROVIDED ON AN *AS IS* BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION ANY IMPLIED
WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR A PARTICULAR PURPOSE,
MERCHANTABILITY OR NON-INFRINGEMENT.

See the Apache Version 2.0 License for specific language governing permissions
and limitations under the License.
***************************************************************************** */


/// <reference lib="es2015" />
/// <reference lib="es2018.asynciterable" />

/////////////////////////////
/// Window APIs
/////////////////////////////

interface AacEncoderConfig {
    format?: AacBitstreamFormat;
}

interface AddEventListenerOptions extends EventListenerOptions {
    once?: boolean;
    passive?: boolean;
    signal?: AbortSignal;
}

interface AddressErrors {
    addressLine?: string;
    city?: string;
    country?: string;
    dependentLocality?: string;
    organization?: string;
    phone?: string;
    postalCode?: string;
    recipient?: string;
    region?: string;
    sortingCode?: string;
}

interface AesCbcParams extends Algorithm {
    iv: BufferSource;
}

interface AesCtrParams extends Algorithm {
    counter: BufferSource;
    length: number;
}

interface AesDerivedKeyParams extends Algorithm {
    length: number;
}

interface AesGcmParams extends Algorithm {
    additionalData?: BufferSource;
    iv: BufferSource;
    tagLength?: number;
}

interface AesKeyAlgorithm extends KeyAlgorithm {
    length: number;
}

interface AesKeyGenParams extends Algorithm {
    length: number;
}

interface Algorithm {
    name: string;
}

interface AllAcceptedCredentialsOptions {
    allAcceptedCredentialIds: Base64URLString[];
    rpId: string;
    userId: Base64URLString;
}

interface AnalyserOptions extends AudioNodeOptions {
    fftSize?: number;
    maxDecibels?: number;
    minDecibels?: number;
    smoothingTimeConstant?: number;
}

interface AnimationEventInit extends EventInit {
    animationName?: string;
    elapsedTime?: number;
    pseudoElement?: string;
}

interface AnimationPlaybackEventInit extends EventInit {
    currentTime?: CSSNumberish | null;
    timelineTime?: CSSNumberish | null;
}

interface AssignedNodesOptions {
    flatten?: boolean;
}

interface AudioBufferOptions {
    length: number;
    numberOfChannels?: number;
    sampleRate: number;
}

interface AudioBufferSourceOptions {
    buffer?: AudioBuffer | null;
    detune?: number;
    loop?: boolean;
    loopEnd?: number;
    loopStart?: number;
    playbackRate?: number;
}

interface AudioConfiguration {
    bitrate?: number;
    channels?: string;
    contentType: string;
    samplerate?: number;
    spatialRendering?: boolean;
}

interface AudioContextOptions {
    latencyHint?: AudioContextLatencyCategory | number;
    sampleRate?: number;
}

interface AudioDataCopyToOptions {
    format?: AudioSampleFormat;
    frameCount?: number;
    frameOffset?: number;
    planeIndex: number;
}

interface AudioDataInit {
    data: BufferSource;
    format: AudioSampleFormat;
    numberOfChannels: number;
    numberOfFrames: number;
    sampleRate: number;
    timestamp: number;
    transfer?: ArrayBuffer[];
}

interface AudioDecoderConfig {
    codec: string;
    description?: AllowSharedBufferSource;
    numberOfChannels: number;
    sampleRate: number;
}

interface AudioDecoderInit {
    error: WebCodecsErrorCallback;
    output: AudioDataOutputCallback;
}

interface AudioDecoderSupport {
    config?: AudioDecoderConfig;
    supported?: boolean;
}

interface AudioEncoderConfig {
    aac?: AacEncoderConfig;
    bitrate?: number;
    bitrateMode?: BitrateMode;
    codec: string;
    numberOfChannels: number;
    opus?: OpusEncoderConfig;
    sampleRate: number;
}

interface AudioEncoderInit {
    error: WebCodecsErrorCallback;
    output: EncodedAudioChunkOutputCallback;
}

interface AudioEncoderSupport {
    config?: AudioEncoderConfig;
    supported?: boolean;
}

interface AudioNodeOptions {
    channelCount?: number;
    channelCountMode?: ChannelCountMode;
    channelInterpretation?: ChannelInterpretation;
}

interface AudioProcessingEventInit extends EventInit {
    inputBuffer: AudioBuffer;
    outputBuffer: AudioBuffer;
    playbackTime: number;
}

interface AudioTimestamp {
    contextTime?: number;
    performanceTime?: DOMHighResTimeStamp;
}

interface AudioWorkletNodeOptions extends AudioNodeOptions {
    numberOfInputs?: number;
    numberOfOutputs?: number;
    outputChannelCount?: number[];
    parameterData?: Record<string, number>;
    processorOptions?: any;
}

interface AuthenticationExtensionsClientInputs {
    appid?: string;
    credProps?: boolean;
    credentialProtectionPolicy?: string;
    enforceCredentialProtectionPolicy?: boolean;
    hmacCreateSecret?: boolean;
    largeBlob?: AuthenticationExtensionsLargeBlobInputs;
    minPinLength?: boolean;
    prf?: AuthenticationExtensionsPRFInputs;
}

interface AuthenticationExtensionsClientInputsJSON {
    appid?: string;
    credProps?: boolean;
    largeBlob?: AuthenticationExtensionsLargeBlobInputsJSON;
    prf?: AuthenticationExtensionsPRFInputsJSON;
}

interface AuthenticationExtensionsClientOutputs {
    appid?: boolean;
    credProps?: CredentialPropertiesOutput;
    hmacCreateSecret?: boolean;
    largeBlob?: AuthenticationExtensionsLargeBlobOutputs;
    prf?: AuthenticationExtensionsPRFOutputs;
}

interface AuthenticationExtensionsClientOutputsJSON {
    appid?: boolean;
    credProps?: CredentialPropertiesOutput;
    largeBlob?: AuthenticationExtensionsLargeBlobOutputsJSON;
    prf?: AuthenticationExtensionsPRFOutputsJSON;
}

interface AuthenticationExtensionsLargeBlobInputs {
    read?: boolean;
    support?: string;
    write?: BufferSource;
}

interface AuthenticationExtensionsLargeBlobInputsJSON {
    read?: boolean;
    support?: string;
    write?: Base64URLString;
}

interface AuthenticationExtensionsLargeBlobOutputs {
    blob?: ArrayBuffer;
    supported?: boolean;
    written?: boolean;
}

interface AuthenticationExtensionsLargeBlobOutputsJSON {
    blob?: Base64URLString;
    supported?: boolean;
    written?: boolean;
}

interface AuthenticationExtensionsPRFInputs {
    eval?: AuthenticationExtensionsPRFValues;
    evalByCredential?: Record<string, AuthenticationExtensionsPRFValues>;
}

interface AuthenticationExtensionsPRFInputsJSON {
    eval?: AuthenticationExtensionsPRFValuesJSON;
    evalByCredential?: Record<string, AuthenticationExtensionsPRFValuesJSON>;
}

interface AuthenticationExtensionsPRFOutputs {
    enabled?: boolean;
    results?: AuthenticationExtensionsPRFValues;
}

interface AuthenticationExtensionsPRFOutputsJSON {
    enabled?: boolean;
    results?: AuthenticationExtensionsPRFValuesJSON;
}

interface AuthenticationExtensionsPRFValues {
    first: BufferSource;
    second?: BufferSource;
}

interface AuthenticationExtensionsPRFValuesJSON {
    first: Base64URLString;
    second?: Base64URLString;
}

interface AuthenticationResponseJSON {
    authenticatorAttachment?: string;
    clientExtensionResults: AuthenticationExtensionsClientOutputsJSON;
    id: string;
    rawId: Base64URLString;
    response: AuthenticatorAssertionResponseJSON;
    type: string;
}

interface AuthenticatorAssertionResponseJSON {
    authenticatorData: Base64URLString;
    clientDataJSON: Base64URLString;
    signature: Base64URLString;
    userHandle?: Base64URLString;
}

interface AuthenticatorAttestationResponseJSON {
    attestationObject: Base64URLString;
    authenticatorData: Base64URLString;
    clientDataJSON: Base64URLString;
    publicKey?: Base64URLString;
    publicKeyAlgorithm: COSEAlgorithmIdentifier;
    transports: string[];
}

interface AuthenticatorSelectionCriteria {
    authenticatorAttachment?: AuthenticatorAttachment;
    requireResidentKey?: boolean;
    residentKey?: ResidentKeyRequirement;
    userVerification?: UserVerificationRequirement;
}

interface AvcEncoderConfig {
    format?: AvcBitstreamFormat;
}

interface BiquadFilterOptions extends AudioNodeOptions {
    Q?: number;
    detune?: number;
    frequency?: number;
    gain?: number;
    type?: BiquadFilterType;
}

interface BlobEventInit extends EventInit {
    data: Blob;
    timecode?: DOMHighResTimeStamp;
}

interface BlobPropertyBag {
    endings?: EndingType;
    type?: string;
}

interface CSSMatrixComponentOptions {
    is2D?: boolean;
}

interface CSSNumericType {
    angle?: number;
    flex?: number;
    frequency?: number;
    length?: number;
    percent?: number;
    percentHint?: CSSNumericBaseType;
    resolution?: number;
    time?: number;
}

interface CSSStyleSheetInit {
    baseURL?: string;
    disabled?: boolean;
    media?: MediaList | string;
}

interface CacheQueryOptions {
    ignoreMethod?: boolean;
    ignoreSearch?: boolean;
    ignoreVary?: boolean;
}

interface CanvasRenderingContext2DSettings {
    alpha?: boolean;
    colorSpace?: PredefinedColorSpace;
    desynchronized?: boolean;
    willReadFrequently?: boolean;
}

interface CaretPositionFromPointOptions {
    shadowRoots?: ShadowRoot[];
}

interface ChannelMergerOptions extends AudioNodeOptions {
    numberOfInputs?: number;
}

interface ChannelSplitterOptions extends AudioNodeOptions {
    numberOfOutputs?: number;
}

interface CheckVisibilityOptions {
    checkOpacity?: boolean;
    checkVisibilityCSS?: boolean;
    contentVisibilityAuto?: boolean;
    opacityProperty?: boolean;
    visibilityProperty?: boolean;
}

interface ClientQueryOptions {
    includeUncontrolled?: boolean;
    type?: ClientTypes;
}

interface ClipboardEventInit extends EventInit {
    clipboardData?: DataTransfer | null;
}

interface ClipboardItemOptions {
    presentationStyle?: PresentationStyle;
}

interface CloseEventInit extends EventInit {
    code?: number;
    reason?: string;
    wasClean?: boolean;
}

interface CommandEventInit extends EventInit {
    command?: string;
    source?: Element | null;
}

interface CompositionEventInit extends UIEventInit {
    data?: string;
}

interface ComputedEffectTiming extends EffectTiming {
    activeDuration?: CSSNumberish;
    currentIteration?: number | null;
    endTime?: CSSNumberish;
    localTime?: CSSNumberish | null;
    progress?: number | null;
    startTime?: CSSNumberish;
}

interface ComputedKeyframe {
    composite: CompositeOperationOrAuto;
    computedOffset: number;
    easing: string;
    offset: number | null;
    [property: string]: string | number | null | undefined;
}

interface ConstantSourceOptions {
    offset?: number;
}

interface ConstrainBooleanOrDOMStringParameters {
    exact?: boolean | string;
    ideal?: boolean | string;
}

interface ConstrainBooleanParameters {
    exact?: boolean;
    ideal?: boolean;
}

interface ConstrainDOMStringParameters {
    exact?: string | string[];
    ideal?: string | string[];
}

interface ConstrainDoubleRange extends DoubleRange {
    exact?: number;
    ideal?: number;
}

interface ConstrainULongRange extends ULongRange {
    exact?: number;
    ideal?: number;
}

interface ContentVisibilityAutoStateChangeEventInit extends EventInit {
    skipped?: boolean;
}

interface ConvolverOptions extends AudioNodeOptions {
    buffer?: AudioBuffer | null;
    disableNormalization?: boolean;
}

interface CookieChangeEventInit extends EventInit {
    changed?: CookieList;
    deleted?: CookieList;
}

interface CookieInit {
    domain?: string | null;
    expires?: DOMHighResTimeStamp | null;
    name: string;
    partitioned?: boolean;
    path?: string;
    sameSite?: CookieSameSite;
    value: string;
}

interface CookieListItem {
    name?: string;
    value?: string;
}

interface CookieStoreDeleteOptions {
    domain?: string | null;
    name: string;
    partitioned?: boolean;
    path?: string;
}

interface CookieStoreGetOptions {
    name?: string;
    url?: string;
}

interface CredentialCreationOptions {
    publicKey?: PublicKeyCredentialCreationOptions;
    signal?: AbortSignal;
}

interface CredentialPropertiesOutput {
    rk?: boolean;
}

interface CredentialRequestOptions {
    mediation?: CredentialMediationRequirement;
    publicKey?: PublicKeyCredentialRequestOptions;
    signal?: AbortSignal;
}

interface CryptoKeyPair {
    privateKey: CryptoKey;
    publicKey: CryptoKey;
}

interface CurrentUserDetailsOptions {
    displayName: string;
    name: string;
    rpId: string;
    userId: Base64URLString;
}

interface CustomEventInit<T = any> extends EventInit {
    detail?: T;
}

interface DOMMatrix2DInit {
    a?: number;
    b?: number;
    c?: number;
    d?: number;
    e?: number;
    f?: number;
    m11?: number;
    m12?: number;
    m21?: number;
    m22?: number;
    m41?: number;
    m42?: number;
}

interface DOMMatrixInit extends DOMMatrix2DInit {
    is2D?: boolean;
    m13?: number;
    m14?: number;
    m23?: number;
    m24?: number;
    m31?: number;
    m32?: number;
    m33?: number;
    m34?: number;
    m43?: number;
    m44?: number;
}

interface DOMPointInit {
    w?: number;
    x?: number;
    y?: number;
    z?: number;
}

interface DOMQuadInit {
    p1?: DOMPointInit;
    p2?: DOMPointInit;
    p3?: DOMPointInit;
    p4?: DOMPointInit;
}

interface DOMRectInit {
    height?: number;
    width?: number;
    x?: number;
    y?: number;
}

interface DelayOptions extends AudioNodeOptions {
    delayTime?: number;
    maxDelayTime?: number;
}

interface DeviceMotionEventAccelerationInit {
    x?: number | null;
    y?: number | null;
    z?: number | null;
}

interface DeviceMotionEventInit extends EventInit {
    acceleration?: DeviceMotionEventAccelerationInit;
    accelerationIncludingGravity?: DeviceMotionEventAccelerationInit;
    interval?: number;
    rotationRate?: DeviceMotionEventRotationRateInit;
}

interface DeviceMotionEventRotationRateInit {
    alpha?: number | null;
    beta?: number | null;
    gamma?: number | null;
}

interface DeviceOrientationEventInit extends EventInit {
    absolute?: boolean;
    alpha?: number | null;
    beta?: number | null;
    gamma?: number | null;
}

interface DisplayMediaStreamOptions {
    audio?: boolean | MediaTrackConstraints;
    video?: boolean | MediaTrackConstraints;
}

interface DocumentTimelineOptions {
    originTime?: DOMHighResTimeStamp;
}

interface DoubleRange {
    max?: number;
    min?: number;
}

interface DragEventInit extends MouseEventInit {
    dataTransfer?: DataTransfer | null;
}

interface DynamicsCompressorOptions extends AudioNodeOptions {
    attack?: number;
    knee?: number;
    ratio?: number;
    release?: number;
    threshold?: number;
}

interface EcKeyAlgorithm extends KeyAlgorithm {
    namedCurve: NamedCurve;
}

interface EcKeyGenParams extends Algorithm {
    namedCurve: NamedCurve;
}

interface EcKeyImportParams extends Algorithm {
    namedCurve: NamedCurve;
}

interface EcdhKeyDeriveParams extends Algorithm {
    public: CryptoKey;
}

interface EcdsaParams extends Algorithm {
    hash: HashAlgorithmIdentifier;
}

interface EffectTiming {
    delay?: number;
    direction?: PlaybackDirection;
    duration?: number | CSSNumericValue | string;
    easing?: string;
    endDelay?: number;
    fill?: FillMode;
    iterationStart?: number;
    iterations?: number;
    playbackRate?: number;
}

interface ElementCreationOptions {
    customElementRegistry?: CustomElementRegistry | null;
    is?: string;
}

interface ElementDefinitionOptions {
    extends?: string;
}

interface EncodedAudioChunkInit {
    data: AllowSharedBufferSource;
    duration?: number;
    timestamp: number;
    transfer?: ArrayBuffer[];
    type: EncodedAudioChunkType;
}

interface EncodedAudioChunkMetadata {
    decoderConfig?: AudioDecoderConfig;
}

interface EncodedVideoChunkInit {
    data: AllowSharedBufferSource;
    duration?: number;
    timestamp: number;
    type: EncodedVideoChunkType;
}

interface EncodedVideoChunkMetadata {
    decoderConfig?: VideoDecoderConfig;
    svc?: SvcOutputMetadata;
}

interface ErrorEventInit extends EventInit {
    colno?: number;
    error?: any;
    filename?: string;
    lineno?: number;
    message?: string;
}

interface EventInit {
    bubbles?: boolean;
    cancelable?: boolean;
    composed?: boolean;
}

interface EventListenerOptions {
    capture?: boolean;
}

interface EventModifierInit extends UIEventInit {
    altKey?: boolean;
    ctrlKey?: boolean;
    metaKey?: boolean;
    modifierAltGraph?: boolean;
    modifierCapsLock?: boolean;
    modifierFn?: boolean;
    modifierFnLock?: boolean;
    modifierHyper?: boolean;
    modifierNumLock?: boolean;
    modifierScrollLock?: boolean;
    modifierSuper?: boolean;
    modifierSymbol?: boolean;
    modifierSymbolLock?: boolean;
    shiftKey?: boolean;
}

interface EventSourceInit {
    withCredentials?: boolean;
}

interface FilePropertyBag extends BlobPropertyBag {
    lastModified?: number;
}

interface FileSystemCreateWritableOptions {
    keepExistingData?: boolean;
}

interface FileSystemFlags {
    create?: boolean;
    exclusive?: boolean;
}

interface FileSystemGetDirectoryOptions {
    create?: boolean;
}

interface FileSystemGetFileOptions {
    create?: boolean;
}

interface FileSystemRemoveOptions {
    recursive?: boolean;
}

interface FocusEventInit extends UIEventInit {
    relatedTarget?: EventTarget | null;
}

interface FocusOptions {
    focusVisible?: boolean;
    preventScroll?: boolean;
}

interface FontFaceDescriptors {
    ascentOverride?: string;
    descentOverride?: string;
    display?: FontDisplay;
    featureSettings?: string;
    lineGapOverride?: string;
    stretch?: string;
    style?: string;
    unicodeRange?: string;
    variationSettings?: string;
    weight?: string;
}

interface FontFaceSetLoadEventInit extends EventInit {
    fontfaces?: FontFace[];
}

interface FormDataEventInit extends EventInit {
    formData: FormData;
}

interface FullscreenOptions {
    navigationUI?: FullscreenNavigationUI;
}

interface GPUBindGroupDescriptor extends GPUObjectDescriptorBase {
    entries: GPUBindGroupEntry[];
    layout: GPUBindGroupLayout;
}

interface GPUBindGroupEntry {
    binding: GPUIndex32;
    resource: GPUBindingResource;
}

interface GPUBindGroupLayoutDescriptor extends GPUObjectDescriptorBase {
    entries: GPUBindGroupLayoutEntry[];
}

interface GPUBindGroupLayoutEntry {
    binding: GPUIndex32;
    buffer?: GPUBufferBindingLayout;
    externalTexture?: GPUExternalTextureBindingLayout;
    sampler?: GPUSamplerBindingLayout;
    storageTexture?: GPUStorageTextureBindingLayout;
    texture?: GPUTextureBindingLayout;
    visibility: GPUShaderStageFlags;
}

interface GPUBlendComponent {
    dstFactor?: GPUBlendFactor;
    operation?: GPUBlendOperation;
    srcFactor?: GPUBlendFactor;
}

interface GPUBlendState {
    alpha: GPUBlendComponent;
    color: GPUBlendComponent;
}

interface GPUBufferBinding {
    buffer: GPUBuffer;
    offset?: GPUSize64;
    size?: GPUSize64;
}

interface GPUBufferBindingLayout {
    hasDynamicOffset?: boolean;
    minBindingSize?: GPUSize64;
    type?: GPUBufferBindingType;
}

interface GPUBufferDescriptor extends GPUObjectDescriptorBase {
    mappedAtCreation?: boolean;
    size: GPUSize64;
    usage: GPUBufferUsageFlags;
}

interface GPUCanvasConfiguration {
    alphaMode?: GPUCanvasAlphaMode;
    colorSpace?: PredefinedColorSpace;
    device: GPUDevice;
    format: GPUTextureFormat;
    toneMapping?: GPUCanvasToneMapping;
    usage?: GPUTextureUsageFlags;
    viewFormats?: GPUTextureFormat[];
}

interface GPUCanvasToneMapping {
    mode?: GPUCanvasToneMappingMode;
}

interface GPUColorDict {
    a: number;
    b: number;
    g: number;
    r: number;
}

interface GPUColorTargetState {
    blend?: GPUBlendState;
    format: GPUTextureFormat;
    writeMask?: GPUColorWriteFlags;
}

interface GPUCommandBufferDescriptor extends GPUObjectDescriptorBase {
}

interface GPUCommandEncoderDescriptor extends GPUObjectDescriptorBase {
}

interface GPUComputePassDescriptor extends GPUObjectDescriptorBase {
    timestampWrites?: GPUComputePassTimestampWrites;
}

interface GPUComputePassTimestampWrites {
    beginningOfPassWriteIndex?: GPUSize32;
    endOfPassWriteIndex?: GPUSize32;
    querySet: GPUQuerySet;
}

interface GPUComputePipelineDescriptor extends GPUPipelineDescriptorBase {
    compute: GPUProgrammableStage;
}

interface GPUCopyExternalImageDestInfo extends GPUTexelCopyTextureInfo {
    colorSpace?: PredefinedColorSpace;
    premultipliedAlpha?: boolean;
}

interface GPUCopyExternalImageSourceInfo {
    flipY?: boolean;
    origin?: GPUOrigin2D;
    source: GPUCopyExternalImageSource;
}

interface GPUDepthStencilState {
    depthBias?: GPUDepthBias;
    depthBiasClamp?: number;
    depthBiasSlopeScale?: number;
    depthCompare?: GPUCompareFunction;
    depthWriteEnabled?: boolean;
    format: GPUTextureFormat;
    stencilBack?: GPUStencilFaceState;
    stencilFront?: GPUStencilFaceState;
    stencilReadMask?: GPUStencilValue;
    stencilWriteMask?: GPUStencilValue;
}

interface GPUDeviceDescriptor extends GPUObjectDescriptorBase {
    defaultQueue?: GPUQueueDescriptor;
    requiredFeatures?: GPUFeatureName[];
    requiredLimits?: Record<string, GPUSize64 | undefined>;
}

interface GPUExtent3DDict {
    depthOrArrayLayers?: GPUIntegerCoordinate;
    height?: GPUIntegerCoordinate;
    width: GPUIntegerCoordinate;
}

interface GPUExternalTextureBindingLayout {
}

interface GPUExternalTextureDescriptor extends GPUObjectDescriptorBase {
    colorSpace?: PredefinedColorSpace;
    source: HTMLVideoElement | VideoFrame;
}

interface GPUFragmentState extends GPUProgrammableStage {
    targets: (GPUColorTargetState | null)[];
}

interface GPUMultisampleState {
    alphaToCoverageEnabled?: boolean;
    count?: GPUSize32;
    mask?: GPUSampleMask;
}

interface GPUObjectDescriptorBase {
    label?: string;
}

interface GPUOrigin2DDict {
    x?: GPUIntegerCoordinate;
    y?: GPUIntegerCoordinate;
}

interface GPUOrigin3DDict {
    x?: GPUIntegerCoordinate;
    y?: GPUIntegerCoordinate;
    z?: GPUIntegerCoordinate;
}

interface GPUPipelineDescriptorBase extends GPUObjectDescriptorBase {
    layout: GPUPipelineLayout | GPUAutoLayoutMode;
}

interface GPUPipelineErrorInit {
    reason: GPUPipelineErrorReason;
}

interface GPUPipelineLayoutDescriptor extends GPUObjectDescriptorBase {
    bindGroupLayouts: (GPUBindGroupLayout | null)[];
}

interface GPUPrimitiveState {
    cullMode?: GPUCullMode;
    frontFace?: GPUFrontFace;
    stripIndexFormat?: GPUIndexFormat;
    topology?: GPUPrimitiveTopology;
    unclippedDepth?: boolean;
}

interface GPUProgrammableStage {
    constants?: Record<string, GPUPipelineConstantValue>;
    entryPoint?: string;
    module: GPUShaderModule;
}

interface GPUQuerySetDescriptor extends GPUObjectDescriptorBase {
    count: GPUSize32;
    type: GPUQueryType;
}

interface GPUQueueDescriptor extends GPUObjectDescriptorBase {
}

interface GPURenderBundleDescriptor extends GPUObjectDescriptorBase {
}

interface GPURenderBundleEncoderDescriptor extends GPURenderPassLayout {
    depthReadOnly?: boolean;
    stencilReadOnly?: boolean;
}

interface GPURenderPassColorAttachment {
    clearValue?: GPUColor;
    depthSlice?: GPUIntegerCoordinate;
    loadOp: GPULoadOp;
    resolveTarget?: GPUTexture | GPUTextureView;
    storeOp: GPUStoreOp;
    view: GPUTexture | GPUTextureView;
}

interface GPURenderPassDepthStencilAttachment {
    depthClearValue?: number;
    depthLoadOp?: GPULoadOp;
    depthReadOnly?: boolean;
    depthStoreOp?: GPUStoreOp;
    stencilClearValue?: GPUStencilValue;
    stencilLoadOp?: GPULoadOp;
    stencilReadOnly?: boolean;
    stencilStoreOp?: GPUStoreOp;
    view: GPUTexture | GPUTextureView;
}

interface GPURenderPassDescriptor extends GPUObjectDescriptorBase {
    colorAttachments: (GPURenderPassColorAttachment | null)[];
    depthStencilAttachment?: GPURenderPassDepthStencilAttachment;
    maxDrawCount?: GPUSize64;
    occlusionQuerySet?: GPUQuerySet;
    timestampWrites?: GPURenderPassTimestampWrites;
}

interface GPURenderPassLayout extends GPUObjectDescriptorBase {
    colorFormats: (GPUTextureFormat | null)[];
    depthStencilFormat?: GPUTextureFormat;
    sampleCount?: GPUSize32;
}

interface GPURenderPassTimestampWrites {
    beginningOfPassWriteIndex?: GPUSize32;
    endOfPassWriteIndex?: GPUSize32;
    querySet: GPUQuerySet;
}

interface GPURenderPipelineDescriptor extends GPUPipelineDescriptorBase {
    depthStencil?: GPUDepthStencilState;
    fragment?: GPUFragmentState;
    multisample?: GPUMultisampleState;
    primitive?: GPUPrimitiveState;
    vertex: GPUVertexState;
}

interface GPURequestAdapterOptions {
    forceFallbackAdapter?: boolean;
    powerPreference?: GPUPowerPreference;
}

interface GPUSamplerBindingLayout {
    type?: GPUSamplerBindingType;
}

interface GPUSamplerDescriptor extends GPUObjectDescriptorBase {
    addressModeU?: GPUAddressMode;
    addressModeV?: GPUAddressMode;
    addressModeW?: GPUAddressMode;
    compare?: GPUCompareFunction;
    lodMaxClamp?: number;
    lodMinClamp?: number;
    magFilter?: GPUFilterMode;
    maxAnisotropy?: number;
    minFilter?: GPUFilterMode;
    mipmapFilter?: GPUMipmapFilterMode;
}

interface GPUShaderModuleDescriptor extends GPUObjectDescriptorBase {
    code: string;
}

interface GPUStencilFaceState {
    compare?: GPUCompareFunction;
    depthFailOp?: GPUStencilOperation;
    failOp?: GPUStencilOperation;
    passOp?: GPUStencilOperation;
}

interface GPUStorageTextureBindingLayout {
    access?: GPUStorageTextureAccess;
    format: GPUTextureFormat;
    viewDimension?: GPUTextureViewDimension;
}

interface GPUTexelCopyBufferInfo extends GPUTexelCopyBufferLayout {
    buffer: GPUBuffer;
}

interface GPUTexelCopyBufferLayout {
    bytesPerRow?: GPUSize32;
    offset?: GPUSize64;
    rowsPerImage?: GPUSize32;
}

interface GPUTexelCopyTextureInfo {
    aspect?: GPUTextureAspect;
    mipLevel?: GPUIntegerCoordinate;
    origin?: GPUOrigin3D;
    texture: GPUTexture;
}

interface GPUTextureBindingLayout {
    multisampled?: boolean;
    sampleType?: GPUTextureSampleType;
    viewDimension?: GPUTextureViewDimension;
}

interface GPUTextureDescriptor extends GPUObjectDescriptorBase {
    dimension?: GPUTextureDimension;
    format: GPUTextureFormat;
    mipLevelCount?: GPUIntegerCoordinate;
    sampleCount?: GPUSize32;
    size: GPUExtent3D;
    usage: GPUTextureUsageFlags;
    viewFormats?: GPUTextureFormat[];
}

interface GPUTextureViewDescriptor extends GPUObjectDescriptorBase {
    arrayLayerCount?: GPUIntegerCoordinate;
    aspect?: GPUTextureAspect;
    baseArrayLayer?: GPUIntegerCoordinate;
    baseMipLevel?: GPUIntegerCoordinate;
    dimension?: GPUTextureViewDimension;
    format?: GPUTextureFormat;
    mipLevelCount?: GPUIntegerCoordinate;
    usage?: GPUTextureUsageFlags;
}

interface GPUUncapturedErrorEventInit extends EventInit {
    error: GPUError;
}

interface GPUVertexAttribute {
    format: GPUVertexFormat;
    offset: GPUSize64;
    shaderLocation: GPUIndex32;
}

interface GPUVertexBufferLayout {
    arrayStride: GPUSize64;
    attributes: GPUVertexAttribute[];
    stepMode?: GPUVertexStepMode;
}

interface GPUVertexState extends GPUProgrammableStage {
    buffers?: (GPUVertexBufferLayout | null)[];
}

interface GainOptions extends AudioNodeOptions {
    gain?: number;
}

interface GamepadEffectParameters {
    duration?: number;
    leftTrigger?: number;
    rightTrigger?: number;
    startDelay?: number;
    strongMagnitude?: number;
    weakMagnitude?: number;
}

interface GamepadEventInit extends EventInit {
    gamepad?: Gamepad | null;
}

interface GetAnimationsOptions {
    subtree?: boolean;
}

interface GetComposedRangesOptions {
    shadowRoots?: ShadowRoot[];
}

interface GetHTMLOptions {
    serializableShadowRoots?: boolean;
    shadowRoots?: ShadowRoot[];
}

interface GetNotificationOptions {
    tag?: string;
}

interface GetRootNodeOptions {
    composed?: boolean;
}

interface HashChangeEventInit extends EventInit {
    newURL?: string;
    oldURL?: string;
}

interface HkdfParams extends Algorithm {
    hash: HashAlgorithmIdentifier;
    info: BufferSource;
    salt: BufferSource;
}

interface HmacImportParams extends Algorithm {
    hash: HashAlgorithmIdentifier;
    length?: number;
}

interface HmacKeyAlgorithm extends KeyAlgorithm {
    hash: KeyAlgorithm;
    length: number;
}

interface HmacKeyGenParams extends Algorithm {
    hash: HashAlgorithmIdentifier;
    length?: number;
}

interface IDBDatabaseInfo {
    name?: string;
    version?: number;
}

interface IDBIndexParameters {
    multiEntry?: boolean;
    unique?: boolean;
}

interface IDBObjectStoreParameters {
    autoIncrement?: boolean;
    keyPath?: string | string[] | null;
}

interface IDBTransactionOptions {
    durability?: IDBTransactionDurability;
}

interface IDBVersionChangeEventInit extends EventInit {
    newVersion?: number | null;
    oldVersion?: number;
}

interface IIRFilterOptions extends AudioNodeOptions {
    feedback: number[];
    feedforward: number[];
}

interface IdleRequestOptions {
    timeout?: number;
}

interface ImageBitmapOptions {
    colorSpaceConversion?: ColorSpaceConversion;
    imageOrientation?: ImageOrientation;
    premultiplyAlpha?: PremultiplyAlpha;
    resizeHeight?: number;
    resizeQuality?: ResizeQuality;
    resizeWidth?: number;
}

interface ImageBitmapRenderingContextSettings {
    alpha?: boolean;
}

interface ImageDataSettings {
    colorSpace?: PredefinedColorSpace;
    pixelFormat?: ImageDataPixelFormat;
}

interface ImageDecodeOptions {
    completeFramesOnly?: boolean;
    frameIndex?: number;
}

interface ImageDecodeResult {
    complete: boolean;
    image: VideoFrame;
}

interface ImageDecoderInit {
    colorSpaceConversion?: ColorSpaceConversion;
    data: ImageBufferSource;
    desiredHeight?: number;
    desiredWidth?: number;
    preferAnimation?: boolean;
    transfer?: ArrayBuffer[];
    type: string;
}

interface ImageEncodeOptions {
    quality?: number;
    type?: string;
}

interface ImportNodeOptions {
    customElementRegistry?: CustomElementRegistry;
    selfOnly?: boolean;
}

interface InputEventInit extends UIEventInit {
    data?: string | null;
    dataTransfer?: DataTransfer | null;
    inputType?: string;
    isComposing?: boolean;
    targetRanges?: StaticRange[];
}

interface IntersectionObserverInit {
    root?: Element | Document | null;
    rootMargin?: string;
    scrollMargin?: string;
    threshold?: number | number[];
}

interface JsonWebKey {
    alg?: string;
    crv?: string;
    d?: string;
    dp?: string;
    dq?: string;
    e?: string;
    ext?: boolean;
    k?: string;
    key_ops?: string[];
    kty?: string;
    n?: string;
    oth?: RsaOtherPrimesInfo[];
    p?: string;
    q?: string;
    qi?: string;
    use?: string;
    x?: string;
    y?: string;
}

interface KeyAlgorithm {
    name: string;
}

interface KeySystemTrackConfiguration {
    robustness?: string;
}

interface KeyboardEventInit extends EventModifierInit {
    /** @deprecated `charCode` is inconsistent across environments, consider using `key` instead. */
    charCode?: number;
    code?: string;
    isComposing?: boolean;
    key?: string;
    /** @deprecated `keyCode` is inconsistent across environments, consider using `key` instead. */
    keyCode?: number;
    location?: number;
    repeat?: boolean;
}

interface Keyframe {
    composite?: CompositeOperationOrAuto;
    easing?: string;
    offset?: number | null;
    [property: string]: string | number | null | undefined;
}

interface KeyframeAnimationOptions extends KeyframeEffectOptions {
    id?: string;
    rangeEnd?: TimelineRangeOffset | CSSNumericValue | CSSKeywordValue | string;
    rangeStart?: TimelineRangeOffset | CSSNumericValue | CSSKeywordValue | string;
    timeline?: AnimationTimeline | null;
}

interface KeyframeEffectOptions extends EffectTiming {
    composite?: CompositeOperation;
    iterationComposite?: IterationCompositeOperation;
    pseudoElement?: string | null;
}

interface LockInfo {
    clientId?: string;
    mode?: LockMode;
    name?: string;
}

interface LockManagerSnapshot {
    held?: LockInfo[];
    pending?: LockInfo[];
}

interface LockOptions {
    ifAvailable?: boolean;
    mode?: LockMode;
    signal?: AbortSignal;
    steal?: boolean;
}

interface MIDIConnectionEventInit extends EventInit {
    port?: MIDIPort;
}

interface MIDIMessageEventInit extends EventInit {
    data?: Uint8Array<ArrayBuffer>;
}

interface MIDIOptions {
    software?: boolean;
    sysex?: boolean;
}

interface MediaCapabilitiesDecodingInfo extends MediaCapabilitiesInfo {
    keySystemAccess: MediaKeySystemAccess | null;
}

interface MediaCapabilitiesEncodingInfo extends MediaCapabilitiesInfo {
}

interface MediaCapabilitiesInfo {
    powerEfficient: boolean;
    smooth: boolean;
    supported: boolean;
}

interface MediaCapabilitiesKeySystemConfiguration {
    audio?: KeySystemTrackConfiguration;
    distinctiveIdentifier?: MediaKeysRequirement;
    initDataType?: string;
    keySystem: string;
    persistentState?: MediaKeysRequirement;
    sessionTypes?: string[];
    video?: KeySystemTrackConfiguration;
}

interface MediaConfiguration {
    audio?: AudioConfiguration;
    video?: VideoConfiguration;
}

interface MediaDecodingConfiguration extends MediaConfiguration {
    keySystemConfiguration?: MediaCapabilitiesKeySystemConfiguration;
    type: MediaDecodingType;
}

interface MediaElementAudioSourceOptions {
    mediaElement: HTMLMediaElement;
}

interface MediaEncodingConfiguration extends MediaConfiguration {
    type: MediaEncodingType;
}

interface MediaEncryptedEventInit extends EventInit {
    initData?: ArrayBuffer | null;
    initDataType?: string;
}

interface MediaImage {
    sizes?: string;
    src: string;
    type?: string;
}

interface MediaKeyMessageEventInit extends EventInit {
    message: ArrayBuffer;
    messageType: MediaKeyMessageType;
}

interface MediaKeySystemConfiguration {
    audioCapabilities?: MediaKeySystemMediaCapability[];
    distinctiveIdentifier?: MediaKeysRequirement;
    initDataTypes?: string[];
    label?: string;
    persistentState?: MediaKeysRequirement;
    sessionTypes?: string[];
    videoCapabilities?: MediaKeySystemMediaCapability[];
}

interface MediaKeySystemMediaCapability {
    contentType?: string;
    encryptionScheme?: string | null;
    robustness?: string;
}

interface MediaKeysPolicy {
    minHdcpVersion?: string;
}

interface MediaMetadataInit {
    album?: string;
    artist?: string;
    artwork?: MediaImage[];
    title?: string;
}

interface MediaPositionState {
    duration?: number;
    playbackRate?: number;
    position?: number;
}

interface MediaQueryListEventInit extends EventInit {
    matches?: boolean;
    media?: string;
}

interface MediaRecorderOptions {
    audioBitsPerSecond?: number;
    bitsPerSecond?: number;
    mimeType?: string;
    videoBitsPerSecond?: number;
}

interface MediaSessionActionDetails {
    action: MediaSessionAction;
    fastSeek?: boolean;
    seekOffset?: number;
    seekTime?: number;
}

interface MediaSettingsRange {
    max?: number;
    min?: number;
    step?: number;
}

interface MediaStreamAudioSourceOptions {
    mediaStream: MediaStream;
}

interface MediaStreamConstraints {
    audio?: boolean | MediaTrackConstraints;
    peerIdentity?: string;
    preferCurrentTab?: boolean;
    video?: boolean | MediaTrackConstraints;
}

interface MediaStreamTrackEventInit extends EventInit {
    track: MediaStreamTrack;
}

interface MediaTrackCapabilities {
    aspectRatio?: DoubleRange;
    autoGainControl?: boolean[];
    backgroundBlur?: boolean[];
    channelCount?: ULongRange;
    deviceId?: string;
    displaySurface?: string;
    echoCancellation?: (boolean | string)[];
    facingMode?: string[];
    frameRate?: DoubleRange;
    groupId?: string;
    height?: ULongRange;
    noiseSuppression?: boolean[];
    sampleRate?: ULongRange;
    sampleSize?: ULongRange;
    width?: ULongRange;
}

interface MediaTrackConstraintSet {
    aspectRatio?: ConstrainDouble;
    autoGainControl?: ConstrainBoolean;
    backgroundBlur?: ConstrainBoolean;
    channelCount?: ConstrainULong;
    deviceId?: ConstrainDOMString;
    displaySurface?: ConstrainDOMString;
    echoCancellation?: ConstrainBooleanOrDOMString;
    facingMode?: ConstrainDOMString;
    frameRate?: ConstrainDouble;
    groupId?: ConstrainDOMString;
    height?: ConstrainULong;
    noiseSuppression?: ConstrainBoolean;
    sampleRate?: ConstrainULong;
    sampleSize?: ConstrainULong;
    width?: ConstrainULong;
}

interface MediaTrackConstraints extends MediaTrackConstraintSet {
    advanced?: MediaTrackConstraintSet[];
}

interface MediaTrackSettings {
    aspectRatio?: number;
    autoGainControl?: boolean;
    backgroundBlur?: boolean;
    channelCount?: number;
    deviceId?: string;
    displaySurface?: string;
    echoCancellation?: boolean | string;
    facingMode?: string;
    frameRate?: number;
    groupId?: string;
    height?: number;
    noiseSuppression?: boolean;
    sampleRate?: number;
    sampleSize?: number;
    torch?: boolean;
    whiteBalanceMode?: string;
    width?: number;
    zoom?: number;
}

interface MediaTrackSupportedConstraints {
    aspectRatio?: boolean;
    autoGainControl?: boolean;
    backgroundBlur?: boolean;
    channelCount?: boolean;
    deviceId?: boolean;
    displaySurface?: boolean;
    echoCancellation?: boolean;
    facingMode?: boolean;
    frameRate?: boolean;
    groupId?: boolean;
    height?: boolean;
    noiseSuppression?: boolean;
    sampleRate?: boolean;
    sampleSize?: boolean;
    width?: boolean;
}

interface MessageEventInit<T = any> extends EventInit {
    data?: T;
    lastEventId?: string;
    origin?: string;
    ports?: MessagePort[];
    source?: MessageEventSource | null;
}

interface MouseEventInit extends EventModifierInit {
    button?: number;
    buttons?: number;
    clientX?: number;
    clientY?: number;
    movementX?: number;
    movementY?: number;
    relatedTarget?: EventTarget | null;
    screenX?: number;
    screenY?: number;
}

interface MultiCacheQueryOptions extends CacheQueryOptions {
    cacheName?: string;
}

interface MutationObserverInit {
    /** Set to a list of attribute local names (without namespace) if not all attribute mutations need to be observed and attributes is true or omitted. */
    attributeFilter?: string[];
    /** Set to true if attributes is true or omitted and target's attribute value before the mutation needs to be recorded. */
    attributeOldValue?: boolean;
    /** Set to true if mutations to target's attributes are to be observed. Can be omitted if attributeOldValue or attributeFilter is specified. */
    attributes?: boolean;
    /** Set to true if mutations to target's data are to be observed. Can be omitted if characterDataOldValue is specified. */
    characterData?: boolean;
    /** Set to true if characterData is set to true or omitted and target's data before the mutation needs to be recorded. */
    characterDataOldValue?: boolean;
    /** Set to true if mutations to target's children are to be observed. */
    childList?: boolean;
    /** Set to true if mutations to not just target, but also target's descendants are to be observed. */
    subtree?: boolean;
}

interface NavigateEventInit extends EventInit {
    canIntercept?: boolean;
    destination: NavigationDestination;
    downloadRequest?: string | null;
    formData?: FormData | null;
    hasUAVisualTransition?: boolean;
    hashChange?: boolean;
    info?: any;
    navigationType?: NavigationType;
    signal: AbortSignal;
    sourceElement?: Element | null;
    userInitiated?: boolean;
}

interface NavigationCurrentEntryChangeEventInit extends EventInit {
    from: NavigationHistoryEntry;
    navigationType?: NavigationType | null;
}

interface NavigationInterceptOptions {
    focusReset?: NavigationFocusReset;
    handler?: NavigationInterceptHandler;
    precommitHandler?: NavigationPrecommitHandler;
    scroll?: NavigationScrollBehavior;
}

interface NavigationNavigateOptions extends NavigationOptions {
    history?: NavigationHistoryBehavior;
    state?: any;
}

interface NavigationOptions {
    info?: any;
}

interface NavigationPreloadState {
    enabled?: boolean;
    headerValue?: string;
}

interface NavigationReloadOptions extends NavigationOptions {
    state?: any;
}

interface NavigationResult {
    committed?: Promise<NavigationHistoryEntry>;
    finished?: Promise<NavigationHistoryEntry>;
}

interface NavigationUpdateCurrentEntryOptions {
    state: any;
}

interface NotificationOptions {
    badge?: string;
    body?: string;
    data?: any;
    dir?: NotificationDirection;
    icon?: string;
    lang?: string;
    requireInteraction?: boolean;
    silent?: boolean | null;
    tag?: string;
}

interface OfflineAudioCompletionEventInit extends EventInit {
    renderedBuffer: AudioBuffer;
}

interface OfflineAudioContextOptions {
    length: number;
    numberOfChannels?: number;
    sampleRate: number;
}

interface OptionalEffectTiming {
    delay?: number;
    direction?: PlaybackDirection;
    duration?: number | string;
    easing?: string;
    endDelay?: number;
    fill?: FillMode;
    iterationStart?: number;
    iterations?: number;
    playbackRate?: number;
}

interface OpusEncoderConfig {
    complexity?: number;
    format?: OpusBitstreamFormat;
    frameDuration?: number;
    packetlossperc?: number;
    usedtx?: boolean;
    useinbandfec?: boolean;
}

interface OscillatorOptions extends AudioNodeOptions {
    detune?: number;
    frequency?: number;
    periodicWave?: PeriodicWave;
    type?: OscillatorType;
}

interface PageRevealEventInit extends EventInit {
    viewTransition?: ViewTransition | null;
}

interface PageSwapEventInit extends EventInit {
    activation?: NavigationActivation | null;
    viewTransition?: ViewTransition | null;
}

interface PageTransitionEventInit extends EventInit {
    persisted?: boolean;
}

interface PannerOptions extends AudioNodeOptions {
    coneInnerAngle?: number;
    coneOuterAngle?: number;
    coneOuterGain?: number;
    distanceModel?: DistanceModelType;
    maxDistance?: number;
    orientationX?: number;
    orientationY?: number;
    orientationZ?: number;
    panningModel?: PanningModelType;
    positionX?: number;
    positionY?: number;
    positionZ?: number;
    refDistance?: number;
    rolloffFactor?: number;
}

interface PayerErrors {
    email?: string;
    name?: string;
    phone?: string;
}

interface PaymentCurrencyAmount {
    currency: string;
    value: string;
}

interface PaymentDetailsBase {
    displayItems?: PaymentItem[];
    modifiers?: PaymentDetailsModifier[];
    shippingOptions?: PaymentShippingOption[];
}

interface PaymentDetailsInit extends PaymentDetailsBase {
    id?: string;
    total: PaymentItem;
}

interface PaymentDetailsModifier {
    additionalDisplayItems?: PaymentItem[];
    data?: any;
    supportedMethods: string;
    total?: PaymentItem;
}

interface PaymentDetailsUpdate extends PaymentDetailsBase {
    error?: string;
    paymentMethodErrors?: any;
    shippingAddressErrors?: AddressErrors;
    total?: PaymentItem;
}

interface PaymentItem {
    amount: PaymentCurrencyAmount;
    label: string;
    pending?: boolean;
}

interface PaymentMethodChangeEventInit extends PaymentRequestUpdateEventInit {
    methodDetails?: any;
    methodName?: string;
}

interface PaymentMethodData {
    data?: any;
    supportedMethods: string;
}

interface PaymentOptions {
    requestPayerEmail?: boolean;
    requestPayerName?: boolean;
    requestPayerPhone?: boolean;
    requestShipping?: boolean;
    shippingType?: PaymentShippingType;
}

interface PaymentRequestUpdateEventInit extends EventInit {
}

interface PaymentShippingOption {
    amount: PaymentCurrencyAmount;
    id: string;
    label: string;
    selected?: boolean;
}

interface PaymentValidationErrors {
    error?: string;
    payer?: PayerErrors;
    shippingAddress?: AddressErrors;
}

interface Pbkdf2Params extends Algorithm {
    hash: HashAlgorithmIdentifier;
    iterations: number;
    salt: BufferSource;
}

interface PerformanceMarkOptions {
    detail?: any;
    startTime?: DOMHighResTimeStamp;
}

interface PerformanceMeasureOptions {
    detail?: any;
    duration?: DOMHighResTimeStamp;
    end?: string | DOMHighResTimeStamp;
    start?: string | DOMHighResTimeStamp;
}

interface PerformanceObserverInit {
    buffered?: boolean;
    entryTypes?: string[];
    type?: string;
}

interface PeriodicWaveConstraints {
    disableNormalization?: boolean;
}

interface PeriodicWaveOptions extends PeriodicWaveConstraints {
    imag?: number[] | Float32Array;
    real?: number[] | Float32Array;
}

interface PermissionDescriptor {
    name: PermissionName;
}

interface PhotoCapabilities {
    fillLightMode?: FillLightMode[];
    imageHeight?: MediaSettingsRange;
    imageWidth?: MediaSettingsRange;
    redEyeReduction?: RedEyeReduction;
}

interface PhotoSettings {
    fillLightMode?: FillLightMode;
    imageHeight?: number;
    imageWidth?: number;
    redEyeReduction?: boolean;
}

interface PictureInPictureEventInit extends EventInit {
    pictureInPictureWindow: PictureInPictureWindow;
}

interface PlaneLayout {
    offset: number;
    stride: number;
}

interface PointerEventInit extends MouseEventInit {
    altitudeAngle?: number;
    azimuthAngle?: number;
    coalescedEvents?: PointerEvent[];
    height?: number;
    isPrimary?: boolean;
    pointerId?: number;
    pointerType?: string;
    predictedEvents?: PointerEvent[];
    pressure?: number;
    tangentialPressure?: number;
    tiltX?: number;
    tiltY?: number;
    twist?: number;
    width?: number;
}

interface PointerLockOptions {
    unadjustedMovement?: boolean;
}

interface PopStateEventInit extends EventInit {
    hasUAVisualTransition?: boolean;
    state?: any;
}

interface PositionOptions {
    enableHighAccuracy?: boolean;
    maximumAge?: number;
    timeout?: number;
}

interface ProgressEventInit extends EventInit {
    lengthComputable?: boolean;
    loaded?: number;
    total?: number;
}

interface PromiseRejectionEventInit extends EventInit {
    promise: Promise<any>;
    reason?: any;
}

interface PropertyDefinition {
    inherits: boolean;
    initialValue?: string;
    name: string;
    syntax?: string;
}

interface PropertyIndexedKeyframes {
    composite?: CompositeOperationOrAuto | CompositeOperationOrAuto[];
    easing?: string | string[];
    offset?: number | (number | null)[];
    [property: string]: string | string[] | number | null | (number | null)[] | undefined;
}

interface PublicKeyCredentialCreationOptions {
    attestation?: AttestationConveyancePreference;
    authenticatorSelection?: AuthenticatorSelectionCriteria;
    challenge: BufferSource;
    excludeCredentials?: PublicKeyCredentialDescriptor[];
    extensions?: AuthenticationExtensionsClientInputs;
    pubKeyCredParams: PublicKeyCredentialParameters[];
    rp: PublicKeyCredentialRpEntity;
    timeout?: number;
    user: PublicKeyCredentialUserEntity;
}

interface PublicKeyCredentialCreationOptionsJSON {
    attestation?: string;
    authenticatorSelection?: AuthenticatorSelectionCriteria;
    challenge: Base64URLString;
    excludeCredentials?: PublicKeyCredentialDescriptorJSON[];
    extensions?: AuthenticationExtensionsClientInputsJSON;
    hints?: string[];
    pubKeyCredParams: PublicKeyCredentialParameters[];
    rp: PublicKeyCredentialRpEntity;
    timeout?: number;
    user: PublicKeyCredentialUserEntityJSON;
}

interface PublicKeyCredentialDescriptor {
    id: BufferSource;
    transports?: AuthenticatorTransport[];
    type: PublicKeyCredentialType;
}

interface PublicKeyCredentialDescriptorJSON {
    id: Base64URLString;
    transports?: string[];
    type: string;
}

interface PublicKeyCredentialEntity {
    name: string;
}

interface PublicKeyCredentialParameters {
    alg: COSEAlgorithmIdentifier;
    type: PublicKeyCredentialType;
}

interface PublicKeyCredentialRequestOptions {
    allowCredentials?: PublicKeyCredentialDescriptor[];
    challenge: BufferSource;
    extensions?: AuthenticationExtensionsClientInputs;
    rpId?: string;
    timeout?: number;
    userVerification?: UserVerificationRequirement;
}

interface PublicKeyCredentialRequestOptionsJSON {
    allowCredentials?: PublicKeyCredentialDescriptorJSON[];
    challenge: Base64URLString;
    extensions?: AuthenticationExtensionsClientInputsJSON;
    hints?: string[];
    rpId?: string;
    timeout?: number;
    userVerification?: string;
}

interface PublicKeyCredentialRpEntity extends PublicKeyCredentialEntity {
    id?: string;
}

interface PublicKeyCredentialUserEntity extends PublicKeyCredentialEntity {
    displayName: string;
    id: BufferSource;
}

interface PublicKeyCredentialUserEntityJSON {
    displayName: string;
    id: Base64URLString;
    name: string;
}

interface PushSubscriptionJSON {
    endpoint?: string;
    expirationTime?: EpochTimeStamp | null;
    keys?: Record<string, string>;
}

interface PushSubscriptionOptionsInit {
    applicationServerKey?: BufferSource | string | null;
    userVisibleOnly?: boolean;
}

interface QueuingStrategy<T = any> {
    highWaterMark?: number;
    size?: QueuingStrategySize<T>;
}

interface QueuingStrategyInit {
    /**
     * Creates a new ByteLengthQueuingStrategy with the provided high water mark.
     *
     * Note that the provided high water mark will not be validated ahead of time. Instead, if it is negative, NaN, or not a number, the resulting ByteLengthQueuingStrategy will cause the corresponding stream constructor to throw.
     */
    highWaterMark: number;
}

interface RTCAnswerOptions extends RTCOfferAnswerOptions {
}

interface RTCCertificateExpiration {
    expires?: number;
}

interface RTCConfiguration {
    bundlePolicy?: RTCBundlePolicy;
    certificates?: RTCCertificate[];
    iceCandidatePoolSize?: number;
    iceServers?: RTCIceServer[];
    iceTransportPolicy?: RTCIceTransportPolicy;
    rtcpMuxPolicy?: RTCRtcpMuxPolicy;
}

interface RTCDTMFToneChangeEventInit extends EventInit {
    tone?: string;
}

interface RTCDataChannelEventInit extends EventInit {
    channel: RTCDataChannel;
}

interface RTCDataChannelInit {
    id?: number;
    maxPacketLifeTime?: number;
    maxRetransmits?: number;
    negotiated?: boolean;
    ordered?: boolean;
    protocol?: string;
}

interface RTCDtlsFingerprint {
    algorithm?: string;
    value?: string;
}

interface RTCEncodedAudioFrameMetadata extends RTCEncodedFrameMetadata {
    sequenceNumber?: number;
}

interface RTCEncodedFrameMetadata {
    contributingSources?: number[];
    mimeType?: string;
    payloadType?: number;
    rtpTimestamp?: number;
    synchronizationSource?: number;
}

interface RTCEncodedVideoFrameMetadata extends RTCEncodedFrameMetadata {
    dependencies?: number[];
    frameId?: number;
    height?: number;
    spatialIndex?: number;
    temporalIndex?: number;
    timestamp?: number;
    width?: number;
}

interface RTCErrorEventInit extends EventInit {
    error: RTCError;
}

interface RTCErrorInit {
    errorDetail: RTCErrorDetailType;
    httpRequestStatusCode?: number;
    receivedAlert?: number;
    sctpCauseCode?: number;
    sdpLineNumber?: number;
    sentAlert?: number;
}

interface RTCIceCandidateInit {
    candidate?: string;
    sdpMLineIndex?: number | null;
    sdpMid?: string | null;
    usernameFragment?: string | null;
}

interface RTCIceCandidatePairStats extends RTCStats {
    availableIncomingBitrate?: number;
    availableOutgoingBitrate?: number;
    bytesDiscardedOnSend?: number;
    bytesReceived?: number;
    bytesSent?: number;
    consentRequestsSent?: number;
    currentRoundTripTime?: number;
    lastPacketReceivedTimestamp?: DOMHighResTimeStamp;
    lastPacketSentTimestamp?: DOMHighResTimeStamp;
    localCandidateId: string;
    nominated?: boolean;
    packetsDiscardedOnSend?: number;
    packetsReceived?: number;
    packetsSent?: number;
    remoteCandidateId: string;
    requestsReceived?: number;
    requestsSent?: number;
    responsesReceived?: number;
    responsesSent?: number;
    state: RTCStatsIceCandidatePairState;
    totalRoundTripTime?: number;
    transportId: string;
}

interface RTCIceServer {
    credential?: string;
    urls: string | string[];
    username?: string;
}

interface RTCInboundRtpStreamStats extends RTCReceivedRtpStreamStats {
    audioLevel?: number;
    bytesReceived?: number;
    concealedSamples?: number;
    concealmentEvents?: number;
    decoderImplementation?: string;
    estimatedPlayoutTimestamp?: DOMHighResTimeStamp;
    fecBytesReceived?: number;
    fecPacketsDiscarded?: number;
    fecPacketsReceived?: number;
    fecSsrc?: number;
    firCount?: number;
    frameHeight?: number;
    frameWidth?: number;
    framesAssembledFromMultiplePackets?: number;
    framesDecoded?: number;
    framesDropped?: number;
    framesPerSecond?: number;
    framesReceived?: number;
    framesRendered?: number;
    freezeCount?: number;
    headerBytesReceived?: number;
    insertedSamplesForDeceleration?: number;
    jitterBufferDelay?: number;
    jitterBufferEmittedCount?: number;
    jitterBufferMinimumDelay?: number;
    jitterBufferTargetDelay?: number;
    keyFramesDecoded?: number;
    lastPacketReceivedTimestamp?: DOMHighResTimeStamp;
    mid?: string;
    nackCount?: number;
    packetsDiscarded?: number;
    pauseCount?: number;
    playoutId?: string;
    pliCount?: number;
    qpSum?: number;
    remoteId?: string;
    removedSamplesForAcceleration?: number;
    retransmittedBytesReceived?: number;
    retransmittedPacketsReceived?: number;
    rtxSsrc?: number;
    silentConcealedSamples?: number;
    totalAssemblyTime?: number;
    totalAudioEnergy?: number;
    totalDecodeTime?: number;
    totalFreezesDuration?: number;
    totalInterFrameDelay?: number;
    totalPausesDuration?: number;
    totalProcessingDelay?: number;
    totalSamplesDuration?: number;
    totalSamplesReceived?: number;
    totalSquaredInterFrameDelay?: number;
    trackIdentifier: string;
}

interface RTCLocalIceCandidateInit extends RTCIceCandidateInit {
}

interface RTCLocalSessionDescriptionInit {
    sdp?: string;
    type?: RTCSdpType;
}

interface RTCOfferAnswerOptions {
}

interface RTCOfferOptions extends RTCOfferAnswerOptions {
    iceRestart?: boolean;
    offerToReceiveAudio?: boolean;
    offerToReceiveVideo?: boolean;
}

interface RTCOutboundRtpStreamStats extends RTCSentRtpStreamStats {
    active?: boolean;
    firCount?: number;
    frameHeight?: number;
    frameWidth?: number;
    framesEncoded?: number;
    framesPerSecond?: number;
    framesSent?: number;
    headerBytesSent?: number;
    hugeFramesSent?: number;
    keyFramesEncoded?: number;
    mediaSourceId?: string;
    mid?: string;
    nackCount?: number;
    pliCount?: number;
    qpSum?: number;
    qualityLimitationDurations?: Record<string, number>;
    qualityLimitationReason?: RTCQualityLimitationReason;
    qualityLimitationResolutionChanges?: number;
    remoteId?: string;
    retransmittedBytesSent?: number;
    retransmittedPacketsSent?: number;
    rid?: string;
    rtxSsrc?: number;
    scalabilityMode?: string;
    targetBitrate?: number;
    totalEncodeTime?: number;
    totalEncodedBytesTarget?: number;
    totalPacketSendDelay?: number;
}

interface RTCPeerConnectionIceErrorEventInit extends EventInit {
    address?: string | null;
    errorCode: number;
    errorText?: string;
    port?: number | null;
    url?: string;
}

interface RTCPeerConnectionIceEventInit extends EventInit {
    candidate?: RTCIceCandidate | null;
}

interface RTCReceivedRtpStreamStats extends RTCRtpStreamStats {
    jitter?: number;
    packetsLost?: number;
    packetsReceived?: number;
}

interface RTCRtcpParameters {
    cname?: string;
    reducedSize?: boolean;
}

interface RTCRtpCapabilities {
    codecs: RTCRtpCodec[];
    headerExtensions: RTCRtpHeaderExtensionCapability[];
}

interface RTCRtpCodec {
    channels?: number;
    clockRate: number;
    mimeType: string;
    sdpFmtpLine?: string;
}

interface RTCRtpCodecParameters extends RTCRtpCodec {
    payloadType: number;
}

interface RTCRtpCodingParameters {
    rid?: string;
}

interface RTCRtpContributingSource {
    audioLevel?: number;
    rtpTimestamp: number;
    source: number;
    timestamp: DOMHighResTimeStamp;
}

interface RTCRtpEncodingParameters extends RTCRtpCodingParameters {
    active?: boolean;
    maxBitrate?: number;
    maxFramerate?: number;
    networkPriority?: RTCPriorityType;
    priority?: RTCPriorityType;
    scaleResolutionDownBy?: number;
}

interface RTCRtpHeaderExtensionCapability {
    uri: string;
}

interface RTCRtpHeaderExtensionParameters {
    encrypted?: boolean;
    id: number;
    uri: string;
}

interface RTCRtpParameters {
    codecs: RTCRtpCodecParameters[];
    headerExtensions: RTCRtpHeaderExtensionParameters[];
    rtcp: RTCRtcpParameters;
}

interface RTCRtpReceiveParameters extends RTCRtpParameters {
}

interface RTCRtpSendParameters extends RTCRtpParameters {
    degradationPreference?: RTCDegradationPreference;
    encodings: RTCRtpEncodingParameters[];
    transactionId: string;
}

interface RTCRtpStreamStats extends RTCStats {
    codecId?: string;
    kind: string;
    ssrc: number;
    transportId?: string;
}

interface RTCRtpSynchronizationSource extends RTCRtpContributingSource {
}

interface RTCRtpTransceiverInit {
    direction?: RTCRtpTransceiverDirection;
    sendEncodings?: RTCRtpEncodingParameters[];
    streams?: MediaStream[];
}

interface RTCSentRtpStreamStats extends RTCRtpStreamStats {
    bytesSent?: number;
    packetsSent?: number;
}

interface RTCSessionDescriptionInit {
    sdp?: string;
    type: RTCSdpType;
}

interface RTCSetParameterOptions {
}

interface RTCStats {
    id: string;
    timestamp: DOMHighResTimeStamp;
    type: RTCStatsType;
}

interface RTCTrackEventInit extends EventInit {
    receiver: RTCRtpReceiver;
    streams?: MediaStream[];
    track: MediaStreamTrack;
    transceiver: RTCRtpTransceiver;
}

interface RTCTransportStats extends RTCStats {
    bytesReceived?: number;
    bytesSent?: number;
    dtlsCipher?: string;
    dtlsRole?: RTCDtlsRole;
    dtlsState: RTCDtlsTransportState;
    iceLocalUsernameFragment?: string;
    iceRole?: RTCIceRole;
    iceState?: RTCIceTransportState;
    localCertificateId?: string;
    packetsReceived?: number;
    packetsSent?: number;
    remoteCertificateId?: string;
    selectedCandidatePairChanges?: number;
    selectedCandidatePairId?: string;
    srtpCipher?: string;
    tlsVersion?: string;
}

interface ReadableStreamBYOBReaderReadOptions {
    min?: number;
}

interface ReadableStreamGetReaderOptions {
    /**
     * Creates a ReadableStreamBYOBReader and locks the stream to the new reader.
     *
     * This call behaves the same way as the no-argument variant, except that it only works on readable byte streams, i.e. streams which were constructed specifically with the ability to handle "bring your own buffer" reading. The returned BYOB reader provides the ability to directly read individual chunks from the stream via its read() method, into developer-supplied buffers, allowing more precise control over allocation.
     */
    mode?: ReadableStreamReaderMode;
}

interface ReadableStreamIteratorOptions {
    /**
     * Asynchronously iterates over the chunks in the stream's internal queue.
     *
     * Asynchronously iterating over the stream will lock it, preventing any other consumer from acquiring a reader. The lock will be released if the async iterator's return() method is called, e.g. by breaking out of the loop.
     *
     * By default, calling the async iterator's return() method will also cancel the stream. To prevent this, use the stream's values() method, passing true for the preventCancel option.
     */
    preventCancel?: boolean;
}

interface ReadableStreamReadDoneResult<T> {
    done: true;
    value: T | undefined;
}

interface ReadableStreamReadValueResult<T> {
    done: false;
    value: T;
}

interface ReadableWritablePair<R = any, W = any> {
    readable: ReadableStream<R>;
    /**
     * Provides a convenient, chainable way of piping this readable stream through a transform stream (or any other { writable, readable } pair). It simply pipes the stream into the writable side of the supplied pair, and returns the readable side for further use.
     *
     * Piping a stream will lock it for the duration of the pipe, preventing any other consumer from acquiring a reader.
     */
    writable: WritableStream<W>;
}

interface RegistrationOptions {
    scope?: string;
    type?: WorkerType;
    updateViaCache?: ServiceWorkerUpdateViaCache;
}

interface RegistrationResponseJSON {
    authenticatorAttachment?: string;
    clientExtensionResults: AuthenticationExtensionsClientOutputsJSON;
    id: string;
    rawId: Base64URLString;
    response: AuthenticatorAttestationResponseJSON;
    type: string;
}

interface Report {
    body?: ReportBody | null;
    type?: string;
    url?: string;
}

interface ReportBody {
}

interface ReportingObserverOptions {
    buffered?: boolean;
    types?: string[];
}

interface RequestInit {
    /** A BodyInit object or null to set request's body. */
    body?: BodyInit | null;
    /** A string indicating how the request will interact with the browser's cache to set request's cache. */
    cache?: RequestCache;
    /** A string indicating whether credentials will be sent with the request always, never, or only when sent to a same-origin URL. Sets request's credentials. */
    credentials?: RequestCredentials;
    /** A Headers object, an object literal, or an array of two-item arrays to set request's headers. */
    headers?: HeadersInit;
    /** A cryptographic hash of the resource to be fetched by request. Sets request's integrity. */
    integrity?: string;
    /** A boolean to set request's keepalive. */
    keepalive?: boolean;
    /** A string to set request's method. */
    method?: string;
    /** A string to indicate whether the request will use CORS, or will be restricted to same-origin URLs. Sets request's mode. */
    mode?: RequestMode;
    priority?: RequestPriority;
    /** A string indicating whether request follows redirects, results in an error upon encountering a redirect, or returns the redirect (in an opaque fashion). Sets request's redirect. */
    redirect?: RequestRedirect;
    /** A string whose value is a same-origin URL, "about:client", or the empty string, to set request's referrer. */
    referrer?: string;
    /** A referrer policy to set request's referrerPolicy. */
    referrerPolicy?: ReferrerPolicy;
    /** An AbortSignal to set request's signal. */
    signal?: AbortSignal | null;
    /** Can only be null. Used to disassociate request from any Window. */
    window?: null;
}

interface ResizeObserverOptions {
    box?: ResizeObserverBoxOptions;
}

interface ResponseInit {
    headers?: HeadersInit;
    status?: number;
    statusText?: string;
}

interface RsaHashedImportParams extends Algorithm {
    hash: HashAlgorithmIdentifier;
}

interface RsaHashedKeyAlgorithm extends RsaKeyAlgorithm {
    hash: KeyAlgorithm;
}

interface RsaHashedKeyGenParams extends RsaKeyGenParams {
    hash: HashAlgorithmIdentifier;
}

interface RsaKeyAlgorithm extends KeyAlgorithm {
    modulusLength: number;
    publicExponent: BigInteger;
}

interface RsaKeyGenParams extends Algorithm {
    modulusLength: number;
    publicExponent: BigInteger;
}

interface RsaOaepParams extends Algorithm {
    label?: BufferSource;
}

interface RsaOtherPrimesInfo {
    d?: string;
    r?: string;
    t?: string;
}

interface RsaPssParams extends Algorithm {
    saltLength: number;
}

interface SVGBoundingBoxOptions {
    clipped?: boolean;
    fill?: boolean;
    markers?: boolean;
    stroke?: boolean;
}

interface SanitizerAttributeNamespace {
    name: string;
    namespace?: string | null;
}

interface SanitizerConfig {
    attributes?: SanitizerAttribute[];
    comments?: boolean;
    dataAttributes?: boolean;
    elements?: SanitizerElementWithAttributes[];
    removeAttributes?: SanitizerAttribute[];
    removeElements?: SanitizerElement[];
    replaceWithChildrenElements?: SanitizerElement[];
}

interface SanitizerElementNamespace {
    name: string;
    namespace?: string | null;
}

interface SanitizerElementNamespaceWithAttributes extends SanitizerElementNamespace {
    attributes?: SanitizerAttribute[];
    removeAttributes?: SanitizerAttribute[];
}

interface SchedulerPostTaskOptions {
    delay?: number;
    priority?: TaskPriority;
    signal?: AbortSignal;
}

interface ScrollIntoViewOptions extends ScrollOptions {
    block?: ScrollLogicalPosition;
    inline?: ScrollLogicalPosition;
}

interface ScrollOptions {
    behavior?: ScrollBehavior;
}

interface ScrollTimelineOptions {
    axis?: ScrollAxis;
    source?: Element | null;
}

interface ScrollToOptions extends ScrollOptions {
    left?: number;
    top?: number;
}

interface SecurityPolicyViolationEventInit extends EventInit {
    blockedURI?: string;
    columnNumber?: number;
    disposition?: SecurityPolicyViolationEventDisposition;
    documentURI?: string;
    effectiveDirective?: string;
    lineNumber?: number;
    originalPolicy?: string;
    referrer?: string;
    sample?: string;
    sourceFile?: string;
    statusCode?: number;
    violatedDirective?: string;
}

interface ShadowRootInit {
    clonable?: boolean;
    customElementRegistry?: CustomElementRegistry | null;
    delegatesFocus?: boolean;
    mode: ShadowRootMode;
    serializable?: boolean;
    slotAssignment?: SlotAssignmentMode;
}

interface ShareData {
    files?: File[];
    text?: string;
    title?: string;
    url?: string;
}

interface ShowPopoverOptions {
    source?: HTMLElement;
}

interface SpeechRecognitionErrorEventInit extends EventInit {
    error: SpeechRecognitionErrorCode;
    message?: string;
}

interface SpeechRecognitionEventInit extends EventInit {
    resultIndex?: number;
    results: SpeechRecognitionResultList;
}

interface SpeechSynthesisErrorEventInit extends SpeechSynthesisEventInit {
    error: SpeechSynthesisErrorCode;
}

interface SpeechSynthesisEventInit extends EventInit {
    charIndex?: number;
    charLength?: number;
    elapsedTime?: number;
    name?: string;
    utterance: SpeechSynthesisUtterance;
}

interface StartViewTransitionOptions {
    types?: string[] | null;
    update?: ViewTransitionUpdateCallback | null;
}

interface StaticRangeInit {
    endContainer: Node;
    endOffset: number;
    startContainer: Node;
    startOffset: number;
}

interface StereoPannerOptions extends AudioNodeOptions {
    pan?: number;
}

interface StorageEstimate {
    quota?: number;
    usage?: number;
}

interface StorageEventInit extends EventInit {
    key?: string | null;
    newValue?: string | null;
    oldValue?: string | null;
    storageArea?: Storage | null;
    url?: string;
}

interface StreamPipeOptions {
    preventAbort?: boolean;
    preventCancel?: boolean;
    /**
     * Pipes this readable stream to a given writable stream destination. The way in which the piping process behaves under various error conditions can be customized with a number of passed options. It returns a promise that fulfills when the piping process completes successfully, or rejects if any errors were encountered.
     *
     * Piping a stream will lock it for the duration of the pipe, preventing any other consumer from acquiring a reader.
     *
     * Errors and closures of the source and destination streams propagate as follows:
     *
     * An error in this source readable stream will abort destination, unless preventAbort is truthy. The returned promise will be rejected with the source's error, or with any error that occurs during aborting the destination.
     *
     * An error in destination will cancel this source readable stream, unless preventCancel is truthy. The returned promise will be rejected with the destination's error, or with any error that occurs during canceling the source.
     *
     * When this source readable stream closes, destination will be closed, unless preventClose is truthy. The returned promise will be fulfilled once this process completes, unless an error is encountered while closing the destination, in which case it will be rejected with that error.
     *
     * If destination starts out closed or closing, this source readable stream will be canceled, unless preventCancel is true. The returned promise will be rejected with an error indicating piping to a closed stream failed, or with any error that occurs during canceling the source.
     *
     * The signal option can be set to an AbortSignal to allow aborting an ongoing pipe operation via the corresponding AbortController. In this case, this source readable stream will be canceled, and destination aborted, unless the respective options preventCancel or preventAbort are set.
     */
    preventClose?: boolean;
    signal?: AbortSignal;
}

interface StructuredSerializeOptions {
    transfer?: Transferable[];
}

interface SubmitEventInit extends EventInit {
    submitter?: HTMLElement | null;
}

interface SvcOutputMetadata {
    temporalLayerId?: number;
}

interface TaskControllerInit {
    priority?: TaskPriority;
}

interface TaskPriorityChangeEventInit extends EventInit {
    previousPriority: TaskPriority;
}

interface TaskSignalAnyInit {
    priority?: TaskPriority | TaskSignal;
}

interface TextDecodeOptions {
    stream?: boolean;
}

interface TextDecoderOptions {
    fatal?: boolean;
    ignoreBOM?: boolean;
}

interface TextEncoderEncodeIntoResult {
    read: number;
    written: number;
}

interface TimelineRangeOffset {
    offset?: CSSNumericValue;
    rangeName?: string | null;
}

interface ToggleEventInit extends EventInit {
    newState?: string;
    oldState?: string;
    source?: Element | null;
}

interface TogglePopoverOptions extends ShowPopoverOptions {
    force?: boolean;
}

interface TouchEventInit extends EventModifierInit {
    changedTouches?: Touch[];
    targetTouches?: Touch[];
    touches?: Touch[];
}

interface TouchInit {
    altitudeAngle?: number;
    azimuthAngle?: number;
    clientX?: number;
    clientY?: number;
    force?: number;
    identifier: number;
    pageX?: number;
    pageY?: number;
    radiusX?: number;
    radiusY?: number;
    rotationAngle?: number;
    screenX?: number;
    screenY?: number;
    target: EventTarget;
    touchType?: TouchType;
}

interface TrackEventInit extends EventInit {
    track?: TextTrack | null;
}

interface Transformer<I = any, O = any> {
    flush?: TransformerFlushCallback<O>;
    readableType?: undefined;
    start?: TransformerStartCallback<O>;
    transform?: TransformerTransformCallback<I, O>;
    writableType?: undefined;
}

interface TransitionEventInit extends EventInit {
    elapsedTime?: number;
    propertyName?: string;
    pseudoElement?: string;
}

interface UIEventInit extends EventInit {
    detail?: number;
    view?: Window | null;
    /** @deprecated */
    which?: number;
}

interface ULongRange {
    max?: number;
    min?: number;
}

interface URLPatternComponentResult {
    groups: Record<string, string | undefined>;
    input: string;
}

interface URLPatternInit {
    baseURL?: string;
    hash?: string;
    hostname?: string;
    password?: string;
    pathname?: string;
    port?: string;
    protocol?: string;
    search?: string;
    username?: string;
}

interface URLPatternOptions {
    ignoreCase?: boolean;
}

interface URLPatternResult {
    hash: URLPatternComponentResult;
    hostname: URLPatternComponentResult;
    inputs: URLPatternInput[];
    password: URLPatternComponentResult;
    pathname: URLPatternComponentResult;
    port: URLPatternComponentResult;
    protocol: URLPatternComponentResult;
    search: URLPatternComponentResult;
    username: URLPatternComponentResult;
}

interface UnderlyingByteSource {
    autoAllocateChunkSize?: number;
    cancel?: UnderlyingSourceCancelCallback;
    pull?: (controller: ReadableByteStreamController) => void | PromiseLike<void>;
    start?: (controller: ReadableByteStreamController) => any;
    type: "bytes";
}

interface UnderlyingDefaultSource<R = any> {
    cancel?: UnderlyingSourceCancelCallback;
    pull?: (controller: ReadableStreamDefaultController<R>) => void | PromiseLike<void>;
    start?: (controller: ReadableStreamDefaultController<R>) => any;
    type?: undefined;
}

interface UnderlyingSink<W = any> {
    abort?: UnderlyingSinkAbortCallback;
    close?: UnderlyingSinkCloseCallback;
    start?: UnderlyingSinkStartCallback;
    type?: undefined;
    write?: UnderlyingSinkWriteCallback<W>;
}

interface UnderlyingSource<R = any> {
    autoAllocateChunkSize?: number;
    cancel?: UnderlyingSourceCancelCallback;
    pull?: UnderlyingSourcePullCallback<R>;
    start?: UnderlyingSourceStartCallback<R>;
    type?: ReadableStreamType;
}

interface UnknownCredentialOptions {
    credentialId: Base64URLString;
    rpId: string;
}

interface ValidityStateFlags {
    badInput?: boolean;
    customError?: boolean;
    patternMismatch?: boolean;
    rangeOverflow?: boolean;
    rangeUnderflow?: boolean;
    stepMismatch?: boolean;
    tooLong?: boolean;
    tooShort?: boolean;
    typeMismatch?: boolean;
    valueMissing?: boolean;
}

interface VideoColorSpaceInit {
    fullRange?: boolean | null;
    matrix?: VideoMatrixCoefficients | null;
    primaries?: VideoColorPrimaries | null;
    transfer?: VideoTransferCharacteristics | null;
}

interface VideoConfiguration {
    bitrate: number;
    colorGamut?: ColorGamut;
    contentType: string;
    framerate: number;
    hasAlphaChannel?: boolean;
    hdrMetadataType?: HdrMetadataType;
    height: number;
    scalabilityMode?: string;
    transferFunction?: TransferFunction;
    width: number;
}

interface VideoDecoderConfig {
    codec: string;
    codedHeight?: number;
    codedWidth?: number;
    colorSpace?: VideoColorSpaceInit;
    description?: AllowSharedBufferSource;
    displayAspectHeight?: number;
    displayAspectWidth?: number;
    hardwareAcceleration?: HardwareAcceleration;
    optimizeForLatency?: boolean;
}

interface VideoDecoderInit {
    error: WebCodecsErrorCallback;
    output: VideoFrameOutputCallback;
}

interface VideoDecoderSupport {
    config?: VideoDecoderConfig;
    supported?: boolean;
}

interface VideoEncoderConfig {
    alpha?: AlphaOption;
    avc?: AvcEncoderConfig;
    bitrate?: number;
    bitrateMode?: VideoEncoderBitrateMode;
    codec: string;
    contentHint?: string;
    displayHeight?: number;
    displayWidth?: number;
    framerate?: number;
    hardwareAcceleration?: HardwareAcceleration;
    height: number;
    latencyMode?: LatencyMode;
    scalabilityMode?: string;
    width: number;
}

interface VideoEncoderEncodeOptions {
    avc?: VideoEncoderEncodeOptionsForAvc;
    keyFrame?: boolean;
}

interface VideoEncoderEncodeOptionsForAvc {
    quantizer?: number | null;
}

interface VideoEncoderInit {
    error: WebCodecsErrorCallback;
    output: EncodedVideoChunkOutputCallback;
}

interface VideoEncoderSupport {
    config?: VideoEncoderConfig;
    supported?: boolean;
}

interface VideoFrameBufferInit {
    codedHeight: number;
    codedWidth: number;
    colorSpace?: VideoColorSpaceInit;
    displayHeight?: number;
    displayWidth?: number;
    duration?: number;
    format: VideoPixelFormat;
    layout?: PlaneLayout[];
    timestamp: number;
    visibleRect?: DOMRectInit;
}

interface VideoFrameCallbackMetadata {
    captureTime?: DOMHighResTimeStamp;
    expectedDisplayTime: DOMHighResTimeStamp;
    height: number;
    mediaTime: number;
    presentationTime: DOMHighResTimeStamp;
    presentedFrames: number;
    processingDuration?: number;
    receiveTime?: DOMHighResTimeStamp;
    rtpTimestamp?: number;
    width: number;
}

interface VideoFrameCopyToOptions {
    colorSpace?: PredefinedColorSpace;
    format?: VideoPixelFormat;
    layout?: PlaneLayout[];
    rect?: DOMRectInit;
}

interface VideoFrameInit {
    alpha?: AlphaOption;
    displayHeight?: number;
    displayWidth?: number;
    duration?: number;
    timestamp?: number;
    visibleRect?: DOMRectInit;
}

interface ViewTimelineOptions {
    axis?: ScrollAxis;
    inset?: string | (CSSNumericValue | CSSKeywordValue)[];
    subject?: Element;
}

interface WaveShaperOptions extends AudioNodeOptions {
    curve?: number[] | Float32Array;
    oversample?: OverSampleType;
}

interface WebGLContextAttributes {
    alpha?: boolean;
    antialias?: boolean;
    depth?: boolean;
    desynchronized?: boolean;
    failIfMajorPerformanceCaveat?: boolean;
    powerPreference?: WebGLPowerPreference;
    premultipliedAlpha?: boolean;
    preserveDrawingBuffer?: boolean;
    stencil?: boolean;
    xrCompatible?: boolean;
}

interface WebGLContextEventInit extends EventInit {
    statusMessage?: string;
}

interface WebTransportCloseInfo {
    closeCode?: number;
    reason?: string;
}

interface WebTransportErrorOptions {
    source?: WebTransportErrorSource;
    streamErrorCode?: number | null;
}

interface WebTransportHash {
    algorithm: string;
    value: BufferSource;
}

interface WebTransportOptions {
    allowPooling?: boolean;
    congestionControl?: WebTransportCongestionControl;
    protocols?: string[];
    requireUnreliable?: boolean;
    serverCertificateHashes?: WebTransportHash[];
}

interface WebTransportSendOptions {
    sendOrder?: number;
}

interface WebTransportSendStreamOptions extends WebTransportSendOptions {
}

interface WheelEventInit extends MouseEventInit {
    deltaMode?: number;
    deltaX?: number;
    deltaY?: number;
    deltaZ?: number;
}

interface WindowPostMessageOptions extends StructuredSerializeOptions {
    targetOrigin?: string;
}

interface WorkerOptions {
    credentials?: RequestCredentials;
    name?: string;
    type?: WorkerType;
}

interface WorkletOptions {
    credentials?: RequestCredentials;
}

interface WriteParams {
    data?: BufferSource | Blob | string | null;
    position?: number | null;
    size?: number | null;
    type: WriteCommandType;
}

type NodeFilter = ((node: Node) => number) | { acceptNode(node: Node): number; };

declare var NodeFilter: {
    readonly FILTER_ACCEPT: 1;
    readonly FILTER_REJECT: 2;
    readonly FILTER_SKIP: 3;
    readonly SHOW_ALL: 0xFFFFFFFF;
    readonly SHOW_ELEMENT: 0x1;
    readonly SHOW_ATTRIBUTE: 0x2;
    readonly SHOW_TEXT: 0x4;
    readonly SHOW_CDATA_SECTION: 0x8;
    readonly SHOW_ENTITY_REFERENCE: 0x10;
    readonly SHOW_ENTITY: 0x20;
    readonly SHOW_PROCESSING_INSTRUCTION: 0x40;
    readonly SHOW_COMMENT: 0x80;
    readonly SHOW_DOCUMENT: 0x100;
    readonly SHOW_DOCUMENT_TYPE: 0x200;
    readonly SHOW_DOCUMENT_FRAGMENT: 0x400;
    readonly SHOW_NOTATION: 0x800;
};

type XPathNSResolver = ((prefix: string | null) => string | null) | { lookupNamespaceURI(prefix: string | null): string | null; };

/**
 * The **`ANGLE_instanced_arrays`** extension is part of the WebGL API and allows to draw the same object, or groups of similar objects multiple times, if they share the same vertex data, primitive count and type.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ANGLE_instanced_arrays)
 */
interface ANGLE_instanced_arrays {
    /**
     * The **`ANGLE_instanced_arrays.drawArraysInstancedANGLE()`** method of the WebGL API renders primitives from array data like the gl.drawArrays() method. In addition, it can execute multiple instances of the range of elements.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ANGLE_instanced_arrays/drawArraysInstancedANGLE)
     */
    drawArraysInstancedANGLE(mode: GLenum, first: GLint, count: GLsizei, primcount: GLsizei): void;
    /**
     * The **`ANGLE_instanced_arrays.drawElementsInstancedANGLE()`** method of the WebGL API renders primitives from array data like the gl.drawElements() method. In addition, it can execute multiple instances of a set of elements.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ANGLE_instanced_arrays/drawElementsInstancedANGLE)
     */
    drawElementsInstancedANGLE(mode: GLenum, count: GLsizei, type: GLenum, offset: GLintptr, primcount: GLsizei): void;
    /**
     * The **`ANGLE_instanced_arrays.vertexAttribDivisorANGLE()`** method of the WebGL API modifies the rate at which generic vertex attributes advance when rendering multiple instances of primitives with ext.drawArraysInstancedANGLE() and ext.drawElementsInstancedANGLE().
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ANGLE_instanced_arrays/vertexAttribDivisorANGLE)
     */
    vertexAttribDivisorANGLE(index: GLuint, divisor: GLuint): void;
    readonly VERTEX_ATTRIB_ARRAY_DIVISOR_ANGLE: 0x88FE;
}

interface ARIAMixin {
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/ariaActiveDescendantElement) */
    ariaActiveDescendantElement: Element | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/ariaAtomic) */
    ariaAtomic: string | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/ariaAutoComplete) */
    ariaAutoComplete: string | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/ariaBrailleLabel) */
    ariaBrailleLabel: string | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/ariaBrailleRoleDescription) */
    ariaBrailleRoleDescription: string | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/ariaBusy) */
    ariaBusy: string | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/ariaChecked) */
    ariaChecked: string | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/ariaColCount) */
    ariaColCount: string | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/ariaColIndex) */
    ariaColIndex: string | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/ariaColIndexText) */
    ariaColIndexText: string | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/ariaColSpan) */
    ariaColSpan: string | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/ariaControlsElements) */
    ariaControlsElements: ReadonlyArray<Element> | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/ariaCurrent) */
    ariaCurrent: string | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/ariaDescribedByElements) */
    ariaDescribedByElements: ReadonlyArray<Element> | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/ariaDescription) */
    ariaDescription: string | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/ariaDetailsElements) */
    ariaDetailsElements: ReadonlyArray<Element> | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/ariaDisabled) */
    ariaDisabled: string | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/ariaErrorMessageElements) */
    ariaErrorMessageElements: ReadonlyArray<Element> | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/ariaExpanded) */
    ariaExpanded: string | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/ariaFlowToElements) */
    ariaFlowToElements: ReadonlyArray<Element> | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/ariaHasPopup) */
    ariaHasPopup: string | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/ariaHidden) */
    ariaHidden: string | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/ariaInvalid) */
    ariaInvalid: string | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/ariaKeyShortcuts) */
    ariaKeyShortcuts: string | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/ariaLabel) */
    ariaLabel: string | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/ariaLabelledByElements) */
    ariaLabelledByElements: ReadonlyArray<Element> | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/ariaLevel) */
    ariaLevel: string | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/ariaLive) */
    ariaLive: string | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/ariaModal) */
    ariaModal: string | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/ariaMultiLine) */
    ariaMultiLine: string | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/ariaMultiSelectable) */
    ariaMultiSelectable: string | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/ariaOrientation) */
    ariaOrientation: string | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/ariaOwnsElements) */
    ariaOwnsElements: ReadonlyArray<Element> | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/ariaPlaceholder) */
    ariaPlaceholder: string | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/ariaPosInSet) */
    ariaPosInSet: string | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/ariaPressed) */
    ariaPressed: string | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/ariaReadOnly) */
    ariaReadOnly: string | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/ariaRelevant) */
    ariaRelevant: string | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/ariaRequired) */
    ariaRequired: string | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/ariaRoleDescription) */
    ariaRoleDescription: string | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/ariaRowCount) */
    ariaRowCount: string | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/ariaRowIndex) */
    ariaRowIndex: string | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/ariaRowIndexText) */
    ariaRowIndexText: string | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/ariaRowSpan) */
    ariaRowSpan: string | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/ariaSelected) */
    ariaSelected: string | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/ariaSetSize) */
    ariaSetSize: string | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/ariaSort) */
    ariaSort: string | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/ariaValueMax) */
    ariaValueMax: string | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/ariaValueMin) */
    ariaValueMin: string | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/ariaValueNow) */
    ariaValueNow: string | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/ariaValueText) */
    ariaValueText: string | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/role) */
    role: string | null;
}

/**
 * The **`AbortController`** interface represents a controller object that allows you to abort one or more Web requests as and when desired.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AbortController)
 */
interface AbortController {
    /**
     * The **`signal`** read-only property of the AbortController interface returns an AbortSignal object instance, which can be used to communicate with/abort an asynchronous operation as desired.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AbortController/signal)
     */
    readonly signal: AbortSignal;
    /**
     * The **`abort()`** method of the AbortController interface aborts an asynchronous operation before it has completed. This is able to abort fetch requests, the consumption of any response bodies, or streams.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AbortController/abort)
     */
    abort(reason?: any): void;
}

declare var AbortController: {
    prototype: AbortController;
    new(): AbortController;
};

interface AbortSignalEventMap {
    "abort": Event;
}

/**
 * The **`AbortSignal`** interface represents a signal object that allows you to communicate with an asynchronous operation (such as a fetch request) and abort it if required via an AbortController object.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AbortSignal)
 */
interface AbortSignal extends EventTarget {
    /**
     * The **`aborted`** read-only property returns a value that indicates whether the asynchronous operations the signal is communicating with are aborted (true) or not (false).
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AbortSignal/aborted)
     */
    readonly aborted: boolean;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/AbortSignal/abort_event) */
    onabort: ((this: AbortSignal, ev: Event) => any) | null;
    /**
     * The **`reason`** read-only property returns a JavaScript value that indicates the abort reason.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AbortSignal/reason)
     */
    readonly reason: any;
    /**
     * The **`throwIfAborted()`** method throws the signal's abort reason if the signal has been aborted; otherwise it does nothing.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AbortSignal/throwIfAborted)
     */
    throwIfAborted(): void;
    addEventListener<K extends keyof AbortSignalEventMap>(type: K, listener: (this: AbortSignal, ev: AbortSignalEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof AbortSignalEventMap>(type: K, listener: (this: AbortSignal, ev: AbortSignalEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var AbortSignal: {
    prototype: AbortSignal;
    new(): AbortSignal;
    /**
     * The **`AbortSignal.abort()`** static method returns an AbortSignal that is already set as aborted (and which does not trigger an abort event).
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AbortSignal/abort_static)
     */
    abort(reason?: any): AbortSignal;
    /**
     * The **`AbortSignal.any()`** static method takes an iterable of abort signals and returns an AbortSignal. The returned abort signal is aborted when any of the input iterable abort signals are aborted. The abort reason will be set to the reason of the first signal that is aborted. If any of the given abort signals are already aborted then so will be the returned AbortSignal.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AbortSignal/any_static)
     */
    any(signals: AbortSignal[]): AbortSignal;
    /**
     * The **`AbortSignal.timeout()`** static method returns an AbortSignal that will automatically abort after a specified time.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AbortSignal/timeout_static)
     */
    timeout(milliseconds: number): AbortSignal;
};

/**
 * The **`AbstractRange`** abstract interface is the base class upon which all DOM range types are defined. A range is an object that indicates the start and end points of a section of content within the document.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AbstractRange)
 */
interface AbstractRange {
    /**
     * The read-only **`collapsed`** property of the AbstractRange interface returns true if the range's start position and end position are the same.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AbstractRange/collapsed)
     */
    readonly collapsed: boolean;
    /**
     * The read-only **`endContainer`** property of the AbstractRange interface returns the Node in which the end of the range is located.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AbstractRange/endContainer)
     */
    readonly endContainer: Node;
    /**
     * The **`endOffset`** property of the AbstractRange interface returns the offset into the end node of the range's end position.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AbstractRange/endOffset)
     */
    readonly endOffset: number;
    /**
     * The read-only **`startContainer`** property of the AbstractRange interface returns the Node in which the start of the range is located.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AbstractRange/startContainer)
     */
    readonly startContainer: Node;
    /**
     * The read-only **`startOffset`** property of the AbstractRange interface returns the offset into the start node of the range's start position.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AbstractRange/startOffset)
     */
    readonly startOffset: number;
}

declare var AbstractRange: {
    prototype: AbstractRange;
    new(): AbstractRange;
};

interface AbstractWorkerEventMap {
    "error": ErrorEvent;
}

interface AbstractWorker {
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/ServiceWorker/error_event) */
    onerror: ((this: AbstractWorker, ev: ErrorEvent) => any) | null;
    addEventListener<K extends keyof AbstractWorkerEventMap>(type: K, listener: (this: AbstractWorker, ev: AbstractWorkerEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof AbstractWorkerEventMap>(type: K, listener: (this: AbstractWorker, ev: AbstractWorkerEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

/**
 * The **`AnalyserNode`** interface represents a node able to provide real-time frequency and time-domain analysis information. It is an AudioNode that passes the audio stream unchanged from the input to the output, but allows you to take the generated data, process it, and create audio visualizations.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AnalyserNode)
 */
interface AnalyserNode extends AudioNode {
    /**
     * The **`fftSize`** property of the AnalyserNode interface is an unsigned long value and represents the window size in samples that is used when performing a Fast Fourier Transform (FFT) to get frequency domain data.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AnalyserNode/fftSize)
     */
    fftSize: number;
    /**
     * The **`frequencyBinCount`** read-only property of the AnalyserNode interface contains the total number of data points available to AudioContext sampleRate. This is half of the value of the AnalyserNode.fftSize. The two methods' indices have a linear relationship with the frequencies they represent, between 0 and the Nyquist frequency.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AnalyserNode/frequencyBinCount)
     */
    readonly frequencyBinCount: number;
    /**
     * The **`maxDecibels`** property of the AnalyserNode interface is a double value representing the maximum power value in the scaling range for the FFT analysis data, for conversion to unsigned byte values — basically, this specifies the maximum value for the range of results when using getByteFrequencyData().
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AnalyserNode/maxDecibels)
     */
    maxDecibels: number;
    /**
     * The **`minDecibels`** property of the AnalyserNode interface is a double value representing the minimum power value in the scaling range for the FFT analysis data, for conversion to unsigned byte values — basically, this specifies the minimum value for the range of results when using getByteFrequencyData().
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AnalyserNode/minDecibels)
     */
    minDecibels: number;
    /**
     * The **`smoothingTimeConstant`** property of the AnalyserNode interface is a double value representing the averaging constant with the last analysis frame. It's basically an average between the current buffer and the last buffer the AnalyserNode processed, and results in a much smoother set of value changes over time.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AnalyserNode/smoothingTimeConstant)
     */
    smoothingTimeConstant: number;
    /**
     * The **`getByteFrequencyData()`** method of the AnalyserNode interface copies the current frequency data into a Uint8Array (unsigned byte array) passed into it.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AnalyserNode/getByteFrequencyData)
     */
    getByteFrequencyData(array: Uint8Array<ArrayBuffer>): void;
    /**
     * The **`getByteTimeDomainData()`** method of the AnalyserNode Interface copies the current waveform, or time-domain, data into a Uint8Array (unsigned byte array) passed into it.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AnalyserNode/getByteTimeDomainData)
     */
    getByteTimeDomainData(array: Uint8Array<ArrayBuffer>): void;
    /**
     * The **`getFloatFrequencyData()`** method of the AnalyserNode Interface copies the current frequency data into a Float32Array array passed into it.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AnalyserNode/getFloatFrequencyData)
     */
    getFloatFrequencyData(array: Float32Array<ArrayBuffer>): void;
    /**
     * The **`getFloatTimeDomainData()`** method of the AnalyserNode Interface copies the current waveform, or time-domain, data into a Float32Array array passed into it. Each array value is a sample, the magnitude of the signal at a particular time.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AnalyserNode/getFloatTimeDomainData)
     */
    getFloatTimeDomainData(array: Float32Array<ArrayBuffer>): void;
}

declare var AnalyserNode: {
    prototype: AnalyserNode;
    new(context: BaseAudioContext, options?: AnalyserOptions): AnalyserNode;
};

interface Animatable {
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/animate) */
    animate(keyframes: Keyframe[] | PropertyIndexedKeyframes | null, options?: number | KeyframeAnimationOptions): Animation;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/getAnimations) */
    getAnimations(options?: GetAnimationsOptions): Animation[];
}

interface AnimationEventMap {
    "cancel": AnimationPlaybackEvent;
    "finish": AnimationPlaybackEvent;
    "remove": AnimationPlaybackEvent;
}

/**
 * The **`Animation`** interface of the Web Animations API represents a single animation player and provides playback controls and a timeline for an animation node or source.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Animation)
 */
interface Animation extends EventTarget {
    /**
     * The **`Animation.currentTime`** property of the Web Animations API returns and sets the current time value of the animation in milliseconds, whether running or paused.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Animation/currentTime)
     */
    currentTime: CSSNumberish | null;
    /**
     * The **`Animation.effect`** property of the Web Animations API gets and sets the target effect of an animation. The target effect may be either an effect object of a type based on AnimationEffect, such as KeyframeEffect, or null.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Animation/effect)
     */
    effect: AnimationEffect | null;
    /**
     * The **`Animation.finished`** read-only property of the Web Animations API returns a Promise which resolves once the animation has finished playing.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Animation/finished)
     */
    readonly finished: Promise<Animation>;
    /**
     * The **`Animation.id`** property of the Web Animations API returns or sets a string used to identify the animation.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Animation/id)
     */
    id: string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Animation/cancel_event) */
    oncancel: ((this: Animation, ev: AnimationPlaybackEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Animation/finish_event) */
    onfinish: ((this: Animation, ev: AnimationPlaybackEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Animation/remove_event) */
    onremove: ((this: Animation, ev: AnimationPlaybackEvent) => any) | null;
    /**
     * The **`overallProgress`** read-only property of the Animation interface returns a number between 0 and 1 indicating the animation's overall progress towards its finished state. This is the overall progress across all of the animation's iterations, not each individual iteration.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Animation/overallProgress)
     */
    readonly overallProgress: number | null;
    /**
     * The read-only **`Animation.pending`** property of the Web Animations API indicates whether the animation is currently waiting for an asynchronous operation such as initiating playback or pausing a running animation.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Animation/pending)
     */
    readonly pending: boolean;
    /**
     * The read-only **`Animation.playState`** property of the Web Animations API returns an enumerated value describing the playback state of an animation.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Animation/playState)
     */
    readonly playState: AnimationPlayState;
    /**
     * The **`Animation.playbackRate`** property of the Web Animations API returns or sets the playback rate of the animation.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Animation/playbackRate)
     */
    playbackRate: number;
    /**
     * The read-only **`Animation.ready`** property of the Web Animations API returns a Promise which resolves when the animation is ready to play. A new promise is created every time the animation enters the "pending" play state as well as when the animation is canceled, since in both of those scenarios, the animation is ready to be started again.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Animation/ready)
     */
    readonly ready: Promise<Animation>;
    /**
     * The read-only **`Animation.replaceState`** property of the Web Animations API indicates whether the animation has been removed by the browser automatically after being replaced by another animation.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Animation/replaceState)
     */
    readonly replaceState: AnimationReplaceState;
    /**
     * The **`Animation.startTime`** property of the Animation interface is a double-precision floating-point value which indicates the scheduled time when an animation's playback should begin.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Animation/startTime)
     */
    startTime: CSSNumberish | null;
    /**
     * The **`Animation.timeline`** property of the Animation interface returns or sets the timeline associated with this animation. A timeline is a source of time values for synchronization purposes, and is an AnimationTimeline-based object. By default, the animation's timeline and the Document's timeline are the same.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Animation/timeline)
     */
    timeline: AnimationTimeline | null;
    /**
     * The Web Animations API's **`cancel()`** method of the Animation interface clears all KeyframeEffects caused by this animation and aborts its playback.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Animation/cancel)
     */
    cancel(): void;
    /**
     * The **`commitStyles()`** method of the Web Animations API's Animation interface writes the computed values of the animation's current styles into its target element's style attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Animation/commitStyles)
     */
    commitStyles(): void;
    /**
     * The **`finish()`** method of the Web Animations API's Animation Interface sets the current playback time to the end of the animation corresponding to the current playback direction.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Animation/finish)
     */
    finish(): void;
    /**
     * The **`pause()`** method of the Web Animations API's Animation interface suspends playback of the animation.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Animation/pause)
     */
    pause(): void;
    /**
     * The **`persist()`** method of the Web Animations API's Animation interface explicitly persists an animation, preventing it from being automatically removed when it is replaced by another animation.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Animation/persist)
     */
    persist(): void;
    /**
     * The **`play()`** method of the Web Animations API's Animation Interface starts or resumes playing of an animation. If the animation is finished, calling play() restarts the animation, playing it from the beginning.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Animation/play)
     */
    play(): void;
    /**
     * The **`Animation.reverse()`** method of the Animation Interface reverses the playback direction, meaning the animation ends at its beginning. If called on an unplayed animation, the whole animation is played backwards. If called on a paused animation, the animation will continue in reverse.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Animation/reverse)
     */
    reverse(): void;
    /**
     * The **`updatePlaybackRate()`** method of the Web Animations API's Animation Interface sets the speed of an animation after first synchronizing its playback position.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Animation/updatePlaybackRate)
     */
    updatePlaybackRate(playbackRate: number): void;
    addEventListener<K extends keyof AnimationEventMap>(type: K, listener: (this: Animation, ev: AnimationEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof AnimationEventMap>(type: K, listener: (this: Animation, ev: AnimationEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var Animation: {
    prototype: Animation;
    new(effect?: AnimationEffect | null, timeline?: AnimationTimeline | null): Animation;
};

/**
 * The **`AnimationEffect`** interface of the Web Animations API is an interface representing animation effects.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AnimationEffect)
 */
interface AnimationEffect {
    /**
     * The **`getComputedTiming()`** method of the AnimationEffect interface returns the calculated timing properties for this animation effect.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AnimationEffect/getComputedTiming)
     */
    getComputedTiming(): ComputedEffectTiming;
    /**
     * The **`AnimationEffect.getTiming()`** method of the AnimationEffect interface returns an object containing the timing properties for the Animation Effect.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AnimationEffect/getTiming)
     */
    getTiming(): EffectTiming;
    /**
     * The **`updateTiming()`** method of the AnimationEffect interface updates the specified timing properties for an animation effect.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AnimationEffect/updateTiming)
     */
    updateTiming(timing?: OptionalEffectTiming): void;
}

declare var AnimationEffect: {
    prototype: AnimationEffect;
    new(): AnimationEffect;
};

/**
 * The **`AnimationEvent`** interface represents events providing information related to animations.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AnimationEvent)
 */
interface AnimationEvent extends Event {
    /**
     * The **`AnimationEvent.animationName`** read-only property is a string containing the value of the animation-name CSS property associated with the transition.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AnimationEvent/animationName)
     */
    readonly animationName: string;
    /**
     * The **`AnimationEvent.elapsedTime`** read-only property is a float giving the amount of time the animation has been running, in seconds, when this event fired, excluding any time the animation was paused. For an animationstart event, elapsedTime is 0.0 unless there was a negative value for animation-delay, in which case the event will be fired with elapsedTime containing (-1 * delay).
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AnimationEvent/elapsedTime)
     */
    readonly elapsedTime: number;
    /**
     * The **`AnimationEvent.pseudoElement`** read-only property is a string, starting with '::', containing the name of the pseudo-element the animation runs on. If the animation doesn't run on a pseudo-element but on the element, an empty string: ''.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AnimationEvent/pseudoElement)
     */
    readonly pseudoElement: string;
}

declare var AnimationEvent: {
    prototype: AnimationEvent;
    new(type: string, animationEventInitDict?: AnimationEventInit): AnimationEvent;
};

interface AnimationFrameProvider {
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/DedicatedWorkerGlobalScope/cancelAnimationFrame) */
    cancelAnimationFrame(handle: number): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/DedicatedWorkerGlobalScope/requestAnimationFrame) */
    requestAnimationFrame(callback: FrameRequestCallback): number;
}

/**
 * The **`AnimationPlaybackEvent`** interface of the Web Animations API represents animation events.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AnimationPlaybackEvent)
 */
interface AnimationPlaybackEvent extends Event {
    /**
     * The **`currentTime`** read-only property of the AnimationPlaybackEvent interface represents the current time of the animation that generated the event at the moment the event is queued. This will be unresolved if the animation was idle at the time the event was generated.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AnimationPlaybackEvent/currentTime)
     */
    readonly currentTime: CSSNumberish | null;
    /**
     * The **`timelineTime`** read-only property of the AnimationPlaybackEvent interface represents the time value of the animation's timeline at the moment the event is queued. This will be unresolved if the animation was not associated with a timeline at the time the event was generated or if the associated timeline was inactive.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AnimationPlaybackEvent/timelineTime)
     */
    readonly timelineTime: CSSNumberish | null;
}

declare var AnimationPlaybackEvent: {
    prototype: AnimationPlaybackEvent;
    new(type: string, eventInitDict?: AnimationPlaybackEventInit): AnimationPlaybackEvent;
};

/**
 * The **`AnimationTimeline`** interface of the Web Animations API represents the timeline of an animation. This interface exists to define timeline features, inherited by other timeline types:
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AnimationTimeline)
 */
interface AnimationTimeline {
    /**
     * The **`currentTime`** read-only property of the Web Animations API's AnimationTimeline interface returns the timeline's current time in milliseconds, or null if the timeline is inactive.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AnimationTimeline/currentTime)
     */
    readonly currentTime: CSSNumberish | null;
    /**
     * The **`duration`** read-only property of the Web Animations API's AnimationTimeline interface returns the maximum value for this timeline or null.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AnimationTimeline/duration)
     */
    readonly duration: CSSNumberish | null;
}

declare var AnimationTimeline: {
    prototype: AnimationTimeline;
    new(): AnimationTimeline;
};

/**
 * The **`Attr`** interface represents one of an element's attributes as an object. In most situations, you will directly retrieve the attribute value as a string (e.g., Element.getAttribute()), but some cases may require interacting with Attr instances (e.g., Element.getAttributeNode()).
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Attr)
 */
interface Attr extends Node {
    /**
     * The read-only **`localName`** property of the Attr interface returns the local part of the qualified name of an attribute, that is the name of the attribute, stripped from any namespace in front of it. For example, if the qualified name is xml:lang, the returned local name is lang, if the element supports that namespace.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Attr/localName)
     */
    readonly localName: string;
    /**
     * The read-only **`name`** property of the Attr interface returns the qualified name of an attribute, that is the name of the attribute, with the namespace prefix, if any, in front of it. For example, if the local name is lang and the namespace prefix is xml, the returned qualified name is xml:lang.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Attr/name)
     */
    readonly name: string;
    /**
     * The read-only **`namespaceURI`** property of the Attr interface returns the namespace URI of the attribute, or null if the element is not in a namespace.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Attr/namespaceURI)
     */
    readonly namespaceURI: string | null;
    readonly ownerDocument: Document;
    /**
     * The read-only **`ownerElement`** property of the Attr interface returns the Element the attribute belongs to.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Attr/ownerElement)
     */
    readonly ownerElement: Element | null;
    /**
     * The read-only **`prefix`** property of the Attr returns the namespace prefix of the attribute, or null if no prefix is specified.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Attr/prefix)
     */
    readonly prefix: string | null;
    /**
     * The read-only **`specified`** property of the Attr interface always returns true.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Attr/specified)
     */
    readonly specified: boolean;
    /**
     * The **`value`** property of the Attr interface contains the value of the attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Attr/value)
     */
    value: string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Node/textContent) */
    get textContent(): string;
    set textContent(value: string | null);
}

declare var Attr: {
    prototype: Attr;
    new(): Attr;
};

/**
 * The **`AudioBuffer`** interface represents a short audio asset residing in memory, created from an audio file using the AudioContext.decodeAudioData() method, or from raw data using AudioContext.createBuffer(). Once put into an AudioBuffer, the audio can then be played by being passed into an AudioBufferSourceNode.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioBuffer)
 */
interface AudioBuffer {
    /**
     * The **`duration`** property of the AudioBuffer interface returns a double representing the duration, in seconds, of the PCM data stored in the buffer.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioBuffer/duration)
     */
    readonly duration: number;
    /**
     * The **`length`** property of the AudioBuffer interface returns an integer representing the length, in sample-frames, of the PCM data stored in the buffer.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioBuffer/length)
     */
    readonly length: number;
    /**
     * The **`numberOfChannels`** property of the AudioBuffer interface returns an integer representing the number of discrete audio channels described by the PCM data stored in the buffer.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioBuffer/numberOfChannels)
     */
    readonly numberOfChannels: number;
    /**
     * The **`sampleRate`** property of the AudioBuffer interface returns a float representing the sample rate, in samples per second, of the PCM data stored in the buffer.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioBuffer/sampleRate)
     */
    readonly sampleRate: number;
    /**
     * The **`copyFromChannel()`** method of the AudioBuffer interface copies the audio sample data from the specified channel of the AudioBuffer to a specified Float32Array.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioBuffer/copyFromChannel)
     */
    copyFromChannel(destination: Float32Array<ArrayBuffer>, channelNumber: number, bufferOffset?: number): void;
    /**
     * The **`copyToChannel()`** method of the AudioBuffer interface copies the samples to the specified channel of the AudioBuffer, from the source array.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioBuffer/copyToChannel)
     */
    copyToChannel(source: Float32Array<ArrayBuffer>, channelNumber: number, bufferOffset?: number): void;
    /**
     * The **`getChannelData()`** method of the AudioBuffer Interface returns a Float32Array containing the PCM data associated with the channel, defined by the channel parameter (with 0 representing the first channel).
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioBuffer/getChannelData)
     */
    getChannelData(channel: number): Float32Array<ArrayBuffer>;
}

declare var AudioBuffer: {
    prototype: AudioBuffer;
    new(options: AudioBufferOptions): AudioBuffer;
};

/**
 * The **`AudioBufferSourceNode`** interface is an AudioScheduledSourceNode which represents an audio source consisting of in-memory audio data, stored in an AudioBuffer.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioBufferSourceNode)
 */
interface AudioBufferSourceNode extends AudioScheduledSourceNode {
    /**
     * The **`buffer`** property of the AudioBufferSourceNode interface provides the ability to play back audio using an AudioBuffer as the source of the sound data.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioBufferSourceNode/buffer)
     */
    buffer: AudioBuffer | null;
    /**
     * The **`detune`** property of the AudioBufferSourceNode interface is a k-rate AudioParam representing detuning of oscillation in cents.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioBufferSourceNode/detune)
     */
    readonly detune: AudioParam;
    /**
     * The **`loop`** property of the AudioBufferSourceNode interface is a Boolean indicating if the audio asset must be replayed when the end of the AudioBuffer is reached.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioBufferSourceNode/loop)
     */
    loop: boolean;
    /**
     * The **`loopEnd`** property of the AudioBufferSourceNode interface specifies is a floating point number specifying, in seconds, at what offset into playing the AudioBuffer playback should loop back to the time indicated by the loopStart property. This is only used if the loop property is true.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioBufferSourceNode/loopEnd)
     */
    loopEnd: number;
    /**
     * The **`loopStart`** property of the AudioBufferSourceNode interface is a floating-point value indicating, in seconds, where in the AudioBuffer the restart of the play must happen.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioBufferSourceNode/loopStart)
     */
    loopStart: number;
    /**
     * The **`playbackRate`** property of the AudioBufferSourceNode interface Is a k-rate AudioParam that defines the speed at which the audio asset will be played.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioBufferSourceNode/playbackRate)
     */
    readonly playbackRate: AudioParam;
    /**
     * The **`start()`** method of the AudioBufferSourceNode Interface is used to schedule playback of the audio data contained in the buffer, or to begin playback immediately.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioBufferSourceNode/start)
     */
    start(when?: number, offset?: number, duration?: number): void;
    addEventListener<K extends keyof AudioScheduledSourceNodeEventMap>(type: K, listener: (this: AudioBufferSourceNode, ev: AudioScheduledSourceNodeEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof AudioScheduledSourceNodeEventMap>(type: K, listener: (this: AudioBufferSourceNode, ev: AudioScheduledSourceNodeEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var AudioBufferSourceNode: {
    prototype: AudioBufferSourceNode;
    new(context: BaseAudioContext, options?: AudioBufferSourceOptions): AudioBufferSourceNode;
};

/**
 * The **`AudioContext`** interface represents an audio-processing graph built from audio modules linked together, each represented by an AudioNode.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioContext)
 */
interface AudioContext extends BaseAudioContext {
    /**
     * The **`baseLatency`** read-only property of the AudioContext interface returns a double that represents the number of seconds of processing latency incurred by the AudioContext passing an audio buffer from the AudioDestinationNode — i.e., the end of the audio graph — into the host system's audio subsystem ready for playing.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioContext/baseLatency)
     */
    readonly baseLatency: number;
    /**
     * The **`outputLatency`** read-only property of the AudioContext Interface provides an estimation of the output latency of the current audio context.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioContext/outputLatency)
     */
    readonly outputLatency: number;
    /**
     * The **`close()`** method of the AudioContext Interface closes the audio context, releasing any system audio resources that it uses.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioContext/close)
     */
    close(): Promise<void>;
    /**
     * The **`createMediaElementSource()`** method of the AudioContext Interface is used to create a new MediaElementAudioSourceNode object, given an existing HTML <audio> or <video> element, the audio from which can then be played and manipulated.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioContext/createMediaElementSource)
     */
    createMediaElementSource(mediaElement: HTMLMediaElement): MediaElementAudioSourceNode;
    /**
     * The **`createMediaStreamDestination()`** method of the AudioContext Interface is used to create a new MediaStreamAudioDestinationNode object associated with a WebRTC MediaStream representing an audio stream, which may be stored in a local file or sent to another computer.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioContext/createMediaStreamDestination)
     */
    createMediaStreamDestination(): MediaStreamAudioDestinationNode;
    /**
     * The **`createMediaStreamSource()`** method of the AudioContext Interface is used to create a new MediaStreamAudioSourceNode object, given a media stream (say, from a MediaDevices.getUserMedia instance), the audio from which can then be played and manipulated.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioContext/createMediaStreamSource)
     */
    createMediaStreamSource(mediaStream: MediaStream): MediaStreamAudioSourceNode;
    /**
     * The **`getOutputTimestamp()`** method of the AudioContext interface returns a new AudioTimestamp object containing two audio timestamp values relating to the current audio context.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioContext/getOutputTimestamp)
     */
    getOutputTimestamp(): AudioTimestamp;
    /**
     * The **`resume()`** method of the AudioContext interface resumes the progression of time in an audio context that has previously been suspended.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioContext/resume)
     */
    resume(): Promise<void>;
    /**
     * The **`suspend()`** method of the AudioContext Interface suspends the progression of time in the audio context, temporarily halting audio hardware access and reducing CPU/battery usage in the process — this is useful if you want an application to power down the audio hardware when it will not be using an audio context for a while.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioContext/suspend)
     */
    suspend(): Promise<void>;
    addEventListener<K extends keyof BaseAudioContextEventMap>(type: K, listener: (this: AudioContext, ev: BaseAudioContextEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof BaseAudioContextEventMap>(type: K, listener: (this: AudioContext, ev: BaseAudioContextEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var AudioContext: {
    prototype: AudioContext;
    new(contextOptions?: AudioContextOptions): AudioContext;
};

/**
 * The **`AudioData`** interface of the WebCodecs API represents an audio sample.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioData)
 */
interface AudioData {
    /**
     * The **`duration`** read-only property of the AudioData interface returns the duration in microseconds of this AudioData object.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioData/duration)
     */
    readonly duration: number;
    /**
     * The **`format`** read-only property of the AudioData interface returns the sample format of the AudioData object.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioData/format)
     */
    readonly format: AudioSampleFormat | null;
    /**
     * The **`numberOfChannels`** read-only property of the AudioData interface returns the number of channels in the AudioData object.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioData/numberOfChannels)
     */
    readonly numberOfChannels: number;
    /**
     * The **`numberOfFrames`** read-only property of the AudioData interface returns the number of frames in the AudioData object.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioData/numberOfFrames)
     */
    readonly numberOfFrames: number;
    /**
     * The **`sampleRate`** read-only property of the AudioData interface returns the sample rate in Hz.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioData/sampleRate)
     */
    readonly sampleRate: number;
    /**
     * The **`timestamp`** read-only property of the AudioData interface returns the timestamp of this AudioData object.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioData/timestamp)
     */
    readonly timestamp: number;
    /**
     * The **`allocationSize()`** method of the AudioData interface returns the size in bytes required to hold the current sample as filtered by options passed into the method.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioData/allocationSize)
     */
    allocationSize(options: AudioDataCopyToOptions): number;
    /**
     * The **`clone()`** method of the AudioData interface creates a new AudioData object with reference to the same media resource as the original.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioData/clone)
     */
    clone(): AudioData;
    /**
     * The **`close()`** method of the AudioData interface clears all states and releases the reference to the media resource.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioData/close)
     */
    close(): void;
    /**
     * The **`copyTo()`** method of the AudioData interface copies a plane of an AudioData object to a destination buffer.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioData/copyTo)
     */
    copyTo(destination: AllowSharedBufferSource, options: AudioDataCopyToOptions): void;
}

declare var AudioData: {
    prototype: AudioData;
    new(init: AudioDataInit): AudioData;
};

interface AudioDecoderEventMap {
    "dequeue": Event;
}

/**
 * The **`AudioDecoder`** interface of the WebCodecs API decodes chunks of audio.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioDecoder)
 */
interface AudioDecoder extends EventTarget {
    /**
     * The **`decodeQueueSize`** read-only property of the AudioDecoder interface returns the number of pending decode requests in the queue.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioDecoder/decodeQueueSize)
     */
    readonly decodeQueueSize: number;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioDecoder/dequeue_event) */
    ondequeue: ((this: AudioDecoder, ev: Event) => any) | null;
    /**
     * The **`state`** read-only property of the AudioDecoder interface returns the current state of the underlying codec.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioDecoder/state)
     */
    readonly state: CodecState;
    /**
     * The **`close()`** method of the AudioDecoder interface ends all pending work and releases system resources.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioDecoder/close)
     */
    close(): void;
    /**
     * The **`configure()`** method of the AudioDecoder interface enqueues a control message to configure the audio decoder for decoding chunks.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioDecoder/configure)
     */
    configure(config: AudioDecoderConfig): void;
    /**
     * The **`decode()`** method of the AudioDecoder interface enqueues a control message to decode a given chunk of audio.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioDecoder/decode)
     */
    decode(chunk: EncodedAudioChunk): void;
    /**
     * The **`flush()`** method of the AudioDecoder interface returns a Promise that resolves once all pending messages in the queue have been completed.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioDecoder/flush)
     */
    flush(): Promise<void>;
    /**
     * The **`reset()`** method of the AudioDecoder interface resets all states including configuration, control messages in the control message queue, and all pending callbacks.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioDecoder/reset)
     */
    reset(): void;
    addEventListener<K extends keyof AudioDecoderEventMap>(type: K, listener: (this: AudioDecoder, ev: AudioDecoderEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof AudioDecoderEventMap>(type: K, listener: (this: AudioDecoder, ev: AudioDecoderEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var AudioDecoder: {
    prototype: AudioDecoder;
    new(init: AudioDecoderInit): AudioDecoder;
    /**
     * The **`isConfigSupported()`** static method of the AudioDecoder interface checks if the given config is supported (that is, if AudioDecoder objects can be successfully configured with the given config).
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioDecoder/isConfigSupported_static)
     */
    isConfigSupported(config: AudioDecoderConfig): Promise<AudioDecoderSupport>;
};

/**
 * The **`AudioDestinationNode`** interface represents the end destination of an audio graph in a given context — usually the speakers of your device. It can also be the node that will "record" the audio data when used with an OfflineAudioContext.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioDestinationNode)
 */
interface AudioDestinationNode extends AudioNode {
    /**
     * The **`maxChannelCount`** property of the AudioDestinationNode interface is an unsigned long defining the maximum amount of channels that the physical device can handle.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioDestinationNode/maxChannelCount)
     */
    readonly maxChannelCount: number;
}

declare var AudioDestinationNode: {
    prototype: AudioDestinationNode;
    new(): AudioDestinationNode;
};

interface AudioEncoderEventMap {
    "dequeue": Event;
}

/**
 * The **`AudioEncoder`** interface of the WebCodecs API encodes AudioData objects.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioEncoder)
 */
interface AudioEncoder extends EventTarget {
    /**
     * The **`encodeQueueSize`** read-only property of the AudioEncoder interface returns the number of pending encode requests in the queue.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioEncoder/encodeQueueSize)
     */
    readonly encodeQueueSize: number;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioEncoder/dequeue_event) */
    ondequeue: ((this: AudioEncoder, ev: Event) => any) | null;
    /**
     * The **`state`** read-only property of the AudioEncoder interface returns the current state of the underlying codec.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioEncoder/state)
     */
    readonly state: CodecState;
    /**
     * The **`close()`** method of the AudioEncoder interface ends all pending work and releases system resources.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioEncoder/close)
     */
    close(): void;
    /**
     * The **`configure()`** method of the AudioEncoder interface enqueues a control message to configure the audio encoder for encoding chunks.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioEncoder/configure)
     */
    configure(config: AudioEncoderConfig): void;
    /**
     * The **`encode()`** method of the AudioEncoder interface enqueues a control message to encode a given AudioData object.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioEncoder/encode)
     */
    encode(data: AudioData): void;
    /**
     * The **`flush()`** method of the AudioEncoder interface returns a Promise that resolves once all pending messages in the queue have been completed.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioEncoder/flush)
     */
    flush(): Promise<void>;
    /**
     * The **`reset()`** method of the AudioEncoder interface resets all states including configuration, control messages in the control message queue, and all pending callbacks.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioEncoder/reset)
     */
    reset(): void;
    addEventListener<K extends keyof AudioEncoderEventMap>(type: K, listener: (this: AudioEncoder, ev: AudioEncoderEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof AudioEncoderEventMap>(type: K, listener: (this: AudioEncoder, ev: AudioEncoderEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var AudioEncoder: {
    prototype: AudioEncoder;
    new(init: AudioEncoderInit): AudioEncoder;
    /**
     * The **`isConfigSupported()`** static method of the AudioEncoder interface checks if the given config is supported (that is, if AudioEncoder objects can be successfully configured with the given config).
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioEncoder/isConfigSupported_static)
     */
    isConfigSupported(config: AudioEncoderConfig): Promise<AudioEncoderSupport>;
};

/**
 * The **`AudioListener`** interface represents the position and orientation of the unique person listening to the audio scene, and is used in audio spatialization. All PannerNodes spatialize in relation to the AudioListener stored in the BaseAudioContext.listener attribute.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioListener)
 */
interface AudioListener {
    /**
     * The **`forwardX`** read-only property of the AudioListener interface is an AudioParam representing the x value of the direction vector defining the forward direction the listener is pointing in.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioListener/forwardX)
     */
    readonly forwardX: AudioParam;
    /**
     * The **`forwardY`** read-only property of the AudioListener interface is an AudioParam representing the y value of the direction vector defining the forward direction the listener is pointing in.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioListener/forwardY)
     */
    readonly forwardY: AudioParam;
    /**
     * The **`forwardZ`** read-only property of the AudioListener interface is an AudioParam representing the z value of the direction vector defining the forward direction the listener is pointing in.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioListener/forwardZ)
     */
    readonly forwardZ: AudioParam;
    /**
     * The **`positionX`** read-only property of the AudioListener interface is an AudioParam representing the x position of the listener in 3D cartesian space.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioListener/positionX)
     */
    readonly positionX: AudioParam;
    /**
     * The **`positionY`** read-only property of the AudioListener interface is an AudioParam representing the y position of the listener in 3D cartesian space.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioListener/positionY)
     */
    readonly positionY: AudioParam;
    /**
     * The **`positionZ`** read-only property of the AudioListener interface is an AudioParam representing the z position of the listener in 3D cartesian space.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioListener/positionZ)
     */
    readonly positionZ: AudioParam;
    /**
     * The **`upX`** read-only property of the AudioListener interface is an AudioParam representing the x value of the direction vector defining the up direction the listener is pointing in.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioListener/upX)
     */
    readonly upX: AudioParam;
    /**
     * The **`upY`** read-only property of the AudioListener interface is an AudioParam representing the y value of the direction vector defining the up direction the listener is pointing in.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioListener/upY)
     */
    readonly upY: AudioParam;
    /**
     * The **`upZ`** read-only property of the AudioListener interface is an AudioParam representing the z value of the direction vector defining the up direction the listener is pointing in.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioListener/upZ)
     */
    readonly upZ: AudioParam;
    /**
     * The **`setOrientation()`** method of the AudioListener interface defines the orientation of the listener.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioListener/setOrientation)
     */
    setOrientation(x: number, y: number, z: number, xUp: number, yUp: number, zUp: number): void;
    /**
     * The **`setPosition()`** method of the AudioListener Interface defines the position of the listener.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioListener/setPosition)
     */
    setPosition(x: number, y: number, z: number): void;
}

declare var AudioListener: {
    prototype: AudioListener;
    new(): AudioListener;
};

/**
 * The **`AudioNode`** interface is a generic interface for representing an audio processing module.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioNode)
 */
interface AudioNode extends EventTarget {
    /**
     * The **`channelCount`** property of the AudioNode interface represents an integer used to determine how many channels are used when up-mixing and down-mixing connections to any inputs to the node.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioNode/channelCount)
     */
    channelCount: number;
    /**
     * The **`channelCountMode`** property of the AudioNode interface represents an enumerated value describing the way channels must be matched between the node's inputs and outputs.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioNode/channelCountMode)
     */
    channelCountMode: ChannelCountMode;
    /**
     * The **`channelInterpretation`** property of the AudioNode interface represents an enumerated value describing how input channels are mapped to output channels when the number of inputs/outputs is different. For example, this setting defines how a mono input will be up-mixed to a stereo or 5.1 channel output, or how a quad channel input will be down-mixed to a stereo or mono output.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioNode/channelInterpretation)
     */
    channelInterpretation: ChannelInterpretation;
    /**
     * The read-only **`context`** property of the AudioNode interface returns the associated BaseAudioContext, that is the object representing the processing graph the node is participating in.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioNode/context)
     */
    readonly context: BaseAudioContext;
    /**
     * The **`numberOfInputs`** property of the AudioNode interface returns the number of inputs feeding the node. Source nodes are defined as nodes having a numberOfInputs property with a value of 0.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioNode/numberOfInputs)
     */
    readonly numberOfInputs: number;
    /**
     * The **`numberOfOutputs`** property of the AudioNode interface returns the number of outputs coming out of the node. Destination nodes — like AudioDestinationNode — have a value of 0 for this attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioNode/numberOfOutputs)
     */
    readonly numberOfOutputs: number;
    /**
     * The **`connect()`** method of the AudioNode interface lets you connect one of the node's outputs to a target, which may be either another AudioNode (thereby directing the sound data to the specified node) or an AudioParam, so that the node's output data is automatically used to change the value of that parameter over time.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioNode/connect)
     */
    connect(destinationNode: AudioNode, output?: number, input?: number): AudioNode;
    connect(destinationParam: AudioParam, output?: number): void;
    /**
     * The **`disconnect()`** method of the AudioNode interface lets you disconnect one or more nodes from the node on which the method is called.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioNode/disconnect)
     */
    disconnect(): void;
    disconnect(output: number): void;
    disconnect(destinationNode: AudioNode): void;
    disconnect(destinationNode: AudioNode, output: number): void;
    disconnect(destinationNode: AudioNode, output: number, input: number): void;
    disconnect(destinationParam: AudioParam): void;
    disconnect(destinationParam: AudioParam, output: number): void;
}

declare var AudioNode: {
    prototype: AudioNode;
    new(): AudioNode;
};

/**
 * The Web Audio API's **`AudioParam`** interface represents an audio-related parameter, usually a parameter of an AudioNode (such as GainNode.gain).
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioParam)
 */
interface AudioParam {
    automationRate: AutomationRate;
    /**
     * The **`defaultValue`** read-only property of the AudioParam interface represents the initial value of the attributes as defined by the specific AudioNode creating the AudioParam.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioParam/defaultValue)
     */
    readonly defaultValue: number;
    /**
     * The **`maxValue`** read-only property of the AudioParam interface represents the maximum possible value for the parameter's nominal (effective) range.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioParam/maxValue)
     */
    readonly maxValue: number;
    /**
     * The **`minValue`** read-only property of the AudioParam interface represents the minimum possible value for the parameter's nominal (effective) range.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioParam/minValue)
     */
    readonly minValue: number;
    /**
     * The **`value`** property of the AudioParam interface gets or sets the value of this AudioParam at the current time. Initially, the value is set to AudioParam.defaultValue.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioParam/value)
     */
    value: number;
    /**
     * The **`cancelAndHoldAtTime()`** method of the AudioParam interface cancels all scheduled future changes to the AudioParam but holds its value at a given time until further changes are made using other methods.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioParam/cancelAndHoldAtTime)
     */
    cancelAndHoldAtTime(cancelTime: number): AudioParam;
    /**
     * The **`cancelScheduledValues()`** method of the AudioParam Interface cancels all scheduled future changes to the AudioParam.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioParam/cancelScheduledValues)
     */
    cancelScheduledValues(cancelTime: number): AudioParam;
    /**
     * The **`exponentialRampToValueAtTime()`** method of the AudioParam Interface schedules a gradual exponential change in the value of the AudioParam. The change starts at the time specified for the previous event, follows an exponential ramp to the new value given in the value parameter, and reaches the new value at the time given in the endTime parameter.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioParam/exponentialRampToValueAtTime)
     */
    exponentialRampToValueAtTime(value: number, endTime: number): AudioParam;
    /**
     * The **`linearRampToValueAtTime()`** method of the AudioParam Interface schedules a gradual linear change in the value of the AudioParam. The change starts at the time specified for the previous event, follows a linear ramp to the new value given in the value parameter, and reaches the new value at the time given in the endTime parameter.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioParam/linearRampToValueAtTime)
     */
    linearRampToValueAtTime(value: number, endTime: number): AudioParam;
    /**
     * The **`setTargetAtTime()`** method of the AudioParam interface schedules the start of a gradual change to the AudioParam value. This is useful for decay or release portions of ADSR envelopes.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioParam/setTargetAtTime)
     */
    setTargetAtTime(target: number, startTime: number, timeConstant: number): AudioParam;
    /**
     * The **`setValueAtTime()`** method of the AudioParam interface schedules an instant change to the AudioParam value at a precise time, as measured against AudioContext.currentTime. The new value is given in the value parameter.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioParam/setValueAtTime)
     */
    setValueAtTime(value: number, startTime: number): AudioParam;
    /**
     * The **`setValueCurveAtTime()`** method of the AudioParam interface schedules the parameter's value to change following a curve defined by a list of values.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioParam/setValueCurveAtTime)
     */
    setValueCurveAtTime(values: number[] | Float32Array, startTime: number, duration: number): AudioParam;
}

declare var AudioParam: {
    prototype: AudioParam;
    new(): AudioParam;
};

/**
 * The **`AudioParamMap`** interface of the Web Audio API represents an iterable and read-only set of multiple audio parameters.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioParamMap)
 */
interface AudioParamMap {
    forEach(callbackfn: (value: AudioParam, key: string, parent: AudioParamMap) => void, thisArg?: any): void;
}

declare var AudioParamMap: {
    prototype: AudioParamMap;
    new(): AudioParamMap;
};

/**
 * The **`AudioProcessingEvent`** interface of the Web Audio API represents events that occur when a ScriptProcessorNode input buffer is ready to be processed.
 * @deprecated As of the August 29 2014 Web Audio API spec publication, this feature has been marked as deprecated, and is soon to be replaced by AudioWorklet.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioProcessingEvent)
 */
interface AudioProcessingEvent extends Event {
    /**
     * The **`inputBuffer`** read-only property of the AudioProcessingEvent interface represents the input buffer of an audio processing event.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioProcessingEvent/inputBuffer)
     */
    readonly inputBuffer: AudioBuffer;
    /**
     * The **`outputBuffer`** read-only property of the AudioProcessingEvent interface represents the output buffer of an audio processing event.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioProcessingEvent/outputBuffer)
     */
    readonly outputBuffer: AudioBuffer;
    /**
     * The **`playbackTime`** read-only property of the AudioProcessingEvent interface represents the time when the audio will be played. It is in the same coordinate system as the time used by the AudioContext.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioProcessingEvent/playbackTime)
     */
    readonly playbackTime: number;
}

/** @deprecated */
declare var AudioProcessingEvent: {
    prototype: AudioProcessingEvent;
    new(type: string, eventInitDict: AudioProcessingEventInit): AudioProcessingEvent;
};

interface AudioScheduledSourceNodeEventMap {
    "ended": Event;
}

/**
 * The **`AudioScheduledSourceNode`** interface—part of the Web Audio API—is a parent interface for several types of audio source node interfaces which share the ability to be started and stopped, optionally at specified times. Specifically, this interface defines the start() and stop() methods, as well as the ended event.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioScheduledSourceNode)
 */
interface AudioScheduledSourceNode extends AudioNode {
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioScheduledSourceNode/ended_event) */
    onended: ((this: AudioScheduledSourceNode, ev: Event) => any) | null;
    /**
     * The **`start()`** method on AudioScheduledSourceNode schedules a sound to begin playback at the specified time. If no time is specified, then the sound begins playing immediately.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioScheduledSourceNode/start)
     */
    start(when?: number): void;
    /**
     * The **`stop()`** method on AudioScheduledSourceNode schedules a sound to cease playback at the specified time. If no time is specified, then the sound stops playing immediately.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioScheduledSourceNode/stop)
     */
    stop(when?: number): void;
    addEventListener<K extends keyof AudioScheduledSourceNodeEventMap>(type: K, listener: (this: AudioScheduledSourceNode, ev: AudioScheduledSourceNodeEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof AudioScheduledSourceNodeEventMap>(type: K, listener: (this: AudioScheduledSourceNode, ev: AudioScheduledSourceNodeEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var AudioScheduledSourceNode: {
    prototype: AudioScheduledSourceNode;
    new(): AudioScheduledSourceNode;
};

/**
 * The **`AudioWorklet`** interface of the Web Audio API is used to supply custom audio processing scripts that execute in a separate thread to provide very low latency audio processing.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioWorklet)
 */
interface AudioWorklet extends Worklet {
}

declare var AudioWorklet: {
    prototype: AudioWorklet;
    new(): AudioWorklet;
};

interface AudioWorkletNodeEventMap {
    "processorerror": ErrorEvent;
}

/**
 * The **`AudioWorkletNode`** interface of the Web Audio API represents a base class for a user-defined AudioNode, which can be connected to an audio routing graph along with other nodes. It has an associated AudioWorkletProcessor, which does the actual audio processing in a Web Audio rendering thread.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioWorkletNode)
 */
interface AudioWorkletNode extends AudioNode {
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioWorkletNode/processorerror_event) */
    onprocessorerror: ((this: AudioWorkletNode, ev: ErrorEvent) => any) | null;
    /**
     * The read-only **`parameters`** property of the AudioWorkletNode interface returns the associated AudioParamMap — that is, a Map-like collection of AudioParam objects. They are instantiated during creation of the underlying AudioWorkletProcessor according to its parameterDescriptors static getter.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioWorkletNode/parameters)
     */
    readonly parameters: AudioParamMap;
    /**
     * The read-only **`port`** property of the AudioWorkletNode interface returns the associated MessagePort. It can be used to communicate between the node and its associated AudioWorkletProcessor.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioWorkletNode/port)
     */
    readonly port: MessagePort;
    addEventListener<K extends keyof AudioWorkletNodeEventMap>(type: K, listener: (this: AudioWorkletNode, ev: AudioWorkletNodeEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof AudioWorkletNodeEventMap>(type: K, listener: (this: AudioWorkletNode, ev: AudioWorkletNodeEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var AudioWorkletNode: {
    prototype: AudioWorkletNode;
    new(context: BaseAudioContext, name: string, options?: AudioWorkletNodeOptions): AudioWorkletNode;
};

/**
 * The **`AuthenticatorAssertionResponse`** interface of the Web Authentication API contains a digital signature from the private key of a particular WebAuthn credential. The relying party's server can verify this signature to authenticate a user, for example when they sign in.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AuthenticatorAssertionResponse)
 */
interface AuthenticatorAssertionResponse extends AuthenticatorResponse {
    /**
     * The **`authenticatorData`** property of the AuthenticatorAssertionResponse interface returns an ArrayBuffer containing information from the authenticator such as the Relying Party ID Hash (rpIdHash), a signature counter, test of user presence, user verification flags, and any extensions processed by the authenticator.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AuthenticatorAssertionResponse/authenticatorData)
     */
    readonly authenticatorData: ArrayBuffer;
    /**
     * The **`signature`** read-only property of the AuthenticatorAssertionResponse interface is an ArrayBuffer object which is the signature of the authenticator for both AuthenticatorAssertionResponse.authenticatorData and a SHA-256 hash of the client data (AuthenticatorAssertionResponse.clientDataJSON).
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AuthenticatorAssertionResponse/signature)
     */
    readonly signature: ArrayBuffer;
    /**
     * The **`userHandle`** read-only property of the AuthenticatorAssertionResponse interface is an ArrayBuffer object providing an opaque identifier for the given user. Such an identifier can be used by the relying party's server to link the user account with its corresponding credentials and other data.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AuthenticatorAssertionResponse/userHandle)
     */
    readonly userHandle: ArrayBuffer | null;
}

declare var AuthenticatorAssertionResponse: {
    prototype: AuthenticatorAssertionResponse;
    new(): AuthenticatorAssertionResponse;
};

/**
 * The **`AuthenticatorAttestationResponse`** interface of the Web Authentication API is the result of a WebAuthn credential registration. It contains information about the credential that the server needs to perform WebAuthn assertions, such as its credential ID and public key.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AuthenticatorAttestationResponse)
 */
interface AuthenticatorAttestationResponse extends AuthenticatorResponse {
    /**
     * The **`attestationObject`** property of the AuthenticatorAttestationResponse interface returns an ArrayBuffer containing the new public key, as well as signature over the entire attestationObject with a private key that is stored in the authenticator when it is manufactured.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AuthenticatorAttestationResponse/attestationObject)
     */
    readonly attestationObject: ArrayBuffer;
    /**
     * The **`getAuthenticatorData()`** method of the AuthenticatorAttestationResponse interface returns an ArrayBuffer containing the authenticator data contained within the AuthenticatorAttestationResponse.attestationObject property.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AuthenticatorAttestationResponse/getAuthenticatorData)
     */
    getAuthenticatorData(): ArrayBuffer;
    /**
     * The **`getPublicKey()`** method of the AuthenticatorAttestationResponse interface returns an ArrayBuffer containing the DER SubjectPublicKeyInfo of the new credential (see Subject Public Key Info), or null if this is not available.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AuthenticatorAttestationResponse/getPublicKey)
     */
    getPublicKey(): ArrayBuffer | null;
    /**
     * The **`getPublicKeyAlgorithm()`** method of the AuthenticatorAttestationResponse interface returns a number that is equal to a COSE Algorithm Identifier, representing the cryptographic algorithm used for the new credential.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AuthenticatorAttestationResponse/getPublicKeyAlgorithm)
     */
    getPublicKeyAlgorithm(): COSEAlgorithmIdentifier;
    /**
     * The **`getTransports()`** method of the AuthenticatorAttestationResponse interface returns an array of strings describing the different transports which may be used by the authenticator.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AuthenticatorAttestationResponse/getTransports)
     */
    getTransports(): string[];
}

declare var AuthenticatorAttestationResponse: {
    prototype: AuthenticatorAttestationResponse;
    new(): AuthenticatorAttestationResponse;
};

/**
 * The **`AuthenticatorResponse`** interface of the Web Authentication API is the base interface for interfaces that provide a cryptographic root of trust for a key pair. The child interfaces include information from the browser such as the challenge origin and either may be returned from PublicKeyCredential.response.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AuthenticatorResponse)
 */
interface AuthenticatorResponse {
    /**
     * The **`clientDataJSON`** property of the AuthenticatorResponse interface stores a JSON string in an ArrayBuffer, representing the client data that was passed to navigator.credentials.create() or navigator.credentials.get(). This property is only accessed on one of the child objects of AuthenticatorResponse, specifically AuthenticatorAttestationResponse or AuthenticatorAssertionResponse.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AuthenticatorResponse/clientDataJSON)
     */
    readonly clientDataJSON: ArrayBuffer;
}

declare var AuthenticatorResponse: {
    prototype: AuthenticatorResponse;
    new(): AuthenticatorResponse;
};

/**
 * The **`BarProp`** interface of the Document Object Model represents the web browser user interface elements that are exposed to scripts in web pages. Each of the following interface elements are represented by a BarProp object.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/BarProp)
 */
interface BarProp {
    /**
     * The **`visible`** read-only property of the BarProp interface returns true if the user interface element it represents is visible.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/BarProp/visible)
     */
    readonly visible: boolean;
}

declare var BarProp: {
    prototype: BarProp;
    new(): BarProp;
};

interface BaseAudioContextEventMap {
    "statechange": Event;
}

/**
 * The **`BaseAudioContext`** interface of the Web Audio API acts as a base definition for online and offline audio-processing graphs, as represented by AudioContext and OfflineAudioContext respectively. You wouldn't use BaseAudioContext directly — you'd use its features via one of these two inheriting interfaces.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/BaseAudioContext)
 */
interface BaseAudioContext extends EventTarget {
    /**
     * The **`audioWorklet`** read-only property of the BaseAudioContext interface returns an instance of AudioWorklet that can be used for adding AudioWorkletProcessor-derived classes which implement custom audio processing.
     * Available only in secure contexts.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/BaseAudioContext/audioWorklet)
     */
    readonly audioWorklet: AudioWorklet;
    /**
     * The **`currentTime`** read-only property of the BaseAudioContext interface returns a double representing an ever-increasing hardware timestamp in seconds that can be used for scheduling audio playback, visualizing timelines, etc. It starts at 0.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/BaseAudioContext/currentTime)
     */
    readonly currentTime: number;
    /**
     * The **`destination`** property of the BaseAudioContext interface returns an AudioDestinationNode representing the final destination of all audio in the context. It often represents an actual audio-rendering device such as your device's speakers.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/BaseAudioContext/destination)
     */
    readonly destination: AudioDestinationNode;
    /**
     * The **`listener`** property of the BaseAudioContext interface returns an AudioListener object that can then be used for implementing 3D audio spatialization.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/BaseAudioContext/listener)
     */
    readonly listener: AudioListener;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/BaseAudioContext/statechange_event) */
    onstatechange: ((this: BaseAudioContext, ev: Event) => any) | null;
    /**
     * The **`sampleRate`** property of the BaseAudioContext interface returns a floating point number representing the sample rate, in samples per second, used by all nodes in this audio context. This limitation means that sample-rate converters are not supported.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/BaseAudioContext/sampleRate)
     */
    readonly sampleRate: number;
    /**
     * The **`state`** read-only property of the BaseAudioContext interface returns the current state of the AudioContext.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/BaseAudioContext/state)
     */
    readonly state: AudioContextState;
    /**
     * The **`createAnalyser()`** method of the BaseAudioContext interface creates an AnalyserNode, which can be used to expose audio time and frequency data and create data visualizations.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/BaseAudioContext/createAnalyser)
     */
    createAnalyser(): AnalyserNode;
    /**
     * The **`createBiquadFilter()`** method of the BaseAudioContext interface creates a BiquadFilterNode, which represents a second order filter configurable as several different common filter types.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/BaseAudioContext/createBiquadFilter)
     */
    createBiquadFilter(): BiquadFilterNode;
    /**
     * The **`createBuffer()`** method of the BaseAudioContext Interface is used to create a new, empty AudioBuffer object, which can then be populated by data, and played via an AudioBufferSourceNode.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/BaseAudioContext/createBuffer)
     */
    createBuffer(numberOfChannels: number, length: number, sampleRate: number): AudioBuffer;
    /**
     * The **`createBufferSource()`** method of the BaseAudioContext Interface is used to create a new AudioBufferSourceNode, which can be used to play audio data contained within an AudioBuffer object. AudioBuffers are created using BaseAudioContext.createBuffer or returned by BaseAudioContext.decodeAudioData when it successfully decodes an audio track.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/BaseAudioContext/createBufferSource)
     */
    createBufferSource(): AudioBufferSourceNode;
    /**
     * The **`createChannelMerger()`** method of the BaseAudioContext interface creates a ChannelMergerNode, which combines channels from multiple audio streams into a single audio stream.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/BaseAudioContext/createChannelMerger)
     */
    createChannelMerger(numberOfInputs?: number): ChannelMergerNode;
    /**
     * The **`createChannelSplitter()`** method of the BaseAudioContext Interface is used to create a ChannelSplitterNode, which is used to access the individual channels of an audio stream and process them separately.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/BaseAudioContext/createChannelSplitter)
     */
    createChannelSplitter(numberOfOutputs?: number): ChannelSplitterNode;
    /**
     * The **`createConstantSource()`** property of the BaseAudioContext interface creates a ConstantSourceNode object, which is an audio source that continuously outputs a monaural (one-channel) sound signal whose samples all have the same value.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/BaseAudioContext/createConstantSource)
     */
    createConstantSource(): ConstantSourceNode;
    /**
     * The **`createConvolver()`** method of the BaseAudioContext interface creates a ConvolverNode, which is commonly used to apply reverb effects to your audio. See the spec definition of Convolution for more information.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/BaseAudioContext/createConvolver)
     */
    createConvolver(): ConvolverNode;
    /**
     * The **`createDelay()`** method of the BaseAudioContext Interface is used to create a DelayNode, which is used to delay the incoming audio signal by a certain amount of time.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/BaseAudioContext/createDelay)
     */
    createDelay(maxDelayTime?: number): DelayNode;
    /**
     * The **`createDynamicsCompressor()`** method of the BaseAudioContext Interface is used to create a DynamicsCompressorNode, which can be used to apply compression to an audio signal.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/BaseAudioContext/createDynamicsCompressor)
     */
    createDynamicsCompressor(): DynamicsCompressorNode;
    /**
     * The **`createGain()`** method of the BaseAudioContext interface creates a GainNode, which can be used to control the overall gain (or volume) of the audio graph.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/BaseAudioContext/createGain)
     */
    createGain(): GainNode;
    /**
     * The **`createIIRFilter()`** method of the BaseAudioContext interface creates an IIRFilterNode, which represents a general infinite impulse response (IIR) filter which can be configured to serve as various types of filter.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/BaseAudioContext/createIIRFilter)
     */
    createIIRFilter(feedforward: number[], feedback: number[]): IIRFilterNode;
    /**
     * The **`createOscillator()`** method of the BaseAudioContext interface creates an OscillatorNode, a source representing a periodic waveform. It basically generates a constant tone.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/BaseAudioContext/createOscillator)
     */
    createOscillator(): OscillatorNode;
    /**
     * The **`createPanner()`** method of the BaseAudioContext Interface is used to create a new PannerNode, which is used to spatialize an incoming audio stream in 3D space.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/BaseAudioContext/createPanner)
     */
    createPanner(): PannerNode;
    /**
     * The **`createPeriodicWave()`** method of the BaseAudioContext interface is used to create a PeriodicWave. This wave is used to define a periodic waveform that can be used to shape the output of an OscillatorNode.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/BaseAudioContext/createPeriodicWave)
     */
    createPeriodicWave(real: number[] | Float32Array, imag: number[] | Float32Array, constraints?: PeriodicWaveConstraints): PeriodicWave;
    /**
     * The **`createScriptProcessor()`** method of the BaseAudioContext interface creates a ScriptProcessorNode used for direct audio processing.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/BaseAudioContext/createScriptProcessor)
     */
    createScriptProcessor(bufferSize?: number, numberOfInputChannels?: number, numberOfOutputChannels?: number): ScriptProcessorNode;
    /**
     * The **`createStereoPanner()`** method of the BaseAudioContext interface creates a StereoPannerNode, which can be used to apply stereo panning to an audio source. It positions an incoming audio stream in a stereo image using a low-cost panning algorithm.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/BaseAudioContext/createStereoPanner)
     */
    createStereoPanner(): StereoPannerNode;
    /**
     * The **`createWaveShaper()`** method of the BaseAudioContext interface creates a WaveShaperNode, which represents a non-linear distortion. It is used to apply distortion effects to your audio.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/BaseAudioContext/createWaveShaper)
     */
    createWaveShaper(): WaveShaperNode;
    /**
     * The **`decodeAudioData()`** method of the BaseAudioContext Interface is used to asynchronously decode audio file data contained in an ArrayBuffer that is loaded from fetch(), XMLHttpRequest, or FileReader. The decoded AudioBuffer is resampled to the AudioContext's sampling rate, then passed to a callback or promise.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/BaseAudioContext/decodeAudioData)
     */
    decodeAudioData(audioData: ArrayBuffer, successCallback?: DecodeSuccessCallback | null, errorCallback?: DecodeErrorCallback | null): Promise<AudioBuffer>;
    addEventListener<K extends keyof BaseAudioContextEventMap>(type: K, listener: (this: BaseAudioContext, ev: BaseAudioContextEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof BaseAudioContextEventMap>(type: K, listener: (this: BaseAudioContext, ev: BaseAudioContextEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var BaseAudioContext: {
    prototype: BaseAudioContext;
    new(): BaseAudioContext;
};

/**
 * The **`BeforeUnloadEvent`** interface represents the event object for the beforeunload event, which is fired when the current window, contained document, and associated resources are about to be unloaded.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/BeforeUnloadEvent)
 */
interface BeforeUnloadEvent extends Event {
    /**
     * The **`returnValue`** property of the BeforeUnloadEvent interface, when set to a truthy value, triggers a browser-generated confirmation dialog asking users to confirm if they really want to leave the page when they try to close or reload it, or navigate somewhere else. This is intended to help prevent loss of unsaved data.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/BeforeUnloadEvent/returnValue)
     */
    returnValue: any;
}

declare var BeforeUnloadEvent: {
    prototype: BeforeUnloadEvent;
    new(): BeforeUnloadEvent;
};

/**
 * The **`BiquadFilterNode`** interface represents a simple low-order filter, and is created using the BaseAudioContext/createBiquadFilter method. It is an AudioNode that can represent different kinds of filters, tone control devices, and graphic equalizers. A BiquadFilterNode always has exactly one input and one output.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/BiquadFilterNode)
 */
interface BiquadFilterNode extends AudioNode {
    /**
     * The **`Q`** property of the BiquadFilterNode interface is an a-rate AudioParam, a double representing a Q factor, or quality factor.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/BiquadFilterNode/Q)
     */
    readonly Q: AudioParam;
    /**
     * The **`detune`** property of the BiquadFilterNode interface is an a-rate AudioParam representing detuning of the frequency in cents.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/BiquadFilterNode/detune)
     */
    readonly detune: AudioParam;
    /**
     * The **`frequency`** property of the BiquadFilterNode interface is an a-rate AudioParam — a double representing a frequency in the current filtering algorithm measured in hertz (Hz).
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/BiquadFilterNode/frequency)
     */
    readonly frequency: AudioParam;
    /**
     * The **`gain`** property of the BiquadFilterNode interface is an a-rate AudioParam — a double representing the gain used in the current filtering algorithm.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/BiquadFilterNode/gain)
     */
    readonly gain: AudioParam;
    /**
     * The **`type`** property of the BiquadFilterNode interface is a string (enum) value defining the kind of filtering algorithm the node is implementing.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/BiquadFilterNode/type)
     */
    type: BiquadFilterType;
    /**
     * The **`getFrequencyResponse()`** method of the BiquadFilterNode interface takes the current filtering algorithm's settings and calculates the frequency response for frequencies specified in a specified array of frequencies.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/BiquadFilterNode/getFrequencyResponse)
     */
    getFrequencyResponse(frequencyHz: Float32Array<ArrayBuffer>, magResponse: Float32Array<ArrayBuffer>, phaseResponse: Float32Array<ArrayBuffer>): void;
}

declare var BiquadFilterNode: {
    prototype: BiquadFilterNode;
    new(context: BaseAudioContext, options?: BiquadFilterOptions): BiquadFilterNode;
};

/**
 * The **`Blob`** interface represents a blob, which is a file-like object of immutable, raw data; they can be read as text or binary data, or converted into a ReadableStream so its methods can be used for processing the data.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Blob)
 */
interface Blob {
    /**
     * The **`size`** read-only property of the Blob interface returns the size of the Blob or File in bytes.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Blob/size)
     */
    readonly size: number;
    /**
     * The **`type`** read-only property of the Blob interface returns the MIME type of the file.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Blob/type)
     */
    readonly type: string;
    /**
     * The **`arrayBuffer()`** method of the Blob interface returns a Promise that resolves with the contents of the blob as binary data contained in an ArrayBuffer.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Blob/arrayBuffer)
     */
    arrayBuffer(): Promise<ArrayBuffer>;
    /**
     * The **`bytes()`** method of the Blob interface returns a Promise that resolves with a Uint8Array containing the contents of the blob as an array of bytes.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Blob/bytes)
     */
    bytes(): Promise<Uint8Array<ArrayBuffer>>;
    /**
     * The **`slice()`** method of the Blob interface creates and returns a new Blob object which contains data from a subset of the blob on which it's called.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Blob/slice)
     */
    slice(start?: number, end?: number, contentType?: string): Blob;
    /**
     * The **`stream()`** method of the Blob interface returns a ReadableStream which upon reading returns the data contained within the Blob.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Blob/stream)
     */
    stream(): ReadableStream<Uint8Array<ArrayBuffer>>;
    /**
     * The **`text()`** method of the Blob interface returns a Promise that resolves with a string containing the contents of the blob, interpreted as UTF-8.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Blob/text)
     */
    text(): Promise<string>;
}

declare var Blob: {
    prototype: Blob;
    new(blobParts?: BlobPart[], options?: BlobPropertyBag): Blob;
};

/**
 * The **`BlobEvent`** interface of the MediaStream Recording API represents events associated with a Blob. These blobs are typically, but not necessarily, associated with media content.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/BlobEvent)
 */
interface BlobEvent extends Event {
    /**
     * The **`data`** read-only property of the BlobEvent interface represents a Blob associated with the event.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/BlobEvent/data)
     */
    readonly data: Blob;
    /**
     * The **`timecode`** read-only property of the BlobEvent interface indicates the difference between the timestamp of the first chunk of data, and the timestamp of the first chunk in the first BlobEvent produced by this recorder.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/BlobEvent/timecode)
     */
    readonly timecode: DOMHighResTimeStamp;
}

declare var BlobEvent: {
    prototype: BlobEvent;
    new(type: string, eventInitDict: BlobEventInit): BlobEvent;
};

interface Body {
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Request/body) */
    readonly body: ReadableStream<Uint8Array<ArrayBuffer>> | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Request/bodyUsed) */
    readonly bodyUsed: boolean;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Request/arrayBuffer) */
    arrayBuffer(): Promise<ArrayBuffer>;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Request/blob) */
    blob(): Promise<Blob>;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Request/bytes) */
    bytes(): Promise<Uint8Array<ArrayBuffer>>;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Request/formData) */
    formData(): Promise<FormData>;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Request/json) */
    json(): Promise<any>;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Request/text) */
    text(): Promise<string>;
}

interface BroadcastChannelEventMap {
    "message": MessageEvent;
    "messageerror": MessageEvent;
}

/**
 * The **`BroadcastChannel`** interface represents a named channel that any browsing context of a given origin can subscribe to. It allows communication between different documents (in different windows, tabs, frames or iframes) of the same origin. Messages are broadcasted via a message event fired at all BroadcastChannel objects listening to the channel, except the object that sent the message.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/BroadcastChannel)
 */
interface BroadcastChannel extends EventTarget {
    /**
     * The **`name`** read-only property of the BroadcastChannel interface returns a string, which uniquely identifies the given channel with its name. This name is passed to the BroadcastChannel() constructor at creation time and is therefore read-only.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/BroadcastChannel/name)
     */
    readonly name: string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/BroadcastChannel/message_event) */
    onmessage: ((this: BroadcastChannel, ev: MessageEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/BroadcastChannel/messageerror_event) */
    onmessageerror: ((this: BroadcastChannel, ev: MessageEvent) => any) | null;
    /**
     * The **`close()`** method of the BroadcastChannel interface terminates the connection to the underlying channel, allowing the object to be garbage collected. This is a necessary step to perform as there is no other way for a browser to know that this channel is not needed anymore.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/BroadcastChannel/close)
     */
    close(): void;
    /**
     * The **`postMessage()`** method of the BroadcastChannel interface sends a message, which can be of any kind of Object, to each listener in any browsing context with the same origin. The message is transmitted as a message event targeted at each BroadcastChannel bound to the channel.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/BroadcastChannel/postMessage)
     */
    postMessage(message: any): void;
    addEventListener<K extends keyof BroadcastChannelEventMap>(type: K, listener: (this: BroadcastChannel, ev: BroadcastChannelEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof BroadcastChannelEventMap>(type: K, listener: (this: BroadcastChannel, ev: BroadcastChannelEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var BroadcastChannel: {
    prototype: BroadcastChannel;
    new(name: string): BroadcastChannel;
};

/**
 * The **`ByteLengthQueuingStrategy`** interface of the Streams API provides a built-in byte length queuing strategy that can be used when constructing streams.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ByteLengthQueuingStrategy)
 */
interface ByteLengthQueuingStrategy extends QueuingStrategy<ArrayBufferView> {
    /**
     * The read-only **`ByteLengthQueuingStrategy.highWaterMark`** property returns the total number of bytes that can be contained in the internal queue before backpressure is applied.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ByteLengthQueuingStrategy/highWaterMark)
     */
    readonly highWaterMark: number;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/ByteLengthQueuingStrategy/size) */
    readonly size: QueuingStrategySize<ArrayBufferView>;
}

declare var ByteLengthQueuingStrategy: {
    prototype: ByteLengthQueuingStrategy;
    new(init: QueuingStrategyInit): ByteLengthQueuingStrategy;
};

/**
 * The **`CDATASection`** interface represents a CDATA section that can be used within XML to include extended portions of unescaped text. When inside a CDATA section, the symbols < and & don't need escaping as they normally do.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CDATASection)
 */
interface CDATASection extends Text {
}

declare var CDATASection: {
    prototype: CDATASection;
    new(): CDATASection;
};

/**
 * The **`CSSAnimation`** interface of the Web Animations API represents an Animation object.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSAnimation)
 */
interface CSSAnimation extends Animation {
    /**
     * The **`animationName`** property of the CSSAnimation interface returns the animation-name. This specifies one or more keyframe at-rules which describe the animation applied to the element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSAnimation/animationName)
     */
    readonly animationName: string;
    addEventListener<K extends keyof AnimationEventMap>(type: K, listener: (this: CSSAnimation, ev: AnimationEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof AnimationEventMap>(type: K, listener: (this: CSSAnimation, ev: AnimationEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var CSSAnimation: {
    prototype: CSSAnimation;
    new(): CSSAnimation;
};

/**
 * An object implementing the **`CSSConditionRule`** interface represents a single condition CSS at-rule, which consists of a condition and a statement block.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSConditionRule)
 */
interface CSSConditionRule extends CSSGroupingRule {
    /**
     * The read-only **`conditionText`** property of the CSSConditionRule interface returns or sets the text of the CSS rule.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSConditionRule/conditionText)
     */
    readonly conditionText: string;
}

declare var CSSConditionRule: {
    prototype: CSSConditionRule;
    new(): CSSConditionRule;
};

/**
 * The **`CSSContainerRule`** interface represents a single CSS @container rule.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSContainerRule)
 */
interface CSSContainerRule extends CSSConditionRule {
    /**
     * The read-only **`containerName`** property of the CSSContainerRule interface represents the container name of the associated CSS @container at-rule.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSContainerRule/containerName)
     */
    readonly containerName: string;
    /**
     * The read-only **`containerQuery`** property of the CSSContainerRule interface returns a string representing the container conditions that are evaluated when the container changes size in order to determine if the styles in the associated @container are applied.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSContainerRule/containerQuery)
     */
    readonly containerQuery: string;
}

declare var CSSContainerRule: {
    prototype: CSSContainerRule;
    new(): CSSContainerRule;
};

/**
 * The **`CSSCounterStyleRule`** interface represents an @counter-style at-rule.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSCounterStyleRule)
 */
interface CSSCounterStyleRule extends CSSRule {
    /**
     * The **`additiveSymbols`** property of the CSSCounterStyleRule interface gets and sets the value of the additive-symbols descriptor. If the descriptor does not have a value set, this attribute returns an empty string.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSCounterStyleRule/additiveSymbols)
     */
    additiveSymbols: string;
    /**
     * The **`fallback`** property of the CSSCounterStyleRule interface gets and sets the value of the fallback descriptor. If the descriptor does not have a value set, this attribute returns an empty string.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSCounterStyleRule/fallback)
     */
    fallback: string;
    /**
     * The **`name`** property of the CSSCounterStyleRule interface gets and sets the <custom-ident> defined as the name for the associated rule.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSCounterStyleRule/name)
     */
    name: string;
    /**
     * The **`negative`** property of the CSSCounterStyleRule interface gets and sets the value of the negative descriptor. If the descriptor does not have a value set, this attribute returns an empty string.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSCounterStyleRule/negative)
     */
    negative: string;
    /**
     * The **`pad`** property of the CSSCounterStyleRule interface gets and sets the value of the pad descriptor. If the descriptor does not have a value set, this attribute returns an empty string.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSCounterStyleRule/pad)
     */
    pad: string;
    /**
     * The **`prefix`** property of the CSSCounterStyleRule interface gets and sets the value of the prefix descriptor. If the descriptor does not have a value set, this attribute returns an empty string.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSCounterStyleRule/prefix)
     */
    prefix: string;
    /**
     * The **`range`** property of the CSSCounterStyleRule interface gets and sets the value of the range descriptor. If the descriptor does not have a value set, this attribute returns an empty string.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSCounterStyleRule/range)
     */
    range: string;
    /**
     * The **`speakAs`** property of the CSSCounterStyleRule interface gets and sets the value of the speak-as descriptor. If the descriptor does not have a value set, this attribute returns an empty string.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSCounterStyleRule/speakAs)
     */
    speakAs: string;
    /**
     * The **`suffix`** property of the CSSCounterStyleRule interface gets and sets the value of the suffix descriptor. If the descriptor does not have a value set, this attribute returns an empty string.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSCounterStyleRule/suffix)
     */
    suffix: string;
    /**
     * The **`symbols`** property of the CSSCounterStyleRule interface gets and sets the value of the symbols descriptor. If the descriptor does not have a value set, this attribute returns an empty string.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSCounterStyleRule/symbols)
     */
    symbols: string;
    /**
     * The **`system`** property of the CSSCounterStyleRule interface gets and sets the value of the system descriptor. If the descriptor does not have a value set, this attribute returns an empty string.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSCounterStyleRule/system)
     */
    system: string;
}

declare var CSSCounterStyleRule: {
    prototype: CSSCounterStyleRule;
    new(): CSSCounterStyleRule;
};

/**
 * The **`CSSFontFaceRule`** interface represents an @font-face at-rule.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSFontFaceRule)
 */
interface CSSFontFaceRule extends CSSRule {
    /**
     * The read-only **`style`** property of the CSSFontFaceRule interface contains a CSSStyleDeclaration object representing the descriptors available in the @font-face rule's body.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSFontFaceRule/style)
     */
    get style(): CSSStyleDeclaration;
    set style(cssText: string);
}

declare var CSSFontFaceRule: {
    prototype: CSSFontFaceRule;
    new(): CSSFontFaceRule;
};

/**
 * The **`CSSFontFeatureValuesRule`** interface represents an @font-feature-values at-rule. The values of its instance properties can be accessed with the CSSFontFeatureValuesMap interface.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSFontFeatureValuesRule)
 */
interface CSSFontFeatureValuesRule extends CSSRule {
    /**
     * The **`fontFamily`** property of the CSSFontFeatureValuesRule interface represents the name of the font family it applies to.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSFontFeatureValuesRule/fontFamily)
     */
    fontFamily: string;
}

declare var CSSFontFeatureValuesRule: {
    prototype: CSSFontFeatureValuesRule;
    new(): CSSFontFeatureValuesRule;
};

/**
 * The **`CSSFontPaletteValuesRule`** interface represents an @font-palette-values at-rule.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSFontPaletteValuesRule)
 */
interface CSSFontPaletteValuesRule extends CSSRule {
    /**
     * The read-only **`basePalette`** property of the CSSFontPaletteValuesRule interface indicates the base palette associated with the rule.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSFontPaletteValuesRule/basePalette)
     */
    readonly basePalette: string;
    /**
     * The read-only **`fontFamily`** property of the CSSFontPaletteValuesRule interface lists the font families the rule can be applied to. The font families must be named families; generic families like courier are not valid.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSFontPaletteValuesRule/fontFamily)
     */
    readonly fontFamily: string;
    /**
     * The read-only **`name`** property of the CSSFontPaletteValuesRule interface represents the name identifying the associated @font-palette-values at-rule. A valid name always starts with two dashes, such as --Alternate.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSFontPaletteValuesRule/name)
     */
    readonly name: string;
    /**
     * The read-only **`overrideColors`** property of the CSSFontPaletteValuesRule interface is a string containing a list of color index and color pair that are to be used instead. It is specified in the same format as the corresponding override-colors descriptor.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSFontPaletteValuesRule/overrideColors)
     */
    readonly overrideColors: string;
}

declare var CSSFontPaletteValuesRule: {
    prototype: CSSFontPaletteValuesRule;
    new(): CSSFontPaletteValuesRule;
};

/**
 * The **`CSSGroupingRule`** interface of the CSS Object Model represents any CSS at-rule that contains other rules nested within it.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSGroupingRule)
 */
interface CSSGroupingRule extends CSSRule {
    /**
     * The **`cssRules`** property of the CSSGroupingRule interface returns a CSSRuleList containing a collection of CSSRule objects.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSGroupingRule/cssRules)
     */
    readonly cssRules: CSSRuleList;
    /**
     * The **`deleteRule()`** method of the CSSGroupingRule interface removes a CSS rule from a list of child CSS rules.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSGroupingRule/deleteRule)
     */
    deleteRule(index: number): void;
    /**
     * The **`insertRule()`** method of the CSSGroupingRule interface adds a new CSS rule to a list of CSS rules.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSGroupingRule/insertRule)
     */
    insertRule(rule: string, index?: number): number;
}

declare var CSSGroupingRule: {
    prototype: CSSGroupingRule;
    new(): CSSGroupingRule;
};

/**
 * The **`CSSImageValue`** interface of the CSS Typed Object Model API represents values for properties that take an image, for example background-image, list-style-image, or border-image-source.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSImageValue)
 */
interface CSSImageValue extends CSSStyleValue {
}

declare var CSSImageValue: {
    prototype: CSSImageValue;
    new(): CSSImageValue;
};

/**
 * The **`CSSImportRule`** interface represents an @import at-rule.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSImportRule)
 */
interface CSSImportRule extends CSSRule {
    /**
     * The read-only **`href`** property of the CSSImportRule interface returns the URL specified by the @import at-rule.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSImportRule/href)
     */
    readonly href: string;
    /**
     * The read-only **`layerName`** property of the CSSImportRule interface returns the name of the cascade layer created by the @import at-rule.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSImportRule/layerName)
     */
    readonly layerName: string | null;
    /**
     * The read-only **`media`** property of the CSSImportRule interface returns a MediaList object representing the media query list of the @import rule.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSImportRule/media)
     */
    get media(): MediaList;
    set media(mediaText: string);
    /**
     * The read-only **`styleSheet`** property of the CSSImportRule interface returns the CSS Stylesheet specified by the @import at-rule. This will be in the form of a CSSStyleSheet object.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSImportRule/styleSheet)
     */
    readonly styleSheet: CSSStyleSheet | null;
    /**
     * The read-only **`supportsText`** property of the CSSImportRule interface returns the supports condition specified by the @import at-rule.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSImportRule/supportsText)
     */
    readonly supportsText: string | null;
}

declare var CSSImportRule: {
    prototype: CSSImportRule;
    new(): CSSImportRule;
};

/**
 * The **`CSSKeyframeRule`** interface describes an object representing a set of styles for a given keyframe. It corresponds to the contents of a single keyframe of a @keyframes at-rule.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSKeyframeRule)
 */
interface CSSKeyframeRule extends CSSRule {
    /**
     * The **`keyText`** property of the CSSKeyframeRule interface represents the keyframe selector as a comma-separated list of percentage values. The from and to keywords map to 0% and 100%, respectively.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSKeyframeRule/keyText)
     */
    keyText: string;
    /**
     * The read-only **`style`** property of the CSSKeyframeRule interface contains a CSSStyleDeclaration object representing the descriptors available in the @keyframes rule's body.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSKeyframeRule/style)
     */
    get style(): CSSStyleDeclaration;
    set style(cssText: string);
}

declare var CSSKeyframeRule: {
    prototype: CSSKeyframeRule;
    new(): CSSKeyframeRule;
};

/**
 * The **`CSSKeyframesRule`** interface describes an object representing a complete set of keyframes for a CSS animation. It corresponds to the contents of a whole @keyframes at-rule.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSKeyframesRule)
 */
interface CSSKeyframesRule extends CSSRule {
    /**
     * The read-only **`cssRules`** property of the CSSKeyframeRule interface returns a CSSRuleList containing the rules in the keyframes at-rule.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSKeyframesRule/cssRules)
     */
    readonly cssRules: CSSRuleList;
    /**
     * The read-only **`length`** property of the CSSKeyframesRule interface returns the number of CSSKeyframeRule objects in its list. You can then access each keyframe rule by its index directly on the CSSKeyframeRule object.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSKeyframesRule/length)
     */
    readonly length: number;
    /**
     * The **`name`** property of the CSSKeyframeRule interface gets and sets the name of the animation as used by the animation-name property.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSKeyframesRule/name)
     */
    name: string;
    /**
     * The **`appendRule()`** method of the CSSKeyframeRule interface appends a CSSKeyFrameRule to the end of the rules.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSKeyframesRule/appendRule)
     */
    appendRule(rule: string): void;
    /**
     * The **`deleteRule()`** method of the CSSKeyframeRule interface deletes the CSSKeyFrameRule that matches the specified keyframe selector.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSKeyframesRule/deleteRule)
     */
    deleteRule(select: string): void;
    /**
     * The **`findRule()`** method of the CSSKeyframeRule interface finds the CSSKeyFrameRule that matches the specified keyframe selector.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSKeyframesRule/findRule)
     */
    findRule(select: string): CSSKeyframeRule | null;
    [index: number]: CSSKeyframeRule;
}

declare var CSSKeyframesRule: {
    prototype: CSSKeyframesRule;
    new(): CSSKeyframesRule;
};

/**
 * The **`CSSKeywordValue`** interface of the CSS Typed Object Model API creates an object to represent CSS keywords and other identifiers.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSKeywordValue)
 */
interface CSSKeywordValue extends CSSStyleValue {
    /**
     * The **`value`** property of the CSSKeywordValue interface returns or sets the value of the CSSKeywordValue.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSKeywordValue/value)
     */
    value: string;
}

declare var CSSKeywordValue: {
    prototype: CSSKeywordValue;
    new(value: string): CSSKeywordValue;
};

/**
 * The **`CSSLayerBlockRule`** represents a @layer block rule.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSLayerBlockRule)
 */
interface CSSLayerBlockRule extends CSSGroupingRule {
    /**
     * The read-only **`name`** property of the CSSLayerBlockRule interface represents the name of the associated cascade layer.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSLayerBlockRule/name)
     */
    readonly name: string;
}

declare var CSSLayerBlockRule: {
    prototype: CSSLayerBlockRule;
    new(): CSSLayerBlockRule;
};

/**
 * The **`CSSLayerStatementRule`** represents a @layer statement rule. Unlike CSSLayerBlockRule, it doesn't contain other rules and merely defines one or several layers by providing their names.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSLayerStatementRule)
 */
interface CSSLayerStatementRule extends CSSRule {
    /**
     * The read-only **`nameList`** property of the CSSLayerStatementRule interface return the list of associated cascade layer names. The names can't be modified.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSLayerStatementRule/nameList)
     */
    readonly nameList: ReadonlyArray<string>;
}

declare var CSSLayerStatementRule: {
    prototype: CSSLayerStatementRule;
    new(): CSSLayerStatementRule;
};

interface CSSMathClamp extends CSSMathValue {
    readonly lower: CSSNumericValue;
    readonly upper: CSSNumericValue;
    readonly value: CSSNumericValue;
}

declare var CSSMathClamp: {
    prototype: CSSMathClamp;
    new(lower: CSSNumberish, value: CSSNumberish, upper: CSSNumberish): CSSMathClamp;
};

/**
 * The **`CSSMathInvert`** interface of the CSS Typed Object Model API represents a CSS calc() used as calc(1 / <value>). It inherits properties and methods from its parent CSSNumericValue.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSMathInvert)
 */
interface CSSMathInvert extends CSSMathValue {
    /**
     * The **`CSSMathInvert.value`** read-only property of the CSSMathInvert interface returns a CSSNumericValue object.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSMathInvert/value)
     */
    readonly value: CSSNumericValue;
}

declare var CSSMathInvert: {
    prototype: CSSMathInvert;
    new(arg: CSSNumberish): CSSMathInvert;
};

/**
 * The **`CSSMathMax`** interface of the CSS Typed Object Model API represents the CSS max() function. It inherits properties and methods from its parent CSSNumericValue.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSMathMax)
 */
interface CSSMathMax extends CSSMathValue {
    /**
     * The **`CSSMathMax.values`** read-only property of the CSSMathMax interface returns a CSSNumericArray object which contains one or more CSSNumericValue objects.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSMathMax/values)
     */
    readonly values: CSSNumericArray;
}

declare var CSSMathMax: {
    prototype: CSSMathMax;
    new(...args: CSSNumberish[]): CSSMathMax;
};

/**
 * The **`CSSMathMin`** interface of the CSS Typed Object Model API represents the CSS min() function. It inherits properties and methods from its parent CSSNumericValue.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSMathMin)
 */
interface CSSMathMin extends CSSMathValue {
    /**
     * The **`CSSMathMin.values`** read-only property of the CSSMathMin interface returns a CSSNumericArray object which contains one or more CSSNumericValue objects.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSMathMin/values)
     */
    readonly values: CSSNumericArray;
}

declare var CSSMathMin: {
    prototype: CSSMathMin;
    new(...args: CSSNumberish[]): CSSMathMin;
};

/**
 * The **`CSSMathNegate`** interface of the CSS Typed Object Model API negates the value passed into it. It inherits properties and methods from its parent CSSNumericValue.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSMathNegate)
 */
interface CSSMathNegate extends CSSMathValue {
    /**
     * The **`CSSMathNegate.value`** read-only property of the CSSMathNegate interface returns a CSSNumericValue object.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSMathNegate/value)
     */
    readonly value: CSSNumericValue;
}

declare var CSSMathNegate: {
    prototype: CSSMathNegate;
    new(arg: CSSNumberish): CSSMathNegate;
};

/**
 * The **`CSSMathProduct`** interface of the CSS Typed Object Model API represents the result obtained by calling add(), sub(), or toSum() on CSSNumericValue. It inherits properties and methods from its parent CSSNumericValue.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSMathProduct)
 */
interface CSSMathProduct extends CSSMathValue {
    /**
     * The **`CSSMathProduct.values`** read-only property of the CSSMathProduct interface returns a CSSNumericArray object which contains one or more CSSNumericValue objects.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSMathProduct/values)
     */
    readonly values: CSSNumericArray;
}

declare var CSSMathProduct: {
    prototype: CSSMathProduct;
    new(...args: CSSNumberish[]): CSSMathProduct;
};

/**
 * The **`CSSMathSum`** interface of the CSS Typed Object Model API represents the result obtained by calling add(), sub(), or toSum() on CSSNumericValue.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSMathSum)
 */
interface CSSMathSum extends CSSMathValue {
    /**
     * The **`CSSMathSum.values`** read-only property of the CSSMathSum interface returns a CSSNumericArray object which contains one or more CSSNumericValue objects.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSMathSum/values)
     */
    readonly values: CSSNumericArray;
}

declare var CSSMathSum: {
    prototype: CSSMathSum;
    new(...args: CSSNumberish[]): CSSMathSum;
};

/**
 * The **`CSSMathValue`** interface of the CSS Typed Object Model API a base class for classes representing complex numeric values.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSMathValue)
 */
interface CSSMathValue extends CSSNumericValue {
    /**
     * The **`CSSMathValue.operator`** read-only property of the CSSMathValue interface indicates the operator that the current subtype represents. For example, if the current CSSMathValue subtype is CSSMathSum, this property will return the string "sum".
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSMathValue/operator)
     */
    readonly operator: CSSMathOperator;
}

declare var CSSMathValue: {
    prototype: CSSMathValue;
    new(): CSSMathValue;
};

/**
 * The **`CSSMatrixComponent`** interface of the CSS Typed Object Model API represents the matrix() and matrix3d() values of the individual transform property in CSS. It inherits properties and methods from its parent CSSTransformValue.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSMatrixComponent)
 */
interface CSSMatrixComponent extends CSSTransformComponent {
    /**
     * The **`matrix`** property of the CSSMatrixComponent interface gets and sets a 2d or 3d matrix.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSMatrixComponent/matrix)
     */
    matrix: DOMMatrix;
}

declare var CSSMatrixComponent: {
    prototype: CSSMatrixComponent;
    new(matrix: DOMMatrixReadOnly, options?: CSSMatrixComponentOptions): CSSMatrixComponent;
};

/**
 * The **`CSSMediaRule`** interface represents a single CSS @media rule.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSMediaRule)
 */
interface CSSMediaRule extends CSSConditionRule {
    /**
     * The read-only **`media`** property of the CSSMediaRule interface contains a MediaList object representing the media query list of the @media rule.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSMediaRule/media)
     */
    get media(): MediaList;
    set media(mediaText: string);
}

declare var CSSMediaRule: {
    prototype: CSSMediaRule;
    new(): CSSMediaRule;
};

/**
 * The **`CSSNamespaceRule`** interface describes an object representing a single CSS @namespace at-rule.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSNamespaceRule)
 */
interface CSSNamespaceRule extends CSSRule {
    /**
     * The read-only **`namespaceURI`** property of the CSSNamespaceRule returns a string containing the text of the URI of the given namespace.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSNamespaceRule/namespaceURI)
     */
    readonly namespaceURI: string;
    /**
     * The read-only **`prefix`** property of the CSSNamespaceRule returns a string with the name of the prefix associated to this namespace. If there is no such prefix, it returns an empty string.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSNamespaceRule/prefix)
     */
    readonly prefix: string;
}

declare var CSSNamespaceRule: {
    prototype: CSSNamespaceRule;
    new(): CSSNamespaceRule;
};

/**
 * The **`CSSNestedDeclarations`** interface of the CSS Rule API is used to group nested CSSRules.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSNestedDeclarations)
 */
interface CSSNestedDeclarations extends CSSRule {
    /**
     * The read-only **`style`** property of the CSSNestedDeclarations interface represents the styles associated with the nested rules.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSNestedDeclarations/style)
     */
    get style(): CSSStyleDeclaration;
    set style(cssText: string);
}

declare var CSSNestedDeclarations: {
    prototype: CSSNestedDeclarations;
    new(): CSSNestedDeclarations;
};

/**
 * The **`CSSNumericArray`** interface of the CSS Typed Object Model API contains a list of CSSNumericValue objects.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSNumericArray)
 */
interface CSSNumericArray {
    /**
     * The read-only **`length`** property of the CSSNumericArray interface returns the number of CSSNumericValue objects in the list.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSNumericArray/length)
     */
    readonly length: number;
    forEach(callbackfn: (value: CSSNumericValue, key: number, parent: CSSNumericArray) => void, thisArg?: any): void;
    [index: number]: CSSNumericValue;
}

declare var CSSNumericArray: {
    prototype: CSSNumericArray;
    new(): CSSNumericArray;
};

/**
 * The **`CSSNumericValue`** interface of the CSS Typed Object Model API represents operations that all numeric values can perform.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSNumericValue)
 */
interface CSSNumericValue extends CSSStyleValue {
    /**
     * The **`add()`** method of the CSSNumericValue interface adds a supplied number to the CSSNumericValue.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSNumericValue/add)
     */
    add(...values: CSSNumberish[]): CSSNumericValue;
    /**
     * The **`div()`** method of the CSSNumericValue interface divides the CSSNumericValue by the supplied value.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSNumericValue/div)
     */
    div(...values: CSSNumberish[]): CSSNumericValue;
    /**
     * The **`equals()`** method of the CSSNumericValue interface returns a boolean indicating whether the passed value are strictly equal. To return a value of true, all passed values must be of the same type and value and must be in the same order. This allows structural equality to be tested quickly.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSNumericValue/equals)
     */
    equals(...value: CSSNumberish[]): boolean;
    /**
     * The **`max()`** method of the CSSNumericValue interface returns the highest value from among the values passed. The passed values must be of the same type.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSNumericValue/max)
     */
    max(...values: CSSNumberish[]): CSSNumericValue;
    /**
     * The **`min()`** method of the CSSNumericValue interface returns the lowest value from among those values passed. The passed values must be of the same type.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSNumericValue/min)
     */
    min(...values: CSSNumberish[]): CSSNumericValue;
    /**
     * The **`mul()`** method of the CSSNumericValue interface multiplies the CSSNumericValue by the supplied value.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSNumericValue/mul)
     */
    mul(...values: CSSNumberish[]): CSSNumericValue;
    /**
     * The **`sub()`** method of the CSSNumericValue interface subtracts a supplied number from the CSSNumericValue.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSNumericValue/sub)
     */
    sub(...values: CSSNumberish[]): CSSNumericValue;
    /**
     * The **`to()`** method of the CSSNumericValue interface converts a numeric value from one unit to another.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSNumericValue/to)
     */
    to(unit: string): CSSUnitValue;
    /**
     * The **`toSum()`** method of the CSSNumericValue interface converts the object's value to a CSSMathSum object to values of the specified unit.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSNumericValue/toSum)
     */
    toSum(...units: string[]): CSSMathSum;
    /**
     * The **`type()`** method of the CSSNumericValue interface returns the type of CSSNumericValue, one of angle, flex, frequency, length, resolution, percent, percentHint, or time.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSNumericValue/type)
     */
    type(): CSSNumericType;
}

declare var CSSNumericValue: {
    prototype: CSSNumericValue;
    new(): CSSNumericValue;
    /**
     * The **`parse()`** static method of the CSSNumericValue interface converts a value string into an object whose members are value and the units.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSNumericValue/parse_static)
     */
    parse(cssText: string): CSSNumericValue;
};

/**
 * The **`CSSPageDescriptors`** interface represents a CSS declaration block for an @page at-rule.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPageDescriptors)
 */
interface CSSPageDescriptors extends CSSStyleDeclarationBase {
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPageDescriptors#margin) */
    margin: string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPageDescriptors#margin-bottom) */
    "margin-bottom": string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPageDescriptors#margin-left) */
    "margin-left": string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPageDescriptors#margin-right) */
    "margin-right": string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPageDescriptors#margin-top) */
    "margin-top": string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPageDescriptors#marginbottom) */
    marginBottom: string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPageDescriptors#marginleft) */
    marginLeft: string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPageDescriptors#marginright) */
    marginRight: string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPageDescriptors#margintop) */
    marginTop: string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPageDescriptors#size) */
    size: string;
}

declare var CSSPageDescriptors: {
    prototype: CSSPageDescriptors;
    new(): CSSPageDescriptors;
};

/**
 * **`CSSPageRule`** represents a single CSS @page rule.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPageRule)
 */
interface CSSPageRule extends CSSGroupingRule {
    /**
     * The **`selectorText`** property of the CSSPageRule interface gets and sets the selectors associated with the CSSPageRule.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPageRule/selectorText)
     */
    selectorText: string;
    /**
     * The read-only **`style`** property of the CSSPageRule interface contains a CSSPageDescriptors object representing the descriptors available in the @page rule's body.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPageRule/style)
     */
    get style(): CSSPageDescriptors;
    set style(cssText: string);
}

declare var CSSPageRule: {
    prototype: CSSPageRule;
    new(): CSSPageRule;
};

/**
 * The **`CSSPerspective`** interface of the CSS Typed Object Model API represents the perspective() value of the individual transform property in CSS. It inherits properties and methods from its parent CSSTransformValue.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPerspective)
 */
interface CSSPerspective extends CSSTransformComponent {
    /**
     * The **`length`** property of the CSSPerspective interface sets the distance from z=0.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPerspective/length)
     */
    length: CSSPerspectiveValue;
}

declare var CSSPerspective: {
    prototype: CSSPerspective;
    new(length: CSSPerspectiveValue): CSSPerspective;
};

/**
 * The **`CSSPositionTryDescriptors`** interface defines properties that represent the list of CSS descriptors that can be set in the body of a @position-try at-rule.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPositionTryDescriptors)
 */
interface CSSPositionTryDescriptors extends CSSStyleDeclarationBase {
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPositionTryDescriptors#instance_properties) */
    "align-self": string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPositionTryDescriptors#instance_properties) */
    alignSelf: string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPositionTryDescriptors#instance_properties) */
    "block-size": string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPositionTryDescriptors#instance_properties) */
    blockSize: string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPositionTryDescriptors#instance_properties) */
    bottom: string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPositionTryDescriptors#instance_properties) */
    height: string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPositionTryDescriptors#instance_properties) */
    "inline-size": string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPositionTryDescriptors#instance_properties) */
    inlineSize: string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPositionTryDescriptors#instance_properties) */
    inset: string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPositionTryDescriptors#instance_properties) */
    "inset-block": string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPositionTryDescriptors#instance_properties) */
    "inset-block-end": string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPositionTryDescriptors#instance_properties) */
    "inset-block-start": string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPositionTryDescriptors#instance_properties) */
    "inset-inline": string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPositionTryDescriptors#instance_properties) */
    "inset-inline-end": string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPositionTryDescriptors#instance_properties) */
    "inset-inline-start": string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPositionTryDescriptors#instance_properties) */
    insetBlock: string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPositionTryDescriptors#instance_properties) */
    insetBlockEnd: string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPositionTryDescriptors#instance_properties) */
    insetBlockStart: string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPositionTryDescriptors#instance_properties) */
    insetInline: string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPositionTryDescriptors#instance_properties) */
    insetInlineEnd: string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPositionTryDescriptors#instance_properties) */
    insetInlineStart: string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPositionTryDescriptors#instance_properties) */
    "justify-self": string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPositionTryDescriptors#instance_properties) */
    justifySelf: string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPositionTryDescriptors#instance_properties) */
    left: string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPositionTryDescriptors#instance_properties) */
    margin: string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPositionTryDescriptors#instance_properties) */
    "margin-block": string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPositionTryDescriptors#instance_properties) */
    "margin-block-end": string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPositionTryDescriptors#instance_properties) */
    "margin-block-start": string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPositionTryDescriptors#instance_properties) */
    "margin-bottom": string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPositionTryDescriptors#instance_properties) */
    "margin-inline": string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPositionTryDescriptors#instance_properties) */
    "margin-inline-end": string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPositionTryDescriptors#instance_properties) */
    "margin-inline-start": string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPositionTryDescriptors#instance_properties) */
    "margin-left": string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPositionTryDescriptors#instance_properties) */
    "margin-right": string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPositionTryDescriptors#instance_properties) */
    "margin-top": string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPositionTryDescriptors#instance_properties) */
    marginBlock: string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPositionTryDescriptors#instance_properties) */
    marginBlockEnd: string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPositionTryDescriptors#instance_properties) */
    marginBlockStart: string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPositionTryDescriptors#instance_properties) */
    marginBottom: string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPositionTryDescriptors#instance_properties) */
    marginInline: string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPositionTryDescriptors#instance_properties) */
    marginInlineEnd: string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPositionTryDescriptors#instance_properties) */
    marginInlineStart: string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPositionTryDescriptors#instance_properties) */
    marginLeft: string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPositionTryDescriptors#instance_properties) */
    marginRight: string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPositionTryDescriptors#instance_properties) */
    marginTop: string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPositionTryDescriptors#instance_properties) */
    "max-block-size": string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPositionTryDescriptors#instance_properties) */
    "max-height": string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPositionTryDescriptors#instance_properties) */
    "max-inline-size": string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPositionTryDescriptors#instance_properties) */
    "max-width": string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPositionTryDescriptors#instance_properties) */
    maxBlockSize: string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPositionTryDescriptors#instance_properties) */
    maxHeight: string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPositionTryDescriptors#instance_properties) */
    maxInlineSize: string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPositionTryDescriptors#instance_properties) */
    maxWidth: string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPositionTryDescriptors#instance_properties) */
    "min-block-size": string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPositionTryDescriptors#instance_properties) */
    "min-height": string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPositionTryDescriptors#instance_properties) */
    "min-inline-size": string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPositionTryDescriptors#instance_properties) */
    "min-width": string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPositionTryDescriptors#instance_properties) */
    minBlockSize: string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPositionTryDescriptors#instance_properties) */
    minHeight: string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPositionTryDescriptors#instance_properties) */
    minInlineSize: string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPositionTryDescriptors#instance_properties) */
    minWidth: string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPositionTryDescriptors#instance_properties) */
    "place-self": string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPositionTryDescriptors#instance_properties) */
    placeSelf: string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPositionTryDescriptors#instance_properties) */
    "position-anchor": string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPositionTryDescriptors#instance_properties) */
    "position-area": string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPositionTryDescriptors#instance_properties) */
    positionAnchor: string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPositionTryDescriptors#instance_properties) */
    positionArea: string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPositionTryDescriptors#instance_properties) */
    right: string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPositionTryDescriptors#instance_properties) */
    top: string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPositionTryDescriptors#instance_properties) */
    width: string;
}

declare var CSSPositionTryDescriptors: {
    prototype: CSSPositionTryDescriptors;
    new(): CSSPositionTryDescriptors;
};

/**
 * The **`CSSPositionTryRule`** interface describes an object representing a @position-try at-rule.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPositionTryRule)
 */
interface CSSPositionTryRule extends CSSRule {
    /**
     * The **`name`** read-only property of the CSSPositionTryRule interface represents the name of the position try fallback option specified by the @position-try at-rule's <dashed-ident>.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPositionTryRule/name)
     */
    readonly name: string;
    /**
     * The read-only **`style`** property of the CSSPositionTryRule interface contains a CSSPositionTryDescriptors object representing the descriptors available in the @position-try rule's body.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPositionTryRule/style)
     */
    get style(): CSSPositionTryDescriptors;
    set style(cssText: string);
}

declare var CSSPositionTryRule: {
    prototype: CSSPositionTryRule;
    new(): CSSPositionTryRule;
};

/**
 * The **`CSSPropertyRule`** interface of the CSS Properties and Values API represents a single CSS @property rule.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPropertyRule)
 */
interface CSSPropertyRule extends CSSRule {
    /**
     * The read-only **`inherits`** property of the CSSPropertyRule interface returns the inherit flag of the custom property registration represented by the @property rule, a boolean describing whether or not the property inherits by default.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPropertyRule/inherits)
     */
    readonly inherits: boolean;
    /**
     * The read-only **`initialValue`** nullable property of the CSSPropertyRule interface returns the initial value of the custom property registration represented by the @property rule, controlling the property's initial value.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPropertyRule/initialValue)
     */
    readonly initialValue: string | null;
    /**
     * The read-only **`name`** property of the CSSPropertyRule interface represents the property name, this being the serialization of the name given to the custom property in the @property rule's prelude.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPropertyRule/name)
     */
    readonly name: string;
    /**
     * The read-only **`syntax`** property of the CSSPropertyRule interface returns the literal syntax of the custom property registration represented by the @property rule, controlling how the property's value is parsed at computed-value time.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSPropertyRule/syntax)
     */
    readonly syntax: string;
}

declare var CSSPropertyRule: {
    prototype: CSSPropertyRule;
    new(): CSSPropertyRule;
};

/**
 * The **`CSSRotate`** interface of the CSS Typed Object Model API represents the rotate value of the individual transform property in CSS. It inherits properties and methods from its parent CSSTransformValue.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSRotate)
 */
interface CSSRotate extends CSSTransformComponent {
    /**
     * The **`angle`** property of the CSSRotate interface gets and sets the angle of rotation. A positive angle denotes a clockwise rotation, a negative angle a counter-clockwise one.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSRotate/angle)
     */
    angle: CSSNumericValue;
    /**
     * The **`x`** property of the CSSRotate interface gets and sets the abscissa or x-axis of the translating vector.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSRotate/x)
     */
    x: CSSNumberish;
    /**
     * The **`y`** property of the CSSRotate interface gets and sets the ordinate or y-axis of the translating vector.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSRotate/y)
     */
    y: CSSNumberish;
    /**
     * The **`z`** property of the CSSRotate interface representing the z-component of the translating vector. A positive value moves the element towards the viewer, and a negative value farther away.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSRotate/z)
     */
    z: CSSNumberish;
}

declare var CSSRotate: {
    prototype: CSSRotate;
    new(angle: CSSNumericValue): CSSRotate;
    new(x: CSSNumberish, y: CSSNumberish, z: CSSNumberish, angle: CSSNumericValue): CSSRotate;
};

/**
 * The **`CSSRule`** interface represents a single CSS rule. There are several types of rules which inherit properties from CSSRule.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSRule)
 */
interface CSSRule {
    /**
     * The **`cssText`** property of the CSSRule interface returns the actual text of a CSSStyleSheet style-rule.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSRule/cssText)
     */
    cssText: string;
    /**
     * The **`parentRule`** property of the CSSRule interface returns the containing rule of the current rule if this exists, or otherwise returns null.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSRule/parentRule)
     */
    readonly parentRule: CSSRule | null;
    /**
     * The **`parentStyleSheet`** property of the CSSRule interface returns the StyleSheet object in which the current rule is defined.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSRule/parentStyleSheet)
     */
    readonly parentStyleSheet: CSSStyleSheet | null;
    /**
     * The read-only **`type`** property of the CSSRule interface is a deprecated property that returns an integer indicating which type of rule the CSSRule represents.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSRule/type)
     */
    readonly type: number;
    readonly STYLE_RULE: 1;
    readonly CHARSET_RULE: 2;
    readonly IMPORT_RULE: 3;
    readonly MEDIA_RULE: 4;
    readonly FONT_FACE_RULE: 5;
    readonly PAGE_RULE: 6;
    readonly MARGIN_RULE: 9;
    readonly NAMESPACE_RULE: 10;
    readonly KEYFRAMES_RULE: 7;
    readonly KEYFRAME_RULE: 8;
    readonly SUPPORTS_RULE: 12;
    readonly COUNTER_STYLE_RULE: 11;
    readonly FONT_FEATURE_VALUES_RULE: 14;
}

declare var CSSRule: {
    prototype: CSSRule;
    new(): CSSRule;
    readonly STYLE_RULE: 1;
    readonly CHARSET_RULE: 2;
    readonly IMPORT_RULE: 3;
    readonly MEDIA_RULE: 4;
    readonly FONT_FACE_RULE: 5;
    readonly PAGE_RULE: 6;
    readonly MARGIN_RULE: 9;
    readonly NAMESPACE_RULE: 10;
    readonly KEYFRAMES_RULE: 7;
    readonly KEYFRAME_RULE: 8;
    readonly SUPPORTS_RULE: 12;
    readonly COUNTER_STYLE_RULE: 11;
    readonly FONT_FEATURE_VALUES_RULE: 14;
};

/**
 * A **`CSSRuleList`** represents an ordered collection of read-only CSSRule objects.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSRuleList)
 */
interface CSSRuleList {
    /**
     * The **`length`** property of the CSSRuleList interface returns the number of CSSRule objects in the list.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSRuleList/length)
     */
    readonly length: number;
    /**
     * The **`item()`** method of the CSSRuleList interface returns the CSSRule object at the specified index or null if the specified index doesn't exist.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSRuleList/item)
     */
    item(index: number): CSSRule | null;
    [index: number]: CSSRule;
}

declare var CSSRuleList: {
    prototype: CSSRuleList;
    new(): CSSRuleList;
};

/**
 * The **`CSSScale`** interface of the CSS Typed Object Model API represents the scale() and scale3d() values of the individual transform property in CSS. It inherits properties and methods from its parent CSSTransformValue.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSScale)
 */
interface CSSScale extends CSSTransformComponent {
    /**
     * The **`x`** property of the CSSScale interface gets and sets the abscissa or x-axis of the translating vector.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSScale/x)
     */
    x: CSSNumberish;
    /**
     * The **`y`** property of the CSSScale interface gets and sets the ordinate or y-axis of the translating vector.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSScale/y)
     */
    y: CSSNumberish;
    /**
     * The **`z`** property of the CSSScale interface representing the z-component of the translating vector. A positive value moves the element towards the viewer, and a negative value farther away.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSScale/z)
     */
    z: CSSNumberish;
}

declare var CSSScale: {
    prototype: CSSScale;
    new(x: CSSNumberish, y: CSSNumberish, z?: CSSNumberish): CSSScale;
};

/**
 * The **`CSSScopeRule`** interface of the CSS Object Model represents a CSS @scope at-rule.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSScopeRule)
 */
interface CSSScopeRule extends CSSGroupingRule {
    /**
     * The **`end`** property of the CSSScopeRule interface returns a string containing the value of the @scope at-rule's scope limit.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSScopeRule/end)
     */
    readonly end: string | null;
    /**
     * The **`start`** property of the CSSScopeRule interface returns a string containing the value of the @scope at-rule's scope root.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSScopeRule/start)
     */
    readonly start: string | null;
}

declare var CSSScopeRule: {
    prototype: CSSScopeRule;
    new(): CSSScopeRule;
};

/**
 * The **`CSSSkew`** interface of the CSS Typed Object Model API is part of the CSSTransformValue interface. It represents the skew() value of the individual transform property in CSS.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSSkew)
 */
interface CSSSkew extends CSSTransformComponent {
    /**
     * The **`ax`** property of the CSSSkew interface gets and sets the angle used to distort the element along the x-axis (or abscissa).
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSSkew/ax)
     */
    ax: CSSNumericValue;
    /**
     * The **`ay`** property of the CSSSkew interface gets and sets the angle used to distort the element along the y-axis (or ordinate).
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSSkew/ay)
     */
    ay: CSSNumericValue;
}

declare var CSSSkew: {
    prototype: CSSSkew;
    new(ax: CSSNumericValue, ay: CSSNumericValue): CSSSkew;
};

/**
 * The **`CSSSkewX`** interface of the CSS Typed Object Model API represents the skewX() value of the individual transform property in CSS. It inherits properties and methods from its parent CSSTransformValue.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSSkewX)
 */
interface CSSSkewX extends CSSTransformComponent {
    /**
     * The **`ax`** property of the CSSSkewX interface gets and sets the angle used to distort the element along the x-axis (or abscissa).
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSSkewX/ax)
     */
    ax: CSSNumericValue;
}

declare var CSSSkewX: {
    prototype: CSSSkewX;
    new(ax: CSSNumericValue): CSSSkewX;
};

/**
 * The **`CSSSkewY`** interface of the CSS Typed Object Model API represents the skewY() value of the individual transform property in CSS. It inherits properties and methods from its parent CSSTransformValue.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSSkewY)
 */
interface CSSSkewY extends CSSTransformComponent {
    /**
     * The **`ay`** property of the CSSSkewY interface gets and sets the angle used to distort the element along the y-axis (or ordinate).
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSSkewY/ay)
     */
    ay: CSSNumericValue;
}

declare var CSSSkewY: {
    prototype: CSSSkewY;
    new(ay: CSSNumericValue): CSSSkewY;
};

/**
 * The **`CSSStartingStyleRule`** interface of the CSS Object Model represents a CSS @starting-style at-rule.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSStartingStyleRule)
 */
interface CSSStartingStyleRule extends CSSGroupingRule {
}

declare var CSSStartingStyleRule: {
    prototype: CSSStartingStyleRule;
    new(): CSSStartingStyleRule;
};

/**
 * The **`CSSStyleDeclaration`** interface is the base class for objects that represent CSS declaration blocks with different supported sets of CSS style information:
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSStyleDeclaration)
 */
interface CSSStyleDeclarationBase {
    /**
     * The **`cssText`** property of the CSSStyleDeclaration interface returns or sets the text of the element's inline style declaration only.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSStyleDeclaration/cssText)
     */
    cssText: string;
    /**
     * The read-only property returns an integer that represents the number of style declarations in this CSS declaration block.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSStyleDeclaration/length)
     */
    readonly length: number;
    /**
     * The **`CSSStyleDeclaration.parentRule`** read-only property returns a CSSRule that is the parent of this style block, e.g., a CSSStyleRule representing the style for a CSS selector.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSStyleDeclaration/parentRule)
     */
    readonly parentRule: CSSRule | null;
    /**
     * The **`CSSStyleDeclaration.getPropertyPriority()`** method interface returns a string that provides all explicitly set priorities on the CSS property.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSStyleDeclaration/getPropertyPriority)
     */
    getPropertyPriority(property: string): string;
    /**
     * The **`CSSStyleDeclaration.getPropertyValue()`** method interface returns a string containing the value of a specified CSS property.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSStyleDeclaration/getPropertyValue)
     */
    getPropertyValue(property: string): string;
    /**
     * The **`CSSStyleDeclaration.item()`** method interface returns a CSS property name from a CSSStyleDeclaration by index.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSStyleDeclaration/item)
     */
    item(index: number): string;
    /**
     * The **`CSSStyleDeclaration.removeProperty()`** method interface removes a property from a CSS style declaration object.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSStyleDeclaration/removeProperty)
     */
    removeProperty(property: string): string;
    /**
     * The **`CSSStyleDeclaration.setProperty()`** method interface sets a new value for a property on a CSS style declaration object.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSSStyleDeclaration/setProperty)
     */
    setProperty(property: string, value: string | null, priority?: string): void;
    [index: number]: string;
}

interface CSSStyleDeclaration extends CSSStyleProperties {
}

declare var CSSStyleDeclaration: {
    prototype: CSSStyleDeclaration;
    new(): CSSStyleDeclaration;
};
