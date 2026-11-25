#include "config.h"
#include "YozoraCoreInternal.h"
#include "YozoraCoreThread.h"
#include "YozoraCookies.h"
#include "CachedResourceLoader.h"
#include "ContentType.h"
#include "DestinationColorSpace.h"
#include "Document.h"
#include "DocumentFullscreen.h"
#include "DocumentPage.h"
#include "FloatSize.h"
#include "GraphicsContext.h"
#include "HTMLMediaElement.h"
#include "HTMLVideoElement.h"
#include "LocalFrameView.h"
#include "MediaPlayer.h"
#include "MediaPlayerPrivate.h"
#include "MediaSourcePrivateClient.h"
#include "YozoraMediaSource.h"
#include "../yozora_log.h"
#include "MediaPromiseTypes.h"
#include "PlatformMediaCapabilitiesDecodingInfo.h"
#include "PlatformMediaDecodingConfiguration.h"
#include "PlatformMediaEngineConfigurationFactory.h"
#include "PlatformTimeRanges.h"
#include "RenderLayer.h"
#include "RenderLayerBacking.h"
#include "RenderObjectInlines.h"
#include "YozoraScene.h"
#include "RenderVideo.h"
#include "RenderVideoInlines.h"
#include "ResourceRequest.h"
#include "SecurityOrigin.h"
#include "TypedElementDescendantIteratorInlines.h"
#include <wtf/HashMap.h>
#include <wtf/MainThread.h>
#include <wtf/NeverDestroyed.h>
#include <wtf/RunLoop.h>
#include <wtf/RefCounted.h>
#include <wtf/ThreadSafeWeakPtr.h>
#include <wtf/TZoneMalloc.h>
#include <wtf/WeakPtr.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/WTFString.h>
#include <cmath>
#include <cstdio>
#include <cstring>

using namespace WebCore;
using namespace WTF::StringLiterals;

// the elements are WebCore's own and the interface plays the stream. this is a hole punch player: it paints a
// transparent hole where the video is and the system player's picture shows through from under the page
namespace {

constexpr unsigned open_limit = 8;
constexpr unsigned request_limit = 32;
enum { error_network = 2, error_decode = 3, error_unsupported = 4 };

unsigned last_id = 0;

class YozoraMediaPlayer;

struct Entry {
    yozora_core* core;
    WeakPtr<YozoraMediaPlayer> player;
};

HashMap<unsigned, Entry>& entries()
{
    static NeverDestroyed<HashMap<unsigned, Entry>> map;
    return map;
}

unsigned open_entries(yozora_core& core)
{
    unsigned count = 0;
    for (auto& entry : entries().values()) {
        if (entry.core == &core)
            ++count;
    }
    return count;
}

// a queued seek, volume or rate is replaced by the newer one, so a slider that fires a hundred times does not
// fill the queue
void push_request(yozora_core& core, const yozora_media_request& request)
{
    bool replaces = request.command == YOZORA_MEDIA_SEEK || request.command == YOZORA_MEDIA_VOLUME || request.command == YOZORA_MEDIA_RATE;
    pthread_mutex_lock(&core.lock);
    auto& queue = core.shared.media;
    bool done = false;
    if (replaces) {
        for (auto& queued : queue) {
            if (queued.id == request.id && queued.command == request.command) {
                queued = request;
                done = true;
                break;
            }
        }
    }
    bool full = !done && queue.size() >= request_limit;
    if (!done && !full)
        queue.push_back(request);
    pthread_mutex_unlock(&core.lock);
    if (full)
        yozora_core_console(core, "error: the media queue is full, the interface does not take requests");
}

struct SupportedType {
    const char* container;
    bool video;
};

// what AVPlayer plays on ios 5 and later; webm, ogg, matroska, flac and opus are not among them
const SupportedType supported_types[] = {
    { "video/mp4", true }, { "video/x-m4v", true }, { "video/quicktime", true }, { "video/3gpp", true },
    { "audio/mp4", false }, { "audio/x-m4a", false }, { "audio/m4a", false }, { "audio/aac", false }, { "audio/x-aac", false },
    { "audio/mpeg", false }, { "audio/mp3", false }, { "audio/wav", false }, { "audio/x-wav", false }, { "audio/wave", false },
    { "application/vnd.apple.mpegurl", true }, { "application/x-mpegurl", true }, { "audio/mpegurl", false }, { "audio/x-mpegurl", false }
};

// the codecs the system decoders handle on the oldest supported phones (hevc, vp9, av1 and opus fail there).
// mp4v.20 is MPEG-4 part 2 (what iPods played before H.264), mp4a.67 and mp4a.66 are MPEG-2 AAC object types,
// "1" is WAV PCM, AVPlayer plays all of them from ios 3
bool codec_supported(const String& codec, const String& container)
{
    String lower = codec.convertToASCIILowercase();
    // the codec "1" names PCM only inside a WAV file
    if (lower == "1"_s)
        return container == "audio/wav"_s || container == "audio/x-wav"_s || container == "audio/wave"_s;
    return lower.startsWith("avc1"_s) || lower.startsWith("avc3"_s) || lower.startsWith("mp4a"_s) || lower.startsWith("mp4v.20"_s) || lower == "mp3"_s;
}

bool container_supported(const String& container)
{
    for (auto& type : supported_types) {
        if (container == StringView::fromLatin1(type.container))
            return true;
    }
    return false;
}

bool address_playable(const URL& url)
{
    return url.isValid() && url.protocolIsInHTTPFamily() && url.user().isEmpty() && url.password().isEmpty() && url.string().length() < sizeof(yozora_media_request::url);
}

class YozoraMediaPlayer final : public Yozora::MsePlayer, public RefCounted<YozoraMediaPlayer> {
    WTF_MAKE_TZONE_ALLOCATED_INLINE(YozoraMediaPlayer);
public:
    static Ref<YozoraMediaPlayer> create(MediaPlayer& player) { return adoptRef(*new YozoraMediaPlayer(player)); }
    ~YozoraMediaPlayer() { release(); }

    void ref() const final { RefCounted::ref(); }
    void deref() const final { RefCounted::deref(); }
    constexpr MediaPlayerType mediaPlayerType() const final { return MediaPlayerType::HolePunch; }

    unsigned id() const { return m_id; }

    void load(const URL& url, const LoadOptions&) final
    {
        release();
        resetState();
        yozora_core* core = coreOfPlayer();
        if (!core || !address_playable(url) || open_entries(*core) >= open_limit) {
            setNetworkState(MediaPlayer::NetworkState::FormatError);
            return;
        }
        m_core = core;
        m_id = ++last_id;
        entries().add(m_id, Entry { core, WeakPtr<YozoraMediaPlayer>(*this) });
        yozora_media_request request;
        std::memset(&request, 0, sizeof(request));
        request.command = YOZORA_MEDIA_OPEN;
        request.id = m_id;
        std::snprintf(request.url, sizeof(request.url), "%s", url.string().utf8().data());
        std::snprintf(request.title, sizeof(request.title), "%s", core->title.data() ? core->title.data() : "");
        RefPtr player = m_player.get();
        request.video = player && player->isVideoPlayer();
        request.value = 0;
        fillPageIdentity(url, request);
        push_request(*core, request);
        sendVolume();
        setNetworkState(MediaPlayer::NetworkState::Loading);
        core->media_dirty = true;
    }

    // a MediaSource: what the page appends becomes a system player stream (core/core/YozoraMediaSource.cpp).
    // it has no address, the stream gets one when its first segment is cut
    void load(const URL&, const LoadOptions&, MediaSourcePrivateClient& source) final
    {
        release();
        resetState();
        yozora_core* core = coreOfPlayer();
        if (!core || open_entries(*core) >= open_limit || source.mediaSourcePrivate()) {
            setNetworkState(MediaPlayer::NetworkState::FormatError);
            return;
        }
        m_core = core;
        m_mse = true;
        m_session = Yozora::MseSession::create();
        // the callbacks come from the thread of the source buffers: they only leave a note here and the work is done on the page thread
        auto mailbox = adoptRef(*new Mailbox(*this));
        m_session->setCallbacks([mailbox](unsigned) { callOnMainThread([mailbox] { if (auto player = mailbox->player.get()) player->pollMse(); }); },
            [mailbox](String&& message) { callOnMainThread([mailbox, message = WTF::move(message)] { if (auto player = mailbox->player.get()) player->mseFailed(message); }); });
        m_mediaSource = Yozora::createMediaSourcePrivate(*this, source, Ref { *m_session });
        yozora_log(YOZORA_LOG_INFO, "mse", "media source loaded");
        setNetworkState(MediaPlayer::NetworkState::Loading);
        schedulePoll();
    }

    void cancelLoad() final
    {
        release();
        resetState();
    }

    void play() final
    {
        m_paused = false;
        m_ended = false;
        send(YOZORA_MEDIA_PLAY, m_rate);
    }

    void pause() final
    {
        freezeTime();
        m_paused = true;
        send(YOZORA_MEDIA_PAUSE, 0);
    }

    bool paused() const final { return m_paused; }

    Ref<MediaTimePromise> seekToTarget(const SeekTarget& target) final
    {
        if (m_mse)
            return seekMse(target);
        if (!m_id)
            return MediaTimePromise::createAndReject(PlatformMediaError::Cancelled);
        m_seekPromise.emplace(PlatformMediaError::Cancelled);
        m_ended = false;
        m_time = target.time.toDouble();
        m_timeStamp = MonotonicTime::now();
        send(YOZORA_MEDIA_SEEK, m_time);
        return *m_seekPromise;
    }

    MediaTime currentTime() const final
    {
        double time = m_time;
        if (m_playing) {
            time += (MonotonicTime::now() - m_timeStamp).seconds() * m_rate;
            double limit = m_mse ? duration().toDouble() : m_duration;
            if (std::isfinite(limit) && (!m_mse || limit > 0))
                time = std::min(time, limit);
        }
        return MediaTime::createWithDouble(time);
    }

    MediaTime duration() const final
    {
        if (m_mse)
            return m_mediaSource ? m_mediaSource->duration() : MediaTime::zeroTime();
        return m_hasDuration ? MediaTime::createWithDouble(m_duration) : MediaTime::zeroTime();
    }
    MediaTime maxTimeSeekable() const final
    {
        if (m_mse)
            return duration();
        return std::isfinite(m_duration) && m_hasDuration ? MediaTime::createWithDouble(m_duration) : MediaTime::zeroTime();
    }

    void setRateDouble(double rate) final
    {
        freezeTime();
        m_rate = rate > 0 ? rate : 1;
        if (!m_paused)
            send(YOZORA_MEDIA_RATE, m_rate);
    }
    double rate() const final { return m_rate; }
    bool timeIsProgressing() const final { return m_playing; }
    bool ended() const final { return m_ended; }

    void setVolumeDouble(double volume) final
    {
        m_volume = std::clamp(volume, 0.0, 1.0);
        sendVolume();
    }
    void setMuted(bool muted) final
    {
        m_muted = muted;
        sendVolume();
    }

    FloatSize naturalSize() const final
    {
        if (m_mse && !(m_width > 0 && m_height > 0) && m_session)
            return FloatSize(m_session->width(), m_session->height());
        return FloatSize(m_width, m_height);
    }
    bool hasVideo() const final
    {
        if (m_mse)
            return m_mediaSource && m_mediaSource->hasVideo();
        return m_width > 0 && m_height > 0;
    }
    // the system does not say whether a stream has a sound track
    bool hasAudio() const final
    {
        if (m_mse)
            return m_mediaSource && m_mediaSource->hasAudio();
        return true;
    }
    // the full screen player of the interface takes the stream over from the layer under the page
    bool supportsFullscreen() const final { return true; }
    void setPageIsVisible(bool) final { }
    bool hasAvailableVideoFrame() const final { return m_hasFrame; }

    MediaPlayer::NetworkState networkState() const final { return m_networkState; }
    MediaPlayer::ReadyState readyState() const final
    {
        if (m_mse)
            return m_mediaSource ? m_mediaSource->mediaPlayerReadyState() : MediaPlayer::ReadyState::HaveNothing;
        return m_readyState;
    }
    // the buffered ranges of a media source are the ones of its source buffers, WebCore asks them there
    const PlatformTimeRanges& buffered() const final { return m_mse ? PlatformTimeRanges::emptyRanges() : m_buffered; }

    void readyStateFromMediaSourceChanged() final
    {
        if (RefPtr player = m_player.get())
            player->readyStateChanged();
    }
    void characteristicsFromMediaSourceChanged() final
    {
        if (RefPtr player = m_player.get())
            player->characteristicChanged();
    }
    void mediaSourceHasRetrievedAllData() final { setNetworkState(MediaPlayer::NetworkState::Loaded); }
    void mseDurationChanged(const MediaTime&) final
    {
        if (RefPtr player = m_player.get())
            player->durationChanged();
    }
    void mseActiveSourceBuffersChanged() final
    {
        if (RefPtr player = m_player.get())
            player->activeSourceBuffersChanged();
    }
    bool didLoadingProgress() const final { return std::exchange(m_progressed, false); }
    long platformErrorCode() const final { return m_errorCode; }
    String engineDescription() const final { return "Yozora"_s; }

    void setPresentationSize(const IntSize&) final { }

    // the picture lives in a layer under the page, the page gets a transparent hole where it shows through
    void paint(GraphicsContext& context, const FloatRect& rect) final { context.clearRect(rect); }
    // the pixels of the system player cannot be read, a canvas that draws this video stays empty
    void paintCurrentFrameInContext(GraphicsContext&, const FloatRect&) final { }
    DestinationColorSpace colorSpace() final { return DestinationColorSpace::SRGB(); }

    // core thread: what the interface reported
    void handleEvent(yozora_media_event_kind kind, double value, double extra)
    {
        yozora_log(YOZORA_LOG_DEBUG, "media", "player %u event %d value %.3f extra %.3f", m_id, static_cast<int>(kind), value, extra);
        RefPtr player = m_player.get();
        if (!player)
            return;
        switch (kind) {
        case YOZORA_MEDIA_DURATION:
            // the length of the stream of a media source grows with its segments, the length is the one the page set
            if (m_mse)
                break;
            m_duration = value > 0 ? value : std::numeric_limits<double>::infinity();
            m_hasDuration = true;
            player->durationChanged();
            advance(MediaPlayer::ReadyState::HaveMetadata);
            break;
        case YOZORA_MEDIA_SIZE:
            m_width = static_cast<float>(std::max(0.0, value));
            m_height = static_cast<float>(std::max(0.0, extra));
            player->sizeChanged();
            player->characteristicChanged();
            if (!m_mse)
                advance(MediaPlayer::ReadyState::HaveMetadata);
            break;
        case YOZORA_MEDIA_FRAME:
            m_hasFrame = true;
            player->firstVideoFrameAvailable();
            player->repaint();
            if (!m_mse)
                advance(MediaPlayer::ReadyState::HaveCurrentData);
            if (m_core)
                m_core->media_dirty = true;
            break;
        case YOZORA_MEDIA_READY:
            if (m_mse) {
                // the ready state of a media source is WebCore's, from its buffered ranges. the system player
                // is ready, it goes to the place the page wants
                if (value != 0)
                    startPosition();
                else
                    freezeTime();
            } else if (value != 0) {
                advance(MediaPlayer::ReadyState::HaveEnoughData);
            } else {
                freezeTime();
                m_readyState = m_hasFrame ? MediaPlayer::ReadyState::HaveCurrentData : MediaPlayer::ReadyState::HaveMetadata;
                player->readyStateChanged();
            }
            break;
        case YOZORA_MEDIA_PLAYING:
            m_ended = false;
            m_playing = true;
            m_timeStamp = MonotonicTime::now();
            if (m_paused) {
                m_paused = false;
                player->playbackStateChanged();
            }
            player->rateChanged();
            break;
        case YOZORA_MEDIA_PAUSED:
            freezeTime();
            if (!m_paused) {
                m_paused = true;
                player->playbackStateChanged();
            }
            break;
        case YOZORA_MEDIA_TIME:
            // the time of the stream starts at the first key frame of its epoch
            m_time = m_mse ? m_epochOrigin + value : value;
            m_timeStamp = MonotonicTime::now();
            player->timeChanged();
            break;
        case YOZORA_MEDIA_SEEKED:
            if (m_mse) {
                // the seek of the page ends when the system player stands where the page asked: the stream may have begun earlier, at a key frame
                m_time = m_positionTarget.toDouble();
                m_timeStamp = MonotonicTime::now();
                if (auto promise = std::exchange(m_seekPromise, std::nullopt))
                    promise->resolve(m_positionTarget);
                if (!m_paused)
                    send(YOZORA_MEDIA_PLAY, m_rate);
                player->timeChanged();
                break;
            }
            m_time = value;
            m_timeStamp = MonotonicTime::now();
            if (auto promise = std::exchange(m_seekPromise, std::nullopt))
                promise->resolve(MediaTime::createWithDouble(value));
            player->timeChanged();
            break;
        case YOZORA_MEDIA_BUFFERED:
            // a media source is buffered by its source buffers
            if (!m_mse && extra > value && std::isfinite(extra)) {
                m_buffered.clear();
                m_buffered.add(MediaTime::createWithDouble(std::max(0.0, value)), MediaTime::createWithDouble(extra));
                m_progressed = true;
                if (m_hasDuration && std::isfinite(m_duration) && extra >= m_duration - 0.25) {
                    m_networkState = MediaPlayer::NetworkState::Loaded;
                    player->networkStateChanged();
                }
            }
            break;
        case YOZORA_MEDIA_ENDED:
            m_playing = false;
            m_ended = true;
            if (m_mse)
                m_time = duration().toDouble();
            else if (m_hasDuration && std::isfinite(m_duration))
                m_time = m_duration;
            player->timeChanged();
            break;
        case YOZORA_MEDIA_ERROR:
            fail(static_cast<int>(value));
            break;
        case YOZORA_MEDIA_FULLSCREEN_LEFT:
            // the element leaves full screen in yozora_core_media_event, which has the document at hand
            break;
        }
    }

private:
    explicit YozoraMediaPlayer(MediaPlayer& player)
        : m_player(player)
    {
    }

    RefPtr<Document> documentOfPlayer() const
    {
        RefPtr player = m_player.get();
        CachedResourceLoader* loader = player ? player->cachedResourceLoader() : nullptr;
        return loader ? loader->document() : nullptr;
    }

    yozora_core* coreOfPlayer() const
    {
        RefPtr document = documentOfPlayer();
        return document ? yozora_core_for_page(document->page()) : nullptr;
    }

    // what the system player cannot send itself: the page's cookies for the stream and the page origin, both
    // go to the stream proxy
    void fillPageIdentity(const URL& url, yozora_media_request& request) const
    {
        RefPtr document = documentOfPlayer();
        if (!document)
            return;
        ResourceRequest cookieRequest { URL { url } };
        cookieRequest.setFirstPartyForCookies(document->firstPartyForCookies());
        auto cookie = YozoraCookies::requestHeader(cookieRequest).utf8();
        // a cookie header cut in two would be a different cookie, so one that does not fit is not sent
        if (cookie.length() > 0 && cookie.length() < sizeof(request.cookie))
            std::snprintf(request.cookie, sizeof(request.cookie), "%s", cookie.data());
        auto origin = document->securityOrigin().toString().utf8();
        if (origin.length() > 0 && origin.length() + 1 < sizeof(request.referer) && std::strcmp(origin.data(), "null") != 0)
            std::snprintf(request.referer, sizeof(request.referer), "%s/", origin.data());
    }

    // the callbacks of the session come from another thread and hold this: it is only read on the page thread
    struct Mailbox : ThreadSafeRefCounted<Mailbox> {
        explicit Mailbox(YozoraMediaPlayer& owner) : player(owner) { }
        WeakPtr<YozoraMediaPlayer> player;
    };

    void schedulePoll()
    {
        m_pollTimer = RunLoop::currentSingleton().dispatchAfter(Seconds { 0.15 }, [weakThis = WeakPtr { *this }] {
            if (RefPtr player = weakThis.get())
                player->pollMse();
        });
    }

    void stopPoll()
    {
        if (m_pollTimer) {
            m_pollTimer->stop();
            m_pollTimer = nullptr;
        }
    }

    // page thread, about every 150 ms and whenever the session starts an epoch: the stream goes to the
    // interface once it holds a segment and what lies behind the position is let go
    void pollMse()
    {
        if (!m_mse || !m_session || !m_core)
            return;
        stopPoll();
        unsigned epoch = 0;
        yozora_hls* hls = m_session->retainStream(&epoch);
        if (hls) {
            if (epoch != m_openedEpoch && (yozora_hls_segment_count(hls) >= 1 || yozora_hls_ended(hls)))
                openEpoch(hls, epoch);
            else if (epoch == m_openedEpoch && m_id) {
                // twenty seconds behind the position stay, a seek back farther than that starts a new epoch anyway
                int64_t behind = static_cast<int64_t>((m_time - m_epochOrigin - 20) * 90000);
                if (behind > 0)
                    yozora_hls_trim(hls, behind);
            }
            yozora_hls_release(hls);
        }
        schedulePoll();
    }

    void mseFailed(const String& message)
    {
        yozora_log(YOZORA_LOG_ERROR, "mse", "media source failed: %s", message.utf8().data());
        fail(error_decode);
    }

    // the stream of a new epoch replaces the one that played: the interface opens it, and goes to where the page stands in it
    void openEpoch(yozora_hls* hls, unsigned epoch)
    {
        releaseStream();
        m_id = ++last_id;
        entries().add(m_id, Entry { m_core, WeakPtr<YozoraMediaPlayer>(*this) });
        yozora_hls_retain(hls);
        pthread_mutex_lock(&m_core->lock);
        m_core->shared.mse_streams[m_id] = hls;
        pthread_mutex_unlock(&m_core->lock);
        yozora_media_request request;
        std::memset(&request, 0, sizeof(request));
        request.command = YOZORA_MEDIA_OPEN;
        request.id = m_id;
        std::snprintf(request.url, sizeof(request.url), "yozora-hls:%u", m_id);
        std::snprintf(request.title, sizeof(request.title), "%s", m_core->title.data() ? m_core->title.data() : "");
        request.video = m_session->hasVideo();
        request.value = 0;
        push_request(*m_core, request);
        sendVolume();
        m_openedEpoch = epoch;
        m_epochOrigin = static_cast<double>(yozora_hls_origin(hls)) / 90000.0;
        yozora_log(YOZORA_LOG_INFO, "mse", "epoch %u goes to the interface as player %u: %u segments, starts at %.3f s", epoch, m_id, yozora_hls_segment_count(hls), m_epochOrigin);
        m_positionSent = false;
        m_hasFrame = false;
        m_core->media_dirty = true;
    }

    // the system player is ready in the new stream: it goes to the page time, as far into the stream as that
    // reaches (the stream starts at the key frame before it)
    void startPosition()
    {
        if (!m_id || m_positionSent)
            return;
        m_positionSent = true;
        double offset = std::max(0.0, m_positionTarget.toDouble() - m_epochOrigin);
        send(YOZORA_MEDIA_SEEK, offset);
    }

    // a seek of the page: WebCore settles the time and takes its buffers back to resend samples from a key
    // frame, which starts a new epoch. the seek is done when the interface stands in that epoch at the time
    Ref<MediaTimePromise> seekMse(const SeekTarget& target)
    {
        if (!m_mediaSource)
            return MediaTimePromise::createAndReject(PlatformMediaError::Cancelled);
        freezeTime();
        m_lastSeekTarget = target;
        m_time = target.time.toDouble();
        m_ended = false;
        m_seekPromise.emplace(PlatformMediaError::Cancelled);
        protect(m_mediaSource)->waitForTarget(target)->whenSettled(RunLoop::currentSingleton(), [weakThis = WeakPtr { *this }](auto&& result) {
            RefPtr protectedThis = weakThis.get();
            if (!protectedThis)
                return;
            if (!result) {
                if (auto promise = std::exchange(protectedThis->m_seekPromise, std::nullopt))
                    promise->reject(result.error());
                return;
            }
            const auto seekTime = *result;
            protect(protectedThis->m_mediaSource)->reenqueueMediaForTime(seekTime)->whenSettled(RunLoop::currentSingleton(), [weakThis, seekTime](auto&& result) {
                RefPtr protectedThis = weakThis.get();
                if (!protectedThis || !result)
                    return;
                protectedThis->m_lastSeekTarget.reset();
                protectedThis->m_time = seekTime.toDouble();
                protectedThis->m_positionTarget = seekTime;
                protectedThis->m_positionSent = false;
                // the interface may already stand in the epoch that the samples of this seek start, or it waits for it
                protectedThis->pollMse();
                protectedThis->startPositionIfOpen();
            });
        });
        return *m_seekPromise;
    }

    // after a seek in the epoch that is open already (no new epoch came, the buffers held the time): the interface goes there at once
    void startPositionIfOpen()
    {
        if (m_id && m_session && m_session->epoch() == m_openedEpoch && !m_positionSent)
            startPosition();
    }

    // the id of the interface ends here and the stream that it played goes out of the table of the core
    void releaseStream()
    {
        if (!m_id)
            return;
        send(YOZORA_MEDIA_CLOSE, 0);
        entries().remove(m_id);
        yozora_hls* hls = nullptr;
        if (m_core) {
            pthread_mutex_lock(&m_core->lock);
            auto found = m_core->shared.mse_streams.find(m_id);
            if (found != m_core->shared.mse_streams.end()) {
                hls = found->second;
                m_core->shared.mse_streams.erase(found);
            }
            pthread_mutex_unlock(&m_core->lock);
            m_core->media_dirty = true;
        }
        yozora_hls_release(hls);
        m_id = 0;
    }

    void resetState()
    {
        m_networkState = MediaPlayer::NetworkState::Empty;
        m_readyState = MediaPlayer::ReadyState::HaveNothing;
        m_paused = true;
        m_ended = false;
        m_playing = false;
        m_hasDuration = false;
        m_hasFrame = false;
        m_duration = 0;
        m_time = 0;
        m_width = 0;
        m_height = 0;
        m_errorCode = 0;
        m_progressed = false;
        m_buffered.clear();
        m_seekPromise.reset();
    }

    void send(yozora_media_command command, double value)
    {
        if (!m_id || !m_core)
            return;
        yozora_media_request request;
        std::memset(&request, 0, sizeof(request));
        request.command = command;
        request.id = m_id;
        request.value = value;
        request.muted = m_muted;
        yozora_log(YOZORA_LOG_DEBUG, "media", "player %u command %d value %.3f", m_id, static_cast<int>(command), value);
        push_request(*m_core, request);
    }

    void sendVolume() { send(YOZORA_MEDIA_VOLUME, m_volume); }

    // the position stops being extrapolated from the last report
    void freezeTime()
    {
        if (m_playing)
            m_time = currentTime().toDouble();
        m_playing = false;
    }

    void advance(MediaPlayer::ReadyState state)
    {
        if (state <= m_readyState)
            return;
        m_readyState = state;
        if (RefPtr player = m_player.get())
            player->readyStateChanged();
    }

    void setNetworkState(MediaPlayer::NetworkState state)
    {
        m_networkState = state;
        if (RefPtr player = m_player.get())
            player->networkStateChanged();
    }

    void fail(int code)
    {
        m_errorCode = code;
        release();
        m_playing = false;
        setNetworkState(code == error_network ? MediaPlayer::NetworkState::NetworkError : code == error_decode ? MediaPlayer::NetworkState::DecodeError : MediaPlayer::NetworkState::FormatError);
    }

    // the id ends here: the interface closes its player and nothing it sends later reaches the element
    void release()
    {
        stopPoll();
        if (m_mse) {
            releaseStream();
            if (m_mediaSource) {
                m_mediaSource->shutdown();
                m_mediaSource = nullptr;
            }
            m_session = nullptr;
            m_mse = false;
            m_openedEpoch = 0;
            return;
        }
        if (!m_id)
            return;
        send(YOZORA_MEDIA_CLOSE, 0);
        entries().remove(m_id);
        if (m_core)
            m_core->media_dirty = true;
        m_id = 0;
    }

    ThreadSafeWeakPtr<MediaPlayer> m_player;
    yozora_core* m_core { nullptr };
    unsigned m_id { 0 };
    MediaPlayer::NetworkState m_networkState { MediaPlayer::NetworkState::Empty };
    MediaPlayer::ReadyState m_readyState { MediaPlayer::ReadyState::HaveNothing };
    PlatformTimeRanges m_buffered;
    std::optional<MediaTimePromise::AutoRejectProducer> m_seekPromise;
    MonotonicTime m_timeStamp;
    double m_time { 0 };
    double m_duration { 0 };
    double m_rate { 1 };
    double m_volume { 1 };
    float m_width { 0 };
    float m_height { 0 };
    long m_errorCode { 0 };
    mutable bool m_progressed { false };
    bool m_muted { false };
    bool m_paused { true };
    bool m_ended { false };
    bool m_playing { false };
    bool m_hasDuration { false };
    bool m_hasFrame { false };
    // a media source: the session that turns appended samples into streams, its private part for WebCore, the
    // epoch whose stream the interface plays, when that stream starts in page time, and the place the
    // interface goes to once ready in it
    bool m_mse { false };
    RefPtr<Yozora::MseSession> m_session;
    RefPtr<MediaSourcePrivate> m_mediaSource;
    unsigned m_openedEpoch { 0 };
    double m_epochOrigin { 0 };
    MediaTime m_positionTarget;
    bool m_positionSent { false };
    std::optional<SeekTarget> m_lastSeekTarget;
    RefPtr<RunLoop::DispatchTimer> m_pollTimer;
};

MediaPlayer::SupportsType evaluate_support(const MediaEngineSupportParameters& parameters)
{
    if (parameters.requiresRemotePlayback)
        return MediaPlayer::SupportsType::IsNotSupported;
    String container = parameters.type.containerType().convertToASCIILowercase();
    // what a media source takes is fragmented mp4 with H.264 and AAC and nothing else, the stream is made from it for the system player
    if (parameters.platformType == PlatformMediaDecodingType::MediaSource) {
        if (container.isEmpty())
            return MediaPlayer::SupportsType::MayBeSupported;
        if (container != "video/mp4"_s && container != "audio/mp4"_s)
            return MediaPlayer::SupportsType::IsNotSupported;
        auto codecs = parameters.type.codecs();
        if (codecs.isEmpty())
            return MediaPlayer::SupportsType::MayBeSupported;
        for (auto& codec : codecs) {
            String lower = codec.convertToASCIILowercase();
            if (!(lower.startsWith("avc1"_s) || lower.startsWith("avc3"_s) || lower.startsWith("mp4a.40."_s) || lower == "mp4a.67"_s))
                return MediaPlayer::SupportsType::IsNotSupported;
        }
        return MediaPlayer::SupportsType::IsSupported;
    }
    if (container.isEmpty())
        return MediaPlayer::SupportsType::MayBeSupported;
    if (!container_supported(container))
        return MediaPlayer::SupportsType::IsNotSupported;
    auto codecs = parameters.type.codecs();
    if (codecs.isEmpty())
        return MediaPlayer::SupportsType::MayBeSupported;
    for (auto& codec : codecs) {
        if (!codec_supported(codec, container))
            return MediaPlayer::SupportsType::IsNotSupported;
    }
    return MediaPlayer::SupportsType::IsSupported;
}

class YozoraMediaFactory final : public MediaPlayerFactory {
    WTF_MAKE_TZONE_ALLOCATED_INLINE(YozoraMediaFactory);
    WTF_OVERRIDE_DELETE_FOR_CHECKED_PTR(YozoraMediaFactory);
private:
    MediaPlayerEnums::MediaEngineIdentifier identifier() const final { return MediaPlayerEnums::MediaEngineIdentifier::HolePunch; }
    Ref<MediaPlayerPrivateInterface> createMediaEnginePlayer(MediaPlayer& player) const final { return YozoraMediaPlayer::create(player); }
    void getSupportedTypes(HashSet<String>& types) const final
    {
        for (auto& type : supported_types)
            types.add(String::fromLatin1(type.container));
    }
    MediaPlayer::SupportsType supportsTypeAndCodecs(const MediaEngineSupportParameters& parameters) const final { return evaluate_support(parameters); }
};

void register_engine(MediaEngineRegistrar registrar)
{
    registrar(makeUnique<YozoraMediaFactory>());
}

// navigator.mediaCapabilities.decodingInfo: sites ask before choosing a format and without a factory WebCore
// answers "not supported" to every configuration, so a player (YouTube) finds nothing usable and shows black.
// the answer is the engine's, what canPlayType and isTypeSupported say
bool configuration_supported(const String& contentType, PlatformMediaDecodingType type)
{
    MediaEngineSupportParameters parameters;
    parameters.platformType = type;
    parameters.type = ContentType { contentType };
    return evaluate_support(parameters) != MediaPlayer::SupportsType::IsNotSupported;
}

void create_decoding_configuration(PlatformMediaDecodingConfiguration&& configuration, PlatformMediaEngineConfigurationFactory::DecodingConfigurationCallback&& callback)
{
    PlatformMediaCapabilitiesDecodingInfo info { { }, WTF::move(configuration) };
    auto& config = info.configuration;
    bool supported = config.type != PlatformMediaDecodingType::MediaStream && (config.video || config.audio);
    if (supported && config.video)
        supported = configuration_supported(config.video->contentType, config.type);
    if (supported && config.audio)
        supported = configuration_supported(config.audio->contentType, config.type);
    info.supported = supported;
    // the decoder of the oldest phones is a chip: H.264 up to full HD at 30 frames is smooth on it and costs little power, more is not
    bool light = !config.video || (config.video->width <= 1920 && config.video->height <= 1920 && config.video->framerate <= 30.5);
    info.smooth = supported && light;
    info.powerEfficient = supported;
    yozora_log(supported ? YOZORA_LOG_DEBUG : YOZORA_LOG_INFO, "caps", "decodingInfo %s video %s audio %s: %s", config.type == PlatformMediaDecodingType::MediaSource ? "media source" : "file",
        config.video ? config.video->contentType.utf8().data() : "-", config.audio ? config.audio->contentType.utf8().data() : "-", supported ? "yes" : "no");
    callback(WTF::move(info));
}

// the player an element plays with, null for an element without one or one that gave its stream up
YozoraMediaPlayer* player_of(HTMLMediaElement& element)
{
    RefPtr player = element.player();
    auto* engine = player ? player->playerPrivate() : nullptr;
    if (!engine || engine->mediaPlayerType() != MediaPlayerType::HolePunch)
        return nullptr;
    return static_cast<YozoraMediaPlayer*>(engine);
}

// the video a full screen request is about: the element, or the first video inside it (a script player's
// container asks for full screen, not the video), with an interface player
HTMLVideoElement* fullscreen_video(const Element& request)
{
    // the traversals and player() want a mutable element, nothing here changes it
    Element& element = const_cast<Element&>(request);
    if (auto* video = dynamicDowncast<HTMLVideoElement>(element))
        return player_of(*video) ? video : nullptr;
    for (auto& video : descendantsOfType<HTMLVideoElement>(element)) {
        if (player_of(video))
            return &video;
    }
    return nullptr;
}

// the interface left its full screen player: the element leaves its full screen state, which fires the events of the page
void leave_fullscreen(YozoraMediaPlayer& player)
{
    for (auto& weak : HTMLMediaElement::allMediaElements()) {
        RefPtr video = dynamicDowncast<HTMLVideoElement>(weak.ptr());
        if (!video || player_of(*video) != &player)
            continue;
        Ref fullscreen = protect(video->document())->fullscreen();
        if (fullscreen->fullscreenElement())
            fullscreen->fullyExitFullscreen();
        else if (video->isFullscreen())
            video->exitFullscreen();
        return;
    }
}

}

void yozora_media_install()
{
    PlatformMediaEngineConfigurationFactory::installFactory({ create_decoding_configuration, nullptr });
    MediaPlayerFactorySupport::callRegisterMediaEngine(register_engine);
}

void yozora_media_publish(yozora_core& core, LocalFrameView&)
{
    std::vector<yozora_video> found;
    for (auto& weak : HTMLMediaElement::allMediaElements()) {
        if (found.size() >= YOZORA_MAX_VIDEOS)
            break;
        RefPtr video = dynamicDowncast<HTMLVideoElement>(weak.ptr());
        if (!video || video->document().page() != core.page.get())
            continue;
        auto* engine = player_of(*video);
        CheckedPtr renderer = video->renderer();
        if (!engine || !engine->id() || !renderer || renderer->style().usedVisibility() != Visibility::Visible)
            continue;
        IntRect box = renderer->videoBoxInRootView();
        if (box.isEmpty())
            continue;
        // the layer that the video is painted into: its own when it has one, else the one of the closest ancestor that has
        uint64_t layer_id = 0;
        if (CheckedPtr layer = renderer->enclosingLayer()) {
            if (CheckedPtr compositing = layer->enclosingCompositingLayer()) {
                if (auto* backing = compositing->backing()) {
                    // a replaced element paints in the foreground phase, which lives in the foreground layer when the
                    // backing has one (composited children with a negative z index), or in the scrolled contents layer
                    // of a scrolling box. the primary layer sits under those children, so a black player background
                    // composited there would cover a picture put into it
                    GraphicsLayer* painted = backing->foregroundLayer();
                    if (!painted)
                        painted = backing->scrolledContentsLayer();
                    if (!painted)
                        painted = backing->graphicsLayer();
                    layer_id = yozoraGraphicsLayerId(painted);
                }
            }
        }
        found.push_back(yozora_video { engine->id(), box.x(), box.y(), box.width(), box.height(), layer_id });
        yozora_log(YOZORA_LOG_DEBUG, "media", "video of player %u at %d,%d %dx%d in layer %llu", engine->id(), box.x(), box.y(), box.width(), box.height(), static_cast<unsigned long long>(layer_id));
    }
    core.media_dirty = false;
    pthread_mutex_lock(&core.lock);
    core.shared.videos = WTF::move(found);
    pthread_mutex_unlock(&core.lock);
}

bool yozora_media_can_fullscreen(const Element& element)
{
    return fullscreen_video(element);
}

bool yozora_media_set_fullscreen(yozora_core& core, Element& element, bool on)
{
    auto* video = fullscreen_video(element);
    auto* engine = video ? player_of(*video) : nullptr;
    if (!engine || !engine->id())
        return false;
    yozora_media_request request;
    std::memset(&request, 0, sizeof(request));
    request.command = YOZORA_MEDIA_FULLSCREEN;
    request.id = engine->id();
    request.value = on ? 1 : 0;
    push_request(core, request);
    return true;
}

void yozora_media_forget(yozora_core& core)
{
    // the streams of the media sources of this window are let go: the player that held each of them is going too
    std::vector<yozora_hls*> streams;
    pthread_mutex_lock(&core.lock);
    for (auto& entry : core.shared.mse_streams)
        streams.push_back(entry.second);
    core.shared.mse_streams.clear();
    pthread_mutex_unlock(&core.lock);
    for (auto* hls : streams)
        yozora_hls_release(hls);
    Vector<unsigned> ids;
    for (auto& entry : entries())
        if (entry.value.core == &core)
            ids.append(entry.key);
    for (auto id : ids)
        entries().remove(id);
}

extern "C" int yozora_core_take_media(yozora_core* core, yozora_media_request* request)
{
    if (!core || !request)
        return 0;
    pthread_mutex_lock(&core->lock);
    bool found = !core->shared.media.empty();
    if (found) {
        *request = core->shared.media.front();
        core->shared.media.pop_front();
    }
    pthread_mutex_unlock(&core->lock);
    return found ? 1 : 0;
}

// a media source stream for the interface, retained, the interface releases it when its player closes. null
// for an id that has none
extern "C" yozora_hls* yozora_core_mse_stream(yozora_core* core, unsigned id)
{
    if (!core)
        return nullptr;
    yozora_hls* hls = nullptr;
    pthread_mutex_lock(&core->lock);
    auto found = core->shared.mse_streams.find(id);
    if (found != core->shared.mse_streams.end()) {
        hls = found->second;
        yozora_hls_retain(hls);
    }
    pthread_mutex_unlock(&core->lock);
    return hls;
}

extern "C" int yozora_core_videos(yozora_core* core, yozora_video* out, int capacity)
{
    if (!core || !out || capacity <= 0)
        return 0;
    pthread_mutex_lock(&core->lock);
    int count = std::min<int>(capacity, static_cast<int>(core->shared.videos.size()));
    for (int index = 0; index < count; ++index)
        out[index] = core->shared.videos[index];
    pthread_mutex_unlock(&core->lock);
    return count;
}

extern "C" void yozora_core_media_event(yozora_core* core, unsigned id, yozora_media_event_kind kind, double value, double extra)
{
    if (!core || !std::isfinite(value) || !std::isfinite(extra))
        return;
    YozoraCoreThread::post([core, id, kind, value, extra] {
        auto found = entries().find(id);
        // an id of another window is never driven from this one
        if (found == entries().end() || found->value.core != core)
            return;
        RefPtr player = found->value.player.get();
        if (!player) {
            entries().remove(found);
            return;
        }
        if (kind == YOZORA_MEDIA_FULLSCREEN_LEFT)
            leave_fullscreen(*player);
        else
            player->handleEvent(kind, value, extra);
        core->rendering = true;
    });
}
