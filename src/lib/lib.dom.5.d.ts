
/**
 * The **`RTCDTMFSender`** interface provides a mechanism for transmitting DTMF codes on a WebRTC RTCPeerConnection. You gain access to the connection's RTCDTMFSender through the RTCRtpSender.dtmf property on the audio track you wish to send DTMF with.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCDTMFSender)
 */
interface RTCDTMFSender extends EventTarget {
    /**
     * The **`canInsertDTMF`** read-only property of the RTCDTMFSender interface returns a boolean value which indicates whether the RTCDTMFSender is capable of sending DTMF tones over the RTCPeerConnection.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCDTMFSender/canInsertDTMF)
     */
    readonly canInsertDTMF: boolean;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCDTMFSender/tonechange_event) */
    ontonechange: ((this: RTCDTMFSender, ev: RTCDTMFToneChangeEvent) => any) | null;
    /**
     * The RTCDTMFSender interface's **`toneBuffer`** property returns a string containing a list of the DTMF tones currently queued for sending to the remote peer over the RTCPeerConnection. To place tones into the buffer, call insertDTMF().
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCDTMFSender/toneBuffer)
     */
    readonly toneBuffer: string;
    /**
     * The **`insertDTMF()`** method of the RTCDTMFSender interface sends DTMF tones to the remote peer over the RTCPeerConnection.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCDTMFSender/insertDTMF)
     */
    insertDTMF(tones: string, duration?: number, interToneGap?: number): void;
    addEventListener<K extends keyof RTCDTMFSenderEventMap>(type: K, listener: (this: RTCDTMFSender, ev: RTCDTMFSenderEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof RTCDTMFSenderEventMap>(type: K, listener: (this: RTCDTMFSender, ev: RTCDTMFSenderEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var RTCDTMFSender: {
    prototype: RTCDTMFSender;
    new(): RTCDTMFSender;
};

/**
 * The **`RTCDTMFToneChangeEvent`** interface represents events sent to indicate that DTMF tones have started or finished playing. This interface is used by the tonechange event.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCDTMFToneChangeEvent)
 */
interface RTCDTMFToneChangeEvent extends Event {
    /**
     * The read-only property **`RTCDTMFToneChangeEvent.tone`** returns the DTMF character which has just begun to play, or an empty string (""). if all queued tones have finished playing (that is, RTCDTMFSender.toneBuffer is empty).
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCDTMFToneChangeEvent/tone)
     */
    readonly tone: string;
}

declare var RTCDTMFToneChangeEvent: {
    prototype: RTCDTMFToneChangeEvent;
    new(type: string, eventInitDict?: RTCDTMFToneChangeEventInit): RTCDTMFToneChangeEvent;
};

interface RTCDataChannelEventMap {
    "bufferedamountlow": Event;
    "close": Event;
    "closing": Event;
    "error": RTCErrorEvent;
    "message": MessageEvent;
    "open": Event;
}

/**
 * The **`RTCDataChannel`** interface represents a network channel which can be used for bidirectional peer-to-peer transfers of arbitrary data. Every data channel is associated with an RTCPeerConnection, and each peer connection can have up to a theoretical maximum of 65,534 data channels (the actual limit may vary from browser to browser).
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCDataChannel)
 */
interface RTCDataChannel extends EventTarget {
    /**
     * The property **`binaryType`** on the RTCDataChannel interface is a string which specifies the type of object which should be used to represent binary data received on the RTCDataChannel. Values allowed by the WebSocket.binaryType property are also permitted here: blob if Blob objects are being used or arraybuffer if ArrayBuffer objects are being used. The default is arraybuffer.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCDataChannel/binaryType)
     */
    binaryType: BinaryType;
    /**
     * The read-only RTCDataChannel property **`bufferedAmount`** returns the number of bytes of data currently queued to be sent over the data channel. The queue may build up as a result of calls to the send() method. This only includes data buffered by the user agent itself; it doesn't include any framing overhead or buffering done by the operating system or network hardware.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCDataChannel/bufferedAmount)
     */
    readonly bufferedAmount: number;
    /**
     * The RTCDataChannel property **`bufferedAmountLowThreshold`** is used to specify the number of bytes of buffered outgoing data that is considered "low." The default value is 0. When the number of buffered outgoing bytes, as indicated by the bufferedAmount property, falls to or below this value, a bufferedamountlow event is fired. This event may be used, for example, to implement code which queues more messages to be sent whenever there's room to buffer them. Listeners may be added with onbufferedamountlow or addEventListener().
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCDataChannel/bufferedAmountLowThreshold)
     */
    bufferedAmountLowThreshold: number;
    /**
     * The read-only RTCDataChannel property **`id`** returns an ID number (between 0 and 65,534) which uniquely identifies the RTCDataChannel. This ID is set at the time the data channel is created, either by the user agent (if RTCDataChannel.negotiated is false) or by the site or app script (if negotiated is true).
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCDataChannel/id)
     */
    readonly id: number | null;
    /**
     * The read-only RTCDataChannel property **`label`** returns a string containing a name describing the data channel. These labels are not required to be unique.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCDataChannel/label)
     */
    readonly label: string;
    /**
     * The read-only RTCDataChannel property **`maxPacketLifeTime`** returns the amount of time, in milliseconds, the browser is allowed to take to attempt to transmit a message, as set when the data channel was created, or null. This limits how long the browser can continue to attempt to transmit and retransmit the message before giving up.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCDataChannel/maxPacketLifeTime)
     */
    readonly maxPacketLifeTime: number | null;
    /**
     * The read-only RTCDataChannel property **`maxRetransmits`** returns the maximum number of times the browser should try to retransmit a message before giving up, as set when the data channel was created, or null, which indicates that there is no maximum. This can only be set when the RTCDataChannel is created by calling RTCPeerConnection.createDataChannel(), using the maxRetransmits field in the specified options.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCDataChannel/maxRetransmits)
     */
    readonly maxRetransmits: number | null;
    /**
     * The read-only RTCDataChannel property **`negotiated`** indicates whether the RTCDataChannel's connection was negotiated by the Web app (true) or by the WebRTC layer (false). The default is false.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCDataChannel/negotiated)
     */
    readonly negotiated: boolean;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCDataChannel/bufferedamountlow_event) */
    onbufferedamountlow: ((this: RTCDataChannel, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCDataChannel/close_event) */
    onclose: ((this: RTCDataChannel, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCDataChannel/closing_event) */
    onclosing: ((this: RTCDataChannel, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCDataChannel/error_event) */
    onerror: ((this: RTCDataChannel, ev: RTCErrorEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCDataChannel/message_event) */
    onmessage: ((this: RTCDataChannel, ev: MessageEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCDataChannel/open_event) */
    onopen: ((this: RTCDataChannel, ev: Event) => any) | null;
    /**
     * The read-only RTCDataChannel property **`ordered`** indicates whether or not the data channel guarantees in-order delivery of messages; the default is true, which indicates that the data channel is indeed ordered. This is set when the RTCDataChannel is created, by setting the ordered property on the object passed as RTCPeerConnection.createDataChannel()'s options parameter.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCDataChannel/ordered)
     */
    readonly ordered: boolean;
    /**
     * The read-only RTCDataChannel property **`protocol`** returns a string containing the name of the subprotocol in use. If no protocol was specified when the data channel was created, then this property's value is the empty string ("").
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCDataChannel/protocol)
     */
    readonly protocol: string;
    /**
     * The read-only RTCDataChannel property **`readyState`** returns a string which indicates the state of the data channel's underlying data connection.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCDataChannel/readyState)
     */
    readonly readyState: RTCDataChannelState;
    /**
     * The **`RTCDataChannel.close()`** method closes the RTCDataChannel. Either peer is permitted to call this method to initiate closure of the channel.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCDataChannel/close)
     */
    close(): void;
    /**
     * The **`send()`** method of the RTCDataChannel interface sends data across the data channel to the remote peer. This can be done any time except during the initial process of creating the underlying transport channel. Data sent before connecting is buffered if possible (or an error occurs if it's not possible), and is also buffered if sent while the connection is closing or closed.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCDataChannel/send)
     */
    send(data: string): void;
    send(data: Blob): void;
    send(data: ArrayBuffer): void;
    send(data: ArrayBufferView<ArrayBuffer>): void;
    addEventListener<K extends keyof RTCDataChannelEventMap>(type: K, listener: (this: RTCDataChannel, ev: RTCDataChannelEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof RTCDataChannelEventMap>(type: K, listener: (this: RTCDataChannel, ev: RTCDataChannelEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var RTCDataChannel: {
    prototype: RTCDataChannel;
    new(): RTCDataChannel;
};

/**
 * The **`RTCDataChannelEvent`** interface represents an event related to a specific RTCDataChannel.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCDataChannelEvent)
 */
interface RTCDataChannelEvent extends Event {
    /**
     * The read-only property **`RTCDataChannelEvent.channel`** returns the RTCDataChannel associated with the event.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCDataChannelEvent/channel)
     */
    readonly channel: RTCDataChannel;
}

declare var RTCDataChannelEvent: {
    prototype: RTCDataChannelEvent;
    new(type: string, eventInitDict: RTCDataChannelEventInit): RTCDataChannelEvent;
};

interface RTCDtlsTransportEventMap {
    "error": RTCErrorEvent;
    "statechange": Event;
}

/**
 * The **`RTCDtlsTransport`** interface provides access to information about the Datagram Transport Layer Security (DTLS) transport over which a RTCPeerConnection's RTP and RTCP packets are sent and received by its RTCRtpSender and RTCRtpReceiver objects.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCDtlsTransport)
 */
interface RTCDtlsTransport extends EventTarget {
    /**
     * The **`iceTransport`** read-only property of the RTCDtlsTransport interface contains a reference to the underlying RTCIceTransport.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCDtlsTransport/iceTransport)
     */
    readonly iceTransport: RTCIceTransport;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCDtlsTransport/error_event) */
    onerror: ((this: RTCDtlsTransport, ev: RTCErrorEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCDtlsTransport/statechange_event) */
    onstatechange: ((this: RTCDtlsTransport, ev: Event) => any) | null;
    /**
     * The **`state`** read-only property of the RTCDtlsTransport interface provides information which describes a Datagram Transport Layer Security (DTLS) transport state.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCDtlsTransport/state)
     */
    readonly state: RTCDtlsTransportState;
    getRemoteCertificates(): ArrayBuffer[];
    addEventListener<K extends keyof RTCDtlsTransportEventMap>(type: K, listener: (this: RTCDtlsTransport, ev: RTCDtlsTransportEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof RTCDtlsTransportEventMap>(type: K, listener: (this: RTCDtlsTransport, ev: RTCDtlsTransportEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var RTCDtlsTransport: {
    prototype: RTCDtlsTransport;
    new(): RTCDtlsTransport;
};

/**
 * The **`RTCEncodedAudioFrame`** of the WebRTC API represents an encoded audio frame in the WebRTC receiver or sender pipeline, which may be modified using a WebRTC Encoded Transform.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCEncodedAudioFrame)
 */
interface RTCEncodedAudioFrame {
    /**
     * The **`data`** property of the RTCEncodedAudioFrame interface returns a buffer containing the data for an encoded frame.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCEncodedAudioFrame/data)
     */
    data: ArrayBuffer;
    /**
     * The **`timestamp`** read-only property of the RTCEncodedAudioFrame interface indicates the time at which frame sampling started.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCEncodedAudioFrame/timestamp)
     */
    readonly timestamp: number;
    /**
     * The **`getMetadata()`** method of the RTCEncodedAudioFrame interface returns an object containing the metadata associated with the frame.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCEncodedAudioFrame/getMetadata)
     */
    getMetadata(): RTCEncodedAudioFrameMetadata;
}

declare var RTCEncodedAudioFrame: {
    prototype: RTCEncodedAudioFrame;
    new(): RTCEncodedAudioFrame;
};

/**
 * The **`RTCEncodedVideoFrame`** of the WebRTC API represents an encoded video frame in the WebRTC receiver or sender pipeline, which may be modified using a WebRTC Encoded Transform.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCEncodedVideoFrame)
 */
interface RTCEncodedVideoFrame {
    /**
     * The **`data`** property of the RTCEncodedVideoFrame interface returns a buffer containing the frame data.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCEncodedVideoFrame/data)
     */
    data: ArrayBuffer;
    /**
     * The **`timestamp`** read-only property of the RTCEncodedVideoFrame interface indicates the time at which frame sampling started.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCEncodedVideoFrame/timestamp)
     */
    readonly timestamp: number;
    /**
     * The **`type`** read-only property of the RTCEncodedVideoFrame interface indicates whether this frame is a key frame, delta frame, or empty frame.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCEncodedVideoFrame/type)
     */
    readonly type: EncodedVideoChunkType;
    /**
     * The **`getMetadata()`** method of the RTCEncodedVideoFrame interface returns an object containing the metadata associated with the frame.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCEncodedVideoFrame/getMetadata)
     */
    getMetadata(): RTCEncodedVideoFrameMetadata;
}

declare var RTCEncodedVideoFrame: {
    prototype: RTCEncodedVideoFrame;
    new(): RTCEncodedVideoFrame;
};

/**
 * The **`RTCError`** interface describes an error which has occurred while handling WebRTC operations. It's based upon the standard DOMException interface that describes general DOM errors.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCError)
 */
interface RTCError extends DOMException {
    /**
     * The RTCError interface's read-only **`errorDetail`** property is a string indicating the WebRTC-specific error code that occurred.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCError/errorDetail)
     */
    readonly errorDetail: RTCErrorDetailType;
    /**
     * The RTCError read-only property **`receivedAlert`** specifies the fatal DTLS error which resulted in an alert being received from the remote peer.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCError/receivedAlert)
     */
    readonly receivedAlert: number | null;
    /**
     * The read-only **`sctpCauseCode`** property in an RTCError object provides the SCTP cause code explaining why the SCTP negotiation failed, if the RTCError represents an SCTP error.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCError/sctpCauseCode)
     */
    readonly sctpCauseCode: number | null;
    /**
     * The RTCError interface's read-only property **`sdpLineNumber`** specifies the line number within the SDP at which a syntax error occurred while parsing it.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCError/sdpLineNumber)
     */
    readonly sdpLineNumber: number | null;
    /**
     * The read-only **`sentAlert`** property in an RTCError object specifies the DTLS alert number occurred while sending data to the remote peer, if the error represents an outbound DTLS error.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCError/sentAlert)
     */
    readonly sentAlert: number | null;
}

declare var RTCError: {
    prototype: RTCError;
    new(init: RTCErrorInit, message?: string): RTCError;
};

/**
 * The WebRTC API's **`RTCErrorEvent`** interface represents an error sent to a WebRTC object. It's based on the standard Event interface, but adds RTC-specific information describing the error, as shown below.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCErrorEvent)
 */
interface RTCErrorEvent extends Event {
    /**
     * The read-only RTCErrorEvent property **`error`** contains an RTCError object describing the details of the error which the event is announcing.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCErrorEvent/error)
     */
    readonly error: RTCError;
}

declare var RTCErrorEvent: {
    prototype: RTCErrorEvent;
    new(type: string, eventInitDict: RTCErrorEventInit): RTCErrorEvent;
};

/**
 * The **`RTCIceCandidate`** interface—part of the WebRTC API—represents a candidate Interactive Connectivity Establishment (ICE) configuration which may be used to establish an RTCPeerConnection.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCIceCandidate)
 */
interface RTCIceCandidate {
    /**
     * The RTCIceCandidate interface's read-only **`address`** property is a string providing the IP address of the device which is the source of the candidate. The address is null by default if not otherwise specified.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCIceCandidate/address)
     */
    readonly address: string | null;
    /**
     * The read-only property **`candidate`** on the RTCIceCandidate interface returns a string describing the candidate in detail. Most of the other properties of RTCIceCandidate are actually extracted from this string.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCIceCandidate/candidate)
     */
    readonly candidate: string;
    /**
     * The read-only **`component`** property on the RTCIceCandidate interface is a string which indicates whether the candidate is an RTP or an RTCP candidate.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCIceCandidate/component)
     */
    readonly component: RTCIceComponent | null;
    /**
     * The **`foundation`** read-only property of the RTCIceCandidate interface is a string that allows correlation of candidates from a common network path on multiple RTCIceTransport objects.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCIceCandidate/foundation)
     */
    readonly foundation: string | null;
    /**
     * The RTCIceCandidate interface's read-only **`port`** property contains the port number on the device at the address given by RTCIceCandidate.address at which the candidate's peer can be reached.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCIceCandidate/port)
     */
    readonly port: number | null;
    /**
     * The RTCIceCandidate interface's read-only **`priority`** property specifies the candidate's priority according to the remote peer; the higher this value is, the better the remote peer considers the candidate to be.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCIceCandidate/priority)
     */
    readonly priority: number | null;
    /**
     * The RTCIceCandidate interface's read-only **`protocol`** property is a string which indicates whether the candidate uses UDP or TCP as its transport protocol.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCIceCandidate/protocol)
     */
    readonly protocol: RTCIceProtocol | null;
    /**
     * The RTCIceCandidate interface's read-only **`relatedAddress`** property is a string indicating the related address of a relay or reflexive candidate.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCIceCandidate/relatedAddress)
     */
    readonly relatedAddress: string | null;
    /**
     * The RTCIceCandidate interface's read-only **`relatedPort`** property indicates the port number of reflexive or relay candidates.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCIceCandidate/relatedPort)
     */
    readonly relatedPort: number | null;
    /**
     * The read-only **`sdpMLineIndex`** property on the RTCIceCandidate interface is a zero-based index of the m-line describing the media associated with the candidate.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCIceCandidate/sdpMLineIndex)
     */
    readonly sdpMLineIndex: number | null;
    /**
     * The read-only property **`sdpMid`** on the RTCIceCandidate interface returns a string specifying the media stream identification tag of the media component with which the candidate is associated. This ID uniquely identifies a given stream for the component with which the candidate is associated.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCIceCandidate/sdpMid)
     */
    readonly sdpMid: string | null;
    /**
     * The RTCIceCandidate interface's read-only **`tcpType`** property is included on TCP candidates to provide additional details about the candidate type.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCIceCandidate/tcpType)
     */
    readonly tcpType: RTCIceTcpCandidateType | null;
    /**
     * The RTCIceCandidate interface's read-only **`type`** specifies the type of candidate the object represents.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCIceCandidate/type)
     */
    readonly type: RTCIceCandidateType | null;
    /**
     * The read-only **`usernameFragment`** property on the RTCIceCandidate interface is a string indicating the username fragment ("ufrag") that uniquely identifies a single ICE interaction session.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCIceCandidate/usernameFragment)
     */
    readonly usernameFragment: string | null;
    /**
     * The RTCIceCandidate method **`toJSON()`** converts the RTCIceCandidate on which it's called into JSON.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCIceCandidate/toJSON)
     */
    toJSON(): RTCIceCandidateInit;
}

declare var RTCIceCandidate: {
    prototype: RTCIceCandidate;
    new(candidateInitDict?: RTCLocalIceCandidateInit): RTCIceCandidate;
};

/** The **`RTCIceCandidatePair`** dictionary describes a pair of ICE candidates which together comprise a description of a viable connection between two WebRTC endpoints. It is used as the return value from RTCIceTransport.getSelectedCandidatePair() to identify the currently-selected candidate pair identified by the ICE agent. */
interface RTCIceCandidatePair {
    /** The **`local`** property of the RTCIceCandidatePair dictionary specifies the RTCIceCandidate which describes the configuration of the local end of a viable WebRTC connection. */
    local: RTCIceCandidate;
    /** The **`remote`** property of the RTCIceCandidatePair dictionary specifies the RTCIceCandidate describing the configuration of the remote end of a viable WebRTC connection. */
    remote: RTCIceCandidate;
}

interface RTCIceTransportEventMap {
    "gatheringstatechange": Event;
    "selectedcandidatepairchange": Event;
    "statechange": Event;
}

/**
 * The **`RTCIceTransport`** interface provides access to information about the ICE transport layer over which the data is being sent and received. This is particularly useful if you need to access state information about the connection.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCIceTransport)
 */
interface RTCIceTransport extends EventTarget {
    /**
     * The **`gatheringState`** read-only property of the RTCIceTransport interface returns a string that indicates the current gathering state of the ICE agent for this transport: "new", "gathering", or "complete".
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCIceTransport/gatheringState)
     */
    readonly gatheringState: RTCIceGathererState;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCIceTransport/gatheringstatechange_event) */
    ongatheringstatechange: ((this: RTCIceTransport, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCIceTransport/selectedcandidatepairchange_event) */
    onselectedcandidatepairchange: ((this: RTCIceTransport, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCIceTransport/statechange_event) */
    onstatechange: ((this: RTCIceTransport, ev: Event) => any) | null;
    /**
     * The **`state`** read-only property of the RTCIceTransport interface returns the current state of the ICE transport, so you can determine the state of ICE gathering in which the ICE agent currently is operating.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCIceTransport/state)
     */
    readonly state: RTCIceTransportState;
    /**
     * The **`getSelectedCandidatePair()`** method of the RTCIceTransport interface returns an RTCIceCandidatePair object containing the current best-choice pair of ICE candidates describing the configuration of the endpoints of the transport.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCIceTransport/getSelectedCandidatePair)
     */
    getSelectedCandidatePair(): RTCIceCandidatePair | null;
    addEventListener<K extends keyof RTCIceTransportEventMap>(type: K, listener: (this: RTCIceTransport, ev: RTCIceTransportEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof RTCIceTransportEventMap>(type: K, listener: (this: RTCIceTransport, ev: RTCIceTransportEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var RTCIceTransport: {
    prototype: RTCIceTransport;
    new(): RTCIceTransport;
};

interface RTCPeerConnectionEventMap {
    "connectionstatechange": Event;
    "datachannel": RTCDataChannelEvent;
    "icecandidate": RTCPeerConnectionIceEvent;
    "icecandidateerror": RTCPeerConnectionIceErrorEvent;
    "iceconnectionstatechange": Event;
    "icegatheringstatechange": Event;
    "negotiationneeded": Event;
    "signalingstatechange": Event;
    "track": RTCTrackEvent;
}

/**
 * The **`RTCPeerConnection`** interface represents a WebRTC connection between the local computer and a remote peer. It provides methods to connect to a remote peer, maintain and monitor the connection, and close the connection once it's no longer needed.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCPeerConnection)
 */
interface RTCPeerConnection extends EventTarget {
    /**
     * The **`canTrickleIceCandidates`** read-only property of the RTCPeerConnection interface returns a boolean value which indicates whether or not the remote peer can accept trickled ICE candidates.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCPeerConnection/canTrickleIceCandidates)
     */
    readonly canTrickleIceCandidates: boolean | null;
    /**
     * The **`connectionState`** read-only property of the RTCPeerConnection interface indicates the current state of the peer connection by returning one of the following string values: new, connecting, connected, disconnected, failed, or closed.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCPeerConnection/connectionState)
     */
    readonly connectionState: RTCPeerConnectionState;
    /**
     * The **`currentLocalDescription`** read-only property of the RTCPeerConnection interface returns an RTCSessionDescription object describing the local end of the connection as it was most recently successfully negotiated since the last time the RTCPeerConnection finished negotiating and connecting to a remote peer. Also included is a list of any ICE candidates that may already have been generated by the ICE agent since the offer or answer represented by the description was first instantiated.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCPeerConnection/currentLocalDescription)
     */
    readonly currentLocalDescription: RTCSessionDescription | null;
    /**
     * The **`currentRemoteDescription`** read-only property of the RTCPeerConnection interface returns an RTCSessionDescription object describing the remote end of the connection as it was most recently successfully negotiated since the last time the RTCPeerConnection finished negotiating and connecting to a remote peer. Also included is a list of any ICE candidates that may already have been generated by the ICE agent since the offer or answer represented by the description was first instantiated.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCPeerConnection/currentRemoteDescription)
     */
    readonly currentRemoteDescription: RTCSessionDescription | null;
    /**
     * The **`iceConnectionState`** read-only property of the RTCPeerConnection interface returns a string which state of the ICE agent associated with the RTCPeerConnection: new, checking, connected, completed, failed, disconnected, and closed.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCPeerConnection/iceConnectionState)
     */
    readonly iceConnectionState: RTCIceConnectionState;
    /**
     * The **`iceGatheringState`** read-only property of the RTCPeerConnection interface returns a string that describes the overall ICE gathering state for this connection. This lets you detect, for example, when collection of ICE candidates has finished.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCPeerConnection/iceGatheringState)
     */
    readonly iceGatheringState: RTCIceGatheringState;
    /**
     * The **`localDescription`** read-only property of the RTCPeerConnection interface returns an RTCSessionDescription describing the session for the local end of the connection. If it has not yet been set, this is null.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCPeerConnection/localDescription)
     */
    readonly localDescription: RTCSessionDescription | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCPeerConnection/connectionstatechange_event) */
    onconnectionstatechange: ((this: RTCPeerConnection, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCPeerConnection/datachannel_event) */
    ondatachannel: ((this: RTCPeerConnection, ev: RTCDataChannelEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCPeerConnection/icecandidate_event) */
    onicecandidate: ((this: RTCPeerConnection, ev: RTCPeerConnectionIceEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCPeerConnection/icecandidateerror_event) */
    onicecandidateerror: ((this: RTCPeerConnection, ev: RTCPeerConnectionIceErrorEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCPeerConnection/iceconnectionstatechange_event) */
    oniceconnectionstatechange: ((this: RTCPeerConnection, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCPeerConnection/icegatheringstatechange_event) */
    onicegatheringstatechange: ((this: RTCPeerConnection, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCPeerConnection/negotiationneeded_event) */
    onnegotiationneeded: ((this: RTCPeerConnection, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCPeerConnection/signalingstatechange_event) */
    onsignalingstatechange: ((this: RTCPeerConnection, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCPeerConnection/track_event) */
    ontrack: ((this: RTCPeerConnection, ev: RTCTrackEvent) => any) | null;
    /**
     * The **`pendingLocalDescription`** read-only property of the RTCPeerConnection interface returns an RTCSessionDescription object describing a pending configuration change for the local end of the connection.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCPeerConnection/pendingLocalDescription)
     */
    readonly pendingLocalDescription: RTCSessionDescription | null;
    /**
     * The **`pendingRemoteDescription`** read-only property of the RTCPeerConnection interface returns an RTCSessionDescription object describing a pending configuration change for the remote end of the connection.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCPeerConnection/pendingRemoteDescription)
     */
    readonly pendingRemoteDescription: RTCSessionDescription | null;
    /**
     * The **`remoteDescription`** read-only property of the RTCPeerConnection interface returns a RTCSessionDescription describing the session (which includes configuration and media information) for the remote end of the connection. If this hasn't been set yet, this is null.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCPeerConnection/remoteDescription)
     */
    readonly remoteDescription: RTCSessionDescription | null;
    /**
     * The **`sctp`** read-only property of the RTCPeerConnection interface returns an RTCSctpTransport describing the SCTP transport over which SCTP data is being sent and received. If SCTP hasn't been negotiated, this value is null.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCPeerConnection/sctp)
     */
    readonly sctp: RTCSctpTransport | null;
    /**
     * The **`signalingState`** read-only property of the RTCPeerConnection interface returns a string value describing the state of the signaling process on the local end of the connection while connecting or reconnecting to another peer. See Signaling in our WebRTC session lifetime page.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCPeerConnection/signalingState)
     */
    readonly signalingState: RTCSignalingState;
    /**
     * The **`addIceCandidate()`** method of the RTCPeerConnection interface adds a new remote candidate to the connection's remote description, which describes the state of the remote end of the connection.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCPeerConnection/addIceCandidate)
     */
    addIceCandidate(candidate?: RTCIceCandidateInit | null): Promise<void>;
    /** @deprecated */
    addIceCandidate(candidate: RTCIceCandidateInit | null, successCallback: VoidFunction, failureCallback: RTCPeerConnectionErrorCallback): Promise<void>;
    /**
     * The **`addTrack()`** method of the RTCPeerConnection interface adds a new media track to the set of tracks which will be transmitted to the other peer.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCPeerConnection/addTrack)
     */
    addTrack(track: MediaStreamTrack, ...streams: MediaStream[]): RTCRtpSender;
    /**
     * The **`addTransceiver()`** method of the RTCPeerConnection interface creates a new RTCRtpTransceiver and adds it to the set of transceivers associated with the RTCPeerConnection. Each transceiver represents a bidirectional stream, with both an RTCRtpSender and an RTCRtpReceiver associated with it.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCPeerConnection/addTransceiver)
     */
    addTransceiver(trackOrKind: MediaStreamTrack | string, init?: RTCRtpTransceiverInit): RTCRtpTransceiver;
    /**
     * The **`close()`** method of the RTCPeerConnection interface closes the current peer connection.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCPeerConnection/close)
     */
    close(): void;
    /**
     * The **`createAnswer()`** method of the RTCPeerConnection interface creates an SDP answer to an offer received from a remote peer during the offer/answer negotiation of a WebRTC connection.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCPeerConnection/createAnswer)
     */
    createAnswer(options?: RTCAnswerOptions): Promise<RTCSessionDescriptionInit>;
    /** @deprecated */
    createAnswer(successCallback: RTCSessionDescriptionCallback, failureCallback: RTCPeerConnectionErrorCallback): Promise<void>;
    /**
     * The **`createDataChannel()`** method of the RTCPeerConnection interface creates a new channel linked with the remote peer, over which any kind of data may be transmitted. This can be useful for back-channel content, such as images, file transfer, text chat, game update packets, and so forth.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCPeerConnection/createDataChannel)
     */
    createDataChannel(label: string, dataChannelDict?: RTCDataChannelInit): RTCDataChannel;
    /**
     * The **`createOffer()`** method of the RTCPeerConnection interface initiates the creation of an SDP offer for the purpose of starting a new WebRTC connection to a remote peer.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCPeerConnection/createOffer)
     */
    createOffer(options?: RTCOfferOptions): Promise<RTCSessionDescriptionInit>;
    /** @deprecated */
    createOffer(successCallback: RTCSessionDescriptionCallback, failureCallback: RTCPeerConnectionErrorCallback, options?: RTCOfferOptions): Promise<void>;
    /**
     * The **`getConfiguration()`** method of the RTCPeerConnection interface returns an object which indicates the current configuration of the RTCPeerConnection on which the method is called.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCPeerConnection/getConfiguration)
     */
    getConfiguration(): RTCConfiguration;
    /**
     * The **`getReceivers()`** method of the RTCPeerConnection interface returns an array of RTCRtpReceiver objects, each of which represents one RTP receiver. Each RTP receiver manages the reception and decoding of data for a MediaStreamTrack on an RTCPeerConnection.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCPeerConnection/getReceivers)
     */
    getReceivers(): RTCRtpReceiver[];
    /**
     * The **`getSenders()`** method of the RTCPeerConnection interface returns an array of RTCRtpSender objects, each of which represents the RTP sender responsible for transmitting one track's data. A sender object provides methods and properties for examining and controlling the encoding and transmission of the track's data.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCPeerConnection/getSenders)
     */
    getSenders(): RTCRtpSender[];
    /**
     * The **`getStats()`** method of the RTCPeerConnection interface returns a promise which resolves with data providing statistics about either the overall connection or about the specified MediaStreamTrack.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCPeerConnection/getStats)
     */
    getStats(selector?: MediaStreamTrack | null): Promise<RTCStatsReport>;
    /**
     * The **`getTransceivers()`** method of the RTCPeerConnection interface returns a list of the RTCRtpTransceiver objects being used to send and receive data on the connection.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCPeerConnection/getTransceivers)
     */
    getTransceivers(): RTCRtpTransceiver[];
    /**
     * The **`removeTrack()`** method of the RTCPeerConnection interface tells the local end of the connection to stop sending media from the specified track, without actually removing the corresponding RTCRtpSender from the list of senders as reported by RTCPeerConnection.getSenders(). If the track is already stopped, or is not in the connection's senders list, this method has no effect.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCPeerConnection/removeTrack)
     */
    removeTrack(sender: RTCRtpSender): void;
    /**
     * The **`restartIce()`** method of the RTCPeerConnection interface allows a web application to request that ICE candidate gathering be redone on both ends of the connection. This simplifies the process by allowing the same method to be used by either the caller or the receiver to trigger an ICE restart.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCPeerConnection/restartIce)
     */
    restartIce(): void;
    /**
     * The **`setConfiguration()`** method of the RTCPeerConnection interface sets the current configuration of the connection based on the values included in the specified object. This lets you change the ICE servers used by the connection and which transport policies to use.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCPeerConnection/setConfiguration)
     */
    setConfiguration(configuration?: RTCConfiguration): void;
    /**
     * The **`setLocalDescription()`** method of the RTCPeerConnection interface changes the local description associated with the connection. This description specifies the properties of the local end of the connection, including the media format. The method takes a single parameter—the session description—and it returns a Promise which is fulfilled once the description has been changed, asynchronously.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCPeerConnection/setLocalDescription)
     */
    setLocalDescription(description?: RTCLocalSessionDescriptionInit): Promise<void>;
    /** @deprecated */
    setLocalDescription(description: RTCLocalSessionDescriptionInit, successCallback: VoidFunction, failureCallback: RTCPeerConnectionErrorCallback): Promise<void>;
    /**
     * The **`setRemoteDescription()`** method of the RTCPeerConnection interface sets the specified session description as the remote peer's current offer or answer. The description specifies the properties of the remote end of the connection, including the media format. The method takes a single parameter—the session description—and it returns a Promise which is fulfilled once the description has been changed, asynchronously.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCPeerConnection/setRemoteDescription)
     */
    setRemoteDescription(description: RTCSessionDescriptionInit): Promise<void>;
    /** @deprecated */
    setRemoteDescription(description: RTCSessionDescriptionInit, successCallback: VoidFunction, failureCallback: RTCPeerConnectionErrorCallback): Promise<void>;
    addEventListener<K extends keyof RTCPeerConnectionEventMap>(type: K, listener: (this: RTCPeerConnection, ev: RTCPeerConnectionEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof RTCPeerConnectionEventMap>(type: K, listener: (this: RTCPeerConnection, ev: RTCPeerConnectionEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var RTCPeerConnection: {
    prototype: RTCPeerConnection;
    new(configuration?: RTCConfiguration): RTCPeerConnection;
    /**
     * The **`generateCertificate()`** static function of the RTCPeerConnection interface creates an X.509 certificate and corresponding private key, returning a promise that resolves with the new RTCCertificate once it's generated.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCPeerConnection/generateCertificate_static)
     */
    generateCertificate(keygenAlgorithm: AlgorithmIdentifier): Promise<RTCCertificate>;
};

/**
 * The **`RTCPeerConnectionIceErrorEvent`** interface—based upon the Event interface—provides details pertaining to an ICE error announced by sending an icecandidateerror event to the RTCPeerConnection object.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCPeerConnectionIceErrorEvent)
 */
interface RTCPeerConnectionIceErrorEvent extends Event {
    /**
     * The RTCPeerConnectionIceErrorEvent property **`address`** is a string which indicates the local IP address being used to communicate with the STUN or TURN server during negotiations. The error which occurred involved this address.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCPeerConnectionIceErrorEvent/address)
     */
    readonly address: string | null;
    readonly errorCode: number;
    readonly errorText: string;
    readonly port: number | null;
    readonly url: string;
}

declare var RTCPeerConnectionIceErrorEvent: {
    prototype: RTCPeerConnectionIceErrorEvent;
    new(type: string, eventInitDict: RTCPeerConnectionIceErrorEventInit): RTCPeerConnectionIceErrorEvent;
};

/**
 * The **`RTCPeerConnectionIceEvent`** interface represents events that occur in relation to ICE candidates with the target, usually an RTCPeerConnection.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCPeerConnectionIceEvent)
 */
interface RTCPeerConnectionIceEvent extends Event {
    /**
     * The read-only **`candidate`** property of the RTCPeerConnectionIceEvent interface returns the RTCIceCandidate associated with the event.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCPeerConnectionIceEvent/candidate)
     */
    readonly candidate: RTCIceCandidate | null;
}

declare var RTCPeerConnectionIceEvent: {
    prototype: RTCPeerConnectionIceEvent;
    new(type: string, eventInitDict?: RTCPeerConnectionIceEventInit): RTCPeerConnectionIceEvent;
};

/**
 * The **`RTCRtpReceiver`** interface of the WebRTC API manages the reception and decoding of data for a MediaStreamTrack on an RTCPeerConnection.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCRtpReceiver)
 */
interface RTCRtpReceiver {
    /**
     * The **`jitterBufferTarget`** property of the RTCRtpReceiver interface is a DOMHighResTimeStamp that indicates the application's preferred duration, in milliseconds, for which the jitter buffer should hold media before playing it out.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCRtpReceiver/jitterBufferTarget)
     */
    jitterBufferTarget: DOMHighResTimeStamp | null;
    /**
     * The **`track`** read-only property of the RTCRtpReceiver interface returns the MediaStreamTrack associated with the current RTCRtpReceiver instance.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCRtpReceiver/track)
     */
    readonly track: MediaStreamTrack;
    /**
     * The **`transform`** property of the RTCRtpReceiver object is used to insert a transform stream (TransformStream) running in a worker thread into the receiver pipeline. This allows stream transforms to be applied to encoded video and audio frames as they arrive from the packetizer (before they are played/rendered).
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCRtpReceiver/transform)
     */
    transform: RTCRtpReceiverTransform | null;
    /**
     * The read-only **`transport`** property of an RTCRtpReceiver object provides the RTCDtlsTransport object used to interact with the underlying transport over which the receiver is exchanging Real-time Transport Control Protocol (RTCP) packets.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCRtpReceiver/transport)
     */
    readonly transport: RTCDtlsTransport | null;
    /**
     * The **`getContributingSources()`** method of the RTCRtpReceiver interface returns an array of objects, each corresponding to one CSRC (contributing source) identifier received by the current RTCRtpReceiver in the last ten seconds.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCRtpReceiver/getContributingSources)
     */
    getContributingSources(): RTCRtpContributingSource[];
    /**
     * The **`getParameters()`** method of the RTCRtpReceiver interface returns an object describing the current configuration for how the receiver's track is decoded.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCRtpReceiver/getParameters)
     */
    getParameters(): RTCRtpReceiveParameters;
    /**
     * The RTCRtpReceiver method **`getStats()`** asynchronously requests an RTCStatsReport object which provides statistics about incoming traffic on the owning RTCPeerConnection, returning a Promise whose fulfillment handler will be called once the results are available.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCRtpReceiver/getStats)
     */
    getStats(): Promise<RTCStatsReport>;
    /**
     * The **`getSynchronizationSources()`** method of the RTCRtpReceiver interface returns an array of objects, each corresponding to one SSRC (synchronization source) identifier received by the current RTCRtpReceiver in the last ten seconds.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCRtpReceiver/getSynchronizationSources)
     */
    getSynchronizationSources(): RTCRtpSynchronizationSource[];
}

declare var RTCRtpReceiver: {
    prototype: RTCRtpReceiver;
    new(): RTCRtpReceiver;
    /**
     * The static method **`RTCRtpReceiver.getCapabilities()`** returns an object describing the codec and header extension capabilities supported by RTCRtpReceiver objects on the current device.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCRtpReceiver/getCapabilities_static)
     */
    getCapabilities(kind: string): RTCRtpCapabilities | null;
};

/**
 * The **`RTCRtpScriptTransform`** interface of the WebRTC API is used to insert a WebRTC Encoded Transform (a TransformStream running in a worker thread) into the WebRTC sender and receiver pipelines.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCRtpScriptTransform)
 */
interface RTCRtpScriptTransform {
}

declare var RTCRtpScriptTransform: {
    prototype: RTCRtpScriptTransform;
    new(worker: Worker, options?: any, transfer?: any[]): RTCRtpScriptTransform;
};

/**
 * The **`RTCRtpSender`** interface provides the ability to control and obtain details about how a particular MediaStreamTrack is encoded and sent to a remote peer.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCRtpSender)
 */
interface RTCRtpSender {
    /**
     * The read-only **`dtmf`** property on the RTCRtpSender interface returns a RTCDTMFSender object which can be used to send DTMF tones over the RTCPeerConnection. See Using DTMF for details on how to make use of the returned RTCDTMFSender object.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCRtpSender/dtmf)
     */
    readonly dtmf: RTCDTMFSender | null;
    /**
     * The **`track`** read-only property of the RTCRtpSender interface returns the MediaStreamTrack which is being handled by the RTCRtpSender.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCRtpSender/track)
     */
    readonly track: MediaStreamTrack | null;
    /**
     * The **`transform`** property of the RTCRtpSender object is used to insert a transform stream (TransformStream) running in a worker thread into the sender pipeline. This allows stream transforms to be applied to encoded video and audio frames after they are output by a codec, and before they are sent.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCRtpSender/transform)
     */
    transform: RTCRtpSenderTransform | null;
    /**
     * The read-only **`transport`** property of an RTCRtpSender object provides the RTCDtlsTransport object used to interact with the underlying transport over which the sender is exchanging Real-time Transport Control Protocol (RTCP) packets.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCRtpSender/transport)
     */
    readonly transport: RTCDtlsTransport | null;
    /**
     * The **`getParameters()`** method of the RTCRtpSender interface returns an object describing the current configuration for how the sender's track will be encoded and transmitted to a remote RTCRtpReceiver.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCRtpSender/getParameters)
     */
    getParameters(): RTCRtpSendParameters;
    /**
     * The RTCRtpSender method **`getStats()`** asynchronously requests an RTCStatsReport object which provides statistics about outgoing traffic on the RTCPeerConnection which owns the sender, returning a Promise which is fulfilled when the results are available.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCRtpSender/getStats)
     */
    getStats(): Promise<RTCStatsReport>;
    /**
     * The RTCRtpSender method **`replaceTrack()`** replaces the track currently being used as the sender's source with a new MediaStreamTrack.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCRtpSender/replaceTrack)
     */
    replaceTrack(withTrack: MediaStreamTrack | null): Promise<void>;
    /**
     * The **`setParameters()`** method of the RTCRtpSender interface applies changes the configuration of sender's track, which is the MediaStreamTrack for which the RTCRtpSender is responsible.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCRtpSender/setParameters)
     */
    setParameters(parameters: RTCRtpSendParameters, setParameterOptions?: RTCSetParameterOptions): Promise<void>;
    /**
     * The RTCRtpSender method **`setStreams()`** associates the sender's track with the specified MediaStream objects.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCRtpSender/setStreams)
     */
    setStreams(...streams: MediaStream[]): void;
}

declare var RTCRtpSender: {
    prototype: RTCRtpSender;
    new(): RTCRtpSender;
    /**
     * The static method **`RTCRtpSender.getCapabilities()`** returns an object describing the codec and header extension capabilities supported by the RTCRtpSender.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCRtpSender/getCapabilities_static)
     */
    getCapabilities(kind: string): RTCRtpCapabilities | null;
};

/**
 * The WebRTC interface **`RTCRtpTransceiver`** describes a permanent pairing of an RTCRtpSender and an RTCRtpReceiver, along with some shared state.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCRtpTransceiver)
 */
interface RTCRtpTransceiver {
    /**
     * The read-only RTCRtpTransceiver property **`currentDirection`** is a string which indicates the current negotiated directionality of the transceiver.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCRtpTransceiver/currentDirection)
     */
    readonly currentDirection: RTCRtpTransceiverDirection | null;
    /**
     * The RTCRtpTransceiver property **`direction`** is a string that indicates the transceiver's preferred directionality.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCRtpTransceiver/direction)
     */
    direction: RTCRtpTransceiverDirection;
    /**
     * The read-only RTCRtpTransceiver interface's **`mid`** property specifies the negotiated media ID (mid) which the local and remote peers have agreed upon to uniquely identify the stream's pairing of sender and receiver.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCRtpTransceiver/mid)
     */
    readonly mid: string | null;
    /**
     * The read-only **`receiver`** property of WebRTC's RTCRtpTransceiver interface indicates the RTCRtpReceiver responsible for receiving and decoding incoming media data for the transceiver's stream.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCRtpTransceiver/receiver)
     */
    readonly receiver: RTCRtpReceiver;
    /**
     * The read-only **`sender`** property of WebRTC's RTCRtpTransceiver interface indicates the RTCRtpSender responsible for encoding and sending outgoing media data for the transceiver's stream.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCRtpTransceiver/sender)
     */
    readonly sender: RTCRtpSender;
    /**
     * The **`setCodecPreferences()`** method of the RTCRtpTransceiver interface is used to set the codecs that the transceiver allows for decoding received data, in order of decreasing preference.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCRtpTransceiver/setCodecPreferences)
     */
    setCodecPreferences(codecs: RTCRtpCodec[]): void;
    /**
     * The **`stop()`** method in the RTCRtpTransceiver interface permanently stops the transceiver by stopping both the associated RTCRtpSender and RTCRtpReceiver.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCRtpTransceiver/stop)
     */
    stop(): void;
}

declare var RTCRtpTransceiver: {
    prototype: RTCRtpTransceiver;
    new(): RTCRtpTransceiver;
};

interface RTCSctpTransportEventMap {
    "statechange": Event;
}

/**
 * The **`RTCSctpTransport`** interface provides information which describes a Stream Control Transmission Protocol (SCTP) transport. This provides information about limitations of the transport, but also provides a way to access the underlying Datagram Transport Layer Security (DTLS) transport over which SCTP packets for all of an RTCPeerConnection's data channels are sent and received.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCSctpTransport)
 */
interface RTCSctpTransport extends EventTarget {
    /**
     * The **`maxChannels`** read-only property of the RTCSctpTransport interface indicates the maximum number of RTCDataChannel objects that can be opened simultaneously.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCSctpTransport/maxChannels)
     */
    readonly maxChannels: number | null;
    /**
     * The **`maxMessageSize`** read-only property of the RTCSctpTransport interface indicates the maximum size of a message that can be sent using the RTCDataChannel.send() method.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCSctpTransport/maxMessageSize)
     */
    readonly maxMessageSize: number;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCSctpTransport/statechange_event) */
    onstatechange: ((this: RTCSctpTransport, ev: Event) => any) | null;
    /**
     * The **`state`** read-only property of the RTCSctpTransport interface provides information which describes a Stream Control Transmission Protocol (SCTP) transport state.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCSctpTransport/state)
     */
    readonly state: RTCSctpTransportState;
    /**
     * The **`transport`** read-only property of the RTCSctpTransport interface returns a RTCDtlsTransport object representing the DTLS transport used for the transmission and receipt of data packets.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCSctpTransport/transport)
     */
    readonly transport: RTCDtlsTransport;
    addEventListener<K extends keyof RTCSctpTransportEventMap>(type: K, listener: (this: RTCSctpTransport, ev: RTCSctpTransportEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof RTCSctpTransportEventMap>(type: K, listener: (this: RTCSctpTransport, ev: RTCSctpTransportEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var RTCSctpTransport: {
    prototype: RTCSctpTransport;
    new(): RTCSctpTransport;
};

/**
 * The **`RTCSessionDescription`** interface describes one end of a connection—or potential connection—and how it's configured. Each RTCSessionDescription consists of a description type indicating which part of the offer/answer negotiation process it describes and of the SDP descriptor of the session.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCSessionDescription)
 */
interface RTCSessionDescription {
    /**
     * The property **`RTCSessionDescription.sdp`** is a read-only string containing the SDP which describes the session.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCSessionDescription/sdp)
     */
    readonly sdp: string;
    /**
     * The property **`RTCSessionDescription.type`** is a read-only string value which describes the description's type.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCSessionDescription/type)
     */
    readonly type: RTCSdpType;
    /**
     * The **`RTCSessionDescription.toJSON()`** method generates a JSON description of the object. Both properties, type and sdp, are contained in the generated JSON.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCSessionDescription/toJSON)
     */
    toJSON(): RTCSessionDescriptionInit;
}

declare var RTCSessionDescription: {
    prototype: RTCSessionDescription;
    new(descriptionInitDict: RTCSessionDescriptionInit): RTCSessionDescription;
};

/**
 * The **`RTCStatsReport`** interface of the WebRTC API provides a statistics report for a RTCPeerConnection, RTCRtpSender, or RTCRtpReceiver.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCStatsReport)
 */
interface RTCStatsReport {
    forEach(callbackfn: (value: any, key: string, parent: RTCStatsReport) => void, thisArg?: any): void;
}

declare var RTCStatsReport: {
    prototype: RTCStatsReport;
    new(): RTCStatsReport;
};

/**
 * The WebRTC API interface **`RTCTrackEvent`** represents the track event, which is sent when a new MediaStreamTrack is added to an RTCRtpReceiver which is part of the RTCPeerConnection.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCTrackEvent)
 */
interface RTCTrackEvent extends Event {
    /**
     * The read-only **`receiver`** property of the RTCTrackEvent interface indicates the RTCRtpReceiver which is used to receive data containing media for the track to which the event refers.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCTrackEvent/receiver)
     */
    readonly receiver: RTCRtpReceiver;
    /**
     * The WebRTC API interface RTCTrackEvent's read-only **`streams`** property specifies an array of MediaStream objects, one for each of the streams that comprise the track being added to the RTCPeerConnection.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCTrackEvent/streams)
     */
    readonly streams: ReadonlyArray<MediaStream>;
    /**
     * The WebRTC API interface RTCTrackEvent's read-only **`track`** property specifies the MediaStreamTrack that has been added to the RTCPeerConnection.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCTrackEvent/track)
     */
    readonly track: MediaStreamTrack;
    /**
     * The WebRTC API interface RTCTrackEvent's read-only **`transceiver`** property indicates the RTCRtpTransceiver affiliated with the event's track.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCTrackEvent/transceiver)
     */
    readonly transceiver: RTCRtpTransceiver;
}

declare var RTCTrackEvent: {
    prototype: RTCTrackEvent;
    new(type: string, eventInitDict: RTCTrackEventInit): RTCTrackEvent;
};

/**
 * The **`RadioNodeList`** interface represents a collection of elements in a <form> returned by a call to HTMLFormControlsCollection.namedItem().
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RadioNodeList)
 */
interface RadioNodeList extends NodeListOf<HTMLInputElement> {
    /**
     * If the underlying element collection contains radio buttons, the **`RadioNodeList.value`** property represents the checked radio button. On retrieving the value property, the value of the currently checked radio button is returned as a string. If the collection does not contain any radio buttons or none of the radio buttons in the collection is in checked state, the empty string is returned. On setting the value property, the first radio button input element whose value property is equal to the new value will be set to checked.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RadioNodeList/value)
     */
    value: string;
}

declare var RadioNodeList: {
    prototype: RadioNodeList;
    new(): RadioNodeList;
};

/**
 * The **`Range`** interface represents a fragment of a document that can contain nodes and parts of text nodes.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Range)
 */
interface Range extends AbstractRange {
    /**
     * The **`Range.commonAncestorContainer`** read-only property returns the deepest — or furthest down the document tree — Node that contains both boundary points of the Range. This means that if startContainer and endContainer both refer to the same node, this node is the common ancestor container.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Range/commonAncestorContainer)
     */
    readonly commonAncestorContainer: Node;
    /**
     * The **`cloneContents()`** method of the Range interface copies the selected Node children of the range's commonAncestorContainer and puts them in a new DocumentFragment object.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Range/cloneContents)
     */
    cloneContents(): DocumentFragment;
    /**
     * The **`Range.cloneRange()`** method returns a Range object with boundary points identical to the cloned Range.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Range/cloneRange)
     */
    cloneRange(): Range;
    /**
     * The **`collapse()`** method of the Range interface collapses the Range to one of its boundary points.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Range/collapse)
     */
    collapse(toStart?: boolean): void;
    /**
     * The **`compareBoundaryPoints()`** method of the Range interface compares the boundary points of the Range with those of another range.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Range/compareBoundaryPoints)
     */
    compareBoundaryPoints(how: number, sourceRange: Range): number;
    /**
     * The **`comparePoint()`** method of the Range interface determines whether a specified point is before, within, or after the Range. The point is specified by a reference node and an offset within that node.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Range/comparePoint)
     */
    comparePoint(node: Node, offset: number): number;
    /**
     * The **`Range.createContextualFragment()`** method of the Range interface returns a DocumentFragment representing the parsed input HTML or XML.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Range/createContextualFragment)
     */
    createContextualFragment(string: string): DocumentFragment;
    /**
     * The **`Range.deleteContents()`** method removes all completely-selected nodes within this range from the document. For the partially selected nodes at the start or end of the range, only the selected portion of the text is deleted, while the node itself remains intact. Afterwards, the range is collapsed to the end of the last selected node.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Range/deleteContents)
     */
    deleteContents(): void;
    /**
     * The **`Range.detach()`** method does nothing. It used to disable the Range object and enable the browser to release associated resources. The method has been kept for compatibility.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Range/detach)
     */
    detach(): void;
    /**
     * The **`extractContents()`** method of the Range interface is similar to a combination of Range.cloneContents() and Range.deleteContents(). It removes the child Nodes of the range from the document, clones them, and returns them as a new DocumentFragment object. For partially selected nodes, only the selected text is deleted, but all containing parent nodes up to the common ancestor are cloned as well, resulting in two copies of these nodes, one in the original document and one in the extracted fragment.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Range/extractContents)
     */
    extractContents(): DocumentFragment;
    /**
     * The **`Range.getBoundingClientRect()`** method returns a DOMRect object that bounds the contents of the range; this is a rectangle enclosing the union of the bounding rectangles for all the elements in the range.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Range/getBoundingClientRect)
     */
    getBoundingClientRect(): DOMRect;
    /**
     * The **`Range.getClientRects()`** method returns a list of DOMRect objects representing the area of the screen occupied by the range. This is created by aggregating the results of calls to Element.getClientRects() for all the elements in the range.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Range/getClientRects)
     */
    getClientRects(): DOMRectList;
    /**
     * The **`Range.insertNode()`** method inserts a node at the start of the Range.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Range/insertNode)
     */
    insertNode(node: Node): void;
    /**
     * The **`Range.intersectsNode()`** method returns a boolean indicating whether the given Node intersects the Range.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Range/intersectsNode)
     */
    intersectsNode(node: Node): boolean;
    /**
     * The **`isPointInRange()`** method of the Range interface determines whether a specified point is within the Range. The point is specified by a reference node and an offset within that node. It is equivalent to calling Range.comparePoint() and checking if the result is 0.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Range/isPointInRange)
     */
    isPointInRange(node: Node, offset: number): boolean;
    /**
     * The **`Range.selectNode()`** method sets the Range to contain the Node and its contents. The parent Node of the start and end of the Range will be the same as the parent of the referenceNode.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Range/selectNode)
     */
    selectNode(node: Node): void;
    /**
     * The **`Range.selectNodeContents()`** method sets the Range to contain the contents of a Node.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Range/selectNodeContents)
     */
    selectNodeContents(node: Node): void;
    /**
     * The **`Range.setEnd()`** method sets the end position of a Range to be located at the given offset into the specified node. Setting the end point above (higher in the document) than the start point will result in a collapsed range with the start and end points both set to the specified end position.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Range/setEnd)
     */
    setEnd(node: Node, offset: number): void;
    /**
     * The **`Range.setEndAfter()`** method sets the end position of a Range relative to another Node. The parent Node of end of the Range will be the same as that for the referenceNode.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Range/setEndAfter)
     */
    setEndAfter(node: Node): void;
    /**
     * The **`Range.setEndBefore()`** method sets the end position of a Range relative to another Node. The parent Node of end of the Range will be the same as that for the referenceNode.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Range/setEndBefore)
     */
    setEndBefore(node: Node): void;
    /**
     * The **`Range.setStart()`** method sets the start position of a Range.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Range/setStart)
     */
    setStart(node: Node, offset: number): void;
    /**
     * The **`Range.setStartAfter()`** method sets the start position of a Range relative to a Node. The parent Node of the start of the Range will be the same as that for the referenceNode.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Range/setStartAfter)
     */
    setStartAfter(node: Node): void;
    /**
     * The **`Range.setStartBefore()`** method sets the start position of a Range relative to another Node. The parent Node of the start of the Range will be the same as that for the referenceNode.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Range/setStartBefore)
     */
    setStartBefore(node: Node): void;
    /**
     * The **`surroundContents()`** method of the Range interface surrounds the selected content by a provided node. It extracts the contents of the range, replaces the children of newParent with the extracted contents, inserts newParent at the location of the extracted contents, and makes the range select newParent.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Range/surroundContents)
     */
    surroundContents(newParent: Node): void;
    toString(): string;
    readonly START_TO_START: 0;
    readonly START_TO_END: 1;
    readonly END_TO_END: 2;
    readonly END_TO_START: 3;
}

declare var Range: {
    prototype: Range;
    new(): Range;
    readonly START_TO_START: 0;
    readonly START_TO_END: 1;
    readonly END_TO_END: 2;
    readonly END_TO_START: 3;
};

/**
 * The **`ReadableByteStreamController`** interface of the Streams API represents a controller for a readable byte stream. It allows control of the state and internal queue of a ReadableStream with an underlying byte source, and enables efficient zero-copy transfer of data from the underlying source to a consumer when the stream's internal queue is empty.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ReadableByteStreamController)
 */
interface ReadableByteStreamController {
    /**
     * The **`byobRequest`** read-only property of the ReadableByteStreamController interface returns the current BYOB request, or null if there are no pending requests.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ReadableByteStreamController/byobRequest)
     */
    readonly byobRequest: ReadableStreamBYOBRequest | null;
    /**
     * The **`desiredSize`** read-only property of the ReadableByteStreamController interface returns the number of bytes required to fill the stream's internal queue to its "desired size".
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ReadableByteStreamController/desiredSize)
     */
    readonly desiredSize: number | null;
    /**
     * The **`close()`** method of the ReadableByteStreamController interface closes the associated stream.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ReadableByteStreamController/close)
     */
    close(): void;
    /**
     * The **`enqueue()`** method of the ReadableByteStreamController interface enqueues a given chunk on the associated readable byte stream (the chunk is transferred into the stream's internal queues).
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ReadableByteStreamController/enqueue)
     */
    enqueue(chunk: ArrayBufferView<ArrayBuffer>): void;
    /**
     * The **`error()`** method of the ReadableByteStreamController interface causes any future interactions with the associated stream to error with the specified reason.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ReadableByteStreamController/error)
     */
    error(e?: any): void;
}

declare var ReadableByteStreamController: {
    prototype: ReadableByteStreamController;
    new(): ReadableByteStreamController;
};

/**
 * The **`ReadableStream`** interface of the Streams API represents a readable stream of byte data. The Fetch API offers a concrete instance of a ReadableStream through the body property of a Response object.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ReadableStream)
 */
interface ReadableStream<R = any> {
    /**
     * The **`locked`** read-only property of the ReadableStream interface returns whether or not the readable stream is locked to a reader.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ReadableStream/locked)
     */
    readonly locked: boolean;
    /**
     * The **`cancel()`** method of the ReadableStream interface returns a Promise that resolves when the stream is canceled.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ReadableStream/cancel)
     */
    cancel(reason?: any): Promise<void>;
    /**
     * The **`getReader()`** method of the ReadableStream interface creates a reader and locks the stream to it. While the stream is locked, no other reader can be acquired until this one is released.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ReadableStream/getReader)
     */
    getReader(options: { mode: "byob" }): ReadableStreamBYOBReader;
    getReader(): ReadableStreamDefaultReader<R>;
    getReader(options?: ReadableStreamGetReaderOptions): ReadableStreamReader<R>;
    /**
     * The **`pipeThrough()`** method of the ReadableStream interface provides a chainable way of piping the current stream through a transform stream or any other writable/readable pair.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ReadableStream/pipeThrough)
     */
    pipeThrough<T>(transform: ReadableWritablePair<T, R>, options?: StreamPipeOptions): ReadableStream<T>;
    /**
     * The **`pipeTo()`** method of the ReadableStream interface pipes the current ReadableStream to a given WritableStream and returns a Promise that fulfills when the piping process completes successfully, or rejects if any errors were encountered.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ReadableStream/pipeTo)
     */
    pipeTo(destination: WritableStream<R>, options?: StreamPipeOptions): Promise<void>;
    /**
     * The **`tee()`** method of the ReadableStream interface tees the current readable stream, returning a two-element array containing the two resulting branches as new ReadableStream instances.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ReadableStream/tee)
     */
    tee(): [ReadableStream<R>, ReadableStream<R>];
}

declare var ReadableStream: {
    prototype: ReadableStream;
    new(underlyingSource: UnderlyingByteSource, strategy?: { highWaterMark?: number }): ReadableStream<Uint8Array<ArrayBuffer>>;
    new<R = any>(underlyingSource: UnderlyingDefaultSource<R>, strategy?: QueuingStrategy<R>): ReadableStream<R>;
    new<R = any>(underlyingSource?: UnderlyingSource<R>, strategy?: QueuingStrategy<R>): ReadableStream<R>;
};

/**
 * The **`ReadableStreamBYOBReader`** interface of the Streams API defines a reader for a ReadableStream that supports zero-copy reading from an underlying byte source. It is used for efficient copying from underlying sources where the data is delivered as an "anonymous" sequence of bytes, such as files.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ReadableStreamBYOBReader)
 */
interface ReadableStreamBYOBReader extends ReadableStreamGenericReader {
    /**
     * The **`read()`** method of the ReadableStreamBYOBReader interface is used to read data into a view on a user-supplied buffer from an associated readable byte stream. A request for data will be satisfied from the stream's internal queues if there is any data present. If the stream queues are empty, the request may be supplied as a zero-copy transfer from the underlying byte source.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ReadableStreamBYOBReader/read)
     */
    read<T extends Exclude<BufferSource, ArrayBuffer>>(view: T, options?: ReadableStreamBYOBReaderReadOptions): Promise<ReadableStreamReadResult<T>>;
    /**
     * The **`releaseLock()`** method of the ReadableStreamBYOBReader interface releases the reader's lock on the stream. After the lock is released, the reader is no longer active.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ReadableStreamBYOBReader/releaseLock)
     */
    releaseLock(): void;
}

declare var ReadableStreamBYOBReader: {
    prototype: ReadableStreamBYOBReader;
    new(stream: ReadableStream<Uint8Array<ArrayBuffer>>): ReadableStreamBYOBReader;
};

/**
 * The **`ReadableStreamBYOBRequest`** interface of the Streams API represents a "pull request" for data from an underlying source that will made as a zero-copy transfer to a consumer (bypassing the stream's internal queues).
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ReadableStreamBYOBRequest)
 */
interface ReadableStreamBYOBRequest {
    /**
     * The **`view`** getter property of the ReadableStreamBYOBRequest interface returns the current view.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ReadableStreamBYOBRequest/view)
     */
    readonly view: ArrayBufferView<ArrayBuffer> | null;
    /**
     * The **`respond()`** method of the ReadableStreamBYOBRequest interface is used to signal to the associated readable byte stream that the specified number of bytes were written into the ReadableStreamBYOBRequest.view.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ReadableStreamBYOBRequest/respond)
     */
    respond(bytesWritten: number): void;
    /**
     * The **`respondWithNewView()`** method of the ReadableStreamBYOBRequest interface specifies a new view that the consumer of the associated readable byte stream should write to instead of ReadableStreamBYOBRequest.view.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ReadableStreamBYOBRequest/respondWithNewView)
     */
    respondWithNewView(view: ArrayBufferView<ArrayBuffer>): void;
}

declare var ReadableStreamBYOBRequest: {
    prototype: ReadableStreamBYOBRequest;
    new(): ReadableStreamBYOBRequest;
};

/**
 * The **`ReadableStreamDefaultController`** interface of the Streams API represents a controller allowing control of a ReadableStream's state and internal queue. Default controllers are for streams that are not byte streams.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ReadableStreamDefaultController)
 */
interface ReadableStreamDefaultController<R = any> {
    /**
     * The **`desiredSize`** read-only property of the ReadableStreamDefaultController interface returns the desired size required to fill the stream's internal queue.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ReadableStreamDefaultController/desiredSize)
     */
    readonly desiredSize: number | null;
    /**
     * The **`close()`** method of the ReadableStreamDefaultController interface closes the associated stream.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ReadableStreamDefaultController/close)
     */
    close(): void;
    /**
     * The **`enqueue()`** method of the ReadableStreamDefaultController interface enqueues a given chunk in the associated stream.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ReadableStreamDefaultController/enqueue)
     */
    enqueue(chunk: R): void;
    /**
     * The **`error()`** method of the ReadableStreamDefaultController interface causes any future interactions with the associated stream to error.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ReadableStreamDefaultController/error)
     */
    error(e?: any): void;
}

declare var ReadableStreamDefaultController: {
    prototype: ReadableStreamDefaultController;
    new(): ReadableStreamDefaultController;
};

/**
 * The **`ReadableStreamDefaultReader`** interface of the Streams API represents a default reader that can be used to read stream data supplied from a network (such as a fetch request).
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ReadableStreamDefaultReader)
 */
interface ReadableStreamDefaultReader<R = any> extends ReadableStreamGenericReader {
    /**
     * The **`read()`** method of the ReadableStreamDefaultReader interface returns a Promise providing access to the next chunk in the stream's internal queue.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ReadableStreamDefaultReader/read)
     */
    read(): Promise<ReadableStreamReadResult<R>>;
    /**
     * The **`releaseLock()`** method of the ReadableStreamDefaultReader interface releases the reader's lock on the stream.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ReadableStreamDefaultReader/releaseLock)
     */
    releaseLock(): void;
}

declare var ReadableStreamDefaultReader: {
    prototype: ReadableStreamDefaultReader;
    new<R = any>(stream: ReadableStream<R>): ReadableStreamDefaultReader<R>;
};

interface ReadableStreamGenericReader {
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/ReadableStreamBYOBReader/closed) */
    readonly closed: Promise<void>;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/ReadableStreamBYOBReader/cancel) */
    cancel(reason?: any): Promise<void>;
}

interface RemotePlaybackEventMap {
    "connect": Event;
    "connecting": Event;
    "disconnect": Event;
}

/**
 * The **`RemotePlayback`** interface of the Remote Playback API allows the page to detect availability of remote playback devices, then connect to and control playing on these devices.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RemotePlayback)
 */
interface RemotePlayback extends EventTarget {
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/RemotePlayback/connect_event) */
    onconnect: ((this: RemotePlayback, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/RemotePlayback/connecting_event) */
    onconnecting: ((this: RemotePlayback, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/RemotePlayback/disconnect_event) */
    ondisconnect: ((this: RemotePlayback, ev: Event) => any) | null;
    /**
     * The **`state`** read-only property of the RemotePlayback interface returns the current state of the RemotePlayback connection.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RemotePlayback/state)
     */
    readonly state: RemotePlaybackState;
    /**
     * The **`cancelWatchAvailability()`** method of the RemotePlayback interface cancels the request to watch for one or all available devices.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RemotePlayback/cancelWatchAvailability)
     */
    cancelWatchAvailability(id?: number): Promise<void>;
    /**
     * The **`prompt()`** method of the RemotePlayback interface prompts the user to select an available remote playback device and give permission for the current media to be played using that device.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RemotePlayback/prompt)
     */
    prompt(): Promise<void>;
    /**
     * The **`watchAvailability()`** method of the RemotePlayback interface watches the list of available remote playback devices and returns a Promise that resolves with the callbackId of a remote playback device.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RemotePlayback/watchAvailability)
     */
    watchAvailability(callback: RemotePlaybackAvailabilityCallback): Promise<number>;
    addEventListener<K extends keyof RemotePlaybackEventMap>(type: K, listener: (this: RemotePlayback, ev: RemotePlaybackEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof RemotePlaybackEventMap>(type: K, listener: (this: RemotePlayback, ev: RemotePlaybackEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var RemotePlayback: {
    prototype: RemotePlayback;
    new(): RemotePlayback;
};

/**
 * The **`ReportingObserver`** interface of the Reporting API allows you to collect and access reports.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ReportingObserver)
 */
interface ReportingObserver {
    /**
     * The **`disconnect()`** method of the ReportingObserver interface stops a reporting observer that had previously started observing from collecting reports.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ReportingObserver/disconnect)
     */
    disconnect(): void;
    /**
     * The **`observe()`** method of the ReportingObserver interface instructs a reporting observer to start collecting reports in its report queue.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ReportingObserver/observe)
     */
    observe(): void;
    /**
     * The **`takeRecords()`** method of the ReportingObserver interface returns the current list of reports contained in the observer's report queue, and empties the queue.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ReportingObserver/takeRecords)
     */
    takeRecords(): ReportList;
}

declare var ReportingObserver: {
    prototype: ReportingObserver;
    new(callback: ReportingObserverCallback, options?: ReportingObserverOptions): ReportingObserver;
};

/**
 * The **`Request`** interface of the Fetch API represents a resource request.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Request)
 */
interface Request extends Body {
    /**
     * The **`cache`** read-only property of the Request interface contains the cache mode of the request. It controls how the request will interact with the browser's HTTP cache.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Request/cache)
     */
    readonly cache: RequestCache;
    /**
     * The **`credentials`** read-only property of the Request interface reflects the value given to the Request() constructor in the credentials option. It determines whether or not the browser sends credentials with the request, as well as whether any Set-Cookie response headers are respected.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Request/credentials)
     */
    readonly credentials: RequestCredentials;
    /**
     * The **`destination`** read-only property of the Request interface returns a string describing the type of content being requested.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Request/destination)
     */
    readonly destination: RequestDestination;
    /**
     * The **`headers`** read-only property of the Request interface contains the Headers object associated with the request.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Request/headers)
     */
    readonly headers: Headers;
    /**
     * The **`integrity`** read-only property of the Request interface contains the subresource integrity value of the request.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Request/integrity)
     */
    readonly integrity: string;
    /**
     * The **`keepalive`** read-only property of the Request interface contains the request's keepalive setting (true or false), which indicates whether the browser will keep the associated request alive if the page that initiated it is unloaded before the request is complete.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Request/keepalive)
     */
    readonly keepalive: boolean;
    /**
     * The **`method`** read-only property of the Request interface contains the request's method (GET, POST, etc.)
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Request/method)
     */
    readonly method: string;
    /**
     * The **`mode`** read-only property of the Request interface contains the mode of the request (e.g., cors, no-cors, same-origin, or navigate.) This is used to determine if cross-origin requests lead to valid responses, and which properties of the response are readable.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Request/mode)
     */
    readonly mode: RequestMode;
    /**
     * The **`redirect`** read-only property of the Request interface contains the mode for how redirects are handled.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Request/redirect)
     */
    readonly redirect: RequestRedirect;
    /**
     * The **`referrer`** read-only property of the Request interface is set by the user agent to be the referrer of the Request. (e.g., client, no-referrer, or a URL.)
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Request/referrer)
     */
    readonly referrer: string;
    /**
     * The **`referrerPolicy`** read-only property of the Request interface returns the referrer policy, which governs what referrer information, sent in the Referer header, should be included with the request.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Request/referrerPolicy)
     */
    readonly referrerPolicy: ReferrerPolicy;
    /**
     * The read-only **`signal`** property of the Request interface returns the AbortSignal associated with the request.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Request/signal)
     */
    readonly signal: AbortSignal;
    /**
     * The **`url`** read-only property of the Request interface contains the URL of the request.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Request/url)
     */
    readonly url: string;
    /**
     * The **`clone()`** method of the Request interface creates a copy of the current Request object.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Request/clone)
     */
    clone(): Request;
}

declare var Request: {
    prototype: Request;
    new(input: RequestInfo | URL, init?: RequestInit): Request;
};

/**
 * The **`ResizeObserver`** interface reports changes to the dimensions of an Element's content or border box, or the bounding box of an SVGElement.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ResizeObserver)
 */
interface ResizeObserver {
    /**
     * The **`disconnect()`** method of the ResizeObserver interface unobserves all observed Element or SVGElement targets.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ResizeObserver/disconnect)
     */
    disconnect(): void;
    /**
     * The **`observe()`** method of the ResizeObserver interface starts observing the specified Element or SVGElement.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ResizeObserver/observe)
     */
    observe(target: Element, options?: ResizeObserverOptions): void;
    /**
     * The **`unobserve()`** method of the ResizeObserver interface ends the observing of a specified Element or SVGElement.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ResizeObserver/unobserve)
     */
    unobserve(target: Element): void;
}

declare var ResizeObserver: {
    prototype: ResizeObserver;
    new(callback: ResizeObserverCallback): ResizeObserver;
};

/**
 * The **`ResizeObserverEntry`** interface represents the object passed to the ResizeObserver() constructor's callback function, which allows you to access the new dimensions of the Element or SVGElement being observed.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ResizeObserverEntry)
 */
interface ResizeObserverEntry {
    /**
     * The **`borderBoxSize`** read-only property of the ResizeObserverEntry interface returns an array containing the new border box size of the observed element when the callback is run.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ResizeObserverEntry/borderBoxSize)
     */
    readonly borderBoxSize: ReadonlyArray<ResizeObserverSize>;
    /**
     * The **`contentBoxSize`** read-only property of the ResizeObserverEntry interface returns an array containing the new content box size of the observed element when the callback is run.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ResizeObserverEntry/contentBoxSize)
     */
    readonly contentBoxSize: ReadonlyArray<ResizeObserverSize>;
    /**
     * The **`contentRect`** read-only property of the ResizeObserverEntry interface returns a DOMRectReadOnly object containing the new size of the observed element when the callback is run. Note that this is better supported than ResizeObserverEntry.borderBoxSize or ResizeObserverEntry.contentBoxSize, but it is left over from an earlier implementation of the Resize Observer API, is still included in the spec for web compat reasons, and may be deprecated in future versions.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ResizeObserverEntry/contentRect)
     */
    readonly contentRect: DOMRectReadOnly;
    /**
     * The **`devicePixelContentBoxSize`** read-only property of the ResizeObserverEntry interface returns an array containing the size in device pixels of the observed element when the callback is run.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ResizeObserverEntry/devicePixelContentBoxSize)
     */
    readonly devicePixelContentBoxSize: ReadonlyArray<ResizeObserverSize>;
    /**
     * The **`target`** read-only property of the ResizeObserverEntry interface returns a reference to the Element or SVGElement that is being observed.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ResizeObserverEntry/target)
     */
    readonly target: Element;
}

declare var ResizeObserverEntry: {
    prototype: ResizeObserverEntry;
    new(): ResizeObserverEntry;
};

/**
 * The **`ResizeObserverSize`** interface of the Resize Observer API is used by the ResizeObserverEntry interface to access the box sizing properties of the element being observed.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ResizeObserverSize)
 */
interface ResizeObserverSize {
    /**
     * The **`blockSize`** read-only property of the ResizeObserverSize interface returns the length of the observed element's border box in the block dimension. For boxes with a horizontal writing-mode, this is the vertical dimension, or height; if the writing-mode is vertical, this is the horizontal dimension, or width.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ResizeObserverSize/blockSize)
     */
    readonly blockSize: number;
    /**
     * The **`inlineSize`** read-only property of the ResizeObserverSize interface returns the length of the observed element's border box in the inline dimension. For boxes with a horizontal writing-mode, this is the horizontal dimension, or width; if the writing-mode is vertical, this is the vertical dimension, or height.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ResizeObserverSize/inlineSize)
     */
    readonly inlineSize: number;
}

declare var ResizeObserverSize: {
    prototype: ResizeObserverSize;
    new(): ResizeObserverSize;
};

/**
 * The **`Response`** interface of the Fetch API represents the response to a request.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Response)
 */
interface Response extends Body {
    /**
     * The **`headers`** read-only property of the Response interface contains the Headers object associated with the response.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Response/headers)
     */
    readonly headers: Headers;
    /**
     * The **`ok`** read-only property of the Response interface contains a Boolean stating whether the response was successful (status in the range 200-299) or not.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Response/ok)
     */
    readonly ok: boolean;
    /**
     * The **`redirected`** read-only property of the Response interface indicates whether or not the response is the result of a request you made which was redirected.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Response/redirected)
     */
    readonly redirected: boolean;
    /**
     * The **`status`** read-only property of the Response interface contains the HTTP status codes of the response.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Response/status)
     */
    readonly status: number;
    /**
     * The **`statusText`** read-only property of the Response interface contains the status message corresponding to the HTTP status code in Response.status.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Response/statusText)
     */
    readonly statusText: string;
    /**
     * The **`type`** read-only property of the Response interface contains the type of the response. The type determines whether scripts are able to access the response body and headers.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Response/type)
     */
    readonly type: ResponseType;
    /**
     * The **`url`** read-only property of the Response interface contains the URL of the response. The value of the url property will be the final URL obtained after any redirects.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Response/url)
     */
    readonly url: string;
    /**
     * The **`clone()`** method of the Response interface creates a clone of a response object, identical in every way, but stored in a different variable.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Response/clone)
     */
    clone(): Response;
}

declare var Response: {
    prototype: Response;
    new(body?: BodyInit | null, init?: ResponseInit): Response;
    /**
     * The **`error()`** static method of the Response interface returns a new Response object associated with a network error.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Response/error_static)
     */
    error(): Response;
    /**
     * The **`json()`** static method of the Response interface returns a Response that contains the provided JSON data as body, and a Content-Type header which is set to application/json. The response status, status message, and additional headers can also be set.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Response/json_static)
     */
    json(data: any, init?: ResponseInit): Response;
    /**
     * The **`redirect()`** static method of the Response interface returns a Response resulting in a redirect to the specified URL.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Response/redirect_static)
     */
    redirect(url: string | URL, status?: number): Response;
};

/**
 * The **`SVGAElement`** interface provides access to the properties of an <a> element, as well as methods to manipulate them.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGAElement)
 */
interface SVGAElement extends SVGGraphicsElement, SVGURIReference {
    /**
     * The **`download`** property of the SVGAElement interface returns a string indicating that the browser should treat the linked URL as a download.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGAElement/download)
     */
    download: string;
    /**
     * The **`hreflang`** property of the SVGAElement interface returns a string indicating the language of the linked resource.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGAElement/hreflang)
     */
    hreflang: string;
    /**
     * The **`ping`** property of the SVGAElement interface returns a string that reflects the ping attribute, containing a space-separated list of URLs to which, when the hyperlink is followed, POST requests with the body PING will be sent by the browser (in the background). Typically used for tracking.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGAElement/ping)
     */
    ping: string;
    referrerPolicy: string;
    /**
     * The **`rel`** property of the SVGAElement returns a string reflecting the value of the rel attribute of the SVG <a> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGAElement/rel)
     */
    rel: string;
    /**
     * The read-only **`relList`** property of the SVGAElement returns a live DOMTokenList reflecting the space-separated string <list-of-Link-Types> values of the rel attribute of the SVG <a> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGAElement/relList)
     */
    get relList(): DOMTokenList;
    set relList(value: string);
    /**
     * The **`SVGAElement.target`** read-only property of SVGAElement returns an SVGAnimatedString object that specifies the portion of a target window, frame, pane into which a document is to be opened when a link is activated.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGAElement/target)
     */
    readonly target: SVGAnimatedString;
    /**
     * The **`type`** property of the SVGAElement interface returns a string indicating the MIME type of the linked resource.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGAElement/type)
     */
    type: string;
    addEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGAElement, ev: SVGElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGAElement, ev: SVGElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var SVGAElement: {
    prototype: SVGAElement;
    new(): SVGAElement;
};

/**
 * The **`SVGAngle`** interface is used to represent a value that can be an <angle> or <number> value.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGAngle)
 */
interface SVGAngle {
    /**
     * The **`unitType`** property of the SVGAngle interface is one of the unit type constants and represents the units in which this angle's value is expressed.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGAngle/unitType)
     */
    readonly unitType: number;
    /**
     * The **`value`** property of the SVGAngle interface represents the floating point value of the <angle> in degrees.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGAngle/value)
     */
    value: number;
    /**
     * The **`valueAsString`** property of the SVGAngle interface represents the angle's value as a string, in the units expressed by unitType.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGAngle/valueAsString)
     */
    valueAsString: string;
    /**
     * The **`valueInSpecifiedUnits`** property of the SVGAngle interface represents the value of this angle as a number, in the units expressed by the angle's unitType.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGAngle/valueInSpecifiedUnits)
     */
    valueInSpecifiedUnits: number;
    /**
     * The **`convertToSpecifiedUnits()`** method of the SVGAngle interface allows you to convert the angle's value to the specified unit type.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGAngle/convertToSpecifiedUnits)
     */
    convertToSpecifiedUnits(unitType: number): void;
    /**
     * The **`newValueSpecifiedUnits()`** method of the SVGAngle interface sets the value to a number with an associated unitType, thereby replacing the values for all of the attributes on the object.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGAngle/newValueSpecifiedUnits)
     */
    newValueSpecifiedUnits(unitType: number, valueInSpecifiedUnits: number): void;
    readonly SVG_ANGLETYPE_UNKNOWN: 0;
    readonly SVG_ANGLETYPE_UNSPECIFIED: 1;
    readonly SVG_ANGLETYPE_DEG: 2;
    readonly SVG_ANGLETYPE_RAD: 3;
    readonly SVG_ANGLETYPE_GRAD: 4;
}

declare var SVGAngle: {
    prototype: SVGAngle;
    new(): SVGAngle;
    readonly SVG_ANGLETYPE_UNKNOWN: 0;
    readonly SVG_ANGLETYPE_UNSPECIFIED: 1;
    readonly SVG_ANGLETYPE_DEG: 2;
    readonly SVG_ANGLETYPE_RAD: 3;
    readonly SVG_ANGLETYPE_GRAD: 4;
};

/**
 * The **`SVGAnimateElement`** interface corresponds to the <animate> element.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGAnimateElement)
 */
interface SVGAnimateElement extends SVGAnimationElement {
    addEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGAnimateElement, ev: SVGElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGAnimateElement, ev: SVGElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var SVGAnimateElement: {
    prototype: SVGAnimateElement;
    new(): SVGAnimateElement;
};

/**
 * The **`SVGAnimateMotionElement`** interface corresponds to the <animateMotion> element.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGAnimateMotionElement)
 */
interface SVGAnimateMotionElement extends SVGAnimationElement {
    addEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGAnimateMotionElement, ev: SVGElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGAnimateMotionElement, ev: SVGElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var SVGAnimateMotionElement: {
    prototype: SVGAnimateMotionElement;
    new(): SVGAnimateMotionElement;
};

/**
 * The **`SVGAnimateTransformElement`** interface corresponds to the <animateTransform> element.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGAnimateTransformElement)
 */
interface SVGAnimateTransformElement extends SVGAnimationElement {
    addEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGAnimateTransformElement, ev: SVGElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGAnimateTransformElement, ev: SVGElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var SVGAnimateTransformElement: {
    prototype: SVGAnimateTransformElement;
    new(): SVGAnimateTransformElement;
};

/**
 * The **`SVGAnimatedAngle`** interface is used for attributes of basic type <angle> which can be animated.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGAnimatedAngle)
 */
interface SVGAnimatedAngle {
    /**
     * The **`animVal`** read-only property of the SVGAnimatedAngle interface represents the current animated value of the associated <angle> on an SVG element. If the attribute is not currently being animated, animVal will be the same as the baseVal.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGAnimatedAngle/animVal)
     */
    readonly animVal: SVGAngle;
    /**
     * The **`baseVal`** read-only property of the SVGAnimatedAngle interface represents the base (non-animated) value of the associated <angle> on an SVG element. This property is used to retrieve the static value of the <angle>, unaffected by any ongoing animations.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGAnimatedAngle/baseVal)
     */
    readonly baseVal: SVGAngle;
}

declare var SVGAnimatedAngle: {
    prototype: SVGAnimatedAngle;
    new(): SVGAnimatedAngle;
};

/**
 * The **`SVGAnimatedBoolean`** interface is used for attributes of type boolean which can be animated.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGAnimatedBoolean)
 */
interface SVGAnimatedBoolean {
    /**
     * The **`animVal`** read-only property of the SVGAnimatedBoolean interface represents the current animated value of the associated animatable boolean SVG attribute. If the attribute is not animated, animVal is the same as SVGAnimatedBoolean.baseVal.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGAnimatedBoolean/animVal)
     */
    readonly animVal: boolean;
    /**
     * The **`baseVal`** property of the SVGAnimatedBoolean interface is the value of the associated animatable boolean SVG attribute in its base (none-animated) state. It reflects the value of the associated animatable boolean attribute when no animations are applied.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGAnimatedBoolean/baseVal)
     */
    baseVal: boolean;
}

declare var SVGAnimatedBoolean: {
    prototype: SVGAnimatedBoolean;
    new(): SVGAnimatedBoolean;
};

/**
 * The **`SVGAnimatedEnumeration`** interface describes attribute values which are constants from a particular enumeration and which can be animated.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGAnimatedEnumeration)
 */
interface SVGAnimatedEnumeration {
    /**
     * The **`animVal`** property of the SVGAnimatedEnumeration interface contains the current value of an SVG enumeration. If there is no animation, it is the same value as the baseVal.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGAnimatedEnumeration/animVal)
     */
    readonly animVal: number;
    /**
     * The **`baseVal`** property of the SVGAnimatedEnumeration interface contains the initial value of an SVG enumeration.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGAnimatedEnumeration/baseVal)
     */
    baseVal: number;
}

declare var SVGAnimatedEnumeration: {
    prototype: SVGAnimatedEnumeration;
    new(): SVGAnimatedEnumeration;
};

/**
 * The **`SVGAnimatedInteger`** interface is used for attributes of basic type <integer> which can be animated.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGAnimatedInteger)
 */
interface SVGAnimatedInteger {
    /**
     * The **`animVal`** property of the SVGAnimatedInteger interface represents the animated value of an <integer>. If no animation is applied, animVal equals baseVal.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGAnimatedInteger/animVal)
     */
    readonly animVal: number;
    /**
     * The **`baseVal`** property of the SVGAnimatedInteger interface represents the base (non-animated) value of an animatable <integer>.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGAnimatedInteger/baseVal)
     */
    baseVal: number;
}

declare var SVGAnimatedInteger: {
    prototype: SVGAnimatedInteger;
    new(): SVGAnimatedInteger;
};

/**
 * The **`SVGAnimatedLength`** interface represents attributes of type <length> which can be animated.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGAnimatedLength)
 */
interface SVGAnimatedLength {
    /**
     * The **`animVal`** property of the SVGAnimatedLength interface contains the current value of an SVG enumeration. If there is no animation, it is the same value as the baseVal.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGAnimatedLength/animVal)
     */
    readonly animVal: SVGLength;
    /**
     * The **`baseVal`** property of the SVGAnimatedLength interface contains the initial value of an SVG enumeration.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGAnimatedLength/baseVal)
     */
    readonly baseVal: SVGLength;
}

declare var SVGAnimatedLength: {
    prototype: SVGAnimatedLength;
    new(): SVGAnimatedLength;
};

/**
 * The **`SVGAnimatedLengthList`** interface is used for attributes of type SVGLengthList which can be animated.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGAnimatedLengthList)
 */
interface SVGAnimatedLengthList {
    /**
     * The **`animVal`** read-only property of the SVGAnimatedLengthList interface represents the animated value of an attribute that accepts a list of <length>, <percentage>, or <number> values.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGAnimatedLengthList/animVal)
     */
    readonly animVal: SVGLengthList;
    /**
     * The **`baseVal`** read-only property of the SVGAnimatedLengthList interface represents the base (non-animated) value of an animatable attribute that accepts a list of <length>, <percentage>, or <number> values.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGAnimatedLengthList/baseVal)
     */
    readonly baseVal: SVGLengthList;
}

declare var SVGAnimatedLengthList: {
    prototype: SVGAnimatedLengthList;
    new(): SVGAnimatedLengthList;
};

/**
 * The **`SVGAnimatedNumber`** interface represents attributes of type <number> which can be animated.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGAnimatedNumber)
 */
interface SVGAnimatedNumber {
    /**
     * The **`animVal`** read-only property of the SVGAnimatedNumber interface represents the animated value of an SVG element's numeric attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGAnimatedNumber/animVal)
     */
    readonly animVal: number;
    /**
     * The **`baseVal`** property of the SVGAnimatedNumber interface represents the base (non-animated) value of an animatable numeric attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGAnimatedNumber/baseVal)
     */
    baseVal: number;
}

declare var SVGAnimatedNumber: {
    prototype: SVGAnimatedNumber;
    new(): SVGAnimatedNumber;
};

/**
 * The **`SVGAnimatedNumberList`** interface represents a list of attributes of type <number> which can be animated.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGAnimatedNumberList)
 */
interface SVGAnimatedNumberList {
    /**
     * The **`animVal`** read-only property of the SVGAnimatedNumberList interface represents the current animated value of an animatable attribute that accepts a list of <number> values.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGAnimatedNumberList/animVal)
     */
    readonly animVal: SVGNumberList;
    /**
     * The **`baseVal`** read-only property of the SVGAnimatedNumberList interface represents the base (non-animated) value of an animatable attribute that accepts a list of <number> values.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGAnimatedNumberList/baseVal)
     */
    readonly baseVal: SVGNumberList;
}

declare var SVGAnimatedNumberList: {
    prototype: SVGAnimatedNumberList;
    new(): SVGAnimatedNumberList;
};

interface SVGAnimatedPoints {
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGPolygonElement/animatedPoints) */
    readonly animatedPoints: SVGPointList;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGPolygonElement/points) */
    readonly points: SVGPointList;
}

/**
 * The **`SVGAnimatedPreserveAspectRatio`** interface represents attributes of type SVGPreserveAspectRatio which can be animated.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGAnimatedPreserveAspectRatio)
 */
interface SVGAnimatedPreserveAspectRatio {
    /**
     * The **`animVal`** read-only property of the SVGAnimatedPreserveAspectRatio interface represents the value of the preserveAspectRatio attribute of an SVG element after any animations or transformations are applied.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGAnimatedPreserveAspectRatio/animVal)
     */
    readonly animVal: SVGPreserveAspectRatio;
    /**
     * The **`baseVal`** read-only property of the SVGAnimatedPreserveAspectRatio interface represents the base (non-animated) value of the preserveAspectRatio attribute of an SVG element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGAnimatedPreserveAspectRatio/baseVal)
     */
    readonly baseVal: SVGPreserveAspectRatio;
}

declare var SVGAnimatedPreserveAspectRatio: {
    prototype: SVGAnimatedPreserveAspectRatio;
    new(): SVGAnimatedPreserveAspectRatio;
};

/**
 * The **`SVGAnimatedRect`** interface represents an SVGRect attribute that can be animated.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGAnimatedRect)
 */
interface SVGAnimatedRect {
    /**
     * The **`animVal`** read-only property of the SVGAnimatedRect interface represents the current animated value of the viewBox attribute of an SVG element as a read-only DOMRectReadOnly object. It provides access to the rectangle's dynamic state, including the x, y, width, and height values during the animation.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGAnimatedRect/animVal)
     */
    readonly animVal: DOMRectReadOnly;
    /**
     * The **`baseVal`** read-only property of the SVGAnimatedRect interface represents the current non-animated value of the viewBox attribute of an SVG element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGAnimatedRect/baseVal)
     */
    readonly baseVal: DOMRect;
}

declare var SVGAnimatedRect: {
    prototype: SVGAnimatedRect;
    new(): SVGAnimatedRect;
};

/**
 * The **`SVGAnimatedString`** interface represents string attributes which can be animated from each SVG declaration. You need to create SVG attribute before doing anything else, everything should be declared inside this.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGAnimatedString)
 */
interface SVGAnimatedString {
    /**
     * The **`animVal`** read-only property of the SVGAnimatedString interface is a string representing the animated value of the reflected attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGAnimatedString/animVal)
     */
    readonly animVal: string;
    /**
     * The **`baseVal`** property of the SVGAnimatedString interface gets or sets the base value of the given attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGAnimatedString/baseVal)
     */
    baseVal: string;
}

declare var SVGAnimatedString: {
    prototype: SVGAnimatedString;
    new(): SVGAnimatedString;
};

/**
 * The **`SVGAnimatedTransformList`** interface represents attributes which take a list of numbers and which can be animated.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGAnimatedTransformList)
 */
interface SVGAnimatedTransformList {
    /**
     * The **`animVal`** read-only property of the SVGAnimatedTransformList interface represents the animated value of the transform attribute of an SVG element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGAnimatedTransformList/animVal)
     */
    readonly animVal: SVGTransformList;
    /**
     * The **`baseVal`** read-only property of the SVGAnimatedTransformList interface represents the non-animated value of the transform attribute of an SVG element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGAnimatedTransformList/baseVal)
     */
    readonly baseVal: SVGTransformList;
}

declare var SVGAnimatedTransformList: {
    prototype: SVGAnimatedTransformList;
    new(): SVGAnimatedTransformList;
};

/**
 * The **`SVGAnimationElement`** interface is the base interface for all of the animation element interfaces: SVGAnimateElement, SVGSetElement, SVGAnimateColorElement, SVGAnimateMotionElement and SVGAnimateTransformElement.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGAnimationElement)
 */
interface SVGAnimationElement extends SVGElement, SVGTests {
    /**
     * The **`targetElement`** read-only property of the SVGAnimationElement interface refers to the element which is being animated. If no target element is being animated (for example, because the href attribute specifies an unknown element), the value returned is null.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGAnimationElement/targetElement)
     */
    readonly targetElement: SVGElement | null;
    /**
     * The SVGAnimationElement method **`beginElement()`** creates a begin instance time for the current time. The new instance time is added to the begin instance times list. The behavior of this method is equivalent to beginElementAt(0).
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGAnimationElement/beginElement)
     */
    beginElement(): void;
    /**
     * The SVGAnimationElement method **`beginElementAt()`** creates a begin instance time for the current time plus the specified offset. The new instance time is added to the begin instance times list.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGAnimationElement/beginElementAt)
     */
    beginElementAt(offset: number): void;
    /**
     * The SVGAnimationElement method **`endElement()`** creates an end instance time for the current time. The new instance time is added to the end instance times list. The behavior of this method is equivalent to endElementAt(0).
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGAnimationElement/endElement)
     */
    endElement(): void;
    /**
     * The SVGAnimationElement method **`endElementAt()`** creates an end instance time for the current time plus the specified offset. The new instance time is added to the end instance times list.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGAnimationElement/endElementAt)
     */
    endElementAt(offset: number): void;
    /**
     * The SVGAnimationElement method **`getCurrentTime()`** returns a float representing the current time in seconds relative to time zero for the given time container.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGAnimationElement/getCurrentTime)
     */
    getCurrentTime(): number;
    /**
     * The SVGAnimationElement method **`getSimpleDuration()`** returns a float representing the number of seconds for the simple duration for this animation.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGAnimationElement/getSimpleDuration)
     */
    getSimpleDuration(): number;
    /**
     * The SVGAnimationElement method **`getStartTime()`** returns a float representing the start time, in seconds, for this animation element's current interval, if it exists, regardless of whether the interval has begun yet.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGAnimationElement/getStartTime)
     */
    getStartTime(): number;
    addEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGAnimationElement, ev: SVGElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGAnimationElement, ev: SVGElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var SVGAnimationElement: {
    prototype: SVGAnimationElement;
    new(): SVGAnimationElement;
};

/**
 * The **`SVGCircleElement`** interface is an interface for the <circle> element.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGCircleElement)
 */
interface SVGCircleElement extends SVGGeometryElement {
    /**
     * The **`cx`** read-only property of the SVGCircleElement interface reflects the cx attribute of a <circle> element and by that defines the x-coordinate of the circle's center.<
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGCircleElement/cx)
     */
    readonly cx: SVGAnimatedLength;
    /**
     * The **`cy`** read-only property of the SVGCircleElement interface reflects the cy attribute of a <circle> element and by that defines the y-coordinate of the circle's center.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGCircleElement/cy)
     */
    readonly cy: SVGAnimatedLength;
    /**
     * The **`r`** read-only property of the SVGCircleElement interface reflects the r attribute of a <circle> element and by that defines the radius of the circle.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGCircleElement/r)
     */
    readonly r: SVGAnimatedLength;
    addEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGCircleElement, ev: SVGElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGCircleElement, ev: SVGElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var SVGCircleElement: {
    prototype: SVGCircleElement;
    new(): SVGCircleElement;
};

/**
 * The **`SVGClipPathElement`** interface provides access to the properties of <clipPath> elements, as well as methods to manipulate them.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGClipPathElement)
 */
interface SVGClipPathElement extends SVGElement {
    /**
     * The read-only **`clipPathUnits`** property of the SVGClipPathElement interface reflects the clipPathUnits attribute of a <clipPath> element which defines the coordinate system to use for the content of the element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGClipPathElement/clipPathUnits)
     */
    readonly clipPathUnits: SVGAnimatedEnumeration;
    /**
     * The read-only **`transform`** property of the SVGClipPathElement interface reflects the transform attribute of a <clipPath> element, that is a list of transformations applied to the element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGClipPathElement/transform)
     */
    readonly transform: SVGAnimatedTransformList;
    addEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGClipPathElement, ev: SVGElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGClipPathElement, ev: SVGElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var SVGClipPathElement: {
    prototype: SVGClipPathElement;
    new(): SVGClipPathElement;
};

/**
 * The **`SVGComponentTransferFunctionElement`** interface represents a base interface used by the component transfer function interfaces.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGComponentTransferFunctionElement)
 */
interface SVGComponentTransferFunctionElement extends SVGElement {
    /**
     * The **`amplitude`** read-only property of the SVGComponentTransferFunctionElement interface reflects the amplitude attribute of the given element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGComponentTransferFunctionElement/amplitude)
     */
    readonly amplitude: SVGAnimatedNumber;
    /**
     * The **`exponent`** read-only property of the SVGComponentTransferFunctionElement interface reflects the exponent attribute of the given element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGComponentTransferFunctionElement/exponent)
     */
    readonly exponent: SVGAnimatedNumber;
    /**
     * The **`intercept`** read-only property of the SVGComponentTransferFunctionElement interface reflects the intercept attribute of the given element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGComponentTransferFunctionElement/intercept)
     */
    readonly intercept: SVGAnimatedNumber;
    /**
     * The **`offset`** read-only property of the SVGComponentTransferFunctionElement interface reflects the offset attribute of the given element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGComponentTransferFunctionElement/offset)
     */
    readonly offset: SVGAnimatedNumber;
    /**
     * The **`slope`** read-only property of the SVGComponentTransferFunctionElement interface reflects the slope attribute of the given element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGComponentTransferFunctionElement/slope)
     */
    readonly slope: SVGAnimatedNumber;
    /**
     * The **`tableValues`** read-only property of the SVGComponentTransferFunctionElement interface reflects the tableValues attribute of the given element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGComponentTransferFunctionElement/tableValues)
     */
    readonly tableValues: SVGAnimatedNumberList;
    /**
     * The **`type`** read-only property of the SVGComponentTransferFunctionElement interface reflects the type attribute of the given element. It takes one of the SVG_FECOMPONENTTRANSFER_TYPE_* constants defined on this interface.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGComponentTransferFunctionElement/type)
     */
    readonly type: SVGAnimatedEnumeration;
    readonly SVG_FECOMPONENTTRANSFER_TYPE_UNKNOWN: 0;
    readonly SVG_FECOMPONENTTRANSFER_TYPE_IDENTITY: 1;
    readonly SVG_FECOMPONENTTRANSFER_TYPE_TABLE: 2;
    readonly SVG_FECOMPONENTTRANSFER_TYPE_DISCRETE: 3;
    readonly SVG_FECOMPONENTTRANSFER_TYPE_LINEAR: 4;
    readonly SVG_FECOMPONENTTRANSFER_TYPE_GAMMA: 5;
    addEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGComponentTransferFunctionElement, ev: SVGElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGComponentTransferFunctionElement, ev: SVGElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var SVGComponentTransferFunctionElement: {
    prototype: SVGComponentTransferFunctionElement;
    new(): SVGComponentTransferFunctionElement;
    readonly SVG_FECOMPONENTTRANSFER_TYPE_UNKNOWN: 0;
    readonly SVG_FECOMPONENTTRANSFER_TYPE_IDENTITY: 1;
    readonly SVG_FECOMPONENTTRANSFER_TYPE_TABLE: 2;
    readonly SVG_FECOMPONENTTRANSFER_TYPE_DISCRETE: 3;
    readonly SVG_FECOMPONENTTRANSFER_TYPE_LINEAR: 4;
    readonly SVG_FECOMPONENTTRANSFER_TYPE_GAMMA: 5;
};

/**
 * The **`SVGDefsElement`** interface corresponds to the <defs> element.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGDefsElement)
 */
interface SVGDefsElement extends SVGGraphicsElement {
    addEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGDefsElement, ev: SVGElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGDefsElement, ev: SVGElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var SVGDefsElement: {
    prototype: SVGDefsElement;
    new(): SVGDefsElement;
};

/**
 * The **`SVGDescElement`** interface corresponds to the <desc> element.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGDescElement)
 */
interface SVGDescElement extends SVGElement {
    addEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGDescElement, ev: SVGElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGDescElement, ev: SVGElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var SVGDescElement: {
    prototype: SVGDescElement;
    new(): SVGDescElement;
};

interface SVGElementEventMap extends ElementEventMap, GlobalEventHandlersEventMap {
}

/**
 * All of the SVG DOM interfaces that correspond directly to elements in the SVG language derive from the **`SVGElement`** interface.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGElement)
 */
interface SVGElement extends Element, ElementCSSInlineStyle, GlobalEventHandlers, HTMLOrSVGElement {
    /** @deprecated */
    readonly className: any;
    /**
     * The **`ownerSVGElement`** property of the SVGElement interface reflects the nearest ancestor <svg> element. null if the given element is the outermost <svg> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGElement/ownerSVGElement)
     */
    readonly ownerSVGElement: SVGSVGElement | null;
    /**
     * The **`viewportElement`** property of the SVGElement interface represents the SVGElement which established the current viewport. Often the nearest ancestor <svg> element. null if the given element is the outermost <svg> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGElement/viewportElement)
     */
    readonly viewportElement: SVGElement | null;
    addEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGElement, ev: SVGElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGElement, ev: SVGElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var SVGElement: {
    prototype: SVGElement;
    new(): SVGElement;
};

/**
 * The **`SVGEllipseElement`** interface provides access to the properties of <ellipse> elements.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGEllipseElement)
 */
interface SVGEllipseElement extends SVGGeometryElement {
    /**
     * The **`cx`** read-only property of the SVGEllipseElement interface describes the x-axis coordinate of the center of the ellipse as an SVGAnimatedLength. It reflects the computed value of the cx attribute on the <ellipse> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGEllipseElement/cx)
     */
    readonly cx: SVGAnimatedLength;
    /**
     * The **`cy`** read-only property of the SVGEllipseElement interface describes the y-axis coordinate of the center of the ellipse as an SVGAnimatedLength. It reflects the computed value of the cy attribute on the <ellipse> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGEllipseElement/cy)
     */
    readonly cy: SVGAnimatedLength;
    /**
     * The **`rx`** read-only property of the SVGEllipseElement interface describes the x-axis radius of the ellipse as an SVGAnimatedLength. It reflects the computed value of the rx attribute on the <ellipse> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGEllipseElement/rx)
     */
    readonly rx: SVGAnimatedLength;
    /**
     * The **`ry`** read-only property of the SVGEllipseElement interface describes the y-axis radius of the ellipse as an SVGAnimatedLength. It reflects the computed value of the ry attribute on the <ellipse> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGEllipseElement/ry)
     */
    readonly ry: SVGAnimatedLength;
    addEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGEllipseElement, ev: SVGElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGEllipseElement, ev: SVGElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var SVGEllipseElement: {
    prototype: SVGEllipseElement;
    new(): SVGEllipseElement;
};

/**
 * The **`SVGFEBlendElement`** interface corresponds to the <feBlend> element.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFEBlendElement)
 */
interface SVGFEBlendElement extends SVGElement, SVGFilterPrimitiveStandardAttributes {
    /**
     * The **`in1`** read-only property of the SVGFEBlendElement interface reflects the in attribute of the given element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFEBlendElement/in1)
     */
    readonly in1: SVGAnimatedString;
    /**
     * The **`in2`** read-only property of the SVGFEBlendElement interface reflects the in2 attribute of the given element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFEBlendElement/in2)
     */
    readonly in2: SVGAnimatedString;
    /**
     * The **`mode`** read-only property of the SVGFEBlendElement interface reflects the mode attribute of the given element. It takes one of the SVG_FEBLEND_MODE_* constants defined on this interface.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFEBlendElement/mode)
     */
    readonly mode: SVGAnimatedEnumeration;
    readonly SVG_FEBLEND_MODE_UNKNOWN: 0;
    readonly SVG_FEBLEND_MODE_NORMAL: 1;
    readonly SVG_FEBLEND_MODE_MULTIPLY: 2;
    readonly SVG_FEBLEND_MODE_SCREEN: 3;
    readonly SVG_FEBLEND_MODE_DARKEN: 4;
    readonly SVG_FEBLEND_MODE_LIGHTEN: 5;
    readonly SVG_FEBLEND_MODE_OVERLAY: 6;
    readonly SVG_FEBLEND_MODE_COLOR_DODGE: 7;
    readonly SVG_FEBLEND_MODE_COLOR_BURN: 8;
    readonly SVG_FEBLEND_MODE_HARD_LIGHT: 9;
    readonly SVG_FEBLEND_MODE_SOFT_LIGHT: 10;
    readonly SVG_FEBLEND_MODE_DIFFERENCE: 11;
    readonly SVG_FEBLEND_MODE_EXCLUSION: 12;
    readonly SVG_FEBLEND_MODE_HUE: 13;
    readonly SVG_FEBLEND_MODE_SATURATION: 14;
    readonly SVG_FEBLEND_MODE_COLOR: 15;
    readonly SVG_FEBLEND_MODE_LUMINOSITY: 16;
    addEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGFEBlendElement, ev: SVGElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGFEBlendElement, ev: SVGElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var SVGFEBlendElement: {
    prototype: SVGFEBlendElement;
    new(): SVGFEBlendElement;
    readonly SVG_FEBLEND_MODE_UNKNOWN: 0;
    readonly SVG_FEBLEND_MODE_NORMAL: 1;
    readonly SVG_FEBLEND_MODE_MULTIPLY: 2;
    readonly SVG_FEBLEND_MODE_SCREEN: 3;
    readonly SVG_FEBLEND_MODE_DARKEN: 4;
    readonly SVG_FEBLEND_MODE_LIGHTEN: 5;
    readonly SVG_FEBLEND_MODE_OVERLAY: 6;
    readonly SVG_FEBLEND_MODE_COLOR_DODGE: 7;
    readonly SVG_FEBLEND_MODE_COLOR_BURN: 8;
    readonly SVG_FEBLEND_MODE_HARD_LIGHT: 9;
    readonly SVG_FEBLEND_MODE_SOFT_LIGHT: 10;
    readonly SVG_FEBLEND_MODE_DIFFERENCE: 11;
    readonly SVG_FEBLEND_MODE_EXCLUSION: 12;
    readonly SVG_FEBLEND_MODE_HUE: 13;
    readonly SVG_FEBLEND_MODE_SATURATION: 14;
    readonly SVG_FEBLEND_MODE_COLOR: 15;
    readonly SVG_FEBLEND_MODE_LUMINOSITY: 16;
};

/**
 * The **`SVGFEColorMatrixElement`** interface corresponds to the <feColorMatrix> element.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFEColorMatrixElement)
 */
interface SVGFEColorMatrixElement extends SVGElement, SVGFilterPrimitiveStandardAttributes {
    /**
     * The **`in1`** read-only property of the SVGFEColorMatrixElement interface reflects the in attribute of the given element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFEColorMatrixElement/in1)
     */
    readonly in1: SVGAnimatedString;
    /**
     * The **`type`** read-only property of the SVGFEColorMatrixElement interface reflects the type attribute of the given element. It takes one of the SVG_FECOLORMATRIX_TYPE_* constants defined on this interface.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFEColorMatrixElement/type)
     */
    readonly type: SVGAnimatedEnumeration;
    /**
     * The **`values`** read-only property of the SVGFEColorMatrixElement interface reflects the values attribute of the given element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFEColorMatrixElement/values)
     */
    readonly values: SVGAnimatedNumberList;
    readonly SVG_FECOLORMATRIX_TYPE_UNKNOWN: 0;
    readonly SVG_FECOLORMATRIX_TYPE_MATRIX: 1;
    readonly SVG_FECOLORMATRIX_TYPE_SATURATE: 2;
    readonly SVG_FECOLORMATRIX_TYPE_HUEROTATE: 3;
    readonly SVG_FECOLORMATRIX_TYPE_LUMINANCETOALPHA: 4;
    addEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGFEColorMatrixElement, ev: SVGElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGFEColorMatrixElement, ev: SVGElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var SVGFEColorMatrixElement: {
    prototype: SVGFEColorMatrixElement;
    new(): SVGFEColorMatrixElement;
    readonly SVG_FECOLORMATRIX_TYPE_UNKNOWN: 0;
    readonly SVG_FECOLORMATRIX_TYPE_MATRIX: 1;
    readonly SVG_FECOLORMATRIX_TYPE_SATURATE: 2;
    readonly SVG_FECOLORMATRIX_TYPE_HUEROTATE: 3;
    readonly SVG_FECOLORMATRIX_TYPE_LUMINANCETOALPHA: 4;
};

/**
 * The **`SVGFEComponentTransferElement`** interface corresponds to the <feComponentTransfer> element.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFEComponentTransferElement)
 */
interface SVGFEComponentTransferElement extends SVGElement, SVGFilterPrimitiveStandardAttributes {
    /**
     * The **`in1`** read-only property of the SVGFEComponentTransferElement interface reflects the in attribute of the given <feComponentTransfer> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFEComponentTransferElement/in1)
     */
    readonly in1: SVGAnimatedString;
    addEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGFEComponentTransferElement, ev: SVGElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGFEComponentTransferElement, ev: SVGElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var SVGFEComponentTransferElement: {
    prototype: SVGFEComponentTransferElement;
    new(): SVGFEComponentTransferElement;
};

/**
 * The **`SVGFECompositeElement`** interface corresponds to the <feComposite> element.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFECompositeElement)
 */
interface SVGFECompositeElement extends SVGElement, SVGFilterPrimitiveStandardAttributes {
    /**
     * The **`in1`** read-only property of the SVGFECompositeElement interface reflects the in attribute of the given <feComposite> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFECompositeElement/in1)
     */
    readonly in1: SVGAnimatedString;
    /**
     * The **`in2`** read-only property of the SVGFECompositeElement interface reflects the in2 attribute of the given <feComposite> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFECompositeElement/in2)
     */
    readonly in2: SVGAnimatedString;
    /**
     * The **`k1`** read-only property of the SVGFECompositeElement interface reflects the k1 attribute of the given <feComposite> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFECompositeElement/k1)
     */
    readonly k1: SVGAnimatedNumber;
    /**
     * The **`k2`** read-only property of the SVGFECompositeElement interface reflects the k2 attribute of the given <feComposite> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFECompositeElement/k2)
     */
    readonly k2: SVGAnimatedNumber;
    /**
     * The **`k3`** read-only property of the SVGFECompositeElement interface reflects the k3 attribute of the given <feComposite> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFECompositeElement/k3)
     */
    readonly k3: SVGAnimatedNumber;
    /**
     * The **`k4`** read-only property of the SVGFECompositeElement interface reflects the k4 attribute of the given <feComposite> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFECompositeElement/k4)
     */
    readonly k4: SVGAnimatedNumber;
    /**
     * The **`operator`** read-only property of the SVGFECompositeElement interface reflects the operator attribute of the given <feComposite> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFECompositeElement/operator)
     */
    readonly operator: SVGAnimatedEnumeration;
    readonly SVG_FECOMPOSITE_OPERATOR_UNKNOWN: 0;
    readonly SVG_FECOMPOSITE_OPERATOR_OVER: 1;
    readonly SVG_FECOMPOSITE_OPERATOR_IN: 2;
    readonly SVG_FECOMPOSITE_OPERATOR_OUT: 3;
    readonly SVG_FECOMPOSITE_OPERATOR_ATOP: 4;
    readonly SVG_FECOMPOSITE_OPERATOR_XOR: 5;
    readonly SVG_FECOMPOSITE_OPERATOR_ARITHMETIC: 6;
    addEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGFECompositeElement, ev: SVGElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGFECompositeElement, ev: SVGElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var SVGFECompositeElement: {
    prototype: SVGFECompositeElement;
    new(): SVGFECompositeElement;
    readonly SVG_FECOMPOSITE_OPERATOR_UNKNOWN: 0;
    readonly SVG_FECOMPOSITE_OPERATOR_OVER: 1;
    readonly SVG_FECOMPOSITE_OPERATOR_IN: 2;
    readonly SVG_FECOMPOSITE_OPERATOR_OUT: 3;
    readonly SVG_FECOMPOSITE_OPERATOR_ATOP: 4;
    readonly SVG_FECOMPOSITE_OPERATOR_XOR: 5;
    readonly SVG_FECOMPOSITE_OPERATOR_ARITHMETIC: 6;
};

/**
 * The **`SVGFEConvolveMatrixElement`** interface corresponds to the <feConvolveMatrix> element.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFEConvolveMatrixElement)
 */
interface SVGFEConvolveMatrixElement extends SVGElement, SVGFilterPrimitiveStandardAttributes {
    /**
     * The **`bias`** read-only property of the SVGFEConvolveMatrixElement interface reflects the bias attribute of the given <feConvolveMatrix> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFEConvolveMatrixElement/bias)
     */
    readonly bias: SVGAnimatedNumber;
    /**
     * The **`divisor`** read-only property of the SVGFEConvolveMatrixElement interface reflects the divisor attribute of the given <feConvolveMatrix> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFEConvolveMatrixElement/divisor)
     */
    readonly divisor: SVGAnimatedNumber;
    /**
     * The **`edgeMode`** read-only property of the SVGFEConvolveMatrixElement interface reflects the edgeMode attribute of the given <feConvolveMatrix> element. The SVG_EDGEMODE_* constants defined on this interface are represented by the numbers 1 through 3, where the default duplicate is 1, wrap is 2, and none is 3.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFEConvolveMatrixElement/edgeMode)
     */
    readonly edgeMode: SVGAnimatedEnumeration;
    /**
     * The **`in1`** read-only property of the SVGFEConvolveMatrixElement interface reflects the in attribute of the given <feConvolveMatrix> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFEConvolveMatrixElement/in1)
     */
    readonly in1: SVGAnimatedString;
    /**
     * The **`kernelMatrix`** read-only property of the SVGFEConvolveMatrixElement interface reflects the kernelMatrix attribute of the given <feConvolveMatrix> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFEConvolveMatrixElement/kernelMatrix)
     */
    readonly kernelMatrix: SVGAnimatedNumberList;
    /**
     * The **`kernelUnitLengthX`** read-only property of the SVGFEConvolveMatrixElement interface reflects the kernelUnitLength attribute of the given <feConvolveMatrix> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFEConvolveMatrixElement/kernelUnitLengthX)
     */
    readonly kernelUnitLengthX: SVGAnimatedNumber;
    /**
     * The **`kernelUnitLengthY`** read-only property of the SVGFEConvolveMatrixElement interface reflects the kernelUnitLength attribute of the given <feConvolveMatrix> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFEConvolveMatrixElement/kernelUnitLengthY)
     */
    readonly kernelUnitLengthY: SVGAnimatedNumber;
    /**
     * The **`orderX`** read-only property of the SVGFEConvolveMatrixElement interface reflects the order attribute of the given <feConvolveMatrix> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFEConvolveMatrixElement/orderX)
     */
    readonly orderX: SVGAnimatedInteger;
    /**
     * The **`orderY`** read-only property of the SVGFEConvolveMatrixElement interface reflects the order attribute of the given <feConvolveMatrix> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFEConvolveMatrixElement/orderY)
     */
    readonly orderY: SVGAnimatedInteger;
    /**
     * The **`preserveAlpha`** read-only property of the SVGFEConvolveMatrixElement interface reflects the preserveAlpha attribute of the given <feConvolveMatrix> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFEConvolveMatrixElement/preserveAlpha)
     */
    readonly preserveAlpha: SVGAnimatedBoolean;
    /**
     * The **`targetX`** read-only property of the SVGFEConvolveMatrixElement interface reflects the targetX attribute of the given <feConvolveMatrix> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFEConvolveMatrixElement/targetX)
     */
    readonly targetX: SVGAnimatedInteger;
    /**
     * The **`targetY`** read-only property of the SVGFEConvolveMatrixElement interface reflects the targetY attribute of the given <feConvolveMatrix> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFEConvolveMatrixElement/targetY)
     */
    readonly targetY: SVGAnimatedInteger;
    readonly SVG_EDGEMODE_UNKNOWN: 0;
    readonly SVG_EDGEMODE_DUPLICATE: 1;
    readonly SVG_EDGEMODE_WRAP: 2;
    readonly SVG_EDGEMODE_NONE: 3;
    addEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGFEConvolveMatrixElement, ev: SVGElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGFEConvolveMatrixElement, ev: SVGElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var SVGFEConvolveMatrixElement: {
    prototype: SVGFEConvolveMatrixElement;
    new(): SVGFEConvolveMatrixElement;
    readonly SVG_EDGEMODE_UNKNOWN: 0;
    readonly SVG_EDGEMODE_DUPLICATE: 1;
    readonly SVG_EDGEMODE_WRAP: 2;
    readonly SVG_EDGEMODE_NONE: 3;
};

/**
 * The **`SVGFEDiffuseLightingElement`** interface corresponds to the <feDiffuseLighting> element.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFEDiffuseLightingElement)
 */
interface SVGFEDiffuseLightingElement extends SVGElement, SVGFilterPrimitiveStandardAttributes {
    /**
     * The **`diffuseConstant`** read-only property of the SVGFEDiffuseLightingElement interface reflects the diffuseConstant attribute of the given <feDiffuseLighting> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFEDiffuseLightingElement/diffuseConstant)
     */
    readonly diffuseConstant: SVGAnimatedNumber;
    /**
     * The **`in1`** read-only property of the SVGFEDiffuseLightingElement interface reflects the in attribute of the given <feDiffuseLighting> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFEDiffuseLightingElement/in1)
     */
    readonly in1: SVGAnimatedString;
    /**
     * The **`kernelUnitLengthX`** read-only property of the SVGFEDiffuseLightingElement interface reflects the X component of the kernelUnitLength attribute of the given <feDiffuseLighting> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFEDiffuseLightingElement/kernelUnitLengthX)
     */
    readonly kernelUnitLengthX: SVGAnimatedNumber;
    /**
     * The **`kernelUnitLengthY`** read-only property of the SVGFEDiffuseLightingElement interface reflects the Y component of the kernelUnitLength attribute of the given <feDiffuseLighting> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFEDiffuseLightingElement/kernelUnitLengthY)
     */
    readonly kernelUnitLengthY: SVGAnimatedNumber;
    /**
     * The **`surfaceScale`** read-only property of the SVGFEDiffuseLightingElement interface reflects the surfaceScale attribute of the given <feDiffuseLighting> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFEDiffuseLightingElement/surfaceScale)
     */
    readonly surfaceScale: SVGAnimatedNumber;
    addEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGFEDiffuseLightingElement, ev: SVGElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGFEDiffuseLightingElement, ev: SVGElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var SVGFEDiffuseLightingElement: {
    prototype: SVGFEDiffuseLightingElement;
    new(): SVGFEDiffuseLightingElement;
};

/**
 * The **`SVGFEDisplacementMapElement`** interface corresponds to the <feDisplacementMap> element.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFEDisplacementMapElement)
 */
interface SVGFEDisplacementMapElement extends SVGElement, SVGFilterPrimitiveStandardAttributes {
    /**
     * The **`in1`** read-only property of the SVGFEDisplacementMapElement interface reflects the in attribute of the given <feDisplacementMap> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFEDisplacementMapElement/in1)
     */
    readonly in1: SVGAnimatedString;
    /**
     * The **`in2`** read-only property of the SVGFEDisplacementMapElement interface reflects the in2 attribute of the given <feDisplacementMap> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFEDisplacementMapElement/in2)
     */
    readonly in2: SVGAnimatedString;
    /**
     * The **`scale`** read-only property of the SVGFEDisplacementMapElement interface reflects the scale attribute of the given <feDisplacementMap> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFEDisplacementMapElement/scale)
     */
    readonly scale: SVGAnimatedNumber;
    /**
     * The **`xChannelSelector`** read-only property of the SVGFEDisplacementMapElement interface reflects the xChannelSelector attribute of the given <feDisplacementMap> element. It takes one of the SVG_CHANNEL_* constants defined on this interface.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFEDisplacementMapElement/xChannelSelector)
     */
    readonly xChannelSelector: SVGAnimatedEnumeration;
    /**
     * The **`yChannelSelector`** read-only property of the SVGFEDisplacementMapElement interface reflects the yChannelSelector attribute of the given <feDisplacementMap> element. It takes one of the SVG_CHANNEL_* constants defined on this interface.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFEDisplacementMapElement/yChannelSelector)
     */
    readonly yChannelSelector: SVGAnimatedEnumeration;
    readonly SVG_CHANNEL_UNKNOWN: 0;
    readonly SVG_CHANNEL_R: 1;
    readonly SVG_CHANNEL_G: 2;
    readonly SVG_CHANNEL_B: 3;
    readonly SVG_CHANNEL_A: 4;
    addEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGFEDisplacementMapElement, ev: SVGElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGFEDisplacementMapElement, ev: SVGElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var SVGFEDisplacementMapElement: {
    prototype: SVGFEDisplacementMapElement;
    new(): SVGFEDisplacementMapElement;
    readonly SVG_CHANNEL_UNKNOWN: 0;
    readonly SVG_CHANNEL_R: 1;
    readonly SVG_CHANNEL_G: 2;
    readonly SVG_CHANNEL_B: 3;
    readonly SVG_CHANNEL_A: 4;
};

/**
 * The **`SVGFEDistantLightElement`** interface corresponds to the <feDistantLight> element.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFEDistantLightElement)
 */
interface SVGFEDistantLightElement extends SVGElement {
    /**
     * The **`azimuth`** read-only property of the SVGFEDistantLightElement interface reflects the azimuth attribute of the given <feDistantLight> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFEDistantLightElement/azimuth)
     */
    readonly azimuth: SVGAnimatedNumber;
    /**
     * The **`elevation`** read-only property of the SVGFEDistantLightElement interface reflects the elevation attribute of the given <feDistantLight> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFEDistantLightElement/elevation)
     */
    readonly elevation: SVGAnimatedNumber;
    addEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGFEDistantLightElement, ev: SVGElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGFEDistantLightElement, ev: SVGElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var SVGFEDistantLightElement: {
    prototype: SVGFEDistantLightElement;
    new(): SVGFEDistantLightElement;
};

/**
 * The **`SVGFEDropShadowElement`** interface corresponds to the <feDropShadow> element.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFEDropShadowElement)
 */
interface SVGFEDropShadowElement extends SVGElement, SVGFilterPrimitiveStandardAttributes {
    /**
     * The **`dx`** read-only property of the SVGFEDropShadowElement interface reflects the dx attribute of the given <feDropShadow> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFEDropShadowElement/dx)
     */
    readonly dx: SVGAnimatedNumber;
    /**
     * The **`dy`** read-only property of the SVGFEDropShadowElement interface reflects the dy attribute of the given <feDropShadow> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFEDropShadowElement/dy)
     */
    readonly dy: SVGAnimatedNumber;
    /**
     * The **`in1`** read-only property of the SVGFEDropShadowElement interface reflects the in attribute of the given <feDropShadow> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFEDropShadowElement/in1)
     */
    readonly in1: SVGAnimatedString;
    /**
     * The **`stdDeviationX`** read-only property of the SVGFEDropShadowElement interface reflects the (possibly automatically computed) X component of the stdDeviation attribute of the given <feDropShadow> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFEDropShadowElement/stdDeviationX)
     */
    readonly stdDeviationX: SVGAnimatedNumber;
    /**
     * The **`stdDeviationY`** read-only property of the SVGFEDropShadowElement interface reflects the (possibly automatically computed) Y component of the stdDeviation attribute of the given <feDropShadow> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFEDropShadowElement/stdDeviationY)
     */
    readonly stdDeviationY: SVGAnimatedNumber;
    /**
     * The **`setStdDeviation()`** method of the SVGFEDropShadowElement interface sets the values for the stdDeviation attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFEDropShadowElement/setStdDeviation)
     */
    setStdDeviation(stdDeviationX: number, stdDeviationY: number): void;
    addEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGFEDropShadowElement, ev: SVGElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGFEDropShadowElement, ev: SVGElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var SVGFEDropShadowElement: {
    prototype: SVGFEDropShadowElement;
    new(): SVGFEDropShadowElement;
};

/**
 * The **`SVGFEFloodElement`** interface corresponds to the <feFlood> element.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFEFloodElement)
 */
interface SVGFEFloodElement extends SVGElement, SVGFilterPrimitiveStandardAttributes {
    addEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGFEFloodElement, ev: SVGElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGFEFloodElement, ev: SVGElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var SVGFEFloodElement: {
    prototype: SVGFEFloodElement;
    new(): SVGFEFloodElement;
};

/**
 * The **`SVGFEFuncAElement`** interface corresponds to the <feFuncA> element.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFEFuncAElement)
 */
interface SVGFEFuncAElement extends SVGComponentTransferFunctionElement {
    addEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGFEFuncAElement, ev: SVGElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGFEFuncAElement, ev: SVGElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var SVGFEFuncAElement: {
    prototype: SVGFEFuncAElement;
    new(): SVGFEFuncAElement;
};

/**
 * The **`SVGFEFuncBElement`** interface corresponds to the <feFuncB> element.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFEFuncBElement)
 */
interface SVGFEFuncBElement extends SVGComponentTransferFunctionElement {
    addEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGFEFuncBElement, ev: SVGElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGFEFuncBElement, ev: SVGElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var SVGFEFuncBElement: {
    prototype: SVGFEFuncBElement;
    new(): SVGFEFuncBElement;
};

/**
 * The **`SVGFEFuncGElement`** interface corresponds to the <feFuncG> element.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFEFuncGElement)
 */
interface SVGFEFuncGElement extends SVGComponentTransferFunctionElement {
    addEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGFEFuncGElement, ev: SVGElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGFEFuncGElement, ev: SVGElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var SVGFEFuncGElement: {
    prototype: SVGFEFuncGElement;
    new(): SVGFEFuncGElement;
};

/**
 * The **`SVGFEFuncRElement`** interface corresponds to the <feFuncR> element.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFEFuncRElement)
 */
interface SVGFEFuncRElement extends SVGComponentTransferFunctionElement {
    addEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGFEFuncRElement, ev: SVGElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGFEFuncRElement, ev: SVGElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var SVGFEFuncRElement: {
    prototype: SVGFEFuncRElement;
    new(): SVGFEFuncRElement;
};

/**
 * The **`SVGFEGaussianBlurElement`** interface corresponds to the <feGaussianBlur> element.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFEGaussianBlurElement)
 */
interface SVGFEGaussianBlurElement extends SVGElement, SVGFilterPrimitiveStandardAttributes {
    /**
     * The **`in1`** read-only property of the SVGFEGaussianBlurElement interface reflects the in attribute of the given <feGaussianBlur> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFEGaussianBlurElement/in1)
     */
    readonly in1: SVGAnimatedString;
    /**
     * The **`stdDeviationX`** read-only property of the SVGFEGaussianBlurElement interface reflects the (possibly automatically computed) X component of the stdDeviation attribute of the given <feGaussianBlur> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFEGaussianBlurElement/stdDeviationX)
     */
    readonly stdDeviationX: SVGAnimatedNumber;
    /**
     * The **`stdDeviationY`** read-only property of the SVGFEGaussianBlurElement interface reflects the (possibly automatically computed) Y component of the stdDeviation attribute of the given <feGaussianBlur> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFEGaussianBlurElement/stdDeviationY)
     */
    readonly stdDeviationY: SVGAnimatedNumber;
    /**
     * The **`setStdDeviation()`** method of the SVGFEGaussianBlurElement interface sets the values for the stdDeviation attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFEGaussianBlurElement/setStdDeviation)
     */
    setStdDeviation(stdDeviationX: number, stdDeviationY: number): void;
    addEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGFEGaussianBlurElement, ev: SVGElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGFEGaussianBlurElement, ev: SVGElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var SVGFEGaussianBlurElement: {
    prototype: SVGFEGaussianBlurElement;
    new(): SVGFEGaussianBlurElement;
};

/**
 * The **`SVGFEImageElement`** interface corresponds to the <feImage> element.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFEImageElement)
 */
interface SVGFEImageElement extends SVGElement, SVGFilterPrimitiveStandardAttributes, SVGURIReference {
    /**
     * The **`preserveAspectRatio`** read-only property of the SVGFEImageElement interface reflects the preserveAspectRatio attribute of the given <feImage> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFEImageElement/preserveAspectRatio)
     */
    readonly preserveAspectRatio: SVGAnimatedPreserveAspectRatio;
    addEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGFEImageElement, ev: SVGElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGFEImageElement, ev: SVGElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var SVGFEImageElement: {
    prototype: SVGFEImageElement;
    new(): SVGFEImageElement;
};

/**
 * The **`SVGFEMergeElement`** interface corresponds to the <feMerge> element.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFEMergeElement)
 */
interface SVGFEMergeElement extends SVGElement, SVGFilterPrimitiveStandardAttributes {
    addEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGFEMergeElement, ev: SVGElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGFEMergeElement, ev: SVGElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var SVGFEMergeElement: {
    prototype: SVGFEMergeElement;
    new(): SVGFEMergeElement;
};

/**
 * The **`SVGFEMergeNodeElement`** interface corresponds to the <feMergeNode> element.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFEMergeNodeElement)
 */
interface SVGFEMergeNodeElement extends SVGElement {
    /**
     * The **`in1`** read-only property of the SVGFEMergeNodeElement interface reflects the in attribute of the given <feMergeNode> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFEMergeNodeElement/in1)
     */
    readonly in1: SVGAnimatedString;
    addEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGFEMergeNodeElement, ev: SVGElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGFEMergeNodeElement, ev: SVGElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var SVGFEMergeNodeElement: {
    prototype: SVGFEMergeNodeElement;
    new(): SVGFEMergeNodeElement;
};

/**
 * The **`SVGFEMorphologyElement`** interface corresponds to the <feMorphology> element.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFEMorphologyElement)
 */
interface SVGFEMorphologyElement extends SVGElement, SVGFilterPrimitiveStandardAttributes {
    /**
     * The **`in1`** read-only property of the SVGFEMorphologyElement interface reflects the in attribute of the given <feMorphology> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFEMorphologyElement/in1)
     */
    readonly in1: SVGAnimatedString;
    /**
     * The **`operator`** read-only property of the SVGFEMorphologyElement interface reflects the operator attribute of the given <feMorphology> element. It takes one of the SVG_MORPHOLOGY_OPERATOR_* constants defined on this interface.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFEMorphologyElement/operator)
     */
    readonly operator: SVGAnimatedEnumeration;
    /**
     * The **`radiusX`** read-only property of the SVGFEMorphologyElement interface reflects the X component of the radius attribute of the given <feMorphology> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFEMorphologyElement/radiusX)
     */
    readonly radiusX: SVGAnimatedNumber;
    /**
     * The **`radiusY`** read-only property of the SVGFEMorphologyElement interface reflects the Y component of the radius attribute of the given <feMorphology> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFEMorphologyElement/radiusY)
     */
    readonly radiusY: SVGAnimatedNumber;
    readonly SVG_MORPHOLOGY_OPERATOR_UNKNOWN: 0;
    readonly SVG_MORPHOLOGY_OPERATOR_ERODE: 1;
    readonly SVG_MORPHOLOGY_OPERATOR_DILATE: 2;
    addEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGFEMorphologyElement, ev: SVGElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGFEMorphologyElement, ev: SVGElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var SVGFEMorphologyElement: {
    prototype: SVGFEMorphologyElement;
    new(): SVGFEMorphologyElement;
    readonly SVG_MORPHOLOGY_OPERATOR_UNKNOWN: 0;
    readonly SVG_MORPHOLOGY_OPERATOR_ERODE: 1;
    readonly SVG_MORPHOLOGY_OPERATOR_DILATE: 2;
};

/**
 * The **`SVGFEOffsetElement`** interface corresponds to the <feOffset> element.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFEOffsetElement)
 */
interface SVGFEOffsetElement extends SVGElement, SVGFilterPrimitiveStandardAttributes {
    /**
     * The **`dx`** read-only property of the SVGFEOffsetElement interface reflects the dx attribute of the given <feOffset> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFEOffsetElement/dx)
     */
    readonly dx: SVGAnimatedNumber;
    /**
     * The **`dy`** read-only property of the SVGFEOffsetElement interface reflects the dy attribute of the given <feOffset> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFEOffsetElement/dy)
     */
    readonly dy: SVGAnimatedNumber;
    /**
     * The **`in1`** read-only property of the SVGFEOffsetElement interface reflects the in attribute of the given <feOffset> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFEOffsetElement/in1)
     */
    readonly in1: SVGAnimatedString;
    addEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGFEOffsetElement, ev: SVGElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGFEOffsetElement, ev: SVGElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var SVGFEOffsetElement: {
    prototype: SVGFEOffsetElement;
    new(): SVGFEOffsetElement;
};

/**
 * The **`SVGFEPointLightElement`** interface corresponds to the <fePointLight> element.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFEPointLightElement)
 */
interface SVGFEPointLightElement extends SVGElement {
    /**
     * The **`x`** read-only property of the SVGFEPointLightElement interface describes the horizontal coordinate of the position of an SVG filter primitive as a SVGAnimatedNumber.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFEPointLightElement/x)
     */
    readonly x: SVGAnimatedNumber;
    /**
     * The **`y`** read-only property of the SVGFEPointLightElement interface describes the vertical coordinate of the position of an SVG filter primitive as a SVGAnimatedNumber.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFEPointLightElement/y)
     */
    readonly y: SVGAnimatedNumber;
    /**
     * The **`z`** read-only property of the SVGFEPointLightElement interface describes the z-axis value of the position of an SVG filter primitive as a SVGAnimatedNumber. A positive Z-axis comes out towards the person viewing the content.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFEPointLightElement/z)
     */
    readonly z: SVGAnimatedNumber;
    addEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGFEPointLightElement, ev: SVGElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGFEPointLightElement, ev: SVGElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var SVGFEPointLightElement: {
    prototype: SVGFEPointLightElement;
    new(): SVGFEPointLightElement;
};

/**
 * The **`SVGFESpecularLightingElement`** interface corresponds to the <feSpecularLighting> element.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFESpecularLightingElement)
 */
interface SVGFESpecularLightingElement extends SVGElement, SVGFilterPrimitiveStandardAttributes {
    /**
     * The **`in1`** read-only property of the SVGFESpecularLightingElement interface reflects the in attribute of the given <feSpecularLighting> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFESpecularLightingElement/in1)
     */
    readonly in1: SVGAnimatedString;
    /**
     * The **`kernelUnitLengthX`** read-only property of the SVGFESpecularLightingElement interface reflects the x value of the kernelUnitLength attribute of the given <feSpecularLighting> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFESpecularLightingElement/kernelUnitLengthX)
     */
    readonly kernelUnitLengthX: SVGAnimatedNumber;
    /**
     * The **`kernelUnitLengthY`** read-only property of the SVGFESpecularLightingElement interface reflects the y value of the kernelUnitLength attribute of the given <feSpecularLighting> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFESpecularLightingElement/kernelUnitLengthY)
     */
    readonly kernelUnitLengthY: SVGAnimatedNumber;
    /**
     * The **`specularConstant`** read-only property of the SVGFESpecularLightingElement interface reflects the specularConstant attribute of the given <feSpecularLighting> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFESpecularLightingElement/specularConstant)
     */
    readonly specularConstant: SVGAnimatedNumber;
    /**
     * The **`specularExponent`** read-only property of the SVGFESpecularLightingElement interface reflects the specularExponent attribute of the given <feSpecularLighting> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFESpecularLightingElement/specularExponent)
     */
    readonly specularExponent: SVGAnimatedNumber;
    /**
     * The **`surfaceScale`** read-only property of the SVGFESpecularLightingElement interface reflects the surfaceScale attribute of the given <feSpecularLighting> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFESpecularLightingElement/surfaceScale)
     */
    readonly surfaceScale: SVGAnimatedNumber;
    addEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGFESpecularLightingElement, ev: SVGElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGFESpecularLightingElement, ev: SVGElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var SVGFESpecularLightingElement: {
    prototype: SVGFESpecularLightingElement;
    new(): SVGFESpecularLightingElement;
};

/**
 * The **`SVGFESpotLightElement`** interface corresponds to the <feSpotLight> element.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFESpotLightElement)
 */
interface SVGFESpotLightElement extends SVGElement {
    /**
     * The **`limitingConeAngle`** read-only property of the SVGFESpotLightElement interface reflects the limitingConeAngle attribute of the given <feSpotLight> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFESpotLightElement/limitingConeAngle)
     */
    readonly limitingConeAngle: SVGAnimatedNumber;
    /**
     * The **`pointsAtX`** read-only property of the SVGFESpotLightElement interface reflects the pointsAtX attribute of the given <feSpotLight> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFESpotLightElement/pointsAtX)
     */
    readonly pointsAtX: SVGAnimatedNumber;
    /**
     * The **`pointsAtY`** read-only property of the SVGFESpotLightElement interface reflects the pointsAtY attribute of the given <feSpotLight> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFESpotLightElement/pointsAtY)
     */
    readonly pointsAtY: SVGAnimatedNumber;
    /**
     * The **`pointsAtZ`** read-only property of the SVGFESpotLightElement interface reflects the pointsAtZ attribute of the given <feSpotLight> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFESpotLightElement/pointsAtZ)
     */
    readonly pointsAtZ: SVGAnimatedNumber;
    /**
     * The **`specularExponent`** read-only property of the SVGFESpotLightElement interface reflects the specularExponent attribute of the given <feSpotLight> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFESpotLightElement/specularExponent)
     */
    readonly specularExponent: SVGAnimatedNumber;
    /**
     * The **`x`** read-only property of the SVGFESpotLightElement interface describes the horizontal coordinate of the position of an SVG filter primitive as a SVGAnimatedNumber.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFESpotLightElement/x)
     */
    readonly x: SVGAnimatedNumber;
    /**
     * The **`y`** read-only property of the SVGFESpotLightElement interface describes the vertical coordinate of the position of an SVG filter primitive as a SVGAnimatedNumber.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFESpotLightElement/y)
     */
    readonly y: SVGAnimatedNumber;
    /**
     * The **`z`** read-only property of the SVGFESpotLightElement interface describes the z-axis value of the position of an SVG filter primitive as a SVGAnimatedNumber. A positive Z-axis comes out towards the person viewing the content.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFESpotLightElement/z)
     */
    readonly z: SVGAnimatedNumber;
    addEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGFESpotLightElement, ev: SVGElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGFESpotLightElement, ev: SVGElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var SVGFESpotLightElement: {
    prototype: SVGFESpotLightElement;
    new(): SVGFESpotLightElement;
};

/**
 * The **`SVGFETileElement`** interface corresponds to the <feTile> element.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFETileElement)
 */
interface SVGFETileElement extends SVGElement, SVGFilterPrimitiveStandardAttributes {
    /**
     * The **`in1`** read-only property of the SVGFETileElement interface reflects the in attribute of the given <feTile> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFETileElement/in1)
     */
    readonly in1: SVGAnimatedString;
    addEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGFETileElement, ev: SVGElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGFETileElement, ev: SVGElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var SVGFETileElement: {
    prototype: SVGFETileElement;
    new(): SVGFETileElement;
};

/**
 * The **`SVGFETurbulenceElement`** interface corresponds to the <feTurbulence> element.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFETurbulenceElement)
 */
interface SVGFETurbulenceElement extends SVGElement, SVGFilterPrimitiveStandardAttributes {
    /**
     * The **`baseFrequencyX`** read-only property of the SVGFETurbulenceElement interface reflects the X component of the baseFrequency attribute of the given <feTurbulence> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFETurbulenceElement/baseFrequencyX)
     */
    readonly baseFrequencyX: SVGAnimatedNumber;
    /**
     * The **`baseFrequencyY`** read-only property of the SVGFETurbulenceElement interface reflects the Y component of the baseFrequency attribute of the given <feTurbulence> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFETurbulenceElement/baseFrequencyY)
     */
    readonly baseFrequencyY: SVGAnimatedNumber;
    /**
     * The **`numOctaves`** read-only property of the SVGFETurbulenceElement interface reflects the numOctaves attribute of the given <feTurbulence> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFETurbulenceElement/numOctaves)
     */
    readonly numOctaves: SVGAnimatedInteger;
    /**
     * The **`seed`** read-only property of the SVGFETurbulenceElement interface reflects the seed attribute of the given <feTurbulence> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFETurbulenceElement/seed)
     */
    readonly seed: SVGAnimatedNumber;
    /**
     * The **`stitchTiles`** read-only property of the SVGFETurbulenceElement interface reflects the stitchTiles attribute of the given <feTurbulence> element. It takes one of the SVG_STITCHTYPE_* constants defined on this interface.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFETurbulenceElement/stitchTiles)
     */
    readonly stitchTiles: SVGAnimatedEnumeration;
    /**
     * The **`type`** read-only property of the SVGFETurbulenceElement interface reflects the type attribute of the given <feTurbulence> element. It takes one of the SVG_TURBULENCE_TYPE_* constants defined on this interface.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFETurbulenceElement/type)
     */
    readonly type: SVGAnimatedEnumeration;
    readonly SVG_TURBULENCE_TYPE_UNKNOWN: 0;
    readonly SVG_TURBULENCE_TYPE_FRACTALNOISE: 1;
    readonly SVG_TURBULENCE_TYPE_TURBULENCE: 2;
    readonly SVG_STITCHTYPE_UNKNOWN: 0;
    readonly SVG_STITCHTYPE_STITCH: 1;
    readonly SVG_STITCHTYPE_NOSTITCH: 2;
    addEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGFETurbulenceElement, ev: SVGElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGFETurbulenceElement, ev: SVGElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var SVGFETurbulenceElement: {
    prototype: SVGFETurbulenceElement;
    new(): SVGFETurbulenceElement;
    readonly SVG_TURBULENCE_TYPE_UNKNOWN: 0;
    readonly SVG_TURBULENCE_TYPE_FRACTALNOISE: 1;
    readonly SVG_TURBULENCE_TYPE_TURBULENCE: 2;
    readonly SVG_STITCHTYPE_UNKNOWN: 0;
    readonly SVG_STITCHTYPE_STITCH: 1;
    readonly SVG_STITCHTYPE_NOSTITCH: 2;
};

/**
 * The **`SVGFilterElement`** interface provides access to the properties of <filter> elements, as well as methods to manipulate them.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFilterElement)
 */
interface SVGFilterElement extends SVGElement, SVGURIReference {
    /**
     * The **`filterUnits`** read-only property of the SVGFilterElement interface reflects the filterUnits attribute of the given <filter> element. It takes one of the SVG_UNIT_TYPE_* constants defined in SVGUnitTypes.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFilterElement/filterUnits)
     */
    readonly filterUnits: SVGAnimatedEnumeration;
    /**
     * The **`height`** read-only property of the SVGFilterElement interface describes the vertical size of an SVG filter primitive as a SVGAnimatedLength.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFilterElement/height)
     */
    readonly height: SVGAnimatedLength;
    /**
     * The **`primitiveUnits`** read-only property of the SVGFilterElement interface reflects the primitiveUnits attribute of the given <filter> element. It takes one of the SVG_UNIT_TYPE_* constants defined in SVGUnitTypes.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFilterElement/primitiveUnits)
     */
    readonly primitiveUnits: SVGAnimatedEnumeration;
    /**
     * The **`width`** read-only property of the SVGFilterElement interface describes the horizontal size of an SVG filter primitive as a SVGAnimatedLength.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFilterElement/width)
     */
    readonly width: SVGAnimatedLength;
    /**
     * The **`x`** read-only property of the SVGFilterElement interface describes the horizontal coordinate of the position of an SVG filter primitive as a SVGAnimatedLength.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFilterElement/x)
     */
    readonly x: SVGAnimatedLength;
    /**
     * The **`y`** read-only property of the SVGFilterElement interface describes the vertical coordinate of the position of an SVG filter primitive as a SVGAnimatedLength.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFilterElement/y)
     */
    readonly y: SVGAnimatedLength;
    addEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGFilterElement, ev: SVGElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGFilterElement, ev: SVGElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var SVGFilterElement: {
    prototype: SVGFilterElement;
    new(): SVGFilterElement;
};

interface SVGFilterPrimitiveStandardAttributes {
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFEBlendElement/height) */
    readonly height: SVGAnimatedLength;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFEBlendElement/result) */
    readonly result: SVGAnimatedString;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFEBlendElement/width) */
    readonly width: SVGAnimatedLength;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFEBlendElement/x) */
    readonly x: SVGAnimatedLength;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGFEBlendElement/y) */
    readonly y: SVGAnimatedLength;
}

interface SVGFitToViewBox {
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGMarkerElement/preserveAspectRatio) */
    readonly preserveAspectRatio: SVGAnimatedPreserveAspectRatio;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGMarkerElement/viewBox) */
    readonly viewBox: SVGAnimatedRect;
}

/**
 * The **`SVGForeignObjectElement`** interface provides access to the properties of <foreignObject> elements, as well as methods to manipulate them.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGForeignObjectElement)
 */
interface SVGForeignObjectElement extends SVGGraphicsElement {
    /**
     * The **`height`** read-only property of the SVGForeignObjectElement interface describes the height of the <foreignObject> element. It reflects the computed value of the height attribute on the <foreignObject> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGForeignObjectElement/height)
     */
    readonly height: SVGAnimatedLength;
    /**
     * The **`width`** read-only property of the SVGForeignObjectElement interface describes the width of the <foreignObject> element. It reflects the computed value of the width attribute on the <foreignObject> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGForeignObjectElement/width)
     */
    readonly width: SVGAnimatedLength;
    /**
     * The **`x`** read-only property of the SVGForeignObjectElement interface describes the x-axis coordinate of the <foreignObject> element. It reflects the computed value of the x attribute on the <foreignObject> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGForeignObjectElement/x)
     */
    readonly x: SVGAnimatedLength;
    /**
     * The **`y`** read-only property of the SVGForeignObjectElement interface describes the y-axis coordinate of the <foreignObject> element. It reflects the computed value of the y attribute on the <foreignObject> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGForeignObjectElement/y)
     */
    readonly y: SVGAnimatedLength;
    addEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGForeignObjectElement, ev: SVGElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGForeignObjectElement, ev: SVGElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var SVGForeignObjectElement: {
    prototype: SVGForeignObjectElement;
    new(): SVGForeignObjectElement;
};

/**
 * The **`SVGGElement`** interface corresponds to the <g> element.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGGElement)
 */
interface SVGGElement extends SVGGraphicsElement {
    addEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGGElement, ev: SVGElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGGElement, ev: SVGElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var SVGGElement: {
    prototype: SVGGElement;
    new(): SVGGElement;
};

/**
 * The **`SVGGeometryElement`** interface represents SVG elements whose rendering is defined by geometry with an equivalent path, and which can be filled and stroked. This includes paths and the basic shapes.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGGeometryElement)
 */
interface SVGGeometryElement extends SVGGraphicsElement {
    /**
     * The **`SVGGeometryElement.pathLength`** property reflects the pathLength attribute and returns the total length of the path, in user units.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGGeometryElement/pathLength)
     */
    readonly pathLength: SVGAnimatedNumber;
    /**
     * The **`SVGGeometryElement.getPointAtLength()`** method returns the point at a given distance along the path.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGGeometryElement/getPointAtLength)
     */
    getPointAtLength(distance: number): DOMPoint;
    /**
     * The **`SVGGeometryElement.getTotalLength()`** method returns the user agent's computed value for the total length of the path in user units.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGGeometryElement/getTotalLength)
     */
    getTotalLength(): number;
    /**
     * The **`isPointInFill()`** method of the SVGGeometryElement interface determines whether a given point is within the fill shape of an element. The point argument is interpreted as a point in the local coordinate system of the element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGGeometryElement/isPointInFill)
     */
    isPointInFill(point?: DOMPointInit): boolean;
    /**
     * The **`isPointInStroke()`** method of the SVGGeometryElement interface determines whether a given point is within the stroke shape of an element. The point argument is interpreted as a point in the local coordinate system of the element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGGeometryElement/isPointInStroke)
     */
    isPointInStroke(point?: DOMPointInit): boolean;
    addEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGGeometryElement, ev: SVGElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGGeometryElement, ev: SVGElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var SVGGeometryElement: {
    prototype: SVGGeometryElement;
    new(): SVGGeometryElement;
};

/**
 * The SVGGradient interface is a base interface used by SVGLinearGradientElement and SVGRadialGradientElement.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGGradientElement)
 */
interface SVGGradientElement extends SVGElement, SVGURIReference {
    /**
     * The **`gradientTransform`** read-only property of the SVGGradientElement interface reflects the gradientTransform attribute of the given element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGGradientElement/gradientTransform)
     */
    readonly gradientTransform: SVGAnimatedTransformList;
    /**
     * The **`gradientUnits`** read-only property of the SVGGradientElement interface reflects the gradientUnits attribute of the given element. It takes one of the SVG_UNIT_TYPE_* constants defined in SVGUnitTypes.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGGradientElement/gradientUnits)
     */
    readonly gradientUnits: SVGAnimatedEnumeration;
    /**
     * The **`spreadMethod`** read-only property of the SVGGradientElement interface reflects the spreadMethod attribute of the given element. It takes one of the SVG_SPREADMETHOD_* constants defined on this interface.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGGradientElement/spreadMethod)
     */
    readonly spreadMethod: SVGAnimatedEnumeration;
    readonly SVG_SPREADMETHOD_UNKNOWN: 0;
    readonly SVG_SPREADMETHOD_PAD: 1;
    readonly SVG_SPREADMETHOD_REFLECT: 2;
    readonly SVG_SPREADMETHOD_REPEAT: 3;
    addEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGGradientElement, ev: SVGElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGGradientElement, ev: SVGElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var SVGGradientElement: {
    prototype: SVGGradientElement;
    new(): SVGGradientElement;
    readonly SVG_SPREADMETHOD_UNKNOWN: 0;
    readonly SVG_SPREADMETHOD_PAD: 1;
    readonly SVG_SPREADMETHOD_REFLECT: 2;
    readonly SVG_SPREADMETHOD_REPEAT: 3;
};

/**
 * The **`SVGGraphicsElement`** interface represents SVG elements whose primary purpose is to directly render graphics into a group.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGGraphicsElement)
 */
interface SVGGraphicsElement extends SVGElement, SVGTests {
    /**
     * The **`transform`** read-only property of the SVGGraphicsElement interface reflects the computed value of the transform property and its corresponding transform attribute of the given element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGGraphicsElement/transform)
     */
    readonly transform: SVGAnimatedTransformList;
    /**
     * The **`SVGGraphicsElement.getBBox()`** method allows us to determine the coordinates of the smallest rectangle in which the object fits. The coordinates returned are with respect to the current SVG space (after the application of all geometry attributes on all the elements contained in the target element).
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGGraphicsElement/getBBox)
     */
    getBBox(options?: SVGBoundingBoxOptions): DOMRect;
    /**
     * The **`getCTM()`** method of the SVGGraphicsElement interface represents the matrix that transforms the current element's coordinate system to its SVG viewport's coordinate system.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGGraphicsElement/getCTM)
     */
    getCTM(): DOMMatrix | null;
    /**
     * The **`getScreenCTM()`** method of the SVGGraphicsElement interface represents the matrix that transforms the current element's coordinate system to the coordinate system of the SVG viewport for the SVG document fragment.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGGraphicsElement/getScreenCTM)
     */
    getScreenCTM(): DOMMatrix | null;
    addEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGGraphicsElement, ev: SVGElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGGraphicsElement, ev: SVGElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var SVGGraphicsElement: {
    prototype: SVGGraphicsElement;
    new(): SVGGraphicsElement;
};

/**
 * The **`SVGImageElement`** interface corresponds to the <image> element.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGImageElement)
 */
interface SVGImageElement extends SVGGraphicsElement, SVGURIReference {
    /**
     * The **`crossOrigin`** property of the SVGImageElement interface is a string which specifies the Cross-Origin Resource Sharing (CORS) setting to use when retrieving the image. It reflects the crossorigin content attribute of the given <image> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGImageElement/crossOrigin)
     */
    crossOrigin: string | null;
    /**
     * The **`height`** read-only property of the SVGImageElement interface returns an SVGAnimatedLength corresponding to the height attribute of the given <image> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGImageElement/height)
     */
    readonly height: SVGAnimatedLength;
    /**
     * The **`preserveAspectRatio`** read-only property of the SVGImageElement interface returns an SVGAnimatedPreserveAspectRatio corresponding to the preserveAspectRatio attribute of the given <image> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGImageElement/preserveAspectRatio)
     */
    readonly preserveAspectRatio: SVGAnimatedPreserveAspectRatio;
    /**
     * The **`width`** read-only property of the SVGImageElement interface returns an SVGAnimatedLength corresponding to the width attribute of the given <image> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGImageElement/width)
     */
    readonly width: SVGAnimatedLength;
    /**
     * The **`x`** read-only property of the SVGImageElement interface returns an SVGAnimatedLength corresponding to the x attribute of the given <image> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGImageElement/x)
     */
    readonly x: SVGAnimatedLength;
    /**
     * The **`y`** read-only property of the SVGImageElement interface returns an SVGAnimatedLength corresponding to the y attribute of the given <image> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGImageElement/y)
     */
    readonly y: SVGAnimatedLength;
    addEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGImageElement, ev: SVGElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGImageElement, ev: SVGElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var SVGImageElement: {
    prototype: SVGImageElement;
    new(): SVGImageElement;
};

/**
 * The **`SVGLength`** interface correspond to the <length> basic data type.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGLength)
 */
interface SVGLength {
    /**
     * The **`unitType`** property of the SVGLength interface that represents type of the value as specified by one of the SVG_LENGTHTYPE_* constants defined on this interface.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGLength/unitType)
     */
    readonly unitType: number;
    /**
     * The **`value`** property of the SVGLength interface represents the floating point value of the <length> in user units.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGLength/value)
     */
    value: number;
    /**
     * The **`valueAsString`** property of the SVGLength interface represents the <length>'s value as a string, in the units expressed by unitType.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGLength/valueAsString)
     */
    valueAsString: string;
    /**
     * The **`valueInSpecifiedUnits`** property of the SVGLength interface represents floating point value, in the units expressed by unitType.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGLength/valueInSpecifiedUnits)
     */
    valueInSpecifiedUnits: number;
    /**
     * The **`convertToSpecifiedUnits()`** method of the SVGLength interface allows you to convert the length's value to the specified unit type.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGLength/convertToSpecifiedUnits)
     */
    convertToSpecifiedUnits(unitType: number): void;
    /**
     * The **`newValueSpecifiedUnits()`** method of the SVGLength interface resets the value as a number with an associated unitType, thereby replacing the values for all of the attributes on the object.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGLength/newValueSpecifiedUnits)
     */
    newValueSpecifiedUnits(unitType: number, valueInSpecifiedUnits: number): void;
    readonly SVG_LENGTHTYPE_UNKNOWN: 0;
    readonly SVG_LENGTHTYPE_NUMBER: 1;
    readonly SVG_LENGTHTYPE_PERCENTAGE: 2;
    readonly SVG_LENGTHTYPE_EMS: 3;
    readonly SVG_LENGTHTYPE_EXS: 4;
    readonly SVG_LENGTHTYPE_PX: 5;
    readonly SVG_LENGTHTYPE_CM: 6;
    readonly SVG_LENGTHTYPE_MM: 7;
    readonly SVG_LENGTHTYPE_IN: 8;
    readonly SVG_LENGTHTYPE_PT: 9;
    readonly SVG_LENGTHTYPE_PC: 10;
}

declare var SVGLength: {
    prototype: SVGLength;
    new(): SVGLength;
    readonly SVG_LENGTHTYPE_UNKNOWN: 0;
    readonly SVG_LENGTHTYPE_NUMBER: 1;
    readonly SVG_LENGTHTYPE_PERCENTAGE: 2;
    readonly SVG_LENGTHTYPE_EMS: 3;
    readonly SVG_LENGTHTYPE_EXS: 4;
    readonly SVG_LENGTHTYPE_PX: 5;
    readonly SVG_LENGTHTYPE_CM: 6;
    readonly SVG_LENGTHTYPE_MM: 7;
    readonly SVG_LENGTHTYPE_IN: 8;
    readonly SVG_LENGTHTYPE_PT: 9;
    readonly SVG_LENGTHTYPE_PC: 10;
};

/**
 * The **`SVGLengthList`** interface defines a list of SVGLength objects. It is used for the baseVal and animVal properties of SVGAnimatedLengthList.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGLengthList)
 */
interface SVGLengthList {
    /**
     * The **`length`** property of the SVGLengthList interface returns the number of items in the list. It is an alias of numberOfItems to make SVG lists more array-like.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGLengthList/length)
     */
    readonly length: number;
    /**
     * The **`numberOfItems`** property of the SVGLengthList interface returns the number of items in the list. length is an alias of it.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGLengthList/numberOfItems)
     */
    readonly numberOfItems: number;
    /**
     * The **`appendItem()`** method of the SVGLengthList interface inserts a new item at the end of the list. If the given item is already in a list, it is removed from its previous list before it is inserted into this list. The inserted item is the item itself and not a copy.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGLengthList/appendItem)
     */
    appendItem(newItem: SVGLength): SVGLength;
    /**
     * The **`clear()`** method of the SVGLengthList interface clears all existing items from the list, with the result being an empty list.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGLengthList/clear)
     */
    clear(): void;
    /**
     * The **`getItem()`** method of the SVGLengthList interface returns the specified item from the list. The returned item is the item itself and not a copy. Any changes made to the item are immediately reflected in the list. The first item is indexed 0.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGLengthList/getItem)
     */
    getItem(index: number): SVGLength;
    /**
     * The **`initialize()`** method of the SVGLengthList interface clears all existing items from the list and re-initializes the list to hold the single item specified by the parameter. If the inserted item is already in a list, it is removed from its previous list before it is inserted into this list. The inserted item is the item itself and not a copy. The return value is the item inserted into the list.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGLengthList/initialize)
     */
    initialize(newItem: SVGLength): SVGLength;
    /**
     * The **`insertItemBefore()`** method of the SVGLengthList interface inserts a new item into the list at the specified position. The first item is indexed 0. The inserted item is the item itself and not a copy.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGLengthList/insertItemBefore)
     */
    insertItemBefore(newItem: SVGLength, index: number): SVGLength;
    /**
     * The **`removeItem()`** method of the SVGLengthList interface removes an existing item at the given index from the list.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGLengthList/removeItem)
     */
    removeItem(index: number): SVGLength;
    /**
     * The **`replaceItem()`** method of the SVGLengthList interface replaces an existing item in the list with a new item. If the new item is already in a list, it is removed from its previous list before it is inserted into this list. The inserted item is the item itself and not a copy. If the item is already in this list, note that the index of the item to replace is before the removal of the item.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGLengthList/replaceItem)
     */
    replaceItem(newItem: SVGLength, index: number): SVGLength;
    [index: number]: SVGLength;
}

declare var SVGLengthList: {
    prototype: SVGLengthList;
    new(): SVGLengthList;
};

/**
 * The **`SVGLineElement`** interface provides access to the properties of <line> elements, as well as methods to manipulate them.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGLineElement)
 */
interface SVGLineElement extends SVGGeometryElement {
    /**
     * The **`x1`** read-only property of the SVGLineElement interface describes the start of the SVG line along the x-axis as an SVGAnimatedLength. It reflects the <line> element's x1 geometric attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGLineElement/x1)
     */
    readonly x1: SVGAnimatedLength;
    /**
     * The **`x2`** read-only property of the SVGLineElement interface describes the x-axis coordinate value of the end of a line as an SVGAnimatedLength. It reflects the <line> element's x2 geometric attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGLineElement/x2)
     */
    readonly x2: SVGAnimatedLength;
    /**
     * The **`y1`** read-only property of the SVGLineElement interface describes the start of the SVG line along the y-axis as an SVGAnimatedLength. It reflects the <line> element's y1 geometric attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGLineElement/y1)
     */
    readonly y1: SVGAnimatedLength;
    /**
     * The **`y2`** read-only property of the SVGLineElement interface describes the v-axis coordinate value of the end of a line as an SVGAnimatedLength. It reflects the <line> element's y2 geometric attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGLineElement/y2)
     */
    readonly y2: SVGAnimatedLength;
    addEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGLineElement, ev: SVGElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGLineElement, ev: SVGElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var SVGLineElement: {
    prototype: SVGLineElement;
    new(): SVGLineElement;
};

/**
 * The **`SVGLinearGradientElement`** interface corresponds to the <linearGradient> element.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGLinearGradientElement)
 */
interface SVGLinearGradientElement extends SVGGradientElement {
    /**
     * The **`x1`** read-only property of the SVGLinearGradientElement interface describes the x-axis coordinate of the start point of the gradient as an SVGAnimatedLength. It reflects the computed value of the x1 attribute on the <linearGradient> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGLinearGradientElement/x1)
     */
    readonly x1: SVGAnimatedLength;
    /**
     * The **`x2`** read-only property of the SVGLinearGradientElement interface describes the x-axis coordinate of the start point of the gradient as an SVGAnimatedLength. It reflects the computed value of the x2 attribute on the <linearGradient> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGLinearGradientElement/x2)
     */
    readonly x2: SVGAnimatedLength;
    /**
     * The **`y1`** read-only property of the SVGLinearGradientElement interface describes the y-axis coordinate of the start point of the gradient as an SVGAnimatedLength. It reflects the computed value of the y1 attribute on the <linearGradient> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGLinearGradientElement/y1)
     */
    readonly y1: SVGAnimatedLength;
    /**
     * The **`y2`** read-only property of the SVGLinearGradientElement interface describes the y-axis coordinate of the start point of the gradient as an SVGAnimatedLength. It reflects the computed value of the y2 attribute on the <linearGradient> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGLinearGradientElement/y2)
     */
    readonly y2: SVGAnimatedLength;
    addEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGLinearGradientElement, ev: SVGElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGLinearGradientElement, ev: SVGElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var SVGLinearGradientElement: {
    prototype: SVGLinearGradientElement;
    new(): SVGLinearGradientElement;
};

/**
 * The **`SVGMPathElement`** interface corresponds to the <mpath> element.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGMPathElement)
 */
interface SVGMPathElement extends SVGElement, SVGURIReference {
    addEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGMPathElement, ev: SVGElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGMPathElement, ev: SVGElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var SVGMPathElement: {
    prototype: SVGMPathElement;
    new(): SVGMPathElement;
};

/**
 * The **`SVGMarkerElement`** interface provides access to the properties of <marker> elements, as well as methods to manipulate them. The <marker> element defines the graphics used for drawing marks on a shape.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGMarkerElement)
 */
interface SVGMarkerElement extends SVGElement, SVGFitToViewBox {
    /**
     * The **`markerHeight`** read-only property of the SVGMarkerElement interface returns an SVGAnimatedLength object containing the height of the <marker> viewport as defined by the markerHeight attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGMarkerElement/markerHeight)
     */
    readonly markerHeight: SVGAnimatedLength;
    /**
     * The **`markerUnits`** read-only property of the SVGMarkerElement interface returns an SVGAnimatedEnumeration object. This object returns an integer which represents the keyword values that the markerUnits attribute accepts.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGMarkerElement/markerUnits)
     */
    readonly markerUnits: SVGAnimatedEnumeration;
    /**
     * The **`markerWidth`** read-only property of the SVGMarkerElement interface returns an SVGAnimatedLength object containing the width of the <marker> viewport as defined by the markerWidth attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGMarkerElement/markerWidth)
     */
    readonly markerWidth: SVGAnimatedLength;
    /**
     * The **`orientAngle`** read-only property of the SVGMarkerElement interface returns an SVGAnimatedAngle object containing the angle of the orient attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGMarkerElement/orientAngle)
     */
    readonly orientAngle: SVGAnimatedAngle;
    /**
     * The **`orientType`** read-only property of the SVGMarkerElement interface returns an SVGAnimatedEnumeration object indicating whether the orient attribute is auto, an angle value, or something else.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGMarkerElement/orientType)
     */
    readonly orientType: SVGAnimatedEnumeration;
    /**
     * The **`refX`** read-only property of the SVGMarkerElement interface returns an SVGAnimatedLength object containing the value of the refX attribute of the <marker>.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGMarkerElement/refX)
     */
    readonly refX: SVGAnimatedLength;
    /**
     * The **`refY`** read-only property of the SVGMarkerElement interface returns an SVGAnimatedLength object containing the value of the refY attribute of the <marker>.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGMarkerElement/refY)
     */
    readonly refY: SVGAnimatedLength;
    /**
     * The **`setOrientToAngle()`** method of the SVGMarkerElement interface sets the value of the orient attribute to the value in the SVGAngle passed in.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGMarkerElement/setOrientToAngle)
     */
    setOrientToAngle(angle: SVGAngle): void;
    /**
     * The **`setOrientToAuto()`** method of the SVGMarkerElement interface sets the value of the orient attribute to auto.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGMarkerElement/setOrientToAuto)
     */
    setOrientToAuto(): void;
    readonly SVG_MARKERUNITS_UNKNOWN: 0;
    readonly SVG_MARKERUNITS_USERSPACEONUSE: 1;
    readonly SVG_MARKERUNITS_STROKEWIDTH: 2;
    readonly SVG_MARKER_ORIENT_UNKNOWN: 0;
    readonly SVG_MARKER_ORIENT_AUTO: 1;
    readonly SVG_MARKER_ORIENT_ANGLE: 2;
    readonly SVG_MARKER_ORIENT_AUTO_START_REVERSE: 3;
    addEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGMarkerElement, ev: SVGElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGMarkerElement, ev: SVGElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var SVGMarkerElement: {
    prototype: SVGMarkerElement;
    new(): SVGMarkerElement;
    readonly SVG_MARKERUNITS_UNKNOWN: 0;
    readonly SVG_MARKERUNITS_USERSPACEONUSE: 1;
    readonly SVG_MARKERUNITS_STROKEWIDTH: 2;
    readonly SVG_MARKER_ORIENT_UNKNOWN: 0;
    readonly SVG_MARKER_ORIENT_AUTO: 1;
    readonly SVG_MARKER_ORIENT_ANGLE: 2;
    readonly SVG_MARKER_ORIENT_AUTO_START_REVERSE: 3;
};

/**
 * The **`SVGMaskElement`** interface provides access to the properties of <mask> elements, as well as methods to manipulate them.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGMaskElement)
 */
interface SVGMaskElement extends SVGElement {
    /**
     * The read-only **`height`** property of the SVGMaskElement interface returns an SVGAnimatedLength object containing the value of the height attribute of the <mask>.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGMaskElement/height)
     */
    readonly height: SVGAnimatedLength;
    /**
     * The read-only **`maskContentUnits`** property of the SVGMaskElement interface reflects the maskContentUnits attribute. It indicates which coordinate system to use for the contents of the <mask> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGMaskElement/maskContentUnits)
     */
    readonly maskContentUnits: SVGAnimatedEnumeration;
    /**
     * The read-only **`maskUnits`** property of the SVGMaskElement interface reflects the maskUnits attribute of a <mask> element which defines the coordinate system to use for the mask of the element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGMaskElement/maskUnits)
     */
    readonly maskUnits: SVGAnimatedEnumeration;
    /**
     * The read-only **`width`** property of the SVGMaskElement interface returns an SVGAnimatedLength object containing the value of the width attribute of the <mask>.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGMaskElement/width)
     */
    readonly width: SVGAnimatedLength;
    /**
     * The read-only **`x`** property of the SVGMaskElement interface returns an SVGAnimatedLength object containing the value of the x attribute of the <mask>. It represents the x-axis coordinate of the top-left corner of the masking area.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGMaskElement/x)
     */
    readonly x: SVGAnimatedLength;
    /**
     * The read-onl**`y`** y property of the SVGMaskElement interface returns an SVGAnimatedLength object containing the value of the y attribute of the <mask>. It represents the y-axis coordinate of the top-left corner of the masking area.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGMaskElement/y)
     */
    readonly y: SVGAnimatedLength;
    addEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGMaskElement, ev: SVGElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGMaskElement, ev: SVGElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var SVGMaskElement: {
    prototype: SVGMaskElement;
    new(): SVGMaskElement;
};

/**
 * The **`SVGMetadataElement`** interface corresponds to the <metadata> element.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGMetadataElement)
 */
interface SVGMetadataElement extends SVGElement {
    addEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGMetadataElement, ev: SVGElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGMetadataElement, ev: SVGElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var SVGMetadataElement: {
    prototype: SVGMetadataElement;
    new(): SVGMetadataElement;
};

/**
 * The **`SVGNumber`** interface corresponds to the <number> basic data type.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGNumber)
 */
interface SVGNumber {
    /**
     * The **`value`** read-only property of the SVGNumber interface represents the number.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGNumber/value)
     */
    value: number;
}

declare var SVGNumber: {
    prototype: SVGNumber;
    new(): SVGNumber;
};

/**
 * The **`SVGNumberList`** interface defines a list of numbers.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGNumberList)
 */
interface SVGNumberList {
    /**
     * The **`length`** property of the SVGNumberList interface returns the number of items in the list. It is an alias of numberOfItems to make SVG lists more array-like.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGNumberList/length)
     */
    readonly length: number;
    /**
     * The **`numberOfItems`** property of the SVGNumberList interface returns the number of items in the list. length is an alias of it.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGNumberList/numberOfItems)
     */
    readonly numberOfItems: number;
    /**
     * The **`appendItem()`** method of the SVGNumberList interface inserts a new item at the end of the list. If the given item is already in a list, it is removed from its previous list before it is inserted into this list. The inserted item is the item itself and not a copy.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGNumberList/appendItem)
     */
    appendItem(newItem: SVGNumber): SVGNumber;
    /**
     * The **`clear()`** method of the SVGNumberList interface clears all existing items from the list, with the result being an empty list.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGNumberList/clear)
     */
    clear(): void;
    /**
     * The **`getItem()`** method of the SVGNumberList interface returns the specified item from the list. The returned item is the item itself and not a copy. Any changes made to the item are immediately reflected in the list. The first item is indexed 0.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGNumberList/getItem)
     */
    getItem(index: number): SVGNumber;
    /**
     * The **`initialize()`** method of the SVGNumberList interface clears all existing items from the list and re-initializes the list to hold the single item specified by the parameter. If the inserted item is already in a list, it is removed from its previous list before it is inserted into this list. The inserted item is the item itself and not a copy. The return value is the item inserted into the list.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGNumberList/initialize)
     */
    initialize(newItem: SVGNumber): SVGNumber;
    /**
     * The **`insertItemBefore()`** method of the SVGNumberList interface inserts a new item into the list at the specified position. The first item is indexed 0. The inserted item is the item itself and not a copy.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGNumberList/insertItemBefore)
     */
    insertItemBefore(newItem: SVGNumber, index: number): SVGNumber;
    /**
     * The **`removeItem()`** method of the SVGNumberList interface removes an existing item at the given index from the list.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGNumberList/removeItem)
     */
    removeItem(index: number): SVGNumber;
    /**
     * The **`replaceItem()`** method of the SVGNumberList interface replaces an existing item in the list with a new item. If the new item is already in a list, it is removed from its previous list before it is inserted into this list. The inserted item is the item itself and not a copy. If the item is already in this list, note that the index of the item to replace is before the removal of the item.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGNumberList/replaceItem)
     */
    replaceItem(newItem: SVGNumber, index: number): SVGNumber;
    [index: number]: SVGNumber;
}

declare var SVGNumberList: {
    prototype: SVGNumberList;
    new(): SVGNumberList;
};

/**
 * The **`SVGPathElement`** interface corresponds to the <path> element.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGPathElement)
 */
interface SVGPathElement extends SVGGeometryElement {
    /**
     * The **`pathLength`** read-only property of the SVGPathElement interface reflects the pathLength attribute of the given <path> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGPathElement/pathLength)
     */
    readonly pathLength: SVGAnimatedNumber;
    /**
     * The **`getPointAtLength()`** method of the SVGPathElement interface returns the point at a given distance along the path.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGPathElement/getPointAtLength)
     */
    getPointAtLength(distance: number): DOMPoint;
    /**
     * The **`getTotalLength()`** method of the SVGPathElement interface returns the user agent's computed value for the total length of the path in user units.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGPathElement/getTotalLength)
     */
    getTotalLength(): number;
    addEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGPathElement, ev: SVGElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGPathElement, ev: SVGElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var SVGPathElement: {
    prototype: SVGPathElement;
    new(): SVGPathElement;
};

/**
 * The **`SVGPatternElement`** interface corresponds to the <pattern> element.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGPatternElement)
 */
interface SVGPatternElement extends SVGElement, SVGFitToViewBox, SVGURIReference {
    /**
     * The **`height`** read-only property of the SVGPatternElement interface describes the height of the pattern as an SVGAnimatedLength. It reflects the computed value of the height attribute on the <pattern> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGPatternElement/height)
     */
    readonly height: SVGAnimatedLength;
    /**
     * The **`patternContentUnits`** read-only property of the SVGPatternElement interface reflects the patternContentUnits attribute of the given <pattern> element. It specifies the coordinate system for the pattern content and takes one of the constants defined in SVGUnitTypes.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGPatternElement/patternContentUnits)
     */
    readonly patternContentUnits: SVGAnimatedEnumeration;
    /**
     * The **`patternTransform`** read-only property of the SVGPatternElement interface reflects the patternTransform attribute of the given <pattern> element. This property holds the transformation applied to the pattern itself, allowing for operations like translate, rotate, scale, and skew.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGPatternElement/patternTransform)
     */
    readonly patternTransform: SVGAnimatedTransformList;
    /**
     * The **`patternUnits`** read-only property of the SVGPatternElement interface reflects the patternUnits attribute of the given <pattern> element. It specifies the coordinate system for the pattern content and takes one of the constants defined in SVGUnitTypes.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGPatternElement/patternUnits)
     */
    readonly patternUnits: SVGAnimatedEnumeration;
    /**
     * The **`width`** read-only property of the SVGPatternElement interface describes the width of the pattern as an SVGAnimatedLength. It reflects the computed value of the width attribute on the <pattern> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGPatternElement/width)
     */
    readonly width: SVGAnimatedLength;
    /**
     * The **`x`** read-only property of the SVGPatternElement interface describes the x-axis coordinate of the start point of the pattern as an SVGAnimatedLength. It reflects the computed value of the x attribute on the <pattern> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGPatternElement/x)
     */
    readonly x: SVGAnimatedLength;
    /**
     * The **`y`** read-only property of the SVGPatternElement interface describes the y-axis coordinate of the start point of the pattern as an SVGAnimatedLength. It reflects the computed value of the y attribute on the <pattern> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGPatternElement/y)
     */
    readonly y: SVGAnimatedLength;
    addEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGPatternElement, ev: SVGElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGPatternElement, ev: SVGElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var SVGPatternElement: {
    prototype: SVGPatternElement;
    new(): SVGPatternElement;
};

/**
 * The **`SVGPointList`** interface represents a list of DOMPoint objects.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGPointList)
 */
interface SVGPointList {
    /**
     * The **`length`** read-only property of the SVGPointList interface returns the number of items in the list.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGPointList/length)
     */
    readonly length: number;
    /**
     * The **`numberOfItems`** read-only property of the SVGPointList interface returns the number of items in the list.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGPointList/numberOfItems)
     */
    readonly numberOfItems: number;
    /**
     * The **`appendItem()`** method of the SVGPointList interface adds a DOMPoint to the end of the list.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGPointList/appendItem)
     */
    appendItem(newItem: DOMPoint): DOMPoint;
    /**
     * The **`clear()`** method of the SVGPointList interface removes all items from the list.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGPointList/clear)
     */
    clear(): void;
    /**
     * The **`getItem()`** method of the SVGPointList interface gets one item from the list at the specified index.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGPointList/getItem)
     */
    getItem(index: number): DOMPoint;
    /**
     * The **`initialize()`** method of the SVGPointList interface clears the list then adds a single new DOMPoint object to the list.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGPointList/initialize)
     */
    initialize(newItem: DOMPoint): DOMPoint;
    /**
     * The **`insertItemBefore()`** method of the SVGPointList interface inserts a DOMPoint before another item in the list.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGPointList/insertItemBefore)
     */
    insertItemBefore(newItem: DOMPoint, index: number): DOMPoint;
    /**
     * The **`removeItem()`** method of the SVGPointList interface removes a DOMPoint from the list.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGPointList/removeItem)
     */
    removeItem(index: number): DOMPoint;
    /**
     * The **`replaceItem()`** method of the SVGPointList interface replaces a DOMPoint in the list.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGPointList/replaceItem)
     */
    replaceItem(newItem: DOMPoint, index: number): DOMPoint;
    [index: number]: DOMPoint;
}

declare var SVGPointList: {
    prototype: SVGPointList;
    new(): SVGPointList;
};

/**
 * The **`SVGPolygonElement`** interface provides access to the properties of <polygon> elements, as well as methods to manipulate them.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGPolygonElement)
 */
interface SVGPolygonElement extends SVGGeometryElement, SVGAnimatedPoints {
    addEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGPolygonElement, ev: SVGElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGPolygonElement, ev: SVGElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var SVGPolygonElement: {
    prototype: SVGPolygonElement;
    new(): SVGPolygonElement;
};

/**
 * The **`SVGPolylineElement`** interface provides access to the properties of <polyline> elements, as well as methods to manipulate them.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGPolylineElement)
 */
interface SVGPolylineElement extends SVGGeometryElement, SVGAnimatedPoints {
    addEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGPolylineElement, ev: SVGElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGPolylineElement, ev: SVGElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var SVGPolylineElement: {
    prototype: SVGPolylineElement;
    new(): SVGPolylineElement;
};

/**
 * The **`SVGPreserveAspectRatio`** interface corresponds to the preserveAspectRatio attribute.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGPreserveAspectRatio)
 */
interface SVGPreserveAspectRatio {
    /**
     * The **`align`** read-only property of the SVGPreserveAspectRatio interface reflects the type of the alignment value as specified by one of the SVG_PRESERVEASPECTRATIO_* constants defined on this interface.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGPreserveAspectRatio/align)
     */
    align: number;
    /**
     * The **`meetOrSlice`** read-only property of the SVGPreserveAspectRatio interface reflects the type of the meet-or-slice value as specified by one of the SVG_MEETORSLICE_* constants defined on this interface.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGPreserveAspectRatio/meetOrSlice)
     */
    meetOrSlice: number;
    readonly SVG_PRESERVEASPECTRATIO_UNKNOWN: 0;
    readonly SVG_PRESERVEASPECTRATIO_NONE: 1;
    readonly SVG_PRESERVEASPECTRATIO_XMINYMIN: 2;
    readonly SVG_PRESERVEASPECTRATIO_XMIDYMIN: 3;
    readonly SVG_PRESERVEASPECTRATIO_XMAXYMIN: 4;
    readonly SVG_PRESERVEASPECTRATIO_XMINYMID: 5;
    readonly SVG_PRESERVEASPECTRATIO_XMIDYMID: 6;
    readonly SVG_PRESERVEASPECTRATIO_XMAXYMID: 7;
    readonly SVG_PRESERVEASPECTRATIO_XMINYMAX: 8;
    readonly SVG_PRESERVEASPECTRATIO_XMIDYMAX: 9;
    readonly SVG_PRESERVEASPECTRATIO_XMAXYMAX: 10;
    readonly SVG_MEETORSLICE_UNKNOWN: 0;
    readonly SVG_MEETORSLICE_MEET: 1;
    readonly SVG_MEETORSLICE_SLICE: 2;
}

declare var SVGPreserveAspectRatio: {
    prototype: SVGPreserveAspectRatio;
    new(): SVGPreserveAspectRatio;
    readonly SVG_PRESERVEASPECTRATIO_UNKNOWN: 0;
    readonly SVG_PRESERVEASPECTRATIO_NONE: 1;
    readonly SVG_PRESERVEASPECTRATIO_XMINYMIN: 2;
    readonly SVG_PRESERVEASPECTRATIO_XMIDYMIN: 3;
    readonly SVG_PRESERVEASPECTRATIO_XMAXYMIN: 4;
    readonly SVG_PRESERVEASPECTRATIO_XMINYMID: 5;
    readonly SVG_PRESERVEASPECTRATIO_XMIDYMID: 6;
    readonly SVG_PRESERVEASPECTRATIO_XMAXYMID: 7;
    readonly SVG_PRESERVEASPECTRATIO_XMINYMAX: 8;
    readonly SVG_PRESERVEASPECTRATIO_XMIDYMAX: 9;
    readonly SVG_PRESERVEASPECTRATIO_XMAXYMAX: 10;
    readonly SVG_MEETORSLICE_UNKNOWN: 0;
    readonly SVG_MEETORSLICE_MEET: 1;
    readonly SVG_MEETORSLICE_SLICE: 2;
};

/**
 * The **`SVGRadialGradientElement`** interface corresponds to the <RadialGradient> element.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGRadialGradientElement)
 */
interface SVGRadialGradientElement extends SVGGradientElement {
    /**
     * The **`cx`** read-only property of the SVGRadialGradientElement interface describes the x-axis coordinate of the center of the radial gradient as an SVGAnimatedLength. It reflects the computed value of the cx attribute on the <radialGradient> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGRadialGradientElement/cx)
     */
    readonly cx: SVGAnimatedLength;
    /**
     * The **`cy`** read-only property of the SVGRadialGradientElement interface describes the y-axis coordinate of the center of the radial gradient as an SVGAnimatedLength. It reflects the computed value of the cy attribute on the <radialGradient> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGRadialGradientElement/cy)
     */
    readonly cy: SVGAnimatedLength;
    /**
     * The **`fr`** read-only property of the SVGRadialGradientElement interface describes the radius of the focal circle of the radial gradient as an SVGAnimatedLength. It reflects the computed value of the fr attribute on the <radialGradient> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGRadialGradientElement/fr)
     */
    readonly fr: SVGAnimatedLength;
    /**
     * The **`fx`** read-only property of the SVGRadialGradientElement interface describes the x-axis coordinate of the focal point of the radial gradient as an SVGAnimatedLength. It reflects the computed value of the fx attribute on the <radialGradient> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGRadialGradientElement/fx)
     */
    readonly fx: SVGAnimatedLength;
    /**
     * The **`fy`** read-only property of the SVGRadialGradientElement interface describes the y-axis coordinate of the focal point of the radial gradient as an SVGAnimatedLength. It reflects the computed value of the fy attribute on the <radialGradient> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGRadialGradientElement/fy)
     */
    readonly fy: SVGAnimatedLength;
    /**
     * The **`r`** read-only property of the SVGRadialGradientElement interface describes the radius of the radial gradient as an SVGAnimatedLength. It reflects the computed value of the r attribute on the <radialGradient> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGRadialGradientElement/r)
     */
    readonly r: SVGAnimatedLength;
    addEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGRadialGradientElement, ev: SVGElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGRadialGradientElement, ev: SVGElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var SVGRadialGradientElement: {
    prototype: SVGRadialGradientElement;
    new(): SVGRadialGradientElement;
};

/**
 * The **`SVGRectElement`** interface provides access to the properties of <rect> elements, as well as methods to manipulate them.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGRectElement)
 */
interface SVGRectElement extends SVGGeometryElement {
    /**
     * The **`height`** read-only property of the SVGRectElement interface describes the vertical size of an SVG rectangle as a SVGAnimatedLength. The length is in user coordinate system units along the y-axis. Its syntax is the same as that for <length>.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGRectElement/height)
     */
    readonly height: SVGAnimatedLength;
    /**
     * The **`rx`** read-only property of the SVGRectElement interface describes the horizontal curve of the corners of an SVG rectangle as a SVGAnimatedLength. The length is in user coordinate system units along the x-axis. Its syntax is the same as that for <length>.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGRectElement/rx)
     */
    readonly rx: SVGAnimatedLength;
    /**
     * The **`ry`** read-only property of the SVGRectElement interface describes the vertical curve of the corners of an SVG rectangle as a SVGAnimatedLength. The length is in user coordinate system units along the y-axis. Its syntax is the same as that for <length>.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGRectElement/ry)
     */
    readonly ry: SVGAnimatedLength;
    /**
     * The **`width`** read-only property of the SVGRectElement interface describes the horizontal size of an SVG rectangle as a SVGAnimatedLength. The length is in user coordinate system units along the x-axis. Its syntax is the same as that for <length>.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGRectElement/width)
     */
    readonly width: SVGAnimatedLength;
    /**
     * The **`x`** read-only property of the SVGRectElement interface describes the horizontal coordinate of the position of an SVG rectangle as a SVGAnimatedLength. The <coordinate> is a length in the user coordinate system that is the given distance from the origin of the user coordinate system along the x-axis. Its syntax is the same as that for <length>.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGRectElement/x)
     */
    readonly x: SVGAnimatedLength;
    /**
     * The **`y`** read-only property of the SVGRectElement interface describes the vertical coordinate of the position of an SVG rectangle as a SVGAnimatedLength. The <coordinate> is a length in the user coordinate system that is the given distance from the origin of the user coordinate system along the y-axis. Its syntax is the same as that for <length>.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGRectElement/y)
     */
    readonly y: SVGAnimatedLength;
    addEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGRectElement, ev: SVGElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGRectElement, ev: SVGElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var SVGRectElement: {
    prototype: SVGRectElement;
    new(): SVGRectElement;
};

interface SVGSVGElementEventMap extends SVGElementEventMap, WindowEventHandlersEventMap {
}

/**
 * The **`SVGSVGElement`** interface provides access to the properties of <svg> elements, as well as methods to manipulate them. This interface contains also various miscellaneous commonly-used utility methods, such as matrix operations and the ability to control the time of redraw on visual rendering devices.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGSVGElement)
 */
interface SVGSVGElement extends SVGGraphicsElement, SVGFitToViewBox, WindowEventHandlers {
    /**
     * The **`currentScale`** property of the SVGSVGElement interface reflects the current scale factor relative to the initial view to take into account user magnification and panning operations on the outermost <svg> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGSVGElement/currentScale)
     */
    currentScale: number;
    /**
     * The **`currentTranslate`** read-only property of the SVGSVGElement interface reflects the translation factor that takes into account user "magnification" corresponding to an outermost <svg> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGSVGElement/currentTranslate)
     */
    readonly currentTranslate: DOMPointReadOnly;
    /**
     * The **`height`** read-only property of the SVGSVGElement interface describes the vertical size of element as an SVGAnimatedLength. It reflects the <svg> element's height attribute, which may not be the SVG's rendered height.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGSVGElement/height)
     */
    readonly height: SVGAnimatedLength;
    /**
     * The **`width`** read-only property of the SVGSVGElement interface describes the horizontal size of element as an SVGAnimatedLength. It reflects the <svg> element's width attribute, which may not be the SVG's rendered width.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGSVGElement/width)
     */
    readonly width: SVGAnimatedLength;
    /**
     * The **`x`** read-only property of the SVGSVGElement interface describes the horizontal coordinate of the position of that SVG as an SVGAnimatedLength. When an <svg> is nested within another <svg>, the horizontal coordinate is a length in the user coordinate system that is the given distance from the origin of the user coordinate system along the x-axis. Its syntax is the same as that for <length>.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGSVGElement/x)
     */
    readonly x: SVGAnimatedLength;
    /**
     * The **`y`** read-only property of the SVGSVGElement interface describes the vertical coordinate of the position of that SVG as an SVGAnimatedLength. When an <svg> is nested within another <svg>, the vertical coordinate is a length in the user coordinate system that is the given distance from the origin of the user coordinate system along the y-axis. Its syntax is the same as that for <length>.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGSVGElement/y)
     */
    readonly y: SVGAnimatedLength;
    /**
     * The **`animationsPaused()`** method of the SVGSVGElement interface checks whether the animations in the SVG document fragment are currently paused.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGSVGElement/animationsPaused)
     */
    animationsPaused(): boolean;
    /**
     * The **`checkEnclosure()`** method of the SVGSVGElement interface checks if the rendered content of the given element is entirely contained within the supplied rectangle.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGSVGElement/checkEnclosure)
     */
    checkEnclosure(element: SVGElement, rect: DOMRectReadOnly): boolean;
    /**
     * The **`checkIntersection()`** method of the SVGSVGElement interface checks if the rendered content of the given element intersects the supplied rectangle.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGSVGElement/checkIntersection)
     */
    checkIntersection(element: SVGElement, rect: DOMRectReadOnly): boolean;
    /**
     * The **`createSVGAngle()`** method of the SVGSVGElement interface creates an SVGAngle object outside of any document trees.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGSVGElement/createSVGAngle)
     */
    createSVGAngle(): SVGAngle;
    /**
     * The **`createSVGLength()`** method of the SVGSVGElement interface creates an SVGLength object outside of any document trees.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGSVGElement/createSVGLength)
     */
    createSVGLength(): SVGLength;
    /**
     * The **`createSVGMatrix()`** method of the SVGSVGElement interface creates a DOMMatrix object outside of any document trees.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGSVGElement/createSVGMatrix)
     */
    createSVGMatrix(): DOMMatrix;
    /**
     * The **`createSVGNumber()`** method of the SVGSVGElement interface creates an SVGNumber object outside of any document trees.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGSVGElement/createSVGNumber)
     */
    createSVGNumber(): SVGNumber;
    /**
     * The **`createSVGPoint()`** method of the SVGSVGElement interface creates a DOMPoint object outside of any document trees.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGSVGElement/createSVGPoint)
     */
    createSVGPoint(): DOMPoint;
    /**
     * The **`createSVGRect()`** method of the SVGSVGElement interface creates a DOMRect object outside of any document trees.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGSVGElement/createSVGRect)
     */
    createSVGRect(): DOMRect;
    /**
     * The **`createSVGTransform()`** method of the SVGSVGElement interface creates an SVGTransform object outside of any document trees.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGSVGElement/createSVGTransform)
     */
    createSVGTransform(): SVGTransform;
    /**
     * The **`createSVGTransformFromMatrix()`** method of the SVGSVGElement interface creates an SVGTransform object outside of any document trees, based on the given DOMMatrix object.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGSVGElement/createSVGTransformFromMatrix)
     */
    createSVGTransformFromMatrix(matrix?: DOMMatrix2DInit): SVGTransform;
    /**
     * The **`deselectAll()`** method of the SVGSVGElement interface unselects any selected objects, including any selections of text strings and type-in bars.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGSVGElement/deselectAll)
     */
    deselectAll(): void;
    /** @deprecated */
    forceRedraw(): void;
    /**
     * The **`getCurrentTime()`** method of the SVGSVGElement interface returns the current time in seconds relative to the start time for the current SVG document fragment.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGSVGElement/getCurrentTime)
     */
    getCurrentTime(): number;
    /**
     * The **`getElementById()`** method of the SVGSVGElement interface searches the SVG document fragment (i.e., the search is restricted to a subset of the document tree) for an Element whose id property matches the specified string.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGSVGElement/getElementById)
     */
    getElementById(elementId: string): Element | null;
    getEnclosureList(rect: DOMRectReadOnly, referenceElement: SVGElement | null): NodeListOf<SVGCircleElement | SVGEllipseElement | SVGImageElement | SVGLineElement | SVGPathElement | SVGPolygonElement | SVGPolylineElement | SVGRectElement | SVGTextElement | SVGUseElement>;
    getIntersectionList(rect: DOMRectReadOnly, referenceElement: SVGElement | null): NodeListOf<SVGCircleElement | SVGEllipseElement | SVGImageElement | SVGLineElement | SVGPathElement | SVGPolygonElement | SVGPolylineElement | SVGRectElement | SVGTextElement | SVGUseElement>;
    /**
     * The **`pauseAnimations()`** method of the SVGSVGElement interface suspends (i.e., pauses) all currently running animations that are defined within the SVG document fragment corresponding to this <svg> element, causing the animation clock corresponding to this document fragment to stand still until it is unpaused.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGSVGElement/pauseAnimations)
     */
    pauseAnimations(): void;
    /**
     * The **`setCurrentTime()`** method of the SVGSVGElement interface adjusts the clock for this SVG document fragment, establishing a new current time.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGSVGElement/setCurrentTime)
     */
    setCurrentTime(seconds: number): void;
    /** @deprecated */
    suspendRedraw(maxWaitMilliseconds: number): number;
    /**
     * The **`unpauseAnimations()`** method of the SVGSVGElement interface resumes (i.e., unpauses) currently running animations that are defined within the SVG document fragment, causing the animation clock to continue from the time at which it was suspended.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGSVGElement/unpauseAnimations)
     */
    unpauseAnimations(): void;
    /** @deprecated */
    unsuspendRedraw(suspendHandleID: number): void;
    /** @deprecated */
    unsuspendRedrawAll(): void;
    addEventListener<K extends keyof SVGSVGElementEventMap>(type: K, listener: (this: SVGSVGElement, ev: SVGSVGElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof SVGSVGElementEventMap>(type: K, listener: (this: SVGSVGElement, ev: SVGSVGElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var SVGSVGElement: {
    prototype: SVGSVGElement;
    new(): SVGSVGElement;
};

/**
 * The **`SVGScriptElement`** interface corresponds to the SVG <script> element.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGScriptElement)
 */
interface SVGScriptElement extends SVGElement, SVGURIReference {
    /**
     * The **`type`** read-only property of the SVGScriptElement interface reflects the type attribute of the given <script> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGScriptElement/type)
     */
    type: string;
    addEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGScriptElement, ev: SVGElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGScriptElement, ev: SVGElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var SVGScriptElement: {
    prototype: SVGScriptElement;
    new(): SVGScriptElement;
};

/**
 * The **`SVGSetElement`** interface corresponds to the <set> element.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGSetElement)
 */
interface SVGSetElement extends SVGAnimationElement {
    addEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGSetElement, ev: SVGElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGSetElement, ev: SVGElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var SVGSetElement: {
    prototype: SVGSetElement;
    new(): SVGSetElement;
};

/**
 * The **`SVGStopElement`** interface corresponds to the <stop> element.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGStopElement)
 */
interface SVGStopElement extends SVGElement {
    /**
     * The **`offset`** read-only property of the SVGStopElement interface reflects the offset attribute of the given <stop> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGStopElement/offset)
     */
    readonly offset: SVGAnimatedNumber;
    addEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGStopElement, ev: SVGElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGStopElement, ev: SVGElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var SVGStopElement: {
    prototype: SVGStopElement;
    new(): SVGStopElement;
};

/**
 * The **`SVGStringList`** interface defines a list of strings.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGStringList)
 */
interface SVGStringList {
    /**
     * The **`length`** property of the SVGStringList interface returns the number of items in the list. It is an alias of numberOfItems to make SVG lists more array-like.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGStringList/length)
     */
    readonly length: number;
    /**
     * The **`numberOfItems`** property of the SVGStringList interface returns the number of items in the list. length is an alias of it.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGStringList/numberOfItems)
     */
    readonly numberOfItems: number;
    /**
     * The **`appendItem()`** method of the SVGStringList interface inserts a new item at the end of the list. If the given item is already in a list, it is removed from its previous list before it is inserted into this list. The inserted item is the item itself and not a copy.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGStringList/appendItem)
     */
    appendItem(newItem: string): string;
    /**
     * The **`clear()`** method of the SVGStringList interface clears all existing items from the list, with the result being an empty list.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGStringList/clear)
     */
    clear(): void;
    /**
     * The **`getItem()`** method of the SVGStringList interface returns the specified item from the list. The returned item is the item itself and not a copy. Any changes made to the item are immediately reflected in the list. The first item is indexed 0.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGStringList/getItem)
     */
    getItem(index: number): string;
    /**
     * The **`initialize()`** method of the SVGStringList interface clears all existing items from the list and re-initializes the list to hold the single item specified by the parameter. If the inserted item is already in a list, it is removed from its previous list before it is inserted into this list. The inserted item is the item itself and not a copy. The return value is the item inserted into the list.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGStringList/initialize)
     */
    initialize(newItem: string): string;
    /**
     * The **`insertItemBefore()`** method of the SVGStringList interface inserts a new item into the list at the specified position. The first item is indexed 0. The inserted item is the item itself and not a copy.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGStringList/insertItemBefore)
     */
    insertItemBefore(newItem: string, index: number): string;
    /**
     * The **`removeItem()`** method of the SVGStringList interface removes an existing item at the given index from the list.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGStringList/removeItem)
     */
    removeItem(index: number): string;
    /**
     * The **`replaceItem()`** method of the SVGStringList interface replaces an existing item in the list with a new item. The inserted item is the item itself and not a copy.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGStringList/replaceItem)
     */
    replaceItem(newItem: string, index: number): string;
    [index: number]: string;
}

declare var SVGStringList: {
    prototype: SVGStringList;
    new(): SVGStringList;
};

/**
 * The **`SVGStyleElement`** interface corresponds to the SVG <style> element.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGStyleElement)
 */
interface SVGStyleElement extends SVGElement, LinkStyle {
    /**
     * The **`SVGStyleElement.disabled`** property can be used to get and set whether the stylesheet is disabled (true) or not (false).
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGStyleElement/disabled)
     */
    disabled: boolean;
    /**
     * The **`SVGStyleElement.media`** property is a media query string corresponding to the media attribute of the given SVG style element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGStyleElement/media)
     */
    media: string;
    /**
     * The **`SVGStyleElement.title`** property is a string corresponding to the title attribute of the given SVG style element. It may be used to select between alternate style sheets.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGStyleElement/title)
     */
    title: string;
    /**
     * The **`SVGStyleElement.type`** property returns the type of the current style. The value reflects the associated SVG <style> element's type attribute.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGStyleElement/type)
     */
    type: string;
    addEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGStyleElement, ev: SVGElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGStyleElement, ev: SVGElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var SVGStyleElement: {
    prototype: SVGStyleElement;
    new(): SVGStyleElement;
};

/**
 * The **`SVGSwitchElement`** interface corresponds to the <switch> element.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGSwitchElement)
 */
interface SVGSwitchElement extends SVGGraphicsElement {
    addEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGSwitchElement, ev: SVGElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGSwitchElement, ev: SVGElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var SVGSwitchElement: {
    prototype: SVGSwitchElement;
    new(): SVGSwitchElement;
};

/**
 * The **`SVGSymbolElement`** interface corresponds to the <symbol> element.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGSymbolElement)
 */
interface SVGSymbolElement extends SVGElement, SVGFitToViewBox {
    addEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGSymbolElement, ev: SVGElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGSymbolElement, ev: SVGElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var SVGSymbolElement: {
    prototype: SVGSymbolElement;
    new(): SVGSymbolElement;
};

/**
 * The **`SVGTSpanElement`** interface represents a <tspan> element.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGTSpanElement)
 */
interface SVGTSpanElement extends SVGTextPositioningElement {
    addEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGTSpanElement, ev: SVGElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGTSpanElement, ev: SVGElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var SVGTSpanElement: {
    prototype: SVGTSpanElement;
    new(): SVGTSpanElement;
};

interface SVGTests {
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGAnimationElement/requiredExtensions) */
    readonly requiredExtensions: SVGStringList;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGAnimationElement/systemLanguage) */
    readonly systemLanguage: SVGStringList;
}
