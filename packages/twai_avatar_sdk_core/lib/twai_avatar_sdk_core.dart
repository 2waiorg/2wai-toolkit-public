/// 2wai Avatar SDK — pure-Dart core.
///
/// Transport clients, sessions, and admin API. No Flutter dependency —
/// importable from any Dart context (CLI tools, server, browser, etc).
/// The Flutter-flavored UI (VideoSink + concrete sinks) lives in
/// `package:twai_avatar_sdk` and re-exports everything here.
library;

// Named backend environment (dev/staging/prod) with --dart-define support.
export 'src/environment.dart' show TwaiEnvironment;

// Pluggable credential provider — anonymous / publishable key /
// rotatable view token / bearer JWT / twai-api server key. Modeled
// after twai-web-sdk's TwaiCredentials so both SDKs share auth
// vocabulary.
export 'src/credentials.dart'
    show
        TwaiCredentials,
        AnonymousCredentials,
        PublicKeyCredentials,
        ViewTokenCredentials,
        BearerJwtCredentials,
        TwaiApiKeyCredentials;

// Typed error ladder — marker interface + kind enum + three concrete
// exceptions for codec / handshake / mid-stream transport failures
// (previously rolled into ChatSessionConnectException / -SendException).
// ChatSessionException + all its subclasses also implement TwaiError,
// so `catch (TwaiError e)` + `switch (e.kind)` works uniformly.
export 'src/errors.dart'
    show
        TwaiError,
        TwaiErrorKind,
        TwaiCodecError,
        TwaiHandshakeError,
        TwaiTransportError;

// Single entry point — wraps one tenant's env + API keys and produces
// scoped chat sessions / admin clients. Where future per-tenant
// features hang off.
export 'src/twai_client.dart' show TwaiClient;

// Pure, DOM-free pts-gate for `speaking` events. Ported bit-for-bit
// from twai-web-sdk/packages/core/src/speakingGate.ts so both SDKs
// pass the same conformance vectors (test/conformance/*).
export 'src/speaking_gate.dart' show SpeakingGate, gateSpeaking;

// Golden codec constants — single source of truth for the SDK's
// SourceBuffer type + avcC byte. Aligned with twai-protocol
// schema/constants.json + the codec.json conformance vector.
export 'src/codec_constants.dart'
    show kMseCodecs, kAvccProfileCompatByte, kAvcBaselineCodec;

// Server-side handshake classifier. Mirrors reference-client.mjs
// from twai-protocol; consumed by the Dart conformance runner to
// prove the handshake frames our SDK sends would be accepted.
export 'src/handshake_classifier.dart'
    show HandshakeClassification, classifyHandshake;

// Transport-agnostic ChatSession interface.
export 'src/chat_session.dart'
    show
        Avatar,
        ChatSession,
        ChatSessionEndReason,
        ChatSessionClosed,
        ChatSessionFailed,
        ChatSessionException,
        ChatSessionNotConnectedException,
        ChatSessionAlreadyConnectedException,
        ChatSessionConnectException,
        ChatSessionSendException,
        ChatSessionUnauthorizedException,
        ChatSessionForbiddenException,
        ChatSessionRateLimitedException;

// Adapter 1 — Penthouse MSE-over-WS (WebSocket streaming transport).
export 'src/adapters/mse_stream/mse_stream_chat_session.dart'
    show MseStreamChatSession;
export 'src/adapters/mse_stream/mse_stream_client.dart'
    show MseStreamClient, WebSocketChannelFactory;
export 'src/adapters/mse_stream/mse_stream_config.dart'
    show MseStreamConfig, SpeakingEvent, SpeakingState;
export 'src/adapters/mse_stream/mse_stream_errors.dart'
    show
        MseStreamCloseReason,
        NormalClose,
        ConfigError,
        Unauthorized,
        ServerError,
        OtherClose;

// Adapter 1 — Penthouse POST /ext-api/human (chat gateway).
export 'src/adapters/mse_stream/chat_gateway.dart' show ChatGateway;
export 'src/adapters/mse_stream/chat_gateway_config.dart'
    show ChatGatewayConfig;
export 'src/adapters/mse_stream/chat_gateway_errors.dart'
    show
        ChatResponse,
        ChatGatewayException,
        ChatProtocolException,
        ChatHttpException,
        ChatUnauthorizedException,
        ChatForbiddenException,
        ChatRateLimitedException,
        ChatTransportException;
// Adapter 1 — Brain mood (X-Mood + X-Mood-Humanized response headers).
// Typed enum + value type promoted from raw string in this same commit.
export 'src/adapters/mse_stream/mood.dart' show Mood, MoodEvent;

// Adapter 2 — Pipeline v1.3 POST /chat → MP4.
export 'src/adapters/pipeline_v13/pipeline_v13_chat_session.dart'
    show PipelineV13ChatSession;
export 'src/adapters/pipeline_v13/pipeline_v13_client.dart'
    show PipelineV13Client;
export 'src/adapters/pipeline_v13/pipeline_v13_config.dart'
    show PipelineV13Config;
export 'src/adapters/pipeline_v13/pipeline_v13_errors.dart'
    show
        PipelineV13Response,
        PipelineV13Exception,
        PipelineV13HttpException,
        PipelineV13UnauthorizedException,
        PipelineV13ForbiddenException,
        PipelineV13RateLimitedException,
        PipelineV13TransportException;

// Adapter 4 — twai-api /v1/* REST + WS (2waiorg/twai-api). New default
// access path; dev-direct mode is exercised via TwaiClient.apiSession(),
// prod split-plane wires TwaiApiRestClient at a customer mint proxy.
export 'src/adapters/twai_api/twai_api_chat_session.dart'
    show TwaiApiChatSession, TwaiBrainCallback, TwaiStreamingBrainCallback;
export 'src/adapters/twai_api/twai_api_client.dart'
    show TwaiApiRestClient, TwaiApiWsClient;
export 'src/adapters/twai_api/twai_api_config.dart'
    show
        TwaiApiSessionRequest,
        TwaiApiSessionMint,
        TwaiApiLiveKitSessionRequest,
        TwaiApiLiveKitMint,
        TwaiApiAvatarResult,
        TwaiApiAvatar,
        TwaiApiGreetingPayload;
export 'src/adapters/twai_api/twai_api_errors.dart'
    show
        TwaiApiException,
        TwaiApiHttpException,
        TwaiApiUnauthorizedException,
        TwaiApiForbiddenException,
        TwaiApiRateLimitedException,
        TwaiApiTransportException,
        TwaiApiAvatarNotFoundException,
        TwaiApiCloseReason,
        TwaiApiNormalClose,
        TwaiApiTokenRejected,
        TwaiApiConfigMismatch,
        TwaiApiOtherClose;

// Admin API for the avatar registry — dev-mode only.
export 'src/admin/avatar_admin_client.dart' show AvatarAdminClient;
export 'src/admin/avatar_admin_config.dart'
    show AvatarMetadata, AvatarMutationResult;
// Display catalog — curates the raw registry into product-branded lists.
// AvatarStack describes which lipsync backend an avatar belongs to
// (wav2lip / muse / onnx) so callers know which nginx prefix to route
// its session traffic through. See MseStreamChatSession.pathPrefix.
export 'src/admin/avatar_catalog.dart'
    show AvatarCatalog, AvatarCatalogEntry, AvatarStack, CatalogAvatar;

// Pipeline shape + AvatarProfile — customer-facing value types that
// bundle (avatar, transport shape, TTS + idle config) into one object
// apps select from a menu, fetch from a server, or persist to prefs.
// Data-only (no widgets), so easily serialized.
export 'src/pipeline_shape.dart' show PipelineShape;
export 'src/avatar_profile.dart' show AvatarProfile;
// gen-2wai self-serve avatar generation client (Feature 2 admin surface).
// Talks to gen.2wai.ai's OTP-authenticated wizard endpoints.
export 'src/admin/gen_admin_client.dart' show GenAdminClient;
// One-object facade over GenAdminClient — upload three files, get a
// playable avatar. What Mason plugs into his gen-2wai product flow.
export 'src/admin/twai_avatar_creator.dart'
    show TwaiAvatarCreator, TwaiAvatarCreation;
export 'src/admin/gen_admin_errors.dart'
    show
        GenApiException,
        GenApiHttpException,
        GenApiUnauthorizedException,
        GenApiInsufficientCreditsException,
        GenApiForbiddenException,
        GenApiNotFoundException,
        GenApiValidationException,
        GenApiRateLimitedException,
        GenApiTransportException;
export 'src/admin/gen_admin_types.dart'
    show
        GenUser,
        GenNameCheck,
        GenAssetKind,
        GenSasResponse,
        GenSubmissionResult,
        GenAvatarSummary,
        GenAvatarStatus,
        GenBrainStatus,
        GenStage,
        GenStageState,
        GenSubmissionStatus,
        GenBrainConfig,
        GenViewToken;
export 'src/admin/avatar_admin_errors.dart'
    show
        AvatarAdminException,
        AvatarAdminProtocolException,
        AvatarAdminHttpException,
        AvatarAdminUnauthorizedException,
        AvatarAdminForbiddenException,
        AvatarAdminRateLimitedException,
        AvatarAdminTransportException;
// TTS pronunciation rules — v2 schema types matching penthouse's
// mason/tts-global-pronunciation branch. Backend endpoints not yet live.
export 'src/admin/tts_rules.dart'
    show TtsRule, TtsRuleScope, TtsRuleStage, TtsRuleKind, TtsAuditionResult;
