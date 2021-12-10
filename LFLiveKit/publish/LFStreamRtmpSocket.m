//
//  LFStreamRTMPSocket.m
//  LFLiveKit
//
//  Created by LaiFeng on 16/5/20.
//  Copyright © 2016年 LaiFeng All rights reserved.
//

#import "LFStreamRTMPSocket.h"
#import <LiveKit/Publisher.h>

#if __has_include(<pili-librtmp/rtmp.h>)
#import <pili-librtmp/rtmp.h>
#else
#import "rtmp.h"
#endif

static const NSInteger RetryTimesBreaken = 5;  ///<  重连1分钟  3秒一次 一共20次
static const NSInteger RetryTimesMargin = 3;


#define RTMP_RECEIVE_TIMEOUT    2
#define DATA_ITEMS_MAX_COUNT 100
#define RTMP_DATA_RESERVE_SIZE 400
#define RTMP_HEAD_SIZE (sizeof(RTMPPacket) + RTMP_MAX_HEADER_SIZE)

#define SAVC(x)    static const AVal av_ ## x = AVC(#x)

static const AVal av_setDataFrame = AVC("@setDataFrame");
static const AVal av_SDKVersion = AVC("LFLiveKit 2.4.0");
SAVC(onMetaData);
SAVC(duration);
SAVC(width);
SAVC(height);
SAVC(videocodecid);
SAVC(videodatarate);
SAVC(framerate);
SAVC(audiocodecid);
SAVC(audiodatarate);
SAVC(audiosamplerate);
SAVC(audiosamplesize);
//SAVC(audiochannels);
SAVC(stereo);
SAVC(encoder);
//SAVC(av_stereo);
SAVC(fileSize);
SAVC(avc1);
SAVC(mp4a);

@interface LFStreamRTMPSocket ()<LFStreamingBufferDelegate>
@property (nonatomic, weak) id<LFStreamSocketDelegate> delegate;
@property (nonatomic, strong) LFLiveStreamInfo *stream;
@property (nonatomic, strong) LFStreamingBuffer *buffer;
@property (nonatomic, strong) LFLiveDebug *debugInfo;
@property (nonatomic, strong) dispatch_queue_t rtmpSendQueue;
//错误信息
@property (nonatomic, assign) RTMPError error;
@property (nonatomic, assign) NSInteger retryTimes4netWorkBreaken;
@property (nonatomic, assign) NSInteger reconnectInterval;
@property (nonatomic, assign) NSInteger reconnectCount;

@property (atomic, assign) BOOL isSending;
@property (nonatomic, assign) BOOL isConnected;
@property (nonatomic, assign) BOOL isConnecting;
@property (nonatomic, assign) BOOL isReconnecting;

@property (nonatomic, assign) BOOL sendVideoHead;
@property (nonatomic, assign) BOOL sendAudioHead;
@property (nonatomic, strong) Publisher *publisher;

@end

@implementation LFStreamRTMPSocket

#pragma mark -- LFStreamSocket
- (nullable instancetype)initWithStream:(nullable LFLiveStreamInfo *)stream{
    return [self initWithStream:stream reconnectInterval:0 reconnectCount:0];
}

- (nullable instancetype)initWithStream:(nullable LFLiveStreamInfo *)stream reconnectInterval:(NSInteger)reconnectInterval reconnectCount:(NSInteger)reconnectCount{
    if (!stream) @throw [NSException exceptionWithName:@"LFStreamRtmpSocket init error" reason:@"stream is nil" userInfo:nil];
    if (self = [super init]) {
        _stream = stream;
        if (reconnectInterval > 0) _reconnectInterval = reconnectInterval;
        else _reconnectInterval = RetryTimesMargin;
        
        if (reconnectCount > 0) _reconnectCount = reconnectCount;
        else _reconnectCount = RetryTimesBreaken;
        
        [self addObserver:self forKeyPath:@"isSending" options:NSKeyValueObservingOptionNew context:nil];//这里改成observer主要考虑一直到发送出错情况下，可以继续发送
    }
    return self;
}

- (void)dealloc{
    [self removeObserver:self forKeyPath:@"isSending"];
}

- (void)start {
    dispatch_async(self.rtmpSendQueue, ^{
        [self _start];
    });
}

- (void)_start {
    [self.publisher handshake];
    self.debugInfo.streamId = self.stream.streamId;
    self.debugInfo.uploadUrl = self.stream.url;
    self.debugInfo.isRtmp = YES;
    _isConnecting = YES;
    if (self.delegate && [self.delegate respondsToSelector:@selector(socketStatus:status:)]) {
        [self.delegate socketStatus:self status:LFLivePending];
    }
    _isConnected = YES;
    _isConnecting = NO;
    _isReconnecting = NO;
    _isSending = NO;
    
    if (self.delegate && [self.delegate respondsToSelector:@selector(socketStatus:status:)]) {
        [self.delegate socketStatus:self status:LFLiveStart];
    }
}

- (void)stop {
    dispatch_async(self.rtmpSendQueue, ^{
        [self _stop];
        [NSObject cancelPreviousPerformRequestsWithTarget:self];
    });
}

- (void)_stop {
    if (self.delegate && [self.delegate respondsToSelector:@selector(socketStatus:status:)]) {
        [self.delegate socketStatus:self status:LFLiveStop];
    }
    if (_publisher != nil) {
        _publisher = nil;
    }
    [self clean];
}

- (void)sendFrame:(LFFrame *)frame {
    if (!frame) return;
    [self.buffer appendObject:frame];
    
    if(!self.isSending){
        [self sendFrame];
    }
}

- (void)setDelegate:(id<LFStreamSocketDelegate>)delegate {
    _delegate = delegate;
}

#pragma mark -- CustomMethod
- (void)sendFrame {
    __weak typeof(self) _self = self;
     dispatch_async(self.rtmpSendQueue, ^{
        if (!_self.isSending && _self.buffer.list.count > 0) {
            _self.isSending = YES;

            if (!_self.isConnected || _self.isReconnecting || _self.isConnecting || !_publisher){
                _self.isSending = NO;
                return;
            }

            // 调用发送接口
            LFFrame *frame = [_self.buffer popFirstObject];
            if ([frame isKindOfClass:[LFVideoFrame class]]) {
                if (!_self.sendVideoHead) {
                    _self.sendVideoHead = YES;
                    if(!((LFVideoFrame*)frame).sps || !((LFVideoFrame*)frame).pps){
                        _self.isSending = NO;
                        return;
                    }
                    [_self sendVideoHeader:(LFVideoFrame *)frame];
                } else {
                    [_self sendVideo:(LFVideoFrame *)frame];
                }
            } else {
                if (!_self.sendAudioHead) {
                    _self.sendAudioHead = YES;
                    if(!((LFAudioFrame*)frame).audioInfo){
                        _self.isSending = NO;
                        return;
                    }
                    [_self sendAudioHeader:(LFAudioFrame *)frame];
                } else {
                    [_self sendAudio:frame];
                }
            }

            //debug更新
            _self.debugInfo.totalFrame++;
            _self.debugInfo.dropFrame += _self.buffer.lastDropFrames;
            _self.buffer.lastDropFrames = 0;

            _self.debugInfo.dataFlow += frame.data.length;
            _self.debugInfo.elapsedMilli = CACurrentMediaTime() * 1000 - _self.debugInfo.timeStamp;
            if (_self.debugInfo.elapsedMilli < 1000) {
                _self.debugInfo.bandwidth += frame.data.length;
                if ([frame isKindOfClass:[LFAudioFrame class]]) {
                    _self.debugInfo.capturedAudioCount++;
                } else {
                    _self.debugInfo.capturedVideoCount++;
                }

                _self.debugInfo.unSendCount = _self.buffer.list.count;
            } else {
                _self.debugInfo.currentBandwidth = _self.debugInfo.bandwidth;
                _self.debugInfo.currentCapturedAudioCount = _self.debugInfo.capturedAudioCount;
                _self.debugInfo.currentCapturedVideoCount = _self.debugInfo.capturedVideoCount;
                if (_self.delegate && [_self.delegate respondsToSelector:@selector(socketDebug:debugInfo:)]) {
                    [_self.delegate socketDebug:_self debugInfo:_self.debugInfo];
                }
                _self.debugInfo.bandwidth = 0;
                _self.debugInfo.capturedAudioCount = 0;
                _self.debugInfo.capturedVideoCount = 0;
                _self.debugInfo.timeStamp = CACurrentMediaTime() * 1000;
            }
            
            //修改发送状态
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                //< 这里只为了不循环调用sendFrame方法 调用栈是保证先出栈再进栈
                _self.isSending = NO;
            });
            
        }
    });
}

- (void)clean {
    _publisher = nil;
    _isConnecting = NO;
    _isReconnecting = NO;
    _isSending = NO;
    _isConnected = NO;
    _sendAudioHead = NO;
    _sendVideoHead = NO;
    self.debugInfo = nil;
    [self.buffer removeAllObject];
    self.retryTimes4netWorkBreaken = 0;
}

#pragma mark -- Rtmp Send

- (void)sendVideoHeader:(LFVideoFrame *)videoFrame {

    unsigned char *body = NULL;
    NSInteger iIndex = 0;
    NSInteger rtmpLength = 1024;
    const char *sps = videoFrame.sps.bytes;
    const char *pps = videoFrame.pps.bytes;
    NSInteger sps_len = videoFrame.sps.length;
    NSInteger pps_len = videoFrame.pps.length;

    body = (unsigned char *)malloc(rtmpLength);
    memset(body, 0, rtmpLength);

    body[iIndex++] = 0x17;
    body[iIndex++] = 0x00;

    body[iIndex++] = 0x00;
    body[iIndex++] = 0x00;
    body[iIndex++] = 0x00;

    body[iIndex++] = 0x01;
    body[iIndex++] = sps[1];
    body[iIndex++] = sps[2];
    body[iIndex++] = sps[3];
    body[iIndex++] = 0xff;

    /*sps*/
    body[iIndex++] = 0xe1;
    body[iIndex++] = (sps_len >> 8) & 0xff;
    body[iIndex++] = sps_len & 0xff;
    memcpy(&body[iIndex], sps, sps_len);
    iIndex += sps_len;

    /*pps*/
    body[iIndex++] = 0x01;
    body[iIndex++] = (pps_len >> 8) & 0xff;
    body[iIndex++] = (pps_len) & 0xff;
    memcpy(&body[iIndex], pps, pps_len);
    iIndex += pps_len;

    [self sendPacket:RTMP_PACKET_TYPE_VIDEO data:body size:iIndex nTimestamp:0];
    free(body);
}

- (void)sendVideo:(LFVideoFrame *)frame {

    NSInteger i = 0;
    NSInteger rtmpLength = frame.data.length + 9;
    unsigned char *body = (unsigned char *)malloc(rtmpLength);
    memset(body, 0, rtmpLength);

    if (frame.isKeyFrame) {
        body[i++] = 0x17;        // 1:Iframe  7:AVC
    } else {
        body[i++] = 0x27;        // 2:Pframe  7:AVC
    }
    body[i++] = 0x01;    // AVC NALU
    body[i++] = 0x00;
    body[i++] = 0x00;
    body[i++] = 0x00;
    body[i++] = (frame.data.length >> 24) & 0xff;
    body[i++] = (frame.data.length >> 16) & 0xff;
    body[i++] = (frame.data.length >>  8) & 0xff;
    body[i++] = (frame.data.length) & 0xff;
    memcpy(&body[i], frame.data.bytes, frame.data.length);

    [self.publisher sendVideo:body size:rtmpLength time:(uint32_t)frame.timestamp];
//    [self sendPacket:RTMP_PACKET_TYPE_VIDEO data:body size:(rtmpLength) nTimestamp:frame.timestamp];
    free(body);
}

- (NSInteger)sendPacket:(unsigned int)nPacketType data:(unsigned char *)data size:(NSInteger)size nTimestamp:(uint64_t)nTimestamp {
    [self.publisher sendChunk:data size:(uint32_t)size time:(uint32_t)nTimestamp type:(u_char)nPacketType channel:0x04];
    return size;
}

- (NSInteger)RtmpPacketSend:(PILI_RTMPPacket *)packet {
    if (_publisher) {
        int success = 1;
        return success;
    }
    return -1;
}

- (void)sendAudioHeader:(LFAudioFrame *)audioFrame {
    NSInteger rtmpLength = audioFrame.audioInfo.length + 2;     /*spec data长度,一般是2*/
    unsigned char *body = (unsigned char *)malloc(rtmpLength);
    memset(body, 0, rtmpLength);

    /*AF 00 + AAC RAW data*/
    body[0] = 0xAF;
    body[1] = 0x00;
    memcpy(&body[2], audioFrame.audioInfo.bytes, audioFrame.audioInfo.length);          /*spec_buf是AAC sequence header数据*/
    [self sendPacket:RTMP_PACKET_TYPE_AUDIO data:body size:rtmpLength nTimestamp:0];
    free(body);
}

- (void)sendAudio:(LFFrame *)frame {

    NSInteger rtmpLength = frame.data.length + 2;    /*spec data长度,一般是2*/
    unsigned char *body = (unsigned char *)malloc(rtmpLength);
    memset(body, 0, rtmpLength);

    /*AF 01 + AAC RAW data*/
    body[0] = 0xAF;
    body[1] = 0x01;
    memcpy(&body[2], frame.data.bytes, frame.data.length);
    [self.publisher sendAudio:body size:rtmpLength time:(uint32_t)frame.timestamp];
    free(body);
}

// 断线重连
- (void)reconnect {
    dispatch_async(self.rtmpSendQueue, ^{
        if (self.retryTimes4netWorkBreaken++ < self.reconnectCount && !self.isReconnecting) {
            self.isConnected = NO;
            self.isConnecting = NO;
            self.isReconnecting = YES;
            dispatch_async(dispatch_get_main_queue(), ^{
                 [self performSelector:@selector(_reconnect) withObject:nil afterDelay:self.reconnectInterval];
            });
           
        } else if (self.retryTimes4netWorkBreaken >= self.reconnectCount) {
            if (self.delegate && [self.delegate respondsToSelector:@selector(socketStatus:status:)]) {
                [self.delegate socketStatus:self status:LFLiveError];
            }
            if (self.delegate && [self.delegate respondsToSelector:@selector(socketDidError:errorCode:)]) {
                [self.delegate socketDidError:self errorCode:LFLiveSocketError_ReConnectTimeOut];
            }
        }
    });
}

- (void)_reconnect{
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    
    _isReconnecting = NO;
    if(_isConnected) return;
    
    _isReconnecting = NO;
    if (_isConnected) return;
    if (_publisher != nil) {
        _publisher = nil;
    }
    _sendAudioHead = NO;
    _sendVideoHead = NO;
    
    if (self.delegate && [self.delegate respondsToSelector:@selector(socketStatus:status:)]) {
        [self.delegate socketStatus:self status:LFLiveRefresh];
    }
    
    if (_publisher != nil) {
        _publisher = nil;
    }
}

#pragma mark -- CallBack
void RTMPErrorCallback(RTMPError *error, void *userData) {
    LFStreamRTMPSocket *socket = (__bridge LFStreamRTMPSocket *)userData;
    if (error->code < 0) {
        [socket reconnect];
    }
}

void ConnectionTimeCallback(PILI_CONNECTION_TIME *conn_time, void *userData) {
}

#pragma mark -- LFStreamingBufferDelegate
- (void)streamingBuffer:(nullable LFStreamingBuffer *)buffer bufferState:(LFLiveBuffferState)state{
    if(self.delegate && [self.delegate respondsToSelector:@selector(socketBufferStatus:status:)]){
        [self.delegate socketBufferStatus:self status:state];
    }
}

#pragma mark -- Observer
-(void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context{
    if([keyPath isEqualToString:@"isSending"]){
        if(!self.isSending){
            [self sendFrame];
        }
    }
}

#pragma mark -- Getter Setter

- (LFStreamingBuffer *)buffer {
    if (!_buffer) {
        _buffer = [[LFStreamingBuffer alloc] init];
        _buffer.delegate = self;

    }
    return _buffer;
}

- (LFLiveDebug *)debugInfo {
    if (!_debugInfo) {
        _debugInfo = [[LFLiveDebug alloc] init];
    }
    return _debugInfo;
}

- (dispatch_queue_t)rtmpSendQueue{
    if(!_rtmpSendQueue){
        _rtmpSendQueue = dispatch_queue_create("com.youku.LaiFeng.RtmpSendQueue", NULL);
    }
    return _rtmpSendQueue;
}

- (Publisher *)publisher {
    if (!_publisher) {
        _publisher = [Publisher create];
        PushProps props = {
            .port = 1935,
            .path = "/animal/cat",
            .host = "snail.local"
        };
        _publisher.props = props;
    }
    return _publisher;
}
@end
